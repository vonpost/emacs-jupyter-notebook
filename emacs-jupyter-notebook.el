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

(defvar emacs-jupyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-jupyter-notebook-evaluate-current-cell)
    (define-key map (kbd "C-c C-r") #'emacs-jupyter-notebook-evaluate-region)
    (define-key map (kbd "C-c C-b") #'emacs-jupyter-notebook-evaluate-buffer)
    (define-key map (kbd "C-c C-k") #'emacs-jupyter-notebook-interrupt-kernel)
    (define-key map (kbd "C-c C-s") #'emacs-jupyter-notebook-start-remote-kernel)
    (define-key map (kbd "C-c C-n") #'emacs-jupyter-notebook-reconnect-remote-kernel)
    (define-key map (kbd "C-c C-l") #'emacs-jupyter-notebook-clear-results)
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
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-jupyter-connect local-file))
    (setq entry (plist-put (copy-sequence entry) :tunnel-ports local-ports))
    (setq entry (plist-put entry :local-connection-file local-file))
    (setq emacs-jupyter-notebook--session-entry entry)
    (emacs-jupyter-notebook-registry-save-entry entry)
    entry))

;;;###autoload
(defun emacs-jupyter-notebook-start-remote-kernel (profile-name)
  "Start a detached remote kernel for PROFILE-NAME and connect to it."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (emacs-jupyter-notebook-jupyter--ensure)
  (let* ((profile (emacs-jupyter-notebook--read-host-profile profile-name))
         (session-id (emacs-jupyter-notebook--new-session-id))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (pid (emacs-jupyter-notebook--parse-pid
               (emacs-jupyter-notebook-ssh-run-command (plist-get launch :argv))))
         (entry (list :profile (plist-get profile :profile)
                      :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                      :remote-cwd (plist-get profile :remote-cwd)
                      :kernelspec (plist-get profile :kernelspec)
                      :remote-connection-file (plist-get launch :connection-file)
                      :remote-pid pid
                      :created-at (emacs-jupyter-notebook--timestamp)
                      :tunnel-ports nil
                      :display-name (format "%s:%s"
                                            (emacs-jupyter-notebook-ssh-destination profile)
                                            (plist-get profile :kernelspec))
                      :session-id session-id)))
    (prog1 (emacs-jupyter-notebook--connect-entry entry profile)
      (message "Connected to remote Jupyter kernel %s" session-id))))

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
  "Reconnect current buffer to an existing remote kernel ENTRY."
  (interactive (list (emacs-jupyter-notebook--read-registry-entry)))
  (emacs-jupyter-notebook-jupyter--ensure)
  (let ((profile (emacs-jupyter-notebook--entry-profile entry)))
    (prog1 (emacs-jupyter-notebook--connect-entry entry profile)
      (message "Reconnected to remote Jupyter kernel %s"
               (plist-get entry :session-id)))))

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
  (when (process-live-p emacs-jupyter-notebook--tunnel-process)
    (delete-process emacs-jupyter-notebook--tunnel-process))
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
