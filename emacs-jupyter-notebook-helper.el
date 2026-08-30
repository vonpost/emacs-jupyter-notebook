;;; emacs-jupyter-notebook-helper.el --- Local helper supervision -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; This module owns only the local helper process and its initial protocol
;; handshake.  It never contacts a kernel, SSH, or the durable registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-helper-protocol)

(defconst emacs-jupyter-notebook-helper--hard-timeout 300)
(defconst emacs-jupyter-notebook-helper--hard-stderr-bytes 1048576)
(defconst emacs-jupyter-notebook-helper--module-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory))))

(cl-defstruct (emacs-jupyter-notebook-helper-session
               (:constructor emacs-jupyter-notebook-helper--make-session))
  id owner-buffer process stderr-process stderr-buffer decoder state hello-id
  hello-timer partial-timer ready-callback failure-callback closed-callback
  failure-emitted disposed)

(defvar-local emacs-jupyter-notebook--helper-session nil
  "The local helper session currently owned by this source buffer.")

(defvar emacs-jupyter-notebook-helper--sessions nil
  "Live local helper sessions, used exclusively for local cleanup.")

(defvar emacs-jupyter-notebook-helper--next-id 0)

(defun emacs-jupyter-notebook-helper--bounded-positive-number (value fallback)
  "Return VALUE when it is a sensible finite timeout, otherwise FALLBACK."
  (if (and (numberp value) (> value 0) (<= value emacs-jupyter-notebook-helper--hard-timeout))
      value
    fallback))

(defun emacs-jupyter-notebook-helper--frame-limit ()
  "Return the configured, protocol-safe complete frame ceiling."
  (let ((value emacs-jupyter-notebook-helper-max-to-emacs-frame))
    (if (and (integerp value) (> value 4)
             (<= value ejn-helper-protocol-max-to-emacs-frame))
        value
      ejn-helper-protocol-max-to-emacs-frame)))

(defun emacs-jupyter-notebook-helper--accumulator-limit (frame-limit)
  "Return the configured, protocol-safe stdout accumulator ceiling."
  (let ((value emacs-jupyter-notebook-helper-raw-accumulator-max-bytes))
    (if (and (integerp value) (>= value frame-limit)
             (<= value ejn-helper-protocol-max-raw-accumulator))
        value
      ejn-helper-protocol-max-raw-accumulator)))

(defun emacs-jupyter-notebook-helper--stderr-limit ()
  "Return the finite stderr retention ceiling."
  (let ((value emacs-jupyter-notebook-helper-stderr-max-bytes))
    (if (and (integerp value) (> value 0)
             (<= value emacs-jupyter-notebook-helper--hard-stderr-bytes))
        value
      65536)))

(defun emacs-jupyter-notebook-helper--source-directory ()
  "Return the physical directory containing this module.
`file-truename' deliberately crosses checkout/build symlinks before command
resolution, while the fallback candidates below retain their normal names."
  emacs-jupyter-notebook-helper--module-directory)

(defun emacs-jupyter-notebook-helper--resolve-program (program)
  "Resolve PROGRAM without depending on `default-directory'."
  (cond
   ((not (and (stringp program) (not (string-empty-p program)))) nil)
   ((file-name-absolute-p program)
    (and (file-executable-p program) (file-truename program)))
   ((file-name-directory program)
    (let ((candidate (expand-file-name program
                                       (emacs-jupyter-notebook-helper--source-directory))))
      (and (file-executable-p candidate) (file-truename candidate))))
   ((executable-find program))
   (t
    (let* ((source (emacs-jupyter-notebook-helper--source-directory))
           (candidates
            (list (expand-file-name (concat "result/bin/" program) source)
                  (expand-file-name (concat "../result/bin/" program) source)
                  (expand-file-name (concat "bin/" program) source))))
      (cl-loop for candidate in candidates
               when (file-executable-p candidate)
               return (file-truename candidate))))))

(defun emacs-jupyter-notebook-helper-resolve-argv (&optional command)
  "Resolve configured helper COMMAND to an executable argv list.
Signals a normal error before starting a process when the configuration is
empty or the executable cannot be found."
  (let ((argv (or command emacs-jupyter-notebook-helper-command)))
    (unless (and (listp argv) (stringp (car argv))
                 (cl-every #'stringp argv))
      (error "Helper command must be a non-empty argv list of strings"))
    (let ((program (emacs-jupyter-notebook-helper--resolve-program (car argv))))
      (unless program
        (error "Cannot resolve helper executable: %s" (car argv)))
      (cons program (cdr argv)))))

(defun emacs-jupyter-notebook-helper--owned-p (session process)
  "Return non-nil when PROCESS may still mutate SESSION's local state."
  (and (not (emacs-jupyter-notebook-helper-session-disposed session))
       (eq process (emacs-jupyter-notebook-helper-session-process session))
       (eq (process-get process 'emacs-jupyter-notebook-helper-session) session)
       (let ((owner (emacs-jupyter-notebook-helper-session-owner-buffer session)))
         (or (null owner)
             (and (buffer-live-p owner)
                  (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner)
                      session))))))

(defun emacs-jupyter-notebook-helper--cancel-timer (timer)
  (when (timerp timer) (cancel-timer timer)))

(defun emacs-jupyter-notebook-helper--run-callback (callback session &optional reason)
  "Run CALLBACK defensively; callback errors must not strand local resources."
  (when callback
    (condition-case err
        (funcall callback session reason)
      (error
       (message "emacs-jupyter-notebook helper callback failed: %s"
                (error-message-string err))))))

(defun emacs-jupyter-notebook-helper--append-stderr (session bytes)
  "Append unibyte BYTES to SESSION's bounded stderr buffer."
  (let ((buffer (emacs-jupyter-notebook-helper-session-stderr-buffer session))
        (limit (emacs-jupyter-notebook-helper--stderr-limit)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              ;; Retain at most LIMIT characters before conversion.  UTF-8 can
              ;; expand this bounded suffix, so apply the byte tail below too.
              (incoming (if (multibyte-string-p bytes)
                            (encode-coding-string
                             (if (> (length bytes) limit)
                                 (substring bytes (- (length bytes) limit))
                               bytes)
                             'binary t)
                          bytes)))
          (set-buffer-multibyte nil)
          ;; Trim both sides before insertion, so one hostile pipe chunk never
          ;; makes this buffer temporarily exceed its hard retention limit.
          (when (> (length incoming) limit)
            (setq incoming (substring incoming (- (length incoming) limit))))
          (let ((room (- limit (length incoming))))
            (when (> (buffer-size) room)
              (delete-region (point-min) (+ (point-min) (- (buffer-size) room)))))
          (goto-char (point-max))
          (insert incoming))))))

(defun emacs-jupyter-notebook-helper--stderr-filter (pipe bytes)
  (let ((session (process-get pipe 'emacs-jupyter-notebook-helper-session)))
    (when (and session
               (not (emacs-jupyter-notebook-helper-session-disposed session)))
      (emacs-jupyter-notebook-helper--append-stderr session bytes))))

(defun emacs-jupyter-notebook-helper--clear-partial-deadline (session)
  (emacs-jupyter-notebook-helper--cancel-timer
   (emacs-jupyter-notebook-helper-session-partial-timer session))
  (setf (emacs-jupyter-notebook-helper-session-partial-timer session) nil))

(defun emacs-jupyter-notebook-helper--partial-deadline (session)
  (let ((process (emacs-jupyter-notebook-helper-session-process session)))
    (when (and (processp process)
               (emacs-jupyter-notebook-helper--owned-p session process)
               (ejn-helper-protocol-decoder-partial-p
                (emacs-jupyter-notebook-helper-session-decoder session)))
      (condition-case nil
          (ejn-helper-protocol-decoder-expire-partial
           (emacs-jupyter-notebook-helper-session-decoder session))
        (error nil))
      (emacs-jupyter-notebook-helper--fail session "partial frame timeout"))))

(defun emacs-jupyter-notebook-helper--update-partial-deadline (session)
  (if (ejn-helper-protocol-decoder-partial-p
       (emacs-jupyter-notebook-helper-session-decoder session))
      (unless (timerp (emacs-jupyter-notebook-helper-session-partial-timer session))
        (setf (emacs-jupyter-notebook-helper-session-partial-timer session)
              (run-at-time
               (emacs-jupyter-notebook-helper--bounded-positive-number
                emacs-jupyter-notebook-helper-partial-frame-timeout 5)
               nil #'emacs-jupyter-notebook-helper--partial-deadline session)))
    (emacs-jupyter-notebook-helper--clear-partial-deadline session)))

(defun emacs-jupyter-notebook-helper--hello-result-p (session object)
  "Validate the one response permitted during SESSION startup."
  (let ((result (gethash "result" object)))
    (and (hash-table-p object)
         (integerp (gethash "v" object))
         (= (gethash "v" object) ejn-helper-protocol-version)
         (equal (gethash "kind" object) "response")
         (equal (gethash "id" object) (emacs-jupyter-notebook-helper-session-hello-id session))
         (eq (gethash "ok" object) t)
         (hash-table-p result)
         (integerp (gethash "version" result))
         (= (gethash "version" result) ejn-helper-protocol-version)
         (stringp (gethash "helper_version" result))
         (vectorp (gethash "capabilities" result)))))

(defun emacs-jupyter-notebook-helper--hello-deadline (session)
  (let ((process (emacs-jupyter-notebook-helper-session-process session)))
    (when (and (processp process)
               (emacs-jupyter-notebook-helper--owned-p session process)
               (eq (emacs-jupyter-notebook-helper-session-state session) 'starting))
      (emacs-jupyter-notebook-helper--fail session "helper hello timed out"))))

(defun emacs-jupyter-notebook-helper--fail (session reason)
  "Fail SESSION once, releasing only its local resources."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (emacs-jupyter-notebook-helper-session-failure-emitted session))
    (let ((failure-callback
           (emacs-jupyter-notebook-helper-session-failure-callback session)))
      (setf (emacs-jupyter-notebook-helper-session-failure-emitted session) t
            (emacs-jupyter-notebook-helper-session-state session) 'failed)
      (emacs-jupyter-notebook-helper-dispose session reason)
      (emacs-jupyter-notebook-helper--run-callback
       failure-callback session reason))))

(defun emacs-jupyter-notebook-helper--handle-startup-object (session object)
  (if (emacs-jupyter-notebook-helper--hello-result-p session object)
      (progn
        (emacs-jupyter-notebook-helper--cancel-timer
         (emacs-jupyter-notebook-helper-session-hello-timer session))
        (setf (emacs-jupyter-notebook-helper-session-hello-timer session) nil
              (emacs-jupyter-notebook-helper-session-state session) 'ready)
        (emacs-jupyter-notebook-helper--run-callback
         (emacs-jupyter-notebook-helper-session-ready-callback session) session))
    (emacs-jupyter-notebook-helper--fail session "invalid helper hello response")))

(defun emacs-jupyter-notebook-helper--filter (process bytes)
  "Incrementally decode PROCESS stdout without waiting for more output."
  (let ((session (process-get process 'emacs-jupyter-notebook-helper-session)))
    (when (and session (emacs-jupyter-notebook-helper--owned-p session process))
      (condition-case err
          (let ((objects (ejn-helper-protocol-decoder-feed
                          (emacs-jupyter-notebook-helper-session-decoder session)
                          (if (multibyte-string-p bytes)
                              (encode-coding-string bytes 'binary t)
                            bytes))))
            (dolist (object objects)
              (if (eq (emacs-jupyter-notebook-helper-session-state session) 'starting)
                  (emacs-jupyter-notebook-helper--handle-startup-object session object)
                ;; ET3 owns all post-handshake request/event dispatch.
                (emacs-jupyter-notebook-helper--fail session "unexpected helper frame")))
            (unless (emacs-jupyter-notebook-helper-session-disposed session)
              (emacs-jupyter-notebook-helper--update-partial-deadline session)))
        (error
         (emacs-jupyter-notebook-helper--fail
          session (format "helper protocol error: %s" (error-message-string err))))))))

(defun emacs-jupyter-notebook-helper--sentinel (process event)
  "Observe a helper exit only while PROCESS is still the session's process."
  (let ((session (process-get process 'emacs-jupyter-notebook-helper-session)))
    (when (and session (emacs-jupyter-notebook-helper--owned-p session process))
      (emacs-jupyter-notebook-helper--fail
       session (format "helper exited: %s" (string-trim event))))))

(defun emacs-jupyter-notebook-helper-dispose (session &optional reason)
  "Release SESSION's local process, timers, pipe, and stderr buffer.
This never sends a protocol operation and never affects any durable state."
  (when (and session (not (emacs-jupyter-notebook-helper-session-disposed session)))
    (let ((closed-callback
           (emacs-jupyter-notebook-helper-session-closed-callback session))
          (hello-timer (emacs-jupyter-notebook-helper-session-hello-timer session))
          (partial-timer (emacs-jupyter-notebook-helper-session-partial-timer session))
          (process (emacs-jupyter-notebook-helper-session-process session))
          (stderr-process (emacs-jupyter-notebook-helper-session-stderr-process session))
          (stderr-buffer (emacs-jupyter-notebook-helper-session-stderr-buffer session))
          (owner (emacs-jupyter-notebook-helper-session-owner-buffer session)))
      (setf (emacs-jupyter-notebook-helper-session-disposed session) t
            (emacs-jupyter-notebook-helper-session-state session) 'disposed
            (emacs-jupyter-notebook-helper-session-hello-timer session) nil
            (emacs-jupyter-notebook-helper-session-partial-timer session) nil
            (emacs-jupyter-notebook-helper-session-process session) nil
            (emacs-jupyter-notebook-helper-session-stderr-process session) nil
            (emacs-jupyter-notebook-helper-session-stderr-buffer session) nil
            (emacs-jupyter-notebook-helper-session-decoder session) nil
            (emacs-jupyter-notebook-helper-session-ready-callback session) nil
            (emacs-jupyter-notebook-helper-session-failure-callback session) nil
            (emacs-jupyter-notebook-helper-session-closed-callback session) nil)
      (emacs-jupyter-notebook-helper--cancel-timer hello-timer)
      (emacs-jupyter-notebook-helper--cancel-timer partial-timer)
      (when (processp process)
        (process-put process 'emacs-jupyter-notebook-helper-session nil)
        (when (process-live-p process) (delete-process process)))
      (when (processp stderr-process)
        (process-put stderr-process 'emacs-jupyter-notebook-helper-session nil)
        (when (process-live-p stderr-process) (delete-process stderr-process)))
      (when (and (buffer-live-p owner)
                 (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner) session))
        (with-current-buffer owner (setq emacs-jupyter-notebook--helper-session nil)))
      (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
      (setf (emacs-jupyter-notebook-helper-session-owner-buffer session) nil)
      (setq emacs-jupyter-notebook-helper--sessions
            (delq session emacs-jupyter-notebook-helper--sessions))
      (emacs-jupyter-notebook-helper--run-callback closed-callback session reason))))

(defun emacs-jupyter-notebook-helper--owner-killed ()
  (when emacs-jupyter-notebook--helper-session
    (emacs-jupyter-notebook-helper-dispose emacs-jupyter-notebook--helper-session "owner buffer killed")))

(defun emacs-jupyter-notebook-helper--mode-hook ()
  "Release a buffer-owned helper when the notebook mode is disabled."
  (when (and (boundp 'emacs-jupyter-notebook-mode)
             (not emacs-jupyter-notebook-mode)
             emacs-jupyter-notebook--helper-session)
    (emacs-jupyter-notebook-helper-dispose emacs-jupyter-notebook--helper-session "mode disabled")))

(defun emacs-jupyter-notebook-helper--kill-emacs ()
  "Dispose every local helper; no kernel operation is involved."
  (dolist (session (copy-sequence emacs-jupyter-notebook-helper--sessions))
    (emacs-jupyter-notebook-helper-dispose session "Emacs exiting")))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-helper--kill-emacs)

;;;###autoload
(cl-defun emacs-jupyter-notebook-helper-start
    (&key buffer command ready-callback failure-callback closed-callback)
  "Start one local helper and asynchronously perform its v1 hello exchange.
BUFFER owns the session when non-nil.  Starting a replacement for the same
buffer disposes the prior local session before the new process is created."
  (let ((owner (or buffer (current-buffer))))
    (unless (buffer-live-p owner)
      (error "Cannot start helper for a dead owner buffer"))
    (let* ((id (cl-incf emacs-jupyter-notebook-helper--next-id))
           (frame-limit (emacs-jupyter-notebook-helper--frame-limit))
           (stderr-buffer (generate-new-buffer (format " *ejn-helper-stderr-%d*" id)))
           (session (emacs-jupyter-notebook-helper--make-session
                     :id id :owner-buffer owner :stderr-buffer stderr-buffer
                     :decoder (ejn-helper-protocol-make-decoder
                               frame-limit
                               (emacs-jupyter-notebook-helper--accumulator-limit frame-limit))
                     :state 'starting :hello-id (format "ejn-hello-%d" id)
                     :ready-callback ready-callback :failure-callback failure-callback
                     :closed-callback closed-callback)))
      (with-current-buffer stderr-buffer (set-buffer-multibyte nil))
      (with-current-buffer owner
        (let ((previous emacs-jupyter-notebook--helper-session))
        ;; Claim ownership before the old close callback can reenter and start
        ;; another session.  A reentrant replacement then supersedes this one.
        (setq emacs-jupyter-notebook--helper-session session)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-helper--owner-killed nil t)
        (when (boundp 'emacs-jupyter-notebook-mode)
          (add-hook 'emacs-jupyter-notebook-mode-hook
                    #'emacs-jupyter-notebook-helper--mode-hook nil t))
          (when previous
            (emacs-jupyter-notebook-helper-dispose previous "superseded"))))
      (when (and (buffer-live-p owner)
                 (not (emacs-jupyter-notebook-helper-session-disposed session))
               (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner)
                   session))
        (push session emacs-jupyter-notebook-helper--sessions)
        (condition-case err
        (let* ((argv (emacs-jupyter-notebook-helper-resolve-argv command))
               (stderr-process
                (make-pipe-process :name (format "ejn-helper-stderr-%d" id)
                                   :buffer stderr-buffer :coding 'binary :noquery t
                                   :filter #'emacs-jupyter-notebook-helper--stderr-filter)))
          ;; The pipe is a local resource as soon as it exists.  Record it
          ;; before `make-process' so its failure path can dispose the pipe.
          (setf (emacs-jupyter-notebook-helper-session-stderr-process session) stderr-process)
          (process-put stderr-process 'emacs-jupyter-notebook-helper-session session)
          (let ((process
                 (make-process :name (format "ejn-helper-%d" id)
                               :command argv :connection-type 'pipe :coding 'binary :noquery t
                               :stderr stderr-process
                               :filter #'emacs-jupyter-notebook-helper--filter
                               :sentinel #'emacs-jupyter-notebook-helper--sentinel)))
            (setf (emacs-jupyter-notebook-helper-session-process session) process)
            (process-put process 'emacs-jupyter-notebook-helper-session session)
            (setf (emacs-jupyter-notebook-helper-session-hello-timer session)
                  (run-at-time
                   (emacs-jupyter-notebook-helper--bounded-positive-number
                    emacs-jupyter-notebook-helper-hello-timeout 5)
                   nil #'emacs-jupyter-notebook-helper--hello-deadline session))
            (let ((params (make-hash-table :test 'equal))
                  (hello (make-hash-table :test 'equal)))
              (puthash "versions" (vector ejn-helper-protocol-version) params)
              (puthash "v" ejn-helper-protocol-version hello)
              (puthash "kind" "request" hello)
              (puthash "id" (emacs-jupyter-notebook-helper-session-hello-id session) hello)
              (puthash "op" "hello" hello)
              (puthash "params" params hello)
              (process-send-string process
                                   (ejn-helper-protocol-encode
                                    hello ejn-helper-protocol-max-to-helper-frame)))))
          (error
           (emacs-jupyter-notebook-helper--fail
            session (format "cannot start helper: %s" (error-message-string err))))))
      session)))

(provide 'emacs-jupyter-notebook-helper)
;;; emacs-jupyter-notebook-helper.el ends here
