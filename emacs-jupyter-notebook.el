;;; emacs-jupyter-notebook.el --- Remote Jupyter kernels for local source files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (jupyter "1.0"))
;; Keywords: tools, languages, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Edit normal local source files, evaluate # %% style cells against a
;; remote Jupyter kernel, and reconnect through a durable local registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-cell)
(require 'emacs-jupyter-notebook-registry)
(require 'emacs-jupyter-notebook-connection)
(require 'emacs-jupyter-notebook-ssh)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-jupyter)

(defvar-local emacs-jupyter-notebook--client nil
  "Current buffer's emacs-jupyter client object.")

(defvar-local emacs-jupyter-notebook--session-entry nil
  "Current buffer's registry entry plist.")

(defvar-local emacs-jupyter-notebook--tunnel-process nil
  "Current buffer's SSH tunnel process.")

(defvar-local emacs-jupyter-notebook--async-context nil
  "Current buffer's in-progress async start or reconnect context.")

(defvar emacs-jupyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-jupyter-notebook-evaluate-current-cell)
    (define-key map (kbd "C-c C-r") #'emacs-jupyter-notebook-evaluate-region)
    (define-key map (kbd "C-c C-b") #'emacs-jupyter-notebook-evaluate-buffer)
    (define-key map (kbd "C-c C-k") #'emacs-jupyter-notebook-interrupt-kernel)
    (define-key map (kbd "C-c C-s") #'emacs-jupyter-notebook-start-remote-kernel)
    (define-key map (kbd "C-c C-n") #'emacs-jupyter-notebook-reconnect-remote-kernel)
    (define-key map (kbd "C-c C-l") #'emacs-jupyter-notebook-clear-results)
    (define-key map (kbd "C-c C-x") #'emacs-jupyter-notebook-cancel-operation)
    map)
  "Keymap for `emacs-jupyter-notebook-mode'.")

;;;###autoload
(define-minor-mode emacs-jupyter-notebook-mode
  "Minor mode for evaluating local source cells in remote Jupyter kernels."
  :lighter " EJN"
  :keymap emacs-jupyter-notebook-mode-map)

(defun emacs-jupyter-notebook--new-session-id ()
  "Return a locally unique session id string."
  (md5 (format "%s:%s:%s:%s"
               (current-time-string) (float-time) (random) (emacs-pid))))

(defun emacs-jupyter-notebook--timestamp ()
  "Return an ISO-like timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun emacs-jupyter-notebook--read-profile-name ()
  "Read a profile name for interactive commands."
  (let ((names (mapcar (lambda (entry) (format "%s" (car entry)))
                       emacs-jupyter-notebook-remote-profiles)))
    (if names
        (completing-read "Remote profile: " names nil nil nil nil
                         emacs-jupyter-notebook-default-profile)
      emacs-jupyter-notebook-default-profile)))

(defun emacs-jupyter-notebook--read-host-profile (profile-name)
  "Return PROFILE-NAME profile, prompting for :host if needed."
  (let ((profile (emacs-jupyter-notebook-ssh-profile profile-name)))
    (unless (or (plist-get profile :host) (plist-get profile :remote-host))
      (setq profile (plist-put profile :host (read-string "Remote host: "))))
    profile))

(defun emacs-jupyter-notebook--parse-pid (output)
  "Parse a remote background PID from OUTPUT."
  (when (string-match "[0-9]+" output)
    (string-to-number (match-string 0 output))))

(defun emacs-jupyter-notebook--retrieve-connection-file (profile remote-file local-file)
  "Retrieve REMOTE-FILE for PROFILE into LOCAL-FILE using scp.
Poll until the file is present and parseable or attempts are exhausted."
  (let ((argv (emacs-jupyter-notebook-ssh-scp-from-command
               profile remote-file local-file))
        (attempt 0)
        last-error
        connection)
    (while (and (< attempt emacs-jupyter-notebook-connection-retrieve-attempts)
                (not connection))
      (setq attempt (1+ attempt))
      (condition-case err
          (emacs-jupyter-notebook-ssh-run-command argv)
        (error (setq last-error err)))
      (when (file-readable-p local-file)
        (condition-case err
            (setq connection
                  (emacs-jupyter-notebook-connection-read-file local-file))
          (error (setq last-error err))))
      (unless connection
        (sleep-for emacs-jupyter-notebook-connection-retrieve-delay)))
    (unless connection
      (error "Could not retrieve remote connection file %s: %s"
             remote-file (if last-error (error-message-string last-error) "not found")))
    connection))

(defun emacs-jupyter-notebook--start-tunnel (profile remote-ports local-ports session-id)
  "Start an SSH tunnel for PROFILE from LOCAL-PORTS to REMOTE-PORTS."
  (let* ((argv (emacs-jupyter-notebook-ssh-tunnel-command
                profile remote-ports local-ports))
         (name (format "emacs-jupyter-notebook-tunnel-%s" session-id)))
    (emacs-jupyter-notebook-ssh-start-process
     name argv
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (message "Jupyter tunnel %s: %s" process (string-trim event)))))))

(defun emacs-jupyter-notebook--local-port-open-p (port)
  "Return non-nil when PORT accepts a TCP connection on localhost."
  (condition-case nil
      (let ((proc (open-network-stream
                   (format "emacs-jupyter-notebook-port-%s" port)
                   nil "127.0.0.1" port)))
        (delete-process proc)
        t)
    (error nil)))

(defun emacs-jupyter-notebook--wait-for-tunnel (process local-ports)
  "Wait until PROCESS has opened all LOCAL-PORTS.
Signal an error when the tunnel exits or the timeout expires."
  (let ((deadline (+ (float-time) emacs-jupyter-notebook-tunnel-wait-timeout))
        pending)
    (while (progn
             (setq pending
                   (cl-remove-if
                    (lambda (key)
                      (emacs-jupyter-notebook--local-port-open-p
                       (plist-get local-ports key)))
                    emacs-jupyter-notebook-connection-port-keys))
             (and pending (< (float-time) deadline)))
      (unless (process-live-p process)
        (error "Jupyter SSH tunnel exited before ports were ready"))
      (sleep-for emacs-jupyter-notebook-tunnel-wait-delay))
    (when pending
      (error "Timed out waiting for Jupyter SSH tunnel ports: %s"
             (mapconcat #'symbol-name pending ", ")))
    t))

(defun emacs-jupyter-notebook--process-output (process)
  "Return PROCESS output buffer contents."
  (if-let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (buffer-string)))
    ""))

(defun emacs-jupyter-notebook--async-new-context (&rest properties)
  "Return a new async operation context initialized with PROPERTIES."
  (let ((context (list :phase nil
                       :profile nil
                       :entry nil
                       :session-id nil
                       :launch nil
                       :launch-process nil
                       :scp-process nil
                       :scp-attempt 0
                       :tunnel-process nil
                       :local-ports nil
                       :remote-ports nil
                       :connection nil
                       :remote-copy nil
                       :local-file nil
                       :timer nil
                       :deadline nil
                       :callback nil
                       :error-callback nil
                       :origin-buffer nil
                       :owns-kernel nil
                       :error nil)))
    (while properties
      (setq context (plist-put context (pop properties) (pop properties))))
    context))

(defun emacs-jupyter-notebook--async-put (context property value)
  "Set PROPERTY to VALUE in async CONTEXT and store it in its buffer."
  (setq context (plist-put context property value))
  (when-let* ((buffer (plist-get context :origin-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-jupyter-notebook--async-context context))))
  context)

(defun emacs-jupyter-notebook--async-buffer-live-p (context)
  "Return non-nil when CONTEXT's origin buffer is live."
  (buffer-live-p (plist-get context :origin-buffer)))

(defun emacs-jupyter-notebook--async-message (_context format-string &rest args)
  "Report async progress using FORMAT-STRING and ARGS."
  (apply #'message (concat "emacs-jupyter-notebook: " format-string) args))

(defun emacs-jupyter-notebook--async-cancel-timer (context)
  "Cancel CONTEXT's timer if present."
  (when-let* ((timer (plist-get context :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (emacs-jupyter-notebook--async-put context :timer nil))

(defun emacs-jupyter-notebook--async-delete-process (process)
  "Delete PROCESS and its buffers when PROCESS is live."
  (when (processp process)
    (when (process-live-p process)
      (delete-process process))
    (when-let* ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun emacs-jupyter-notebook--async-delete-file (file)
  "Delete FILE if it exists."
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun emacs-jupyter-notebook--async-kill-remote-kernel (context)
  "Start a best-effort asynchronous remote-kernel cleanup for CONTEXT."
  (when (plist-get context :owns-kernel)
    (when-let* ((entry (plist-get context :entry))
                (connection-file (plist-get entry :remote-connection-file)))
      (ignore-errors
        (emacs-jupyter-notebook-ssh-start-process
         (format "emacs-jupyter-notebook-cleanup-%s"
                 (or (plist-get context :session-id) "kernel"))
         (emacs-jupyter-notebook-ssh-build-remote-cleanup
          (plist-get context :profile) connection-file))))))

(defun emacs-jupyter-notebook--cleanup-remote-entry (entry)
  "Start best-effort asynchronous cleanup for remote kernel ENTRY."
  (when-let* ((connection-file (plist-get entry :remote-connection-file)))
    (ignore-errors
      (emacs-jupyter-notebook-ssh-start-process
       (format "emacs-jupyter-notebook-cleanup-%s"
               (or (plist-get entry :session-id) "kernel"))
       (emacs-jupyter-notebook-ssh-build-remote-cleanup
        (emacs-jupyter-notebook--entry-profile entry) connection-file)))))

(defun emacs-jupyter-notebook--async-fail (context error-data)
  "Move CONTEXT to error state with ERROR-DATA and clean up."
  (setq context (emacs-jupyter-notebook--async-put context :phase 'error))
  (setq context (emacs-jupyter-notebook--async-put context :error error-data))
  (setq context (emacs-jupyter-notebook--async-cancel-timer context))
  (emacs-jupyter-notebook--async-delete-process (plist-get context :launch-process))
  (emacs-jupyter-notebook--async-delete-process (plist-get context :scp-process))
  (emacs-jupyter-notebook--async-delete-process (plist-get context :tunnel-process))
  (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
  (emacs-jupyter-notebook--async-delete-file (plist-get context :local-file))
  (emacs-jupyter-notebook--async-kill-remote-kernel context)
  (if-let ((callback (plist-get context :error-callback)))
      (funcall callback context error-data)
    (display-warning 'emacs-jupyter-notebook
                     (format "%s" error-data)))
  context)

(defun emacs-jupyter-notebook--async-process-failed-p (process)
  "Return non-nil when PROCESS exited unsuccessfully."
  (or (eq (process-status process) 'signal)
      (not (zerop (process-exit-status process)))))

(defun emacs-jupyter-notebook--async-launch (context)
  "Asynchronously launch the remote kernel for CONTEXT."
  (let* ((launch (plist-get context :launch))
         (session-id (plist-get context :session-id))
         (process
          (emacs-jupyter-notebook-ssh-start-process
           (format "emacs-jupyter-notebook-launch-%s" session-id)
           (plist-get launch :argv)
           (lambda (process _event)
             (emacs-jupyter-notebook--async-launch-sentinel context process)))))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'launch))
    (setq context (emacs-jupyter-notebook--async-put context :launch-process process))
    (emacs-jupyter-notebook--async-message context "starting remote kernel %s" session-id)
    context))

(defun emacs-jupyter-notebook--async-launch-sentinel (context process)
  "Advance CONTEXT after remote launch PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (if (emacs-jupyter-notebook--async-process-failed-p process)
        (emacs-jupyter-notebook--async-fail
         context (format "Remote kernel launch failed: %s"
                         (emacs-jupyter-notebook--process-output process)))
      (let ((pid (emacs-jupyter-notebook--parse-pid
                  (emacs-jupyter-notebook--process-output process))))
        (if (not pid)
            (emacs-jupyter-notebook--async-fail
             context "Remote kernel launch did not report a PID")
          (let ((entry (plist-put (copy-sequence (plist-get context :entry))
                                  :remote-pid pid)))
            (setq context (emacs-jupyter-notebook--async-put context :entry entry))
            (emacs-jupyter-notebook--async-retrieve context)))))))

(defun emacs-jupyter-notebook--async-retrieve (context)
  "Begin asynchronous connection-file retrieval for CONTEXT."
  (unless (plist-get context :remote-copy)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :remote-copy
           (make-temp-file "emacs-jupyter-notebook-remote-" nil ".json"))))
  (unless (plist-get context :local-file)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :local-file
           (make-temp-file "emacs-jupyter-notebook-local-" nil ".json"))))
  (setq context (emacs-jupyter-notebook--async-put context :phase 'retrieve))
  (emacs-jupyter-notebook--async-retrieve-attempt context))

(defun emacs-jupyter-notebook--async-retrieve-attempt (context)
  "Start one asynchronous SCP attempt for CONTEXT."
  (let ((attempt (1+ (or (plist-get context :scp-attempt) 0))))
    (if (> attempt emacs-jupyter-notebook-connection-retrieve-attempts)
        (emacs-jupyter-notebook--async-fail
         context "Timed out retrieving remote Jupyter connection file")
      (let* ((entry (plist-get context :entry))
             (argv (emacs-jupyter-notebook-ssh-scp-from-command
                    (plist-get context :profile)
                    (plist-get entry :remote-connection-file)
                    (plist-get context :remote-copy)))
             process)
        (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
        (setq context (emacs-jupyter-notebook--async-put context :scp-attempt attempt))
        (setq process
              (emacs-jupyter-notebook-ssh-start-process
               (format "emacs-jupyter-notebook-scp-%s"
                       (plist-get context :session-id))
               argv
               (lambda (process _event)
                 (emacs-jupyter-notebook--async-scp-sentinel context process))))
        (setq context (emacs-jupyter-notebook--async-put context :scp-process process))
        (emacs-jupyter-notebook--async-message
         context "retrieving connection file, attempt %d" attempt)
        context))))

(defun emacs-jupyter-notebook--async-retrieve-retry (context reason)
  "Schedule another connection-file retrieval for CONTEXT because of REASON."
  (if (>= (or (plist-get context :scp-attempt) 0)
          emacs-jupyter-notebook-connection-retrieve-attempts)
      (emacs-jupyter-notebook--async-fail context reason)
    (let ((timer (run-at-time
                  emacs-jupyter-notebook-connection-retrieve-delay nil
                  #'emacs-jupyter-notebook--async-retrieve-attempt context)))
      (emacs-jupyter-notebook--async-put context :timer timer))))

(defun emacs-jupyter-notebook--async-scp-sentinel (context process)
  "Advance CONTEXT after SCP PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (cond
     ((emacs-jupyter-notebook--async-process-failed-p process)
      (emacs-jupyter-notebook--async-retrieve-retry
       context (format "SCP failed: %s"
                       (emacs-jupyter-notebook--process-output process))))
     (t
      (condition-case err
          (let* ((connection
                  (emacs-jupyter-notebook-connection-read-file
                   (plist-get context :remote-copy)))
                 (remote-ports
                  (emacs-jupyter-notebook-connection-ports connection)))
            (emacs-jupyter-notebook--async-delete-file
             (plist-get context :remote-copy))
            (setq context (emacs-jupyter-notebook--async-put
                           context :connection connection))
            (setq context (emacs-jupyter-notebook--async-put
                           context :remote-ports remote-ports))
            (emacs-jupyter-notebook--async-tunnel context))
        (error
         (emacs-jupyter-notebook--async-retrieve-retry
          context (error-message-string err))))))))

(defun emacs-jupyter-notebook--async-tunnel (context)
  "Start local SSH tunnels for CONTEXT."
  (let* ((connection (plist-get context :connection))
         (remote-ports (plist-get context :remote-ports))
         (local-ports (emacs-jupyter-notebook-connection-allocate-local-ports))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports
                     connection local-ports))
         (tunnel (emacs-jupyter-notebook--start-tunnel
                  (plist-get context :profile)
                  remote-ports local-ports
                  (plist-get context :session-id))))
    (emacs-jupyter-notebook-connection-write-file
     rewritten (plist-get context :local-file))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'tunnel))
    (setq context (emacs-jupyter-notebook--async-put context :local-ports local-ports))
    (setq context (emacs-jupyter-notebook--async-put context :tunnel-process tunnel))
    (setq context (emacs-jupyter-notebook--async-put
                   context :deadline
                   (+ (float-time) emacs-jupyter-notebook-tunnel-wait-timeout)))
    (emacs-jupyter-notebook--async-message context "waiting for SSH tunnel ports")
    (emacs-jupyter-notebook--async-wait-tunnel-tick context)))

(defun emacs-jupyter-notebook--async-wait-tunnel-tick (context)
  "Check tunnel readiness for CONTEXT and reschedule if needed."
  (when (eq (plist-get context :phase) 'tunnel)
    (let* ((tunnel (plist-get context :tunnel-process))
           (local-ports (plist-get context :local-ports))
           (pending
            (cl-remove-if
             (lambda (key)
               (emacs-jupyter-notebook--local-port-open-p
                (plist-get local-ports key)))
             emacs-jupyter-notebook-connection-port-keys)))
      (cond
       ((not (process-live-p tunnel))
        (emacs-jupyter-notebook--async-fail
         context "Jupyter SSH tunnel exited before ports were ready"))
       ((null pending)
        (emacs-jupyter-notebook--async-connect context))
       ((>= (float-time) (plist-get context :deadline))
        (emacs-jupyter-notebook--async-fail
         context
         (format "Timed out waiting for Jupyter SSH tunnel ports: %s"
                 (mapconcat #'symbol-name pending ", "))))
       (t
        (let ((timer (run-at-time
                      emacs-jupyter-notebook-tunnel-wait-delay nil
                      #'emacs-jupyter-notebook--async-wait-tunnel-tick context)))
          (emacs-jupyter-notebook--async-put context :timer timer)))))))

(defun emacs-jupyter-notebook--async-connect (context)
  "Connect emacs-jupyter to the ready tunnel described by CONTEXT."
  (setq context (emacs-jupyter-notebook--async-put context :phase 'connect))
  (setq context (emacs-jupyter-notebook--async-cancel-timer context))
  (if (not (emacs-jupyter-notebook--async-buffer-live-p context))
      (emacs-jupyter-notebook--async-fail context "Origin buffer was killed")
    (with-current-buffer (plist-get context :origin-buffer)
      (condition-case err
          (let* ((entry (copy-sequence (plist-get context :entry)))
                 (local-ports (plist-get context :local-ports))
                 (local-file (plist-get context :local-file)))
            (emacs-jupyter-notebook--async-message
             context "connecting emacs-jupyter client")
            (setq emacs-jupyter-notebook--tunnel-process
                  (plist-get context :tunnel-process))
            (setq emacs-jupyter-notebook--client
                  (emacs-jupyter-notebook-jupyter-connect local-file))
            (setq entry (plist-put entry :tunnel-ports local-ports))
            (setq entry (plist-put entry :local-connection-file local-file))
            (setq emacs-jupyter-notebook--session-entry entry)
            (setq context (emacs-jupyter-notebook--async-put context :entry entry))
            (setq context (emacs-jupyter-notebook--async-put context :phase 'done))
            (emacs-jupyter-notebook-registry-save-entry entry)
            (emacs-jupyter-notebook--async-message
             context "connected to remote Jupyter kernel %s"
             (plist-get context :session-id))
            (when-let ((callback (plist-get context :callback)))
              (funcall callback context))
            context)
        (error
         (emacs-jupyter-notebook--async-fail
          context (error-message-string err)))))))

(defun emacs-jupyter-notebook--async-start-context (profile entry session-id launch)
  "Create and store an async start context for PROFILE, ENTRY and LAUNCH."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'launch
                  :profile profile
                  :entry entry
                  :session-id session-id
                  :launch launch
                  :origin-buffer (current-buffer)
                  :owns-kernel t)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook--async-reconnect-context (profile entry)
  "Create and store an async reconnect context for PROFILE and ENTRY."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'retrieve
                  :profile profile
                  :entry entry
                  :session-id (plist-get entry :session-id)
                  :origin-buffer (current-buffer)
                  :owns-kernel nil)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook-cancel-operation ()
  "Cancel the current buffer's in-progress async Jupyter operation."
  (interactive)
  (if emacs-jupyter-notebook--async-context
      (progn
        (emacs-jupyter-notebook--async-fail
         emacs-jupyter-notebook--async-context "Operation cancelled")
        (setq emacs-jupyter-notebook--async-context nil))
    (user-error "No emacs-jupyter-notebook operation is in progress")))

(defun emacs-jupyter-notebook--connect-entry (entry profile)
  "Connect current buffer to remote kernel ENTRY using PROFILE."
  (let* ((session-id (plist-get entry :session-id))
         (remote-file (plist-get entry :remote-connection-file))
         (remote-copy (make-temp-file "emacs-jupyter-notebook-remote-" nil ".json"))
         (local-file (make-temp-file "emacs-jupyter-notebook-local-" nil ".json"))
         (connection (emacs-jupyter-notebook--retrieve-connection-file
                      profile remote-file remote-copy))
         (remote-ports (emacs-jupyter-notebook-connection-ports connection))
         (local-ports (emacs-jupyter-notebook-connection-allocate-local-ports))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports
                     connection local-ports))
         (tunnel (emacs-jupyter-notebook--start-tunnel
                  profile remote-ports local-ports session-id)))
    (emacs-jupyter-notebook-connection-write-file rewritten local-file)
    (setq emacs-jupyter-notebook--tunnel-process tunnel)
    (emacs-jupyter-notebook--wait-for-tunnel tunnel local-ports)
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-jupyter-connect local-file))
    (setq entry (plist-put (copy-sequence entry) :tunnel-ports local-ports))
    (setq entry (plist-put entry :local-connection-file local-file))
    (setq emacs-jupyter-notebook--session-entry entry)
    (emacs-jupyter-notebook-registry-save-entry entry)
    entry))

;;;###autoload
(defun emacs-jupyter-notebook-start-remote-kernel (profile-name)
  "Start a detached remote kernel for PROFILE-NAME asynchronously."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (emacs-jupyter-notebook-jupyter--ensure)
  (let* ((profile (emacs-jupyter-notebook--read-host-profile profile-name))
         (session-id (emacs-jupyter-notebook--new-session-id))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (entry (list :profile (plist-get profile :profile)
                      :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                      :remote-cwd (plist-get profile :remote-cwd)
                      :kernelspec (plist-get profile :kernelspec)
                      :remote-connection-file (plist-get launch :connection-file)
                      :remote-pid nil
                      :created-at (emacs-jupyter-notebook--timestamp)
                      :tunnel-ports nil
                      :display-name (format "%s:%s"
                                            (emacs-jupyter-notebook-ssh-destination profile)
                                            (plist-get profile :kernelspec))
                      :session-id session-id)))
    (emacs-jupyter-notebook--async-launch
     (emacs-jupyter-notebook--async-start-context
      profile entry session-id launch))))

(defun emacs-jupyter-notebook--entry-profile (entry)
  "Return a profile plist reconstructed from registry ENTRY."
  (emacs-jupyter-notebook-ssh-profile
   (list :profile (plist-get entry :profile)
         :host (plist-get entry :remote-host)
         :remote-cwd (plist-get entry :remote-cwd)
         :remote-cache-dir (file-name-directory
                            (plist-get entry :remote-connection-file))
         :kernelspec (plist-get entry :kernelspec))))

(defun emacs-jupyter-notebook--read-registry-entry ()
  "Read and return a registry entry for reconnect."
  (let* ((entries (emacs-jupyter-notebook-registry-load))
         (choices (mapcar (lambda (entry)
                            (cons (format "%s  %s  %s"
                                          (or (plist-get entry :display-name) "kernel")
                                          (or (plist-get entry :profile) "")
                                          (or (plist-get entry :session-id) ""))
                                  entry))
                          entries))
         (choice (completing-read "Reconnect kernel: " choices nil t)))
    (or (cdr (assoc choice choices))
        (error "No registry entry selected"))))

;;;###autoload
(defun emacs-jupyter-notebook-reconnect-remote-kernel (entry)
  "Reconnect current buffer to an existing remote kernel ENTRY asynchronously."
  (interactive (list (emacs-jupyter-notebook--read-registry-entry)))
  (emacs-jupyter-notebook-jupyter--ensure)
  (let ((profile (emacs-jupyter-notebook--entry-profile entry)))
    (emacs-jupyter-notebook--async-retrieve
     (emacs-jupyter-notebook--async-reconnect-context profile entry))))

(defun emacs-jupyter-notebook--ensure-client ()
  "Return the current buffer's kernel client or signal an error."
  (or emacs-jupyter-notebook--client
      (error "No Jupyter kernel connected; run `emacs-jupyter-notebook-start-remote-kernel'")))

(defun emacs-jupyter-notebook--evaluate-code (code beg end)
  "Evaluate CODE for source range BEG to END without changing source text."
  (let ((modified (buffer-modified-p)))
    (prog1
        (emacs-jupyter-notebook-jupyter-evaluate
         (emacs-jupyter-notebook--ensure-client) code beg end)
      (set-buffer-modified-p modified))))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-current-cell ()
  "Evaluate the current # %% cell."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (emacs-jupyter-notebook--evaluate-code
     (buffer-substring-no-properties beg end) beg end)))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-region (beg end)
  "Evaluate the active region from BEG to END."
  (interactive "r")
  (emacs-jupyter-notebook--evaluate-code
   (buffer-substring-no-properties beg end) beg end))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-buffer ()
  "Evaluate the current buffer."
  (interactive)
  (emacs-jupyter-notebook--evaluate-code
   (buffer-substring-no-properties (point-min) (point-max))
   (point-min) (point-max)))

;;;###autoload
(defun emacs-jupyter-notebook-interrupt-kernel ()
  "Interrupt the current kernel."
  (interactive)
  (emacs-jupyter-notebook-jupyter-interrupt
   (emacs-jupyter-notebook--ensure-client)))

;;;###autoload
(defun emacs-jupyter-notebook-restart-kernel ()
  "Restart the current kernel through emacs-jupyter."
  (interactive)
  (emacs-jupyter-notebook-jupyter-restart
   (emacs-jupyter-notebook--ensure-client)))

;;;###autoload
(defun emacs-jupyter-notebook-shutdown-kernel ()
  "Shut down the current kernel and close the local tunnel."
  (interactive)
  (when emacs-jupyter-notebook--client
    (emacs-jupyter-notebook-jupyter-shutdown emacs-jupyter-notebook--client))
  (when (and (processp emacs-jupyter-notebook--tunnel-process)
             (process-live-p emacs-jupyter-notebook--tunnel-process))
    (delete-process emacs-jupyter-notebook--tunnel-process))
  (when emacs-jupyter-notebook--session-entry
    (emacs-jupyter-notebook--cleanup-remote-entry
     emacs-jupyter-notebook--session-entry))
  (when-let* ((entry emacs-jupyter-notebook--session-entry)
              (key (or (plist-get entry :session-id)
                       (plist-get entry :profile))))
    (emacs-jupyter-notebook-registry-remove-entry key))
  (setq emacs-jupyter-notebook--client nil
        emacs-jupyter-notebook--session-entry nil
        emacs-jupyter-notebook--tunnel-process nil))

;;;###autoload
(defun emacs-jupyter-notebook-clear-results ()
  "Clear inline result overlays from the current buffer."
  (interactive)
  (emacs-jupyter-notebook-result-clear-all)
  (emacs-jupyter-notebook-jupyter-clear-overlays))

(provide 'emacs-jupyter-notebook)

;;; emacs-jupyter-notebook.el ends here
