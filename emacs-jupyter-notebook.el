;;; emacs-jupyter-notebook.el --- Remote Jupyter kernels for local source files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (jupyter "1.0") (code-cells "0.5"))
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

(defvar-local emacs-jupyter-notebook--before-change-text nil)

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function nil
  "Previous buffer-local value of `imenu-create-index-function'.")

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function-local-p nil
  "Whether `imenu-create-index-function' was buffer-local before enabling.")

(defun emacs-jupyter-notebook--before-change (beg end)
  (setq emacs-jupyter-notebook--before-change-text
        (when (and beg end (> end beg))
          (buffer-substring-no-properties beg end))))

(defun emacs-jupyter-notebook--insert-belongs-after-output-p (text)
  "Return non-nil when inserted TEXT should stay below result output."
  (or (equal text "\n")
      (string-match-p "\\`\\(?:\n\\)?# %%" text)))

(defun emacs-jupyter-notebook--after-change-adjust-result-anchors (beg end old-len)
  "Keep result overlays usable after insertions at their anchor.
Non-newline text inserted at a result anchor is a source edit, so move the
result after it.  Newlines and cell markers inserted at the anchor are treated
as new text below the output, so the result stays in place."
  (when (and (zerop old-len) (< beg end))
    (let ((inserted (buffer-substring-no-properties beg end)))
      (unless (emacs-jupyter-notebook--insert-belongs-after-output-p inserted)
        (dolist (ov (emacs-jupyter-notebook-result--all-overlays))
          (when (and (= (overlay-start ov) beg)
                     (= (overlay-end ov) beg)
                     (= (or (overlay-get ov 'emacs-jupyter-notebook-source-end) beg)
                        beg))
            (move-overlay ov end end)
            (overlay-put ov 'emacs-jupyter-notebook-source-end end)))))))

(defun emacs-jupyter-notebook--after-change-cleanup (beg end old-len)
  (emacs-jupyter-notebook--after-change-adjust-result-anchors beg end old-len)
  (when (and (> old-len 0)
             emacs-jupyter-notebook--before-change-text
             (string-match-p "\\(?:^\\|\n\\)# %%" emacs-jupyter-notebook--before-change-text))
    (emacs-jupyter-notebook-result-clear-all)
    (emacs-jupyter-notebook-jupyter-clear-overlays)))

(defun emacs-jupyter-notebook--imenu-index ()
  "Return an imenu index of code-cell markers in the current buffer."
  (let ((entries nil)
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward code-cells-boundary-regexp nil t)
        (setq count (1+ count))
        (let* ((title (string-trim
                       (buffer-substring-no-properties
                        (match-end 0) (line-end-position))))
               (name (if (string-empty-p title)
                         (format "Cell %d" count)
                       title)))
          (push (cons name (copy-marker (match-beginning 0) t)) entries))))
    (nreverse entries)))

(defun emacs-jupyter-notebook--enable-imenu ()
  "Use cell markers as the imenu index for the current buffer."
  (setq emacs-jupyter-notebook--saved-imenu-create-index-function
        imenu-create-index-function
        emacs-jupyter-notebook--saved-imenu-create-index-function-local-p
        (local-variable-p 'imenu-create-index-function))
  (setq-local imenu-create-index-function
              #'emacs-jupyter-notebook--imenu-index))

(defun emacs-jupyter-notebook--disable-imenu ()
  "Restore the imenu index function that was active before mode enable."
  (let ((saved-function emacs-jupyter-notebook--saved-imenu-create-index-function)
        (saved-local-p emacs-jupyter-notebook--saved-imenu-create-index-function-local-p))
    (if saved-local-p
        (setq-local imenu-create-index-function saved-function)
      (kill-local-variable 'imenu-create-index-function))
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function)
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function-local-p)))

(defvar-local emacs-jupyter-notebook--client nil
  "Current buffer's emacs-jupyter client object.")

(defvar-local emacs-jupyter-notebook--session-entry nil
  "Current buffer's registry entry plist.")

(defvar-local emacs-jupyter-notebook--tunnel-process nil
  "Current buffer's SSH tunnel process.")

(defvar-local emacs-jupyter-notebook--async-context nil
  "Current buffer's in-progress async start or reconnect context.")

(defvar-local emacs-jupyter-notebook--tunnel-dead nil
  "Non-nil when the current buffer's SSH tunnel has disconnected.")

(defvar-local emacs-jupyter-notebook--kernel-status nil
  "Current kernel status: `busy', `idle', or nil.")

(defvar-local emacs-jupyter-notebook--completion-cache nil
  "Last completion result plist with :key and :reply.")

(defvar-local emacs-jupyter-notebook--completion-pending-key nil
  "In-flight completion request key.")

(defvar-local emacs-jupyter-notebook--completion-idle-timer nil
  "Idle timer for populating completion cache.")

(defvar-local emacs-jupyter-notebook--inspect-request-id 0
  "Monotonic inspect request id.")

(defvar-local emacs-jupyter-notebook--is-complete-request-id 0
  "Monotonic is-complete request id.")

(defvar-local emacs-jupyter-notebook--evaluation-timer nil
  "Timeout timer for current evaluation.")

(defun emacs-jupyter-notebook--mode-line-string ()
  "Return the mode line lighter string based on kernel state."
  (cond
   (emacs-jupyter-notebook--tunnel-dead " EJN!")
    ((eq emacs-jupyter-notebook--kernel-status 'busy) " EJN*")
    (t " EJN")))

(defun emacs-jupyter-notebook--tunnel-state ()
  "Return the current tunnel state as a symbol."
  (cond
   (emacs-jupyter-notebook--tunnel-dead 'dead)
   ((and (processp emacs-jupyter-notebook--tunnel-process)
         (process-live-p emacs-jupyter-notebook--tunnel-process))
    'alive)
   (emacs-jupyter-notebook--tunnel-process 'exited)
   (t 'none)))

(defun emacs-jupyter-notebook-status-snapshot ()
  "Return a plist describing the current buffer's notebook engine state."
  (let ((entry emacs-jupyter-notebook--session-entry)
        (context emacs-jupyter-notebook--async-context))
    (list :buffer (buffer-name)
          :file buffer-file-name
          :client (and emacs-jupyter-notebook--client t)
          :kernel-status emacs-jupyter-notebook--kernel-status
          :tunnel-state (emacs-jupyter-notebook--tunnel-state)
          :async-phase (plist-get context :phase)
          :async-error (plist-get context :error)
          :profile (or (plist-get entry :profile)
                       (plist-get (plist-get context :entry) :profile))
          :session-id (or (plist-get entry :session-id)
                          (plist-get context :session-id))
          :remote-host (plist-get entry :remote-host)
          :remote-pid (plist-get entry :remote-pid)
          :remote-connection-file (plist-get entry :remote-connection-file)
          :local-connection-file (plist-get entry :local-connection-file)
          :tunnel-ports (plist-get entry :tunnel-ports))))

(defun emacs-jupyter-notebook--format-status (snapshot)
  "Format status SNAPSHOT for display."
  (string-join
   (list
    (format "Buffer: %s" (plist-get snapshot :buffer))
    (format "File: %s" (or (plist-get snapshot :file) "none"))
    (format "Profile: %s" (or (plist-get snapshot :profile) "none"))
    (format "Session: %s" (or (plist-get snapshot :session-id) "none"))
    (format "Client: %s" (if (plist-get snapshot :client) "connected" "none"))
    (format "Kernel status: %s" (or (plist-get snapshot :kernel-status) "unknown"))
    (format "Tunnel: %s" (plist-get snapshot :tunnel-state))
    (format "Async phase: %s" (or (plist-get snapshot :async-phase) "none"))
    (format "Async error: %s" (or (plist-get snapshot :async-error) "none"))
    (format "Remote host: %s" (or (plist-get snapshot :remote-host) "unknown"))
    (format "Remote PID: %s" (or (plist-get snapshot :remote-pid) "unknown"))
    (format "Remote connection: %s"
            (or (plist-get snapshot :remote-connection-file) "none"))
    (format "Local connection: %s"
            (or (plist-get snapshot :local-connection-file) "none"))
    (format "Tunnel ports: %S" (plist-get snapshot :tunnel-ports)))
   "\n"))

(defvar emacs-jupyter-notebook-cell-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "p") #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "a") #'emacs-jupyter-notebook-beginning-of-cell)
    (define-key map (kbd "e") #'emacs-jupyter-notebook-end-of-cell)
    (define-key map (kbd "s") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "i") #'emacs-jupyter-notebook-insert-cell-below)
    (define-key map (kbd "I") #'emacs-jupyter-notebook-insert-cell-above)
    (define-key map (kbd "d") #'emacs-jupyter-notebook-delete-cell)
    (define-key map (kbd "k") #'emacs-jupyter-notebook-kill-cell)
    (define-key map (kbd "K") #'emacs-jupyter-notebook-clear-cell)
    (define-key map (kbd "y") #'emacs-jupyter-notebook-duplicate-cell)
    (define-key map (kbd "P") #'emacs-jupyter-notebook-move-cell-up)
    (define-key map (kbd "N") #'emacs-jupyter-notebook-move-cell-down)
    (define-key map (kbd "@") #'code-cells-mark-cell)
    map)
  "Cell editing keymap for `emacs-jupyter-notebook-mode'.")

(defvar emacs-jupyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-jupyter-notebook-evaluate-current-cell)
    (define-key map (kbd "C-c C-r") #'emacs-jupyter-notebook-evaluate-region)
    (define-key map (kbd "C-c C-b") #'emacs-jupyter-notebook-evaluate-buffer)
    (define-key map (kbd "C-c TAB") #'emacs-jupyter-notebook-complete-at-point)
    (define-key map (kbd "C-c C-d") #'emacs-jupyter-notebook-inspect-at-point)
    (define-key map (kbd "C-c C-k") #'emacs-jupyter-notebook-interrupt-kernel)
    (define-key map (kbd "C-c C-s") #'emacs-jupyter-notebook-start-remote-kernel)
    (define-key map (kbd "C-c C-n") #'emacs-jupyter-notebook-reconnect-remote-kernel)
    (define-key map (kbd "C-c C-y") #'emacs-jupyter-notebook-retry-fresh-kernel)
    (define-key map (kbd "C-c C-/") #'emacs-jupyter-notebook-status)
    (define-key map (kbd "C-c C-v") #'emacs-jupyter-notebook-fetch-remote-log)
    (define-key map (kbd "C-c C-q") #'emacs-jupyter-notebook-list-remote-processes)
    (define-key map (kbd "C-c C-w") #'emacs-jupyter-notebook-clean-orphaned-kernels)
    (define-key map (kbd "C-c C-l") #'emacs-jupyter-notebook-clear-results)
    (define-key map (kbd "C-c C-x") #'emacs-jupyter-notebook-cancel-operation)
    (define-key map (kbd "C-c C-t") #'emacs-jupyter-notebook-toggle-output)
    (define-key map (kbd "C-c C-o") #'emacs-jupyter-notebook-show-output)
    (define-key map (kbd "C-c C-f") #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "C-c C-p") #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "C-c C-j") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "C-c %") emacs-jupyter-notebook-cell-map)
    map)
  "Keymap for `emacs-jupyter-notebook-mode'.")

;;;###autoload
(define-minor-mode emacs-jupyter-notebook-mode
  "Minor mode for evaluating local source cells in remote Jupyter kernels."
  :lighter (:eval (emacs-jupyter-notebook--mode-line-string))
  :keymap emacs-jupyter-notebook-mode-map
  (if emacs-jupyter-notebook-mode
      (progn
        (code-cells-mode 1)
        (add-hook 'completion-at-point-functions
                  #'emacs-jupyter-notebook-completion-at-point nil t)
        (add-hook 'before-change-functions
                  #'emacs-jupyter-notebook--before-change nil t)
        (add-hook 'after-change-functions
                  #'emacs-jupyter-notebook--after-change-cleanup nil t)
        (emacs-jupyter-notebook--enable-imenu)
        (emacs-jupyter-notebook--completion-start-idle-timer))
    (code-cells-mode -1)
    (remove-hook 'completion-at-point-functions
                 #'emacs-jupyter-notebook-completion-at-point t)
    (remove-hook 'before-change-functions
                 #'emacs-jupyter-notebook--before-change t)
    (remove-hook 'after-change-functions
                 #'emacs-jupyter-notebook--after-change-cleanup t)
    (emacs-jupyter-notebook--disable-imenu)
    (emacs-jupyter-notebook--completion-cancel-idle-timer)))

(add-to-list 'code-cells-eval-region-commands
              '(emacs-jupyter-notebook-mode . emacs-jupyter-notebook-evaluate-region))

(defun emacs-jupyter-notebook--clear-cell-region-artifacts (beg end)
  "Clear result artifacts attached to source positions between BEG and END."
  (emacs-jupyter-notebook-result-clear-region beg end)
  (emacs-jupyter-notebook-jupyter-clear-overlays))

(defun emacs-jupyter-notebook--clear-all-cell-artifacts ()
  "Clear all result artifacts before structural cell edits."
  (emacs-jupyter-notebook-result-clear-all)
  (emacs-jupyter-notebook-jupyter-clear-overlays))

(defun emacs-jupyter-notebook--goto-live-cell-start ()
  "Move point to the current cell body when the buffer is nonempty."
  (unless (= (point-min) (point-max))
    (emacs-jupyter-notebook-cell-goto-code-start)))

(defun emacs-jupyter-notebook-beginning-of-cell ()
  "Move to the first editable line of the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-end-of-cell ()
  "Move to the end of the current cell body."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-end))

(defun emacs-jupyter-notebook-insert-cell-below ()
  "Insert an empty cell below the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-below))

(defun emacs-jupyter-notebook-insert-cell-above ()
  "Insert an empty cell above the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-above))

(defun emacs-jupyter-notebook-delete-cell ()
  "Delete the current cell without touching the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-kill-cell ()
  "Kill the current cell, saving it in the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (kill-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-clear-cell ()
  "Delete the current cell body while keeping the cell marker."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (goto-char beg)))

(defun emacs-jupyter-notebook-duplicate-cell ()
  "Duplicate the current cell below itself and move to the duplicate."
  (interactive)
  (pcase-let* ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds))
               (text (buffer-substring beg end)))
    (goto-char end)
    (let ((start (point)))
      (insert text)
      (emacs-jupyter-notebook-cell-goto-code-start start))))

(defun emacs-jupyter-notebook-move-cell-up (&optional arg)
  "Move the current cell up ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-up (or arg 1))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-move-cell-down (&optional arg)
  "Move the current cell down ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-down (or arg 1))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-evaluate-current-cell-and-advance ()
  "Evaluate the current cell, then move to the next cell when one exists."
  (interactive)
  (emacs-jupyter-notebook-evaluate-current-cell)
  (condition-case nil
      (emacs-jupyter-notebook-forward-cell 1)
    (user-error nil)))

(defun emacs-jupyter-notebook--new-session-id (&optional hint)
  "Return a locally unique session id string, optionally containing HINT."
  (let ((base (or hint (format "%s" (emacs-pid)))))
    (format "%s-%s" base
            (md5 (format "%s:%s:%s:%s"
                         (current-time-string) (float-time) (random) (emacs-pid))))))

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

(defun emacs-jupyter-notebook--entry-profile (entry)
  "Return a profile plist reconstructed from registry ENTRY."
  (emacs-jupyter-notebook-ssh-profile
   (list :profile (plist-get entry :profile)
         :host (plist-get entry :remote-host)
         :remote-cwd (plist-get entry :remote-cwd)
          :remote-cache-dir (file-name-directory
                             (plist-get entry :remote-connection-file))
          :kernelspec (plist-get entry :kernelspec)
          :jupyter-command (plist-get entry :jupyter-command))))

(defun emacs-jupyter-notebook--current-file-registry-entry ()
  "Return the latest registry entry for the current buffer's file, or nil."
  (when buffer-file-name
    (emacs-jupyter-notebook-registry-latest-for-file
     buffer-file-name
     (emacs-jupyter-notebook-registry-load))))

(defun emacs-jupyter-notebook--remove-registry-entry (entry)
  "Remove ENTRY from the durable registry when it has an identity key."
  (when-let* ((key (or (plist-get entry :session-id)
                       (plist-get entry :profile))))
    (emacs-jupyter-notebook-registry-remove-entry key)))

(defun emacs-jupyter-notebook--read-registry-entry ()
  "Read and return a registry entry for reconnect."
  (if-let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
      entry
    (let ((entries (emacs-jupyter-notebook-registry-load)))
      (unless entries
        (user-error "No kernel sessions found in registry"))
      (let* ((choices (mapcar (lambda (entry)
                                (cons (format "%s  %s  %s"
                                              (or (plist-get entry :display-name) "kernel")
                                              (or (plist-get entry :profile) "")
                                              (or (plist-get entry :session-id) ""))
                                      entry))
                              entries))
             (choice (completing-read "Reconnect kernel: " choices nil t)))
        (or (cdr (assoc choice choices))
            (error "No registry entry selected"))))))

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
  (string-join
   (delq nil
         (mapcar (lambda (buffer)
                   (when (and buffer (buffer-live-p buffer))
                     (with-current-buffer buffer
                       (let ((text (string-trim (buffer-string))))
                         (unless (string-empty-p text)
                           text)))))
                 (list (process-buffer process)
                       (process-get process 'emacs-jupyter-notebook-stderr-buffer))))
   "\n"))

(defun emacs-jupyter-notebook--install-tunnel-sentinel (process buffer)
  "Install a sentinel on PROCESS that marks the tunnel dead in BUFFER."
  (if (not (process-live-p process))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq emacs-jupyter-notebook--tunnel-dead t)
          (setq emacs-jupyter-notebook--kernel-status nil)
          (force-mode-line-update t)))
    (set-process-sentinel
     process
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq emacs-jupyter-notebook--tunnel-dead t)
             (setq emacs-jupyter-notebook--kernel-status nil)
             (force-mode-line-update t))))))))

;;; Async machinery

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

(defun emacs-jupyter-notebook--async-get (context property)
  "Return PROPERTY from async CONTEXT."
  (plist-get context property))

(defun emacs-jupyter-notebook--async-in-progress-p ()
  "Return non-nil when an async operation is in progress."
  (and emacs-jupyter-notebook--async-context
       (not (memq (plist-get emacs-jupyter-notebook--async-context :phase)
                  '(done error nil)))))

(defun emacs-jupyter-notebook--ensure-no-async-operation ()
  "Signal when the current buffer already has an async operation running."
  (when (emacs-jupyter-notebook--async-in-progress-p)
    (user-error
     "A Jupyter operation is already in progress; use M-x emacs-jupyter-notebook-cancel-operation to cancel it")))

(defun emacs-jupyter-notebook--async-add-callback (context callback)
  "Add CALLBACK to CONTEXT's callback chain."
  (let ((existing (plist-get context :callback)))
    (emacs-jupyter-notebook--async-put
     context :callback
     (if existing
         (lambda (ctx)
           (funcall existing ctx)
           (funcall callback ctx))
       callback))))

(defun emacs-jupyter-notebook--async-add-error-callback (context callback)
  "Add error CALLBACK to CONTEXT's error-callback chain."
  (let ((existing (plist-get context :error-callback)))
    (emacs-jupyter-notebook--async-put
     context :error-callback
     (if existing
         (lambda (ctx err)
           (funcall existing ctx err)
           (funcall callback ctx err))
       callback))))

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
    (emacs-jupyter-notebook-connection-write-file rewritten (plist-get context :local-file))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'tunnel))
    (setq context (emacs-jupyter-notebook--async-put context :local-ports local-ports))
    (setq context (emacs-jupyter-notebook--async-put context :tunnel-process tunnel))
    (when (emacs-jupyter-notebook--async-buffer-live-p context)
      (with-current-buffer (plist-get context :origin-buffer)
        (emacs-jupyter-notebook--install-tunnel-sentinel tunnel (current-buffer))))
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

(defun emacs-jupyter-notebook--async-connect-finalize (buffer entry local-ports local-file client)
  "Finalize the async connect for BUFFER with CLIENT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect)
        (emacs-jupyter-notebook--async-cancel-timer
         emacs-jupyter-notebook--async-context)
        (if (not client)
            (emacs-jupyter-notebook--async-fail
             emacs-jupyter-notebook--async-context
             "Kernel did not respond to kernel_info_request")
          (setq emacs-jupyter-notebook--client client)
          (setq emacs-jupyter-notebook--tunnel-dead nil)
          (setq entry (plist-put entry :tunnel-ports local-ports))
          (setq entry (plist-put entry :local-connection-file local-file))
          (setq emacs-jupyter-notebook--session-entry entry)
          (let ((ctx emacs-jupyter-notebook--async-context))
            (setq ctx (emacs-jupyter-notebook--async-put ctx :entry entry))
            (setq ctx (emacs-jupyter-notebook--async-put ctx :phase 'done))
            (emacs-jupyter-notebook-registry-save-entry entry)
            (emacs-jupyter-notebook--async-message
             ctx "connected to remote Jupyter kernel %s"
             (plist-get ctx :session-id))
            (let ((cb (plist-get ctx :callback)))
              (when cb
                (funcall cb ctx)))))))))

(defun emacs-jupyter-notebook--async-connect-timeout (buffer)
  "Check if async connect for BUFFER has timed out."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect)
        (emacs-jupyter-notebook--async-fail
         emacs-jupyter-notebook--async-context
         "Timed out waiting for kernel_info_reply")))))

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
                 (local-file (plist-get context :local-file))
                 (buffer (current-buffer)))
            (emacs-jupyter-notebook--async-message
             context "connecting emacs-jupyter client")
            (setq emacs-jupyter-notebook--tunnel-process
                  (plist-get context :tunnel-process))
            (emacs-jupyter-notebook--install-tunnel-sentinel
              emacs-jupyter-notebook--tunnel-process buffer)
            (let ((timer (run-at-time
                          emacs-jupyter-notebook-jupyter-connect-timeout nil
                          #'emacs-jupyter-notebook--async-connect-timeout
                          buffer)))
              (setq context (emacs-jupyter-notebook--async-put context :timer timer)))
            (emacs-jupyter-notebook-jupyter-connect-async
             local-file
             (lambda (client)
               (emacs-jupyter-notebook--async-connect-finalize
                buffer entry local-ports local-file client)))
            context)
        (error
         (emacs-jupyter-notebook--async-fail
          context (error-message-string err)))))))

(defun emacs-jupyter-notebook--async-start-context (profile entry session-id launch
                                                     &optional callback error-callback)
  "Create and store an async start context.
PROFILE, ENTRY, SESSION-ID, and LAUNCH describe the kernel.
CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'launch
                  :profile profile
                  :entry entry
                  :session-id session-id
                  :launch launch
                  :origin-buffer (current-buffer)
                  :owns-kernel t
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook--async-reconnect-context (profile entry
                                                        &optional callback error-callback)
  "Create and store an async reconnect context for PROFILE and ENTRY.
CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'retrieve
                  :profile profile
                  :entry entry
                  :session-id (plist-get entry :session-id)
                  :origin-buffer (current-buffer)
                  :owns-kernel nil
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook--tunnel-reconnect (buffer &optional callback error-callback)
  "Reconnect the tunnel for BUFFER asynchronously.
CALLBACK is called on success, ERROR-CALLBACK on failure."
  (when-let* ((entry emacs-jupyter-notebook--session-entry))
    (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
           (context (emacs-jupyter-notebook--async-reconnect-context
                     profile entry callback error-callback)))
      (with-current-buffer buffer
        (setq emacs-jupyter-notebook--async-context context))
      (emacs-jupyter-notebook--async-retrieve context))))

;;; Synchronous connect path

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
    (setq emacs-jupyter-notebook--tunnel-dead nil)
    (emacs-jupyter-notebook--install-tunnel-sentinel tunnel (current-buffer))
    (emacs-jupyter-notebook--wait-for-tunnel tunnel local-ports)
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-jupyter-connect local-file))
    (setq entry (plist-put (copy-sequence entry) :tunnel-ports local-ports))
    (setq entry (plist-put entry :local-connection-file local-file))
    (setq emacs-jupyter-notebook--session-entry entry)
    (emacs-jupyter-notebook-registry-save-entry entry)
    entry))

;;; Ensure client (async)

(defun emacs-jupyter-notebook--ensure-client-async (callback error-callback)
  "Ensure a kernel client is connected, then call CALLBACK.
On failure, call ERROR-CALLBACK with (context error-data)."
  (cond
   (emacs-jupyter-notebook--tunnel-dead
    (emacs-jupyter-notebook--tunnel-reconnect
     (current-buffer) callback error-callback))
   (emacs-jupyter-notebook--client
    (funcall callback nil))
   ((emacs-jupyter-notebook--async-in-progress-p)
     (emacs-jupyter-notebook--async-add-callback
      emacs-jupyter-notebook--async-context callback)
     (when error-callback
       (emacs-jupyter-notebook--async-add-error-callback
        emacs-jupyter-notebook--async-context error-callback)))
   (t
     (if-let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
         (emacs-jupyter-notebook-reconnect-remote-kernel
          entry callback
          (lambda (_context error-data)
            (emacs-jupyter-notebook--remove-registry-entry entry)
            (message "emacs-jupyter-notebook: reconnect failed (%s); starting a new kernel"
                     error-data)
            (emacs-jupyter-notebook-start-remote-kernel
             emacs-jupyter-notebook-default-profile callback error-callback)))
       (emacs-jupyter-notebook-start-remote-kernel
        emacs-jupyter-notebook-default-profile callback error-callback)))))

;;; Completion

(defun emacs-jupyter-notebook--completion-context ()
  "Build a completion context from the current cell."
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg)))
    (list :key (format "%s:%d" code cursor-pos)
          :code code
          :cursor-pos cursor-pos)))

(defun emacs-jupyter-notebook--completion-result ()
  "Return cached CAPF result or nil."
  (when (and emacs-jupyter-notebook--completion-cache
             emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let* ((context (emacs-jupyter-notebook--completion-context))
           (cache emacs-jupyter-notebook--completion-cache)
           (key (plist-get context :key)))
      (when (equal (plist-get cache :key) key)
        (let* ((reply (plist-get cache :reply))
               (matches (plist-get reply :matches))
               (cursor-start (plist-get reply :cursor_start))
               (cursor-end (plist-get reply :cursor_end)))
          (when matches
            (list (- (point) (- cursor-end cursor-start))
                  (point)
                  (append matches nil))))))))

(defun emacs-jupyter-notebook--request-completion (&optional show-results)
  "Fire an async completion request and update cache on reply."
  (when emacs-jupyter-notebook--client
    (let* ((context (emacs-jupyter-notebook--completion-context))
           (key (plist-get context :key))
           (code (plist-get context :code))
           (cursor-pos (plist-get context :cursor-pos))
           (buffer (current-buffer)))
      (unless (equal emacs-jupyter-notebook--completion-pending-key key)
        (setq emacs-jupyter-notebook--completion-pending-key key)
        (emacs-jupyter-notebook-jupyter-complete
          emacs-jupyter-notebook--client code cursor-pos
          (lambda (reply _error)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (equal emacs-jupyter-notebook--completion-pending-key key)
                  (setq emacs-jupyter-notebook--completion-pending-key nil)
                  (when reply
                    (setq emacs-jupyter-notebook--completion-cache
                          (list :key key :reply reply))
                    (when (and show-results
                               (equal (emacs-jupyter-notebook--completion-context)
                                      context))
                      (let ((result (emacs-jupyter-notebook--completion-result)))
                        (when result
                          (apply #'completion-in-region result))))))))))))))

(defun emacs-jupyter-notebook-completion-at-point ()
  "CAPF function: return cached completions or fire async request."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let ((result (emacs-jupyter-notebook--completion-result)))
      (if result
          result
        (when (memq this-command
                    '(self-insert-command
                      delete-backward-char
                      backward-delete-char-untabify
                      yank))
          (emacs-jupyter-notebook--request-completion t))
        nil))))

(defun emacs-jupyter-notebook-complete-at-point ()
  "Explicit completion command."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (emacs-jupyter-notebook--request-completion t))

(defun emacs-jupyter-notebook--completion-start-idle-timer ()
  "Start the completion cache idle timer."
  (emacs-jupyter-notebook--completion-cancel-idle-timer)
  (setq emacs-jupyter-notebook--completion-idle-timer
        (run-with-idle-timer 0.5 nil #'emacs-jupyter-notebook--completion-idle-populate)))

(defun emacs-jupyter-notebook--completion-cancel-idle-timer ()
  "Cancel the completion cache idle timer."
  (when (timerp emacs-jupyter-notebook--completion-idle-timer)
    (cancel-timer emacs-jupyter-notebook--completion-idle-timer))
  (setq emacs-jupyter-notebook--completion-idle-timer nil))

(defun emacs-jupyter-notebook--completion-idle-populate ()
  "Populate completion cache on idle."
  (when (and emacs-jupyter-notebook-mode
             emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy))
             (not (emacs-jupyter-notebook--async-in-progress-p)))
    (let* ((context (emacs-jupyter-notebook--completion-context))
           (key (plist-get context :key)))
      (unless (or (equal key emacs-jupyter-notebook--completion-pending-key)
                  (equal key (plist-get emacs-jupyter-notebook--completion-cache :key)))
        (emacs-jupyter-notebook--request-completion)))))

;;; Inspect

(defun emacs-jupyter-notebook-inspect-at-point ()
  "Inspect the symbol at point using the Jupyter kernel."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg)))
    (emacs-jupyter-notebook-jupyter-inspect
     emacs-jupyter-notebook--client code cursor-pos 0
     (lambda (reply _error)
       (when reply
         (let* ((data (plist-get reply :data))
                (text (plist-get data :text/plain)))
           (when text
             (display-message-or-buffer text))))))))

;;; Completeness check

(defun emacs-jupyter-notebook--evaluate-after-completeness (code beg end)
  "Check CODE completeness and evaluate if complete.
BEG and END are source bounds."
  (if (not emacs-jupyter-notebook-check-code-completeness)
      (emacs-jupyter-notebook--evaluate-code-now code beg end)
    (emacs-jupyter-notebook-jupyter-is-complete
     emacs-jupyter-notebook--client code
     (lambda (reply _error)
       (when (and reply (equal (plist-get reply :status) "complete"))
         (emacs-jupyter-notebook--evaluate-code-now code beg end))))))

;;; Evaluation

(defun emacs-jupyter-notebook--evaluate-code-now (code beg end)
  "Evaluate CODE immediately for source range BEG to END."
  (let ((modified (buffer-modified-p)))
    (prog1
        (emacs-jupyter-notebook-jupyter-evaluate
         emacs-jupyter-notebook--client code beg end)
      (set-buffer-modified-p modified))))

(defun emacs-jupyter-notebook--evaluate-code (code beg end)
  "Ensure client then evaluate CODE for source range BEG to END."
  (let ((eval-cb (lambda (_ctx)
                   (emacs-jupyter-notebook--evaluate-after-completeness code beg end)))
        (error-cb (lambda (_ctx err)
                    (message "emacs-jupyter-notebook: evaluation failed: %s" err))))
    (emacs-jupyter-notebook--ensure-client-async eval-cb error-cb)))

;;; Commands

(defun emacs-jupyter-notebook--registry-entry-key (entry)
  "Return the registry key for ENTRY, or nil."
  (or (plist-get entry :session-id)
      (plist-get entry :profile)))

(defun emacs-jupyter-notebook--cleanup-current-state (&optional reason skip-jupyter-shutdown)
  "Clean current buffer's client, tunnel, async context, and registry state.
REASON is used when cancelling an async context.  When SKIP-JUPYTER-SHUTDOWN is
non-nil, do not send a Jupyter shutdown request to the current client."
  (let ((entry emacs-jupyter-notebook--session-entry)
        (context emacs-jupyter-notebook--async-context))
    (when (and context (emacs-jupyter-notebook--async-in-progress-p))
      (emacs-jupyter-notebook--async-fail context (or reason "Operation cancelled")))
    (when (and emacs-jupyter-notebook--client (not skip-jupyter-shutdown))
      (ignore-errors
        (emacs-jupyter-notebook-jupyter-shutdown emacs-jupyter-notebook--client)))
    (when (and (processp emacs-jupyter-notebook--tunnel-process)
               (process-live-p emacs-jupyter-notebook--tunnel-process))
      (delete-process emacs-jupyter-notebook--tunnel-process))
    (when entry
      (emacs-jupyter-notebook--cleanup-remote-entry entry))
    (when-let* ((key (and entry (emacs-jupyter-notebook--registry-entry-key entry))))
      (emacs-jupyter-notebook-registry-remove-entry key))
    (when-let* ((local-file (plist-get entry :local-connection-file)))
      (emacs-jupyter-notebook--async-delete-file local-file))
    (setq emacs-jupyter-notebook--client nil
          emacs-jupyter-notebook--session-entry nil
          emacs-jupyter-notebook--tunnel-process nil
          emacs-jupyter-notebook--tunnel-dead nil
          emacs-jupyter-notebook--kernel-status nil
          emacs-jupyter-notebook--async-context nil
          emacs-jupyter-notebook--evaluation-timer nil)
    (force-mode-line-update t)
    entry))

(defun emacs-jupyter-notebook--display-command-output (buffer-name output)
  "Display OUTPUT in read-only BUFFER-NAME."
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output)
        (goto-char (point-min)))
      (setq buffer-read-only t))
    (display-buffer buf)))

;;;###autoload
(defun emacs-jupyter-notebook-start-remote-kernel (profile-name &optional callback error-callback)
  "Start a detached remote kernel for PROFILE-NAME asynchronously.
  CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (unless buffer-file-name
    (user-error "Buffer has no associated file"))
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (emacs-jupyter-notebook-jupyter--ensure)
  (let* ((profile (emacs-jupyter-notebook--read-host-profile profile-name))
         (session-id (emacs-jupyter-notebook--new-session-id
                      (file-name-base buffer-file-name)))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (entry (list :profile (plist-get profile :profile)
                       :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                       :remote-cwd (plist-get profile :remote-cwd)
                       :kernelspec (plist-get profile :kernelspec)
                       :jupyter-command (plist-get profile :jupyter-command)
                       :remote-connection-file (plist-get launch :connection-file)
                      :remote-pid nil
                      :created-at (emacs-jupyter-notebook--timestamp)
                      :tunnel-ports nil
                      :display-name (format "%s:%s"
                                            (emacs-jupyter-notebook-ssh-destination profile)
                                            (plist-get profile :kernelspec))
                      :session-id session-id
                      :local-file buffer-file-name))
         (context (emacs-jupyter-notebook--async-start-context
                   profile entry session-id launch callback error-callback)))
    (setq context (emacs-jupyter-notebook--async-launch context))
    context))

;;;###autoload
(defun emacs-jupyter-notebook-reconnect-remote-kernel (entry &optional callback error-callback)
  "Reconnect current buffer to an existing remote kernel ENTRY asynchronously.
  CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (interactive (list (emacs-jupyter-notebook--read-registry-entry)))
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (emacs-jupyter-notebook-jupyter--ensure)
  (let ((profile (emacs-jupyter-notebook--entry-profile entry)))
    (emacs-jupyter-notebook--async-retrieve
     (emacs-jupyter-notebook--async-reconnect-context profile entry callback error-callback))))

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
  "Shut down the current kernel, close tunnel, and reset state."
  (interactive)
  (emacs-jupyter-notebook--cleanup-current-state "Kernel shut down"))

(defun emacs-jupyter-notebook-retry-fresh-kernel (&optional profile-name)
  "Cancel/cleanup current state and start a fresh kernel.
With PROFILE-NAME, start that profile.  Otherwise reuse the current session's
profile, then fall back to `emacs-jupyter-notebook-default-profile'."
  (interactive)
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (context emacs-jupyter-notebook--async-context)
         (profile (or profile-name
                      (plist-get entry :profile)
                      (plist-get (plist-get context :profile) :profile)
                      emacs-jupyter-notebook-default-profile)))
    (emacs-jupyter-notebook--cleanup-current-state "Retrying with fresh kernel" t)
    (emacs-jupyter-notebook-start-remote-kernel profile)))

;;;###autoload
(defun emacs-jupyter-notebook-status ()
  "Display the current buffer's EJN engine state."
  (interactive)
  (let ((text (emacs-jupyter-notebook--format-status
               (emacs-jupyter-notebook-status-snapshot))))
    (if (called-interactively-p 'interactive)
        (emacs-jupyter-notebook--display-command-output "*ejn-status*" text)
      text)))

(defun emacs-jupyter-notebook-fetch-remote-log ()
  "Fetch and display the current session's remote kernel log."
  (interactive)
  (unless emacs-jupyter-notebook--session-entry
    (user-error "No active EJN session"))
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (connection-file (plist-get entry :remote-connection-file)))
    (unless connection-file
      (user-error "Current EJN session has no remote connection file"))
    (emacs-jupyter-notebook--display-command-output
     "*ejn-log*"
     (emacs-jupyter-notebook-ssh-run-command
      (emacs-jupyter-notebook-ssh-build-remote-cat-log
       (emacs-jupyter-notebook--entry-profile entry) connection-file)))))

(defun emacs-jupyter-notebook-list-remote-processes (&optional profile-name)
  "List likely remote EJN kernel processes for PROFILE-NAME."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (emacs-jupyter-notebook--display-command-output
     "*ejn-remote-processes*"
     (emacs-jupyter-notebook-ssh-run-command
      (emacs-jupyter-notebook-ssh-build-remote-ps-command profile)))))

(defun emacs-jupyter-notebook-clean-orphaned-kernels (&optional profile-name)
  "Clean all EJN kernel files and processes in PROFILE-NAME's remote cache."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (when (or (not (called-interactively-p 'interactive))
              (yes-or-no-p (format "Clean EJN kernels in %s on %s? "
                                   (plist-get profile :remote-cache-dir)
                                   (emacs-jupyter-notebook-ssh-destination profile))))
      (emacs-jupyter-notebook-ssh-run-command
       (emacs-jupyter-notebook-ssh-build-remote-cleanup-all profile))
      (message "emacs-jupyter-notebook: requested remote orphan cleanup"))))

;;;###autoload
(defun emacs-jupyter-notebook-clear-results ()
  "Clear inline result overlays from the current buffer."
  (interactive)
  (emacs-jupyter-notebook-result-clear-all)
  (emacs-jupyter-notebook-jupyter-clear-overlays))

(defun emacs-jupyter-notebook-cancel-operation ()
  "Cancel the current buffer's in-progress async Jupyter operation."
  (interactive)
  (if emacs-jupyter-notebook--async-context
      (progn
        (emacs-jupyter-notebook--async-fail
         emacs-jupyter-notebook--async-context "Operation cancelled")
        (setq emacs-jupyter-notebook--async-context nil))
    (user-error "No emacs-jupyter-notebook operation is in progress")))

(defun emacs-jupyter-notebook-show-output ()
  "Open the full output of the nearest result overlay in a dedicated buffer."
  (interactive)
  (let ((ov (emacs-jupyter-notebook-result--nearest-overlay)))
    (unless ov
      (user-error "No result overlay at or near point"))
    (let* ((content (or (overlay-get ov 'emacs-jupyter-notebook-result-full-content)
                        (overlay-get ov 'emacs-jupyter-notebook-content)
                        ""))
           (buf (get-buffer-create "*ejn-output*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert content)
          (goto-char (point-min)))
        (setq buffer-read-only t))
      (display-buffer buf))))

(defun emacs-jupyter-notebook--ensure-client ()
  "Return the current buffer's kernel client or signal an error."
  (or emacs-jupyter-notebook--client
      (error "No Jupyter kernel connected; run `emacs-jupyter-notebook-start-remote-kernel'")))

(provide 'emacs-jupyter-notebook)

;;; emacs-jupyter-notebook.el ends here
