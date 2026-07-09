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
    (let ((timeout emacs-jupyter-notebook-ssh-connect-timeout))
      (when (and (integerp timeout) (> timeout 0))
        (setq args (append args (list "-o" (format "ConnectTimeout=%d" timeout))))))
    (when emacs-jupyter-notebook-ssh-batch-mode
      (setq args (append args (list "-o" "BatchMode=yes"))))
    (when-let ((port (plist-get profile :port)))
      (setq args (append args (list (if scp "-P" "-p") (format "%s" port)))))
    (when-let ((identity (plist-get profile :identity-file)))
      (setq args (append args (list "-i" (expand-file-name identity)))))
    args))

(defun emacs-jupyter-notebook-ssh--control-args ()
  "Return SSH connection-multiplexing option args, or nil when disabled.
Shared by the short one-shot commands (launch, connection-file retrieval,
PID probe, remote cleanup) so they ride a single master connection instead
of re-handshaking each time.  The persistent tunnel does NOT use these;
see `--no-control-args'."
  (when emacs-jupyter-notebook-ssh-control-master
    (list "-o" "ControlMaster=auto"
          "-o" (format "ControlPath=%s" emacs-jupyter-notebook-ssh-control-path)
          "-o" (format "ControlPersist=%s"
                       emacs-jupyter-notebook-ssh-control-persist))))

(defun emacs-jupyter-notebook-ssh--no-control-args ()
  "Return SSH option args that force this connection to stand alone.
When multiplexing is enabled globally, the persistent tunnel must still own
its own SSH connection so a dropped link is visible to the tunnel
sentinel/heartbeat; `ControlPath=none' opts it out of any shared master
(including one configured in the user's ssh_config)."
  (when emacs-jupyter-notebook-ssh-control-master
    (list "-o" "ControlPath=none")))

(defun emacs-jupyter-notebook-ssh-command (profile &optional remote-command)
  "Return an SSH argv list for PROFILE.
When REMOTE-COMMAND is non-nil, append it as the remote shell command."
  (append (list emacs-jupyter-notebook-ssh-command)
          (emacs-jupyter-notebook-ssh--option-args profile)
          (emacs-jupyter-notebook-ssh--control-args)
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
          (emacs-jupyter-notebook-ssh--no-control-args)
          (list "-N" "-T" "-o" "ExitOnForwardFailure=yes")
          (emacs-jupyter-notebook-ssh--keepalive-args)
          (cl-loop for key in emacs-jupyter-notebook-connection-port-keys
                   for remote = (plist-get remote-ports key)
                   for local = (plist-get local-ports key)
                   when (and remote local)
                   append (list "-L" (format "%d:127.0.0.1:%d" local remote)))
          (list (emacs-jupyter-notebook-ssh-destination profile))))

(defun emacs-jupyter-notebook-ssh--scp-remote-path (path)
  "Return PATH rewritten for scp's remote-file argument.
Unlike the remote-launch / cleanup commands, scp does NOT run through the
remote login shell, so a leading `~' is never shell-expanded here.  Worse,
scp on OpenSSH 9+ speaks the SFTP protocol by default, whose server treats
a leading `~' as a LITERAL directory name rather than the home directory —
so `host:~/.cache/...' fails with \"No such file or directory\" even though
the launch created the directory (there `~'/`$HOME' DID expand, via the
shell).  Convert a `~'-anchored PATH to the equivalent home-RELATIVE path:
both the SFTP server and the legacy SCP-protocol remote shell resolve a
bare relative path against the login user's home directory, so retrieval
works identically across OpenSSH versions.  Absolute paths (and any path
without a `~' anchor) are returned unchanged."
  (cond
   ((equal path "~") ".")
   ((string-prefix-p "~/" path) (substring path 2))
   (t path)))

(defun emacs-jupyter-notebook-ssh-scp-from-command (profile remote-file local-file)
  "Return an SCP argv list copying REMOTE-FILE from PROFILE to LOCAL-FILE."
  (append (list emacs-jupyter-notebook-scp-command)
          (emacs-jupyter-notebook-ssh--option-args profile t)
          (emacs-jupyter-notebook-ssh--control-args)
          (list (format "%s:%s"
                        (emacs-jupyter-notebook-ssh-destination profile)
                        (emacs-jupyter-notebook-ssh--scp-remote-path remote-file))
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

(defun emacs-jupyter-notebook-ssh-build-pid-alive (profile pid)
  "Return an SSH argv list that exits 0 iff PID is alive on PROFILE's host.
Uses `kill -0 <pid>' which sends no signal but reports whether the process
exists and is owned by the SSH user.  Intended for the W4.4 reconnect-time
liveness probe."
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "kill -0 %s" (shell-quote-argument (format "%s" pid)))))

(defun emacs-jupyter-notebook-ssh-build-batch-pid-alive (profile pids &optional connect-timeout)
  "Return an SSH argv reporting which of PIDS are alive on PROFILE's host.
W11: the batched, per-host liveness probe behind the non-destructive
registry prune.  One ssh runs a shell loop that echoes each PID that
`kill -0' confirms alive (no signal is sent), then prints the sentinel
`__EJN_DONE__' so callers can tell a genuine \"host answered, these are
dead\" reply apart from a connection failure (which yields no sentinel and
a non-zero ssh exit).  The loop always exits 0 because of the trailing
sentinel `echo', so it does not trip a non-zero-exit error path.

A bounded `ConnectTimeout' (CONNECT-TIMEOUT, default
`emacs-jupyter-notebook-prune-ssh-timeout') plus `BatchMode=yes' guarantee
an unreachable or auth-prompting host cannot hang Emacs — it fails fast
and its PIDs stay UNKNOWN (never pruned)."
  (let* ((timeout (or connect-timeout emacs-jupyter-notebook-prune-ssh-timeout 5))
         (pid-list (mapconcat (lambda (p) (shell-quote-argument (format "%s" p)))
                              pids " "))
         (remote (format
                  "for p in %s; do kill -0 \"$p\" 2>/dev/null && echo \"$p\"; done; echo __EJN_DONE__"
                  pid-list))
         (argv (emacs-jupyter-notebook-ssh-command profile remote)))
    ;; Splice the bounding options in right after the ssh program name so
    ;; they apply to this one-shot probe without touching the shared
    ;; `ssh-options' customization.
    (append (list (car argv)
                  "-o" (format "ConnectTimeout=%d" timeout)
                  "-o" "BatchMode=yes")
            (cdr argv))))

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

(defun emacs-jupyter-notebook-ssh--self-excluding-pattern (pattern)
  "Return PATTERN with its first character bracketed for pkill/grep self-exclusion.
A `pkill -f' / `grep' invocation embeds its own PATTERN in the running
shell's command line, so an unbracketed pattern matches — and kills — that
shell too.  Bracketing the first character (`Kfoo' -> `[K]foo') keeps the
regex matching the target kernel processes while ensuring the literal
pattern text can never match the pkill/grep process itself.  A nil or empty
PATTERN is returned unchanged."
  (if (and (stringp pattern) (> (length pattern) 0))
      (format "[%c]%s" (aref pattern 0) (substring pattern 1))
    pattern))

(defun emacs-jupyter-notebook-ssh-build-remote-ps-command (profile)
  "Return an SSH argv list that lists likely remote EJN kernel processes.
The `KernelManager.connection_file=' match pattern is emitted inside double
quotes so a `~'-anchored cache dir's `$HOME' still expands in the remote
shell (it must, to match the kernel's expanded argv) while glob/whitespace
metacharacters stay inert, and its first character is bracketed so the
`grep' does not list itself (see `--self-excluding-pattern')."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (emacs-jupyter-notebook-ssh--quote-remote-path
                     (plist-get profile :remote-cache-dir)))
         (pattern (emacs-jupyter-notebook-ssh--self-excluding-pattern
                   (format "KernelManager.connection_file=%s/kernel-" cache-dir))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format "ps -eo pid,ppid,stat,etime,args | grep \"%s\" || true" pattern))))

(defun emacs-jupyter-notebook-ssh-build-remote-cleanup-all (profile)
  "Return an SSH argv list that cleans all EJN cache-dir kernels for PROFILE.
The `pkill -f' pattern is double-quoted (so a `~' cache dir's `$HOME'
expands to match the kernel's expanded argv, unlike the previous
double-`shell-quote-argument' form that escaped the `$' to a literal that
matched nothing) and its first character is bracketed so the running shell
is not itself killed before the `rm' half runs (see
`--self-excluding-pattern')."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (emacs-jupyter-notebook-ssh--quote-remote-path
                     (plist-get profile :remote-cache-dir)))
         (pattern (emacs-jupyter-notebook-ssh--self-excluding-pattern
                   (format "KernelManager.connection_file=%s/kernel-" cache-dir))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format (concat "{ pkill -f \"%s\" 2>/dev/null || true; "
                     "rm -f %s/kernel-*.json %s/kernel-*.log; }")
             pattern cache-dir cache-dir))))

(defun emacs-jupyter-notebook-ssh-classify-stderr (stderr)
  "Classify SSH STDERR into a (:kind SYMBOL :hint STRING) plist.
This is a pure function: input is a string (possibly multi-line), output is
a plist describing the dominant failure mode and an actionable hint suitable
for surfacing to the user.

Kinds (in priority order; the first matching pattern wins):
- `host-key-changed' — the remote host key changed; the user must accept the
  new key explicitly (often by editing ~/.ssh/known_hosts).
- `auth-failed' — permission denied / authentication failed; check identity
  file, agent, or `:user' / `:identity-file' on the profile.
- `host-unreachable' — name resolution or routing failure; check the host
  name and connectivity.
- `connection-refused' — TCP-level refusal; sshd may be down or behind a
  firewall.
- `forward-refused' — port forwarding refused by the remote; usually means
  the requested remote port is already in use or AllowTcpForwarding is off.
- `unknown' — fallback when no pattern matches."
  (let ((s (or stderr "")))
    (cond
     ((string-match-p
       (concat "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"
               "\\|Host key verification failed")
       s)
      (list :kind 'host-key-changed
            :hint
            (concat "Remote host key changed. Verify with the admin and "
                    "either remove the stale line from ~/.ssh/known_hosts "
                    "or `ssh-keygen -R <host>'.")))
     ((string-match-p
       (concat "Permission denied"
               "\\|Authentication failed"
               "\\|Too many authentication failures"
               "\\|Could not open a connection to your authentication agent")
       s)
      (list :kind 'auth-failed
            :hint
            (concat "SSH authentication failed. Check the profile's "
                    "`:identity-file', `:user', and that ssh-agent is "
                    "running or the key is loaded.")))
     ((string-match-p
       (concat "Name or service not known"
               "\\|Could not resolve hostname"
               "\\|nodename nor servname provided"
               "\\|No route to host"
               "\\|Network is unreachable")
       s)
      (list :kind 'host-unreachable
            :hint
            (concat "Could not reach the remote host. Verify the profile's "
                    "`:host', DNS, and network connectivity.")))
     ((string-match-p "Connection refused" s)
      (list :kind 'connection-refused
            :hint
            (concat "The remote SSH port refused the connection. Confirm "
                    "sshd is running and the profile's `:port' is correct.")))
     ((string-match-p
       (concat "remote port forwarding failed"
               "\\|Could not request local forwarding"
               "\\|cannot listen to port"
               "\\|bind \\[127\\.0\\.0\\.1\\]")
       s)
      (list :kind 'forward-refused
            :hint
            (concat "SSH port forwarding refused. The remote tunnel port may "
                    "already be in use, or AllowTcpForwarding is disabled.")))
     (t
      (list :kind 'unknown
            :hint
            (concat "Unrecognized SSH failure. See *Messages* or run "
                    "`M-x emacs-jupyter-notebook-fetch-remote-log' for "
                    "details."))))))

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
