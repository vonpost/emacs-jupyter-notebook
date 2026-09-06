;;; emacs-jupyter-notebook-inspect.el --- Bounded local slice viewer -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-runtime)
(require 'emacs-jupyter-notebook-helper-protocol)
(require 'emacs-jupyter-notebook-result)

(declare-function emacs-jupyter-notebook--current-cell-key "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-send-cell "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook--execution-record "emacs-jupyter-notebook" (id))

(defcustom emacs-jupyter-notebook-inspector-command nil
  "Explicit local PyQtGraph viewer argv, or nil for the separate Nix output.
The manager appends --stdio. No command is installed on a remote system."
  :type '(choice (const nil) (repeat string)) :group 'emacs-jupyter-notebook)

(cl-defstruct (ejn-inspection (:constructor ejn-inspection-create))
  process stderr decoder ready closed pending active waiter timer drain raw raw-bytes
  partial-timer counter owner cancels stderr-tail spawning build-owner)

(defvar emacs-jupyter-notebook-inspect--state nil)
(defvar emacs-jupyter-notebook-inspect--watches nil)

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
    (setf (ejn-inspection-closed state) t)
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
      (message "EJN viewer: %s%s" reason
               (if (string-empty-p (or (ejn-inspection-stderr-tail state) "")) ""
                 (format " — %.500s" (string-trim
                                      (decode-coding-string (ejn-inspection-stderr-tail state) 'utf-8 t))))))))

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
  (process-send-string
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
        (emacs-jupyter-notebook-inspect--release (ejn-inspection-active state))
        (setf (ejn-inspection-active state) nil (ejn-inspection-timer state) nil)
        (message "EJN viewer: %s" (if success "slice loaded" "image could not be loaded")))
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
  (let* ((state (or emacs-jupyter-notebook-inspect--state
                    (setq emacs-jupyter-notebook-inspect--state
                          (ejn-inspection-create :decoder (ejn-helper-protocol-make-decoder 65536 65536)
                                                 :raw-bytes 0 :counter 0 :owner (current-buffer)))))
         (job (list :lease lease :focus (not no-focus) :owner (current-buffer))))
    (emacs-jupyter-notebook-inspect--release (ejn-inspection-pending state))
    (setf (ejn-inspection-pending state) job)
    (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)
    (when (buffer-live-p (plist-get lease :source-buffer))
      (with-current-buffer (plist-get lease :source-buffer)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)))
    (condition-case err
     (if (ejn-inspection-process state)
        (emacs-jupyter-notebook-inspect--pump state)
      (unless (ejn-inspection-waiter state)
        ;; The build is shared by the current selection, not by the first
        ;; source that happened to trigger it. Superseding A with B must not
        ;; let killing A cancel B's still-live handoff.
        (setf (ejn-inspection-build-owner state)
              (generate-new-buffer " *ejn-inspector-build-owner*"))
        (setf (ejn-inspection-waiter state)
              (emacs-jupyter-notebook-runtime-ensure
               #'emacs-jupyter-notebook-inspect--probe
               (lambda ()
                 (setf (ejn-inspection-waiter state) nil)
                 (emacs-jupyter-notebook-inspect--spawn state)
                 (when (buffer-live-p (ejn-inspection-build-owner state))
                   (kill-buffer (ejn-inspection-build-owner state))))
               (lambda (reason) (emacs-jupyter-notebook-inspect--stop state reason))
               (ejn-inspection-build-owner state) t))))
     ((error quit) (emacs-jupyter-notebook-inspect--stop state (error-message-string err))))
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

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-and-inspect ()
  "Evaluate this cell and inspect its first numerical publication.
Track this execution even if point moves before its output arrives."
  (interactive)
  (let* ((source (current-buffer))
         (id (emacs-jupyter-notebook-send-cell))
         (handle (plist-get (emacs-jupyter-notebook--execution-record id) :panel-entry)))
    (unless handle (user-error "Evaluation did not create an inspectable execution"))
    (setq emacs-jupyter-notebook-inspect--watches
          (cl-remove source emacs-jupyter-notebook-inspect--watches :key #'car))
    (when (>= (length emacs-jupyter-notebook-inspect--watches) 8)
      (setq emacs-jupyter-notebook-inspect--watches
            (butlast emacs-jupyter-notebook-inspect--watches)))
    (push (cons source handle) emacs-jupyter-notebook-inspect--watches)
    (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t)
    (message "EJN viewer: waiting for this execution's numerical output")))

(defun emacs-jupyter-notebook-inspect--published (handle output-id)
  "Schedule only a watched exact HANDLE/OUTPUT-ID, never whatever point now names."
  (when-let ((watch (cl-find handle emacs-jupyter-notebook-inspect--watches
                             :key #'cdr :test #'equal)))
    (setq emacs-jupyter-notebook-inspect--watches (delq watch emacs-jupyter-notebook-inspect--watches))
    (let ((source (car watch)))
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p source)
           (with-current-buffer source
             (when-let ((lease (ejn-panel-acquire-array handle output-id)))
               (emacs-jupyter-notebook-inspect-publication lease)))))))))

(add-hook 'ejn-panel-array-published-hook #'emacs-jupyter-notebook-inspect--published)

(defun emacs-jupyter-notebook-inspect--shutdown ()
  (when emacs-jupyter-notebook-inspect--state
    (emacs-jupyter-notebook-inspect--stop emacs-jupyter-notebook-inspect--state)))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-inspect--shutdown)
(provide 'emacs-jupyter-notebook-inspect)
;;; emacs-jupyter-notebook-inspect.el ends here
