;;; emacs-jupyter-notebook-ssh.el --- SSH and SCP command construction  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; External-process remote interaction.  This file does not use TRAMP.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-connection)

(defun emacs-jupyter-notebook-ssh--profile-name (profile)
  "Return PROFILE's string name."
  (cond
   ((plistp profile) (or (plist-get profile :profile)
                         emacs-jupyter-notebook-default-profile))
   ((null profile) emacs-jupyter-notebook-default-profile)
   ((symbolp profile) (symbol-name profile))
   (t (format "%s" profile))))

(defun emacs-jupyter-notebook-ssh--profile-entry (name)
  "Return the profile entry named NAME."
  (cl-find-if (lambda (entry)
                (string= name (format "%s" (car entry))))
              emacs-jupyter-notebook-remote-profiles))

(defun emacs-jupyter-notebook-ssh-profile (&optional profile)
  "Return PROFILE as a normalized plist with defaults applied."
  (let* ((name (emacs-jupyter-notebook-ssh--profile-name profile))
         (stored (and (not (plistp profile))
                      (cdr (emacs-jupyter-notebook-ssh--profile-entry name))))
         (plist (copy-sequence (or (and (plistp profile) profile)
                                   stored
                                   nil))))
    (setq plist (plist-put plist :profile name))
    (unless (plist-member plist :remote-cwd)
      (setq plist (plist-put plist :remote-cwd
                             emacs-jupyter-notebook-remote-working-directory)))
    (unless (plist-member plist :remote-cache-dir)
      (setq plist (plist-put plist :remote-cache-dir
                             emacs-jupyter-notebook-remote-cache-directory)))
    (unless (plist-member plist :kernelspec)
      (setq plist (plist-put plist :kernelspec
                             emacs-jupyter-notebook-default-kernelspec)))
    (unless (plist-member plist :jupyter-command)
      (setq plist (plist-put plist :jupyter-command
                             emacs-jupyter-notebook-jupyter-command)))
    plist))

(defun emacs-jupyter-notebook-ssh-destination (profile)
  "Return the SSH destination for PROFILE."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (host (or (plist-get profile :host)
                   (plist-get profile :remote-host)))
         (user (plist-get profile :user)))
    (unless (and host (not (string-empty-p host)))
      (error "Remote profile %s has no :host" (plist-get profile :profile)))
    (if (and user (not (string-match-p "@" host)))
        (format "%s@%s" user host)
      host)))

(defun emacs-jupyter-notebook-ssh--option-args (profile &optional scp)
  "Return option arguments for PROFILE.
When SCP is non-nil, translate :port to scp's -P option."
  (let ((profile (emacs-jupyter-notebook-ssh-profile profile))
        args)
    (setq args (append args emacs-jupyter-notebook-ssh-options))
    (setq args (append args (plist-get profile :ssh-options)))
    (when-let ((port (plist-get profile :port)))
      (setq args (append args (list (if scp "-P" "-p") (format "%s" port)))))
    (when-let ((identity (plist-get profile :identity-file)))
      (setq args (append args (list "-i" (expand-file-name identity)))))
    args))

(defun emacs-jupyter-notebook-ssh-command (profile &optional remote-command)
  "Return an SSH argv list for PROFILE.
When REMOTE-COMMAND is non-nil, append it as the remote shell command."
  (append (list emacs-jupyter-notebook-ssh-command)
          (emacs-jupyter-notebook-ssh--option-args profile)
          (list (emacs-jupyter-notebook-ssh-destination profile))
          (when remote-command (list remote-command))))

(defun emacs-jupyter-notebook-ssh--keepalive-args ()
  "Return SSH keepalive option args based on the keepalive customization.
When `emacs-jupyter-notebook-tunnel-keepalive-interval' is a
positive integer, return `(\"-o\" \"ServerAliveInterval=N\" \"-o\"
\"ServerAliveCountMax=3\")'.  Otherwise return nil."
  (let ((interval emacs-jupyter-notebook-tunnel-keepalive-interval))
    (when (and (integerp interval) (> interval 0))
      (list "-o" (format "ServerAliveInterval=%d" interval)
            "-o" "ServerAliveCountMax=3"))))

(defun emacs-jupyter-notebook-ssh-tunnel-command (profile remote-ports local-ports)
  "Return an SSH tunnel argv list for PROFILE.
REMOTE-PORTS and LOCAL-PORTS are plists keyed by Jupyter channel
port keys."
  (append (list emacs-jupyter-notebook-ssh-command)
          (emacs-jupyter-notebook-ssh--option-args profile)
          (list "-N" "-T" "-o" "ExitOnForwardFailure=yes")
          (emacs-jupyter-notebook-ssh--keepalive-args)
          (cl-loop for key in emacs-jupyter-notebook-connection-port-keys
                   for remote = (plist-get remote-ports key)
                   for local = (plist-get local-ports key)
                   when (and remote local)
                   append (list "-L" (format "%d:127.0.0.1:%d" local remote)))
          (list (emacs-jupyter-notebook-ssh-destination profile))))

(defun emacs-jupyter-notebook-ssh-scp-from-command (profile remote-file local-file)
  "Return an SCP argv list copying REMOTE-FILE from PROFILE to LOCAL-FILE."
  (append (list emacs-jupyter-notebook-scp-command)
          (emacs-jupyter-notebook-ssh--option-args profile t)
          (list (format "%s:%s"
                        (emacs-jupyter-notebook-ssh-destination profile)
                        remote-file)
                local-file)))

(defun emacs-jupyter-notebook-ssh--remote-join (directory file)
  "Join remote DIRECTORY and FILE without invoking file handlers."
  (concat (string-remove-suffix "/" directory) "/" file))

(defun emacs-jupyter-notebook-ssh--quote-remote-path (path)
  "Quote remote shell PATH while preserving leading home expansion."
  (cond
   ((equal path "~") "$HOME")
   ((string-prefix-p "~/" path)
    (let ((rest (substring path 2)))
      (if (string-empty-p rest)
          "$HOME/"
        (concat "$HOME/" (shell-quote-argument rest)))))
   (t (shell-quote-argument path))))

(defun emacs-jupyter-notebook-ssh-remote-connection-file (profile session-id)
  "Return the remote connection file path for PROFILE and SESSION-ID."
  (emacs-jupyter-notebook-ssh--remote-join
   (plist-get (emacs-jupyter-notebook-ssh-profile profile) :remote-cache-dir)
   (format "kernel-%s.json" session-id)))

(defun emacs-jupyter-notebook-ssh-build-remote-launch (profile session-id)
  "Return launch metadata for starting a remote kernel.
The return value is a plist containing :argv, :remote-command,
:connection-file, and :log-file."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (plist-get profile :remote-cache-dir))
         (remote-cwd (plist-get profile :remote-cwd))
         (kernelspec (plist-get profile :kernelspec))
         (jupyter-cmd (plist-get profile :jupyter-command))
         (connection-file (emacs-jupyter-notebook-ssh-remote-connection-file
                           profile session-id))
         (log-file (emacs-jupyter-notebook-ssh--remote-join
                    cache-dir (format "kernel-%s.log" session-id)))
         (remote-command
          (mapconcat
           #'identity
           (list
            (format "mkdir -p %s"
                    (emacs-jupyter-notebook-ssh--quote-remote-path cache-dir))
            (format "cd %s"
                    (emacs-jupyter-notebook-ssh--quote-remote-path remote-cwd))
            (format (concat "{ nohup %s kernel --kernel=%s "
                            "--KernelManager.connection_file=%s "
                            "> %s 2>&1 < /dev/null & printf 'EJN_PID=%%s\\n' \"$!\"; }")
                    jupyter-cmd
                    (shell-quote-argument kernelspec)
                    (emacs-jupyter-notebook-ssh--quote-remote-path connection-file)
                    (emacs-jupyter-notebook-ssh--quote-remote-path log-file)))
           " && ")))
    (list :argv (emacs-jupyter-notebook-ssh-command profile remote-command)
          :remote-command remote-command
          :connection-file connection-file
          :log-file log-file)))

(defun emacs-jupyter-notebook-ssh-build-remote-kill (profile pid)
  "Return an SSH argv list that asks the remote shell to terminate PID."
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "kill %s" (shell-quote-argument (format "%s" pid)))))

(defun emacs-jupyter-notebook-ssh-build-remote-cleanup (profile connection-file)
  "Return an SSH argv list that cleans remote processes for CONNECTION-FILE."
  (let ((remote-file (emacs-jupyter-notebook-ssh--quote-remote-path connection-file))
        (remote-log (emacs-jupyter-notebook-ssh--quote-remote-path
                     (replace-regexp-in-string "\\.json\\'" ".log" connection-file))))
    (emacs-jupyter-notebook-ssh-command
     profile
      (format "{ pkill -f %s 2>/dev/null || true; rm -f %s %s; }"
              remote-file remote-file remote-log))))

(defun emacs-jupyter-notebook-ssh-build-remote-cat-log (profile connection-file)
  "Return an SSH argv list that prints the log for CONNECTION-FILE."
  (let ((remote-log (emacs-jupyter-notebook-ssh--quote-remote-path
                     (replace-regexp-in-string "\\.json\\'" ".log" connection-file))))
    (emacs-jupyter-notebook-ssh-command profile (format "cat %s" remote-log))))

(defun emacs-jupyter-notebook-ssh-build-remote-ps-command (profile)
  "Return an SSH argv list that lists likely remote EJN kernel processes."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (emacs-jupyter-notebook-ssh--quote-remote-path
                     (plist-get profile :remote-cache-dir))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format "ps -eo pid,ppid,stat,etime,args | grep %s | grep -v grep || true"
             (shell-quote-argument (format "KernelManager.connection_file=%s/kernel-"
                                           cache-dir))))))

(defun emacs-jupyter-notebook-ssh-build-remote-cleanup-all (profile)
  "Return an SSH argv list that cleans all EJN cache-dir kernels for PROFILE."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (emacs-jupyter-notebook-ssh--quote-remote-path
                     (plist-get profile :remote-cache-dir))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format (concat "{ pkill -f %s 2>/dev/null || true; "
                     "rm -f %s/kernel-*.json %s/kernel-*.log; }")
             (shell-quote-argument (format "KernelManager.connection_file=%s/kernel-"
                                           cache-dir))
             cache-dir cache-dir))))

(defun emacs-jupyter-notebook-ssh-run-command (argv)
  "Run ARGV synchronously and return stdout.
Signal an error if the command exits non-zero."
  (with-temp-buffer
    (let ((status (apply #'process-file (car argv) nil (current-buffer) nil (cdr argv))))
      (unless (and (integerp status) (zerop status))
        (error "Command failed (%s): %s\n%s"
               status (mapconcat #'identity argv " ") (buffer-string)))
      (buffer-string))))

(defun emacs-jupyter-notebook-ssh-start-process (name argv &optional sentinel)
  "Start ARGV asynchronously as process NAME and return the process."
  (let* ((stderr-buffer (generate-new-buffer (format " *%s stderr*" name)))
         (process (make-process :name name
                                :buffer (generate-new-buffer (format " *%s*" name))
                                :command argv
                                :connection-type 'pipe
                                :noquery t
                                :sentinel sentinel
                                :stderr stderr-buffer)))
    (process-put process 'emacs-jupyter-notebook-stderr-buffer stderr-buffer)
    process))

(provide 'emacs-jupyter-notebook-ssh)

;;; emacs-jupyter-notebook-ssh.el ends here
