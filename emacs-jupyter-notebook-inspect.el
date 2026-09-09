;;; emacs-jupyter-notebook-inspect.el --- Bounded local slice viewer -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-runtime)
(require 'emacs-jupyter-notebook-helper-protocol)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-result)

(declare-function emacs-jupyter-notebook--current-cell-key "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-send-cell "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook--execution-record "emacs-jupyter-notebook" (id))
(declare-function emacs-jupyter-notebook--evaluate-code "emacs-jupyter-notebook"
                  (code cell-key &optional start-profile announce-start options))
(defvar emacs-jupyter-notebook-execution-created-hook)
(declare-function emacs-jupyter-notebook--log-append "emacs-jupyter-notebook" (phase format-string &rest args))

(defcustom emacs-jupyter-notebook-inspector-command nil
  "Explicit local PyQtGraph viewer argv, or nil for the separate Nix output.
The manager appends --stdio. No command is installed on a remote system."
  :type '(choice (const nil) (repeat string)) :group 'emacs-jupyter-notebook)

(cl-defstruct (ejn-inspection (:constructor ejn-inspection-create))
  process stderr decoder ready closed pending active waiter timer drain raw raw-bytes
  partial-timer counter owner cancels stderr-tail spawning build-owner phase)

(defvar emacs-jupyter-notebook-inspect--state nil)
(defvar emacs-jupyter-notebook-inspect--watches nil)
(defvar emacs-jupyter-notebook-inspect--follows nil
  "At most four source/cell/workspace subscriptions for the live viewer.
Each subscription coalesces publications into a single pending timer.")
(defvar emacs-jupyter-notebook-inspect--last-message "Viewer has not been requested")

(defun emacs-jupyter-notebook-inspect--report (state format-string &rest args)
  "Report bounded, redacted viewer feedback to Messages and the EJN log."
  (let* ((raw (apply #'format format-string args))
         (text (emacs-jupyter-notebook-helper--truncate-utf8-bytes
                (replace-regexp-in-string
                 "[[:cntrl:]]" " "
                 (emacs-jupyter-notebook-helper--redact-diagnostic-text
                  (substring raw 0 (min 2048 (length raw)))) t t)
                512))
         (owner (and state (ejn-inspection-owner state))))
    (setq emacs-jupyter-notebook-inspect--last-message text)
    (message "EJN viewer: %s" text)
    ;; Logging must not interfere with ownership/cleanup, including during exit.
    (when (fboundp 'emacs-jupyter-notebook--log-append)
      (ignore-errors
        (with-current-buffer (if (buffer-live-p owner) owner (current-buffer))
          (emacs-jupyter-notebook--log-append 'viewer "%s" text))))))

;;;###autoload
(defun emacs-jupyter-notebook-inspector-status ()
  "Show the local viewer phase and most recent diagnostic, without any I/O."
  (interactive)
  (message "EJN viewer [%s]: %s"
           (if emacs-jupyter-notebook-inspect--state
               (or (ejn-inspection-phase emacs-jupyter-notebook-inspect--state) 'idle)
             'stopped)
           emacs-jupyter-notebook-inspect--last-message))

(defun emacs-jupyter-notebook-inspect--object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun emacs-jupyter-notebook-inspect--live-p (state)
  (and (eq state emacs-jupyter-notebook-inspect--state)
       (not (ejn-inspection-closed state))))

(defun emacs-jupyter-notebook-inspect--release (job)
  (when-let ((release (plist-get (plist-get job :lease) :release)))
    (plist-put job :lease nil)
    (condition-case nil (funcall release) (error nil))))

(defun emacs-jupyter-notebook-inspect--stop (state &optional reason)
  "Revoke this local viewer epoch before releasing any artifact handoffs."
  (unless (ejn-inspection-closed state)
    (setf (ejn-inspection-closed state) t (ejn-inspection-phase state) 'stopped)
    (emacs-jupyter-notebook-inspect--forget-follows
     (lambda (follow) (eq state (plist-get follow :state))))
    (when (eq state emacs-jupyter-notebook-inspect--state)
      (setq emacs-jupyter-notebook-inspect--state nil))
    (dolist (timer (list (ejn-inspection-timer state) (ejn-inspection-drain state)
                        (ejn-inspection-partial-timer state)))
      (when (timerp timer) (ignore-errors (cancel-timer timer))))
    (when (ejn-inspection-waiter state)
      (ignore-errors (emacs-jupyter-notebook-runtime-cancel-waiter (ejn-inspection-waiter state))))
    (when (buffer-live-p (ejn-inspection-build-owner state))
      (ignore-errors (kill-buffer (ejn-inspection-build-owner state))))
    (let ((process (ejn-inspection-process state)))
      (when (processp process)
        (ignore-errors (set-process-sentinel process #'ignore))
        (ignore-errors (when (process-live-p process) (delete-process process)))))
    (let ((stderr (ejn-inspection-stderr state)))
      (when (processp stderr)
        (ignore-errors (set-process-sentinel stderr #'ignore))
        (ignore-errors (when (process-live-p stderr) (delete-process stderr)))))
    (emacs-jupyter-notebook-inspect--release (ejn-inspection-active state))
    (emacs-jupyter-notebook-inspect--release (ejn-inspection-pending state))
    (setf (ejn-inspection-active state) nil (ejn-inspection-pending state) nil
          (ejn-inspection-raw state) nil)
    (when reason
      (let ((tail (or (ejn-inspection-stderr-tail state) "")))
        ;; A full rolling tail may begin inside a credential-bearing line.
        ;; Omit that first line rather than logging a suffix without its key.
        (when (>= (length tail) 8192)
          (setq tail (if (string-match "\n" tail)
                         (substring tail (match-end 0)) "")))
        (emacs-jupyter-notebook-inspect--report
         state "%s%s" reason
         (if (string-empty-p tail) ""
           (format " — %.500s" (string-trim (decode-coding-string tail 'utf-8 t)))))))))

(defun emacs-jupyter-notebook-inspect--command ()
  (if emacs-jupyter-notebook-inspector-command
      (let ((command emacs-jupyter-notebook-inspector-command))
        (unless (and (listp command) (<= (length command) 32)
                     (cl-every #'stringp command)
                     (executable-find (car command)))
          (error "Invalid or unavailable inspector command"))
        command)
    (when emacs-jupyter-notebook-runtime-viewer-directory
      (let ((program (expand-file-name "bin/ejn-viewer"
                                      emacs-jupyter-notebook-runtime-viewer-directory)))
        (when (file-executable-p program) (list program))))))

(defun emacs-jupyter-notebook-inspect--probe ()
  (list :ready (and (emacs-jupyter-notebook-inspect--command) t)
        :buildable (null emacs-jupyter-notebook-inspector-command)))

(defun emacs-jupyter-notebook-inspect--send (state id op params)
  (emacs-jupyter-notebook-process-send
   (ejn-inspection-process state)
   (ejn-helper-protocol-encode
    (emacs-jupyter-notebook-inspect--object "v" 1 "id" id "op" op "params" params)
    65536)))

(defun emacs-jupyter-notebook-inspect--identity (identity)
  "Translate Emacs (inode . device) or (inode device) to (device inode)."
  (let ((inode (car-safe identity))
        (device (if (consp (cdr-safe identity)) (cadr identity) (cdr-safe identity))))
    (unless (and (integerp inode) (integerp device)
                 (<= 0 inode 9007199254740991) (<= 0 device 9007199254740991))
      (error "Invalid local artifact identity"))
    (list device inode)))

(defun emacs-jupyter-notebook-inspect--params (lease focus)
  (let* ((root (emacs-jupyter-notebook-inspect--identity (plist-get lease :root-identity)))
         (file (emacs-jupyter-notebook-inspect--identity (plist-get lease :identity)))
         (params
          (emacs-jupyter-notebook-inspect--object
           "workspace" (plist-get lease :workspace) "generation" (plist-get lease :generation)
           "execution" (plist-get lease :execution) "kind" (symbol-name (plist-get lease :kind))
           "focus" (if focus t :false)
           "artifact" (emacs-jupyter-notebook-inspect--object
                       "root" (directory-file-name (plist-get lease :root))
                       "path" (plist-get lease :file)
                       "root_device" (car root) "root_inode" (cadr root)
                       "device" (car file) "inode" (cadr file)
                       "size" (plist-get lease :size) "sha256" (plist-get lease :sha256)))))
    (when (eq (plist-get lease :kind) 'raster)
      (puthash "mime" (plist-get lease :mime) params))
    params))

(defun emacs-jupyter-notebook-inspect--pump (state)
  (when (and (emacs-jupyter-notebook-inspect--live-p state)
             (ejn-inspection-ready state) (not (ejn-inspection-active state))
             (ejn-inspection-pending state))
    (let* ((job (ejn-inspection-pending state))
           (id (format "open-%d" (cl-incf (ejn-inspection-counter state)))))
      (setf (ejn-inspection-pending state) nil (ejn-inspection-active state) job)
      (setf (ejn-inspection-phase state) 'loading)
      (emacs-jupyter-notebook-inspect--report state "Loading selected images")
      (plist-put job :id id)
      (condition-case err
          (progn
            (setf (ejn-inspection-timer state)
                  (run-at-time 30 nil #'emacs-jupyter-notebook-inspect--stop state
                               "Image loading timed out; no code was replayed"))
            (emacs-jupyter-notebook-inspect--send
             state id "open" (emacs-jupyter-notebook-inspect--params
                               (plist-get job :lease) (plist-get job :focus))))
        (error (emacs-jupyter-notebook-inspect--stop state (error-message-string err)))))))

(defun emacs-jupyter-notebook-inspect--response (state object)
  (unless (and (hash-table-p object) (eql (gethash "v" object) 1)
               (stringp (gethash "id" object)) (memq (gethash "ok" object) '(t :false)))
    (error "Malformed viewer response"))
  (when (eq (gethash "ok" object) :false)
    (let* ((failure (gethash "error" object))
           (code (and (hash-table-p failure) (gethash "code" failure)))
           (text (and (hash-table-p failure) (gethash "message" failure))))
      (unless (and (stringp code) (<= 1 (length code) 64)
                   (stringp text) (<= (length text) 512) (<= (string-bytes text) 512))
        (error "Malformed viewer error"))))
  (let ((id (gethash "id" object)))
    (cond
     ((member id (ejn-inspection-cancels state))
      (setf (ejn-inspection-cancels state) (delete id (ejn-inspection-cancels state))))
     ((and (not (ejn-inspection-ready state)) (equal id "hello"))
      (unless (and (eq (gethash "ok" object) t)
                   (hash-table-p (gethash "result" object))
                   (eql (gethash "version" (gethash "result" object)) 1)
                   (let ((caps (gethash "capabilities" (gethash "result" object))))
                     (and (vectorp caps) (<= (length caps) 32)
                          (cl-every (lambda (cap) (and (stringp cap) (<= 1 (length cap) 64))) caps)
                          (member "array-group-v1" (append caps nil)))))
        (error "Viewer negotiation failed"))
      (when (timerp (ejn-inspection-timer state)) (cancel-timer (ejn-inspection-timer state)))
      (setf (ejn-inspection-timer state) nil (ejn-inspection-ready state) t)
      (emacs-jupyter-notebook-inspect--pump state))
     ((equal id (plist-get (ejn-inspection-active state) :id))
      (when (timerp (ejn-inspection-timer state)) (cancel-timer (ejn-inspection-timer state)))
      (let ((success (eq (gethash "ok" object) t)))
        (when success
          (unless (and (hash-table-p (gethash "result" object))
                       (member (gethash "state" (gethash "result" object)) '("visible" "pending")))
            (error "Viewer did not acknowledge snapshot ownership")))
        (when (and success (eq (gethash "closed" (gethash "result" object)) t))
          (let ((workspace (plist-get (plist-get (ejn-inspection-active state) :lease) :workspace)))
            (emacs-jupyter-notebook-inspect--forget-follows
             (lambda (follow) (and (eq state (plist-get follow :state))
                                   (equal workspace (plist-get follow :workspace)))))))
        (emacs-jupyter-notebook-inspect--release (ejn-inspection-active state))
        (setf (ejn-inspection-active state) nil (ejn-inspection-timer state) nil)
        (setf (ejn-inspection-phase state) 'ready)
        (emacs-jupyter-notebook-inspect--report
         state "%s" (if success
                         (cond ((eq (gethash "closed" (gethash "result" object)) t)
                                "Viewer closed; stopped following")
                               ((eq (gethash "frozen" (gethash "result" object)) t)
                                "Viewer frozen; kept current evaluation")
                               (t "Slice loaded"))
                       (format "Image could not be loaded — %s"
                               (gethash "code" (gethash "error" object))))))
      (emacs-jupyter-notebook-inspect--pump state))
     (t (error "Unexpected viewer response")))))

(defun emacs-jupyter-notebook-inspect--drain (state)
  (setf (ejn-inspection-drain state) nil)
  (when (emacs-jupyter-notebook-inspect--live-p state)
    (condition-case err
        (let ((chunks (ejn-inspection-raw state)))
          (setf (ejn-inspection-raw state) nil (ejn-inspection-raw-bytes state) 0)
          (dolist (chunk chunks)
            (dolist (object (ejn-helper-protocol-decoder-feed (ejn-inspection-decoder state) chunk))
              (when (emacs-jupyter-notebook-inspect--live-p state)
                (emacs-jupyter-notebook-inspect--response state object))))
          (if (ejn-helper-protocol-decoder-partial-p (ejn-inspection-decoder state))
              (unless (timerp (ejn-inspection-partial-timer state))
                (setf (ejn-inspection-partial-timer state)
                      (run-at-time 5 nil #'emacs-jupyter-notebook-inspect--stop state
                                   "Incomplete viewer response")))
            (when (timerp (ejn-inspection-partial-timer state))
              (cancel-timer (ejn-inspection-partial-timer state))
              (setf (ejn-inspection-partial-timer state) nil))))
      (error (emacs-jupyter-notebook-inspect--stop state (error-message-string err))))))

(defun emacs-jupyter-notebook-inspect--filter (state process bytes)
  (when (and (emacs-jupyter-notebook-inspect--live-p state)
             (ejn-inspection-spawning state) (not (ejn-inspection-process state)))
    (setf (ejn-inspection-process state) process))
  (when (and (emacs-jupyter-notebook-inspect--live-p state)
             (eq process (ejn-inspection-process state)))
    (if (> (+ (ejn-inspection-raw-bytes state) (length bytes)) 65536)
        (emacs-jupyter-notebook-inspect--stop state "Viewer output exceeded its budget")
      (cl-incf (ejn-inspection-raw-bytes state) (length bytes))
      (setf (ejn-inspection-raw state) (nconc (ejn-inspection-raw state) (list bytes)))
      (unless (timerp (ejn-inspection-drain state))
        (setf (ejn-inspection-drain state)
              (run-at-time 0 nil #'emacs-jupyter-notebook-inspect--drain state))))))

(defun emacs-jupyter-notebook-inspect--spawn (state)
  (when (emacs-jupyter-notebook-inspect--live-p state)
    (condition-case err
        (let ((command (emacs-jupyter-notebook-inspect--command)))
          (unless command (error "Viewer executable is unavailable after build"))
          (setf (ejn-inspection-phase state) 'starting)
          (emacs-jupyter-notebook-inspect--report state "Starting local viewer")
          (setf (ejn-inspection-stderr state)
                (make-pipe-process
                 :name "ejn-inspector-stderr" :buffer nil :noquery t :coding 'binary
                 :filter (lambda (_process bytes)
                           (when (emacs-jupyter-notebook-inspect--live-p state)
                             (let ((tail (concat (or (ejn-inspection-stderr-tail state) "")
                                                 (substring bytes (max 0 (- (length bytes) 8192))))))
                               (setf (ejn-inspection-stderr-tail state)
                                     (substring tail (max 0 (- (length tail) 8192)))))))))
          (setf (ejn-inspection-spawning state) t)
          (let ((process
                 (make-process
                  :name "ejn-inspector" :command (append command '("--stdio"))
                  :connection-type 'pipe :coding 'binary :noquery t :buffer nil :stderr (ejn-inspection-stderr state)
                  :filter (lambda (process bytes) (emacs-jupyter-notebook-inspect--filter state process bytes))
                  :sentinel (lambda (process _event)
                              (when (and (emacs-jupyter-notebook-inspect--live-p state)
                                         (ejn-inspection-spawning state)
                                         (not (ejn-inspection-process state)))
                                (setf (ejn-inspection-process state) process))
                              (when (and (emacs-jupyter-notebook-inspect--live-p state)
                                         (eq process (ejn-inspection-process state))
                                         (not (process-live-p process)))
                                (emacs-jupyter-notebook-inspect--stop state "Local viewer exited"))))))
            (setf (ejn-inspection-spawning state) nil)
            (if (not (emacs-jupyter-notebook-inspect--live-p state))
                (when (process-live-p process) (delete-process process))
             (setf (ejn-inspection-process state) process
                  (ejn-inspection-timer state)
                  (run-at-time 15 nil #'emacs-jupyter-notebook-inspect--stop state
                               "Viewer startup timed out"))
            (emacs-jupyter-notebook-inspect--send state "hello" "hello"
                                                (emacs-jupyter-notebook-inspect--object)))))
      (error (emacs-jupyter-notebook-inspect--stop state (error-message-string err))))))

;;;###autoload
(defun emacs-jupyter-notebook-inspect-publication (lease &optional no-focus)
  "Inspect exact acquired LEASE asynchronously, taking ownership of its release.
At most one handoff and one latest pending selection are retained."
  (unless (functionp (plist-get lease :release)) (error "Inspection requires an acquired artifact lease"))
  ;; A stale waiter token must not swallow every later explicit Inspect.
  ;; Revoke the old epoch before rebuilding so late callbacks cannot adopt it.
  (when-let ((old emacs-jupyter-notebook-inspect--state))
    (when (or (ejn-inspection-closed old)
              (and (ejn-inspection-process old)
                   (not (process-live-p (ejn-inspection-process old))))
              (and (ejn-inspection-waiter old)
                   (not (ejn-inspection-process old))
                   (not (emacs-jupyter-notebook-runtime-waiter-active-p
                         (ejn-inspection-waiter old) t))))
      (emacs-jupyter-notebook-inspect--stop old "Recovering stale local viewer startup")
      (when (eq old emacs-jupyter-notebook-inspect--state)
        (setq emacs-jupyter-notebook-inspect--state nil))))
  (let* ((state (or emacs-jupyter-notebook-inspect--state
                    (setq emacs-jupyter-notebook-inspect--state
                          (ejn-inspection-create :decoder (ejn-helper-protocol-make-decoder 65536 65536)
                                                 :raw-bytes 0 :counter 0 :owner (current-buffer)))))
         (job (list :lease lease :focus (not no-focus) :owner (current-buffer))))
    (if (and no-focus (plist-get (ejn-inspection-pending state) :focus))
        ;; An automatic update must not replace the user's exact explicit
        ;; selection while another image is loading. Release its lease now.
        (emacs-jupyter-notebook-inspect--release job)
      (progn
	(unless no-focus
	  (emacs-jupyter-notebook-inspect--remember-follow lease state))
	(setf (ejn-inspection-owner state)
              (if (buffer-live-p (plist-get lease :source-buffer))
		  (plist-get lease :source-buffer) (current-buffer)))
	(emacs-jupyter-notebook-inspect--release (ejn-inspection-pending state))
	(setf (ejn-inspection-pending state) job)
	(add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)
	(when (buffer-live-p (plist-get lease :source-buffer))
	  (with-current-buffer (plist-get lease :source-buffer)
            (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)))
	(condition-case err
	    (if (ejn-inspection-process state)
		(progn
		  (emacs-jupyter-notebook-inspect--report
		   state "%s" (cond ((not (ejn-inspection-ready state)) "Waiting for viewer startup")
				    ((ejn-inspection-active state) "Image selection queued")
				    (t "Inspecting selected images")))
		  (emacs-jupyter-notebook-inspect--pump state))
	      (if (ejn-inspection-waiter state)
		  (emacs-jupyter-notebook-inspect--report state "Waiting for viewer build")
		;; The build is shared by the current selection, not by the first
		;; source that happened to trigger it. Superseding A with B must not
		;; let killing A cancel B's still-live handoff.
		(setf (ejn-inspection-build-owner state)
		      (generate-new-buffer " *ejn-inspector-build-owner*"))
		(setf (ejn-inspection-phase state) 'building)
		(emacs-jupyter-notebook-inspect--report
		 state "%s" (if (emacs-jupyter-notebook-inspect--command)
				"Using available local viewer"
			      "Building local viewer via Nix (.#ejn-viewer)"))
		(let ((token
		       (emacs-jupyter-notebook-runtime-ensure
			#'emacs-jupyter-notebook-inspect--probe
			(lambda ()
			  (setf (ejn-inspection-waiter state) nil)
			  (emacs-jupyter-notebook-inspect--spawn state)
			  (when (buffer-live-p (ejn-inspection-build-owner state))
			    (kill-buffer (ejn-inspection-build-owner state))))
			(lambda (reason) (emacs-jupyter-notebook-inspect--stop state reason))
			(ejn-inspection-build-owner state) t
			(lambda (_buffer line)
			  (when (emacs-jupyter-notebook-inspect--live-p state)
			    (emacs-jupyter-notebook-inspect--report state "Nix — %s" line))))))
		  ;; Ready/failure callbacks may fire before ensure returns.
		  (when (and (emacs-jupyter-notebook-inspect--live-p state)
			     (not (ejn-inspection-process state)))
		    (setf (ejn-inspection-waiter state) token)))))
	  ((error quit) (emacs-jupyter-notebook-inspect--stop state (error-message-string err))))))
    state))

;;;###autoload
(defun emacs-jupyter-notebook-inspect-images ()
  "Open the selected panel publication or current cell's latest numerical output."
  (interactive)
  (let ((lease (if (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
                   (emacs-jupyter-notebook-panel-acquire-array-at-point)
                 (emacs-jupyter-notebook-panel-acquire-array-for-cell
                  (current-buffer) (emacs-jupyter-notebook--current-cell-key)))))
    (unless lease (user-error "No numerical output here; publish selected slices with ejn.view"))
    (emacs-jupyter-notebook-inspect-publication lease)))

(defun emacs-jupyter-notebook-inspect--owner-killed ()
  (emacs-jupyter-notebook-inspect--forget-follows
   (lambda (follow) (or (eq (current-buffer) (plist-get follow :source))
                        (eq (current-buffer) (plist-get follow :panel)))))
  (setq emacs-jupyter-notebook-inspect--watches
        (cl-remove (current-buffer) emacs-jupyter-notebook-inspect--watches :key #'car))
  (when-let ((state emacs-jupyter-notebook-inspect--state))
    (cl-labels ((owned (job)
                  (or (eq (current-buffer) (plist-get job :owner))
                      (eq (current-buffer) (plist-get (plist-get job :lease) :source-buffer)))))
      (when (owned (ejn-inspection-pending state))
        (emacs-jupyter-notebook-inspect--release (ejn-inspection-pending state))
        (setf (ejn-inspection-pending state) nil))
      (cond
       ((and (not (ejn-inspection-ready state)) (not (ejn-inspection-process state))
             (not (ejn-inspection-pending state)))
        (emacs-jupyter-notebook-inspect--stop state))
       ((and (owned (ejn-inspection-active state))
             (not (plist-get (ejn-inspection-active state) :cancelled)))
        (let* ((job (ejn-inspection-active state))
               (cancel-id (concat "cancel-" (plist-get job :id))))
          (plist-put job :cancelled t)
          (when (>= (length (ejn-inspection-cancels state)) 8)
            (emacs-jupyter-notebook-inspect--stop state "Too many unacknowledged cancellations"))
          (push cancel-id (ejn-inspection-cancels state))
          (condition-case err
              (when (emacs-jupyter-notebook-inspect--live-p state)
                (emacs-jupyter-notebook-inspect--send
                 state cancel-id "cancel" (emacs-jupyter-notebook-inspect--object "id" (plist-get job :id))))
            (error (emacs-jupyter-notebook-inspect--stop state (error-message-string err))))))))))

(defun emacs-jupyter-notebook-inspect--watch-record (record)
  "Watch RECORD before it can dispatch, retaining only one watch per source."
  (let ((source (current-buffer)) (handle (plist-get record :panel-entry)))
    (unless handle (error "Inspection requires a reserved execution"))
    (setq emacs-jupyter-notebook-inspect--watches
          (cl-remove source emacs-jupyter-notebook-inspect--watches :key #'car))
    (when (>= (length emacs-jupyter-notebook-inspect--watches) 8)
      (setq emacs-jupyter-notebook-inspect--watches
            (butlast emacs-jupyter-notebook-inspect--watches)))
    (push (cons source handle) emacs-jupyter-notebook-inspect--watches)
    (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)))

(defun emacs-jupyter-notebook-inspect-evaluate (code title)
  "Queue generated variable inspection CODE under TITLE and open its output.
Uses the ordinary FIFO/artifact path, with input history disabled.  Source
text is never edited, and the exact output watch exists before dispatch."
  (emacs-jupyter-notebook--evaluate-code
   code nil nil nil
   (list :title title :inspection t
         :on-created #'emacs-jupyter-notebook-inspect--watch-record)))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-and-inspect ()
  "Evaluate this cell and inspect its first numerical publication.
Track this execution even if point moves before its output arrives."
  (interactive)
  (let ((emacs-jupyter-notebook-execution-created-hook
         (cons #'emacs-jupyter-notebook-inspect--watch-record
               emacs-jupyter-notebook-execution-created-hook)))
    (emacs-jupyter-notebook-send-cell)
    (message "EJN viewer: waiting for this execution's numerical output")))

(defun emacs-jupyter-notebook-inspect--forget-follows (predicate)
  "Cancel and remove subscriptions satisfying PREDICATE."
  (setq emacs-jupyter-notebook-inspect--follows
        (cl-delete-if
         (lambda (follow)
           (when (funcall predicate follow)
             (when (timerp (plist-get follow :timer))
               (cancel-timer (plist-get follow :timer)))
             t))
         emacs-jupyter-notebook-inspect--follows)))

(defun emacs-jupyter-notebook-inspect--remember-follow (lease state)
  "Follow future publications for LEASE's exact source cell in STATE."
  (let ((source (plist-get lease :source-buffer))
        (key (plist-get lease :cell-key))
        (workspace (plist-get lease :workspace))
        (panel (plist-get (plist-get lease :entry-handle) :panel)))
    (when (and (buffer-live-p source) key (stringp workspace))
      (emacs-jupyter-notebook-inspect--forget-follows
       (lambda (follow) (equal workspace (plist-get follow :workspace))))
      (when (>= (length emacs-jupyter-notebook-inspect--follows) 4)
        (let ((old (car (last emacs-jupyter-notebook-inspect--follows))))
          (emacs-jupyter-notebook-inspect--forget-follows
           (lambda (follow) (eq follow old)))))
      (push (list :source source :cell-key key :workspace workspace :state state
                  :panel panel
                  :generation (plist-get lease :generation) :timer nil :latest nil)
            emacs-jupyter-notebook-inspect--follows)
      (when (buffer-live-p panel)
        (with-current-buffer panel
          (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t))))))

(defun emacs-jupyter-notebook-inspect--schedule-follow (follow handle output-id)
  "Coalesce FOLLOW's latest exact HANDLE/OUTPUT-ID, without taking focus."
  (plist-put follow :latest (cons handle output-id))
  (unless (timerp (plist-get follow :timer))
    (plist-put
     follow :timer
     (run-at-time
      0 nil
      (lambda ()
        (plist-put follow :timer nil)
        (let ((source (plist-get follow :source))
              (selection (plist-get follow :latest)))
          (plist-put follow :latest nil)
          (when (and (memq follow emacs-jupyter-notebook-inspect--follows)
                     (buffer-live-p source)
                     (emacs-jupyter-notebook-inspect--live-p (plist-get follow :state)))
            (with-current-buffer source
              (when-let ((lease (ejn-panel-acquire-array (car selection) (cdr selection))))
                (if (equal (plist-get lease :workspace) (plist-get follow :workspace))
                    (emacs-jupyter-notebook-inspect-publication lease t)
                  (funcall (plist-get lease :release))))))))))))

(defun emacs-jupyter-notebook-inspect--published (handle output-id)
  "Schedule exact HANDLE/OUTPUT-ID for an explicit watch or followed workspace."
  (if-let ((watch (cl-find handle emacs-jupyter-notebook-inspect--watches
                           :key #'cdr :test #'equal)))
      (progn
        (setq emacs-jupyter-notebook-inspect--watches
              (delq watch emacs-jupyter-notebook-inspect--watches))
        (let ((source (car watch)))
          (run-at-time
           0 nil
           (lambda ()
             (when (buffer-live-p source)
               (with-current-buffer source
                 (when-let ((lease (ejn-panel-acquire-array handle output-id)))
                   (emacs-jupyter-notebook-inspect-publication lease))))))))
    (let* ((panel (plist-get handle :panel))
           (source (and (buffer-live-p panel)
                        (buffer-local-value 'emacs-jupyter-notebook-panel--source-buffer panel)))
           (entry (ejn-panel-entry-snapshot handle))
           (artifact (cdr (cl-find-if
                           (lambda (segment)
                             (and (eq (car segment) 'array)
                                  (equal output-id (plist-get (cdr segment) :output-id))))
                           (plist-get entry :outputs)))))
      (dolist (follow emacs-jupyter-notebook-inspect--follows)
        (when (and (eq source (plist-get follow :source))
                   (eq panel (plist-get follow :panel))
                   (equal (plist-get handle :cell-key) (plist-get follow :cell-key))
                   (equal (plist-get artifact :workspace) (plist-get follow :workspace))
                   (equal (plist-get handle :generation) (plist-get follow :generation)))
          (emacs-jupyter-notebook-inspect--schedule-follow follow handle output-id))))))

(add-hook 'ejn-panel-array-published-hook #'emacs-jupyter-notebook-inspect--published)

(defun emacs-jupyter-notebook-inspect--shutdown ()
  (when emacs-jupyter-notebook-inspect--state
    (emacs-jupyter-notebook-inspect--stop emacs-jupyter-notebook-inspect--state)))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-inspect--shutdown)
(provide 'emacs-jupyter-notebook-inspect)
;;; emacs-jupyter-notebook-inspect.el ends here
