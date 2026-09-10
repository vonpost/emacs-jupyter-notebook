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

(defconst emacs-jupyter-notebook-ssh-kernelspec-max-bytes 65536)
(defconst emacs-jupyter-notebook-ssh-kernelspec-max-argv 64)
(defconst emacs-jupyter-notebook-ssh-kernelspec-max-env 64)
(defconst emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes 4096)
(defconst emacs-jupyter-notebook-ssh-kernelspec-max-argv-bytes 16384)
(defconst emacs-jupyter-notebook-ssh-kernelspec-max-env-bytes 16384)
(defconst emacs-jupyter-notebook-ssh--management-output-hard-limit
  (* 1024 1024)
  "Immutable per-stream management output ceiling.")

(defconst emacs-jupyter-notebook-ssh--kernelspec-resolver
  (concat
   "import json,os,re,shutil,sys\n"
   "from string import Template\n"
   "from jupyter_client.kernelspec import KernelSpecManager\n"
   "name,connection,session=sys.argv[1:]\n"
   "spec=KernelSpecManager().get_kernel_spec(name)\n"
   "resource=os.path.abspath(spec.resource_dir)\n"
   "argv=list(spec.argv); env=dict(spec.env)\n"
   "def text(x): return isinstance(x,str) and '\\0' not in x and len(x.encode('utf-8'))<=4096\n"
   "def braces(x):\n"
   " out=[]; i=0; repl={'{connection_file}':connection,'{resource_dir}':resource}\n"
   " while i<len(x):\n"
   "  a=x.find('{',i); b=x.find('}',i)\n"
   "  if b>=0 and (a<0 or b<a): raise ValueError('placeholder')\n"
   "  if a<0: out.append(x[i:]); break\n"
   "  z=x.find('}',a+1)\n"
   "  if z<0: raise ValueError('placeholder')\n"
   "  out.append(x[i:a]); token=x[a:z+1]\n"
   "  if token not in repl: raise ValueError('placeholder')\n"
   "  out.append(repl[token]); i=z+1\n"
   " return ''.join(out)\n"
   "if not (text(name) and text(connection) and text(session) and os.path.isabs(connection) and os.path.basename(connection)==f'kernel-{session}.json' and isinstance(argv,list) and 1<=len(argv)<=64 and isinstance(env,dict) and len(env)<=64 and text(resource) and os.path.isabs(resource) and os.path.isdir(resource)): raise ValueError('schema')\n"
   "count=0; final=[]\n"
   "for value in argv:\n"
   " if not text(value): raise ValueError('argv')\n"
   " count+=value.count('{connection_file}'); value=braces(value)\n"
   " if not value or not text(value): raise ValueError('argv')\n"
   " final.append(value)\n"
   "if count!=1 or sum(len(x.encode('utf-8')) for x in final)>16384: raise ValueError('argv')\n"
   "if re.fullmatch(r'python(?:3(?:\\.\\d+)?)?',final[0]): final[0]=sys.executable\n"
   "elif not os.path.isabs(final[0]): final[0]=shutil.which(final[0]) or ''\n"
   "if not final[0] or not os.path.isabs(final[0]) or sum(len(x.encode('utf-8')) for x in final)>16384: raise ValueError('executable')\n"
   "expanded={}\n"
   "for key,value in env.items():\n"
   " if not (text(key) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',key) and text(value)): raise ValueError('env')\n"
   " value=Template(value).safe_substitute(os.environ)\n"
   " if not text(value): raise ValueError('env')\n"
   " expanded[key]=value\n"
   "if sum(len(k.encode('utf-8'))+len(v.encode('utf-8')) for k,v in expanded.items())>16384: raise ValueError('env')\n"
   "print(json.dumps({'kernelspecs':{name:{'resource_dir':resource,'spec':{'argv':final,'env':expanded,'metadata':{'ejn_connection_file':connection,'ejn_session_id':session}}}}},separators=(',',':')))\n")
  "Constant remote Python source that resolves one selected kernelspec.")

(defun emacs-jupyter-notebook-ssh--python-command (profile)
  "Return PROFILE's validated structured resolver Python argv.
Legacy `:jupyter-command' profile values are rejected rather than parsed."
  (when (plist-member profile :jupyter-command)
    (error "Legacy :jupyter-command is unsupported; use :python-command argv"))
  (let ((argv (plist-get profile :python-command)))
    (unless (and (listp argv) argv
                 (<= (length argv)
                     emacs-jupyter-notebook-ssh-kernelspec-max-argv)
                 (cl-every (lambda (value)
                             (and (stringp value)
                                  (not (string-empty-p value))
                                  (not (string-match-p (string 0) value))
                                  (<= (string-bytes value)
                                      emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)))
                           argv)
                 (<= (apply #'+ (mapcar #'string-bytes argv))
                     emacs-jupyter-notebook-ssh-kernelspec-max-argv-bytes))
      (error ":python-command must be a non-empty argv list of strings"))
    (copy-sequence argv)))

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
    (when (plist-member plist :jupyter-command)
      (error "Legacy :jupyter-command is unsupported; use :python-command argv"))
    (unless (plist-member plist :python-command)
      (setq plist (plist-put plist :python-command
                             emacs-jupyter-notebook-python-command)))
    (emacs-jupyter-notebook-ssh--python-command plist)
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
The persistent target tunnel must own its connection, even when one-shot
multiplexing is disabled.  Append these args after all user options: unlike
`-o ControlPath=none', the final `-S none' overrides an earlier `-S' or
`-o ControlPath' as well as ssh_config.  A ProxyJump child still uses the
jump host's own SSH configuration."
  (list "-S" "none"))

(defun emacs-jupyter-notebook-ssh-command (profile &optional remote-command)
  "Return an SSH argv list for PROFILE.
When REMOTE-COMMAND is non-nil, append it as the remote shell command."
  (append (list emacs-jupyter-notebook-ssh-command)
          (emacs-jupyter-notebook-ssh--option-args profile)
          (emacs-jupyter-notebook-ssh--control-args)
          (emacs-jupyter-notebook-ssh--keepalive-args)
          (list (emacs-jupyter-notebook-ssh-destination profile))
          (when remote-command (list remote-command))))

(defun emacs-jupyter-notebook-ssh--keepalive-args ()
  "Return ServerAlive option args based on the keepalive customization.
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
          (emacs-jupyter-notebook-ssh--keepalive-args)
          (list (format "%s:%s"
                        (emacs-jupyter-notebook-ssh-destination profile)
                        (emacs-jupyter-notebook-ssh--scp-remote-path remote-file))
                local-file)))

(defun emacs-jupyter-notebook-ssh-scp-to-command (profile local-file remote-file)
  "Return an SCP argv list copying LOCAL-FILE to REMOTE-FILE on PROFILE.
The caller chooses a private sibling staging path and publishes it separately,
so an interrupted upload can never replace the live connection file."
  (append (list emacs-jupyter-notebook-scp-command "-p")
          (emacs-jupyter-notebook-ssh--option-args profile t)
          (emacs-jupyter-notebook-ssh--control-args)
          (emacs-jupyter-notebook-ssh--keepalive-args)
          (list local-file
                (format "%s:%s"
                        (emacs-jupyter-notebook-ssh-destination profile)
                        (emacs-jupyter-notebook-ssh--scp-remote-path remote-file)))))

(defun emacs-jupyter-notebook-ssh--restart-staging-paths-valid-p
    (staging-file connection-file)
  "Return non-nil for one private restart staging sibling and destination."
  (and (stringp connection-file) (stringp staging-file)
       (file-name-absolute-p connection-file)
       (file-name-absolute-p staging-file)
       (not (string-match-p "[\0\n\r]" connection-file))
       (not (string-match-p "[\0\n\r]" staging-file))
       (<= (string-bytes connection-file)
           emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
       (<= (string-bytes staging-file)
           emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
       (equal (file-name-directory staging-file)
              (file-name-directory connection-file))
       (string-match-p "\\`kernel-[[:alnum:]_.-]+\\.json\\'"
                       (file-name-nondirectory connection-file))
       (string-match-p
        (concat "\\`" (regexp-quote (file-name-nondirectory connection-file))
                "\\.restart-[[:alnum:]_.-]+\\'")
        (file-name-nondirectory staging-file))))

(defun emacs-jupyter-notebook-ssh-build-remote-publish-connection
    (profile staging-file connection-file)
  "Return bounded SSH argv that publishes STAGING-FILE as CONNECTION-FILE.
The destination must be absent after a confirmed direct-kernel shutdown.  Do
not overwrite it: a stale cancelled restart must never replace a later
kernel's live connection file."
  (unless (emacs-jupyter-notebook-ssh--restart-staging-paths-valid-p
           staging-file connection-file)
    (error "Restart connection publish paths are invalid"))
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "umask 077; test ! -e %s && test ! -L %s && test ! -L %s && test -f %s && chmod 600 %s && ln %s %s && rm -f -- %s"
           (emacs-jupyter-notebook-ssh--quote-remote-path connection-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path connection-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path connection-file)
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file))))

(defun emacs-jupyter-notebook-ssh-build-remote-remove-restart-staging
    (profile staging-file connection-file)
  "Return bounded SSH argv unlinking only validated restart STAGING-FILE."
  (unless (emacs-jupyter-notebook-ssh--restart-staging-paths-valid-p
           staging-file connection-file)
    (error "Restart connection cleanup paths are invalid"))
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "rm -f -- %s"
           (emacs-jupyter-notebook-ssh--quote-remote-path staging-file))))

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

(defun emacs-jupyter-notebook-ssh-build-kernelspec-resolution (profile session-id)
  "Return bounded async kernelspec-resolution metadata for PROFILE.
The resolver prefix is structured argv; it never passes through shell parsing."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (plist-get profile :remote-cache-dir))
         (remote-cwd (plist-get profile :remote-cwd))
         (kernelspec (plist-get profile :kernelspec))
         (python-command (emacs-jupyter-notebook-ssh--python-command profile))
         (connection-file (emacs-jupyter-notebook-ssh-remote-connection-file
                           profile session-id))
         (log-file (emacs-jupyter-notebook-ssh--remote-join
                    cache-dir (format "kernel-%s.log" session-id)))
         (sidecar-file (emacs-jupyter-notebook-ssh--remote-join
                        cache-dir (format "kernel-%s.pid" session-id)))
         (_ (unless (and (stringp kernelspec) (not (string-empty-p kernelspec))
                         (not (string-match-p (string 0) kernelspec))
                         (<= (string-bytes kernelspec)
                             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
                         (stringp cache-dir) (stringp remote-cwd)
                         (stringp session-id) (not (string-empty-p session-id))
                         (not (string-match-p (string 0) session-id))
                         (string-match-p "\\`[[:alnum:]_.-]+\\'" session-id)
                         (<= (string-bytes session-id)
                             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
                         (not (string-empty-p cache-dir))
                         (not (string-empty-p remote-cwd))
                         (not (string-match-p (string 0) cache-dir))
                         (not (string-match-p (string 0) remote-cwd))
                         (not (string-match-p "[\n\r]" cache-dir))
                         (not (string-match-p "[\n\r]" remote-cwd))
                         (<= (string-bytes cache-dir)
                             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
                         (<= (string-bytes remote-cwd)
                             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes))
              (error "Remote profile has invalid kernelspec or paths")))
         (remote-command
          (concat
           (format (concat "mkdir -p %s && cd %s && connection_file=%s && "
                           "printf 'EJN_CONNECTION_FILE=%%s\\n' \"$connection_file\" && ")
                   (emacs-jupyter-notebook-ssh--quote-remote-path cache-dir)
                   (emacs-jupyter-notebook-ssh--quote-remote-path remote-cwd)
                   (emacs-jupyter-notebook-ssh--quote-remote-path connection-file))
           (mapconcat #'shell-quote-argument
                      (append python-command
                              (list "-c"
                                    emacs-jupyter-notebook-ssh--kernelspec-resolver
                                    kernelspec))
                      " ")
           " "
           "\"$connection_file\""
           " "
           (shell-quote-argument session-id))))
    (list :argv (emacs-jupyter-notebook-ssh-command profile remote-command)
          :remote-command remote-command
          :connection-file connection-file
          :log-file log-file
          :sidecar-file sidecar-file)))

(defun emacs-jupyter-notebook-ssh-build-remote-direct-launch
    (profile session-id resolved)
  "Build the detached direct-kernel launch from parsed RESOLVED metadata.
RESOLVED is trusted only after the strict local parser in the async pipeline.
The resolver prefix is intentionally absent from the final process argv."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile))
         (cache-dir (plist-get profile :remote-cache-dir))
         (remote-cwd (plist-get profile :remote-cwd))
         (connection-file (plist-get resolved :connection-file))
         (argv (plist-get resolved :argv))
         (environment (plist-get resolved :env))
         (connection-tokens (plist-get resolved :connection-tokens))
         (_ (unless (and (stringp session-id)
                         (string-match-p "\\`[[:alnum:]_.-]+\\'" session-id)
                         (stringp connection-file) (file-name-absolute-p connection-file)
                         (equal (file-name-nondirectory connection-file)
                                (format "kernel-%s.json" session-id))
                         (not (string-match-p "[\n\r]" connection-file))
                         (listp argv) argv (stringp (car argv))
                         (file-name-absolute-p (car argv))
                         (cl-every (lambda (value)
                                     (and (stringp value) (not (string-empty-p value))
                                          (not (string-match-p (string 0) value))))
                                   argv)
                         (listp environment)
                         (listp connection-tokens) connection-tokens
                         (<= (length connection-tokens) 2)
                         (cl-every (lambda (value)
                                     (and (stringp value)
                                          (not (string-empty-p value))
                                          (not (string-match-p (string 0) value))))
                                   connection-tokens)
                         (cl-every (lambda (pair)
                                     (and (consp pair) (stringp (car pair)) (stringp (cdr pair))
                                          (not (string-match-p (string 0) (car pair)))
                                          (not (string-match-p (string 0) (cdr pair)))
                                          (<= (string-bytes (car pair))
                                              emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
                                          (<= (string-bytes (cdr pair))
                                              emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
                                          (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" (car pair))))
                                   environment)
                         (<= (cl-loop for pair in environment
                                      sum (+ (string-bytes (car pair))
                                             (string-bytes (cdr pair))))
                             emacs-jupyter-notebook-ssh-kernelspec-max-env-bytes))
              (error "Direct kernel launch requires validated resolved argv and environment")))
         (log-file (replace-regexp-in-string
                    "\\.json\\'" ".log" connection-file))
         (sidecar-file (replace-regexp-in-string
                        "\\.json\\'" ".pid" connection-file))
         (program (append (list "env")
                          (mapcar (lambda (pair)
                                    (concat (car pair) "=" (cdr pair))) environment)
                          argv))
         (wrapper
          (concat "umask 077; pidfile=$1; session=$2; shift 2; "
                  "tmp=\"$pidfile.$$\"; "
                  "{ printf 'EJN_PID=%s\\n' \"$$\"; "
                  "printf 'EJN_SESSION=%s\\n' \"$session\"; } > \"$tmp\" && "
                  "chmod 600 \"$tmp\" && mv -f \"$tmp\" \"$pidfile\" && "
                  "exec \"$@\""))
         (remote-command
          (format (concat "mkdir -p %s && cd %s && { nohup sh -c %s ejn-kernel %s %s %s "
                          "> %s 2>&1 < /dev/null & printf 'EJN_LAUNCH_ADMITTED\\n'; }")
                  (emacs-jupyter-notebook-ssh--quote-remote-path cache-dir)
                  (emacs-jupyter-notebook-ssh--quote-remote-path remote-cwd)
                  (shell-quote-argument wrapper)
                  (emacs-jupyter-notebook-ssh--quote-remote-path sidecar-file)
                  (shell-quote-argument session-id)
                  (mapconcat #'shell-quote-argument program " ")
                  (emacs-jupyter-notebook-ssh--quote-remote-path log-file))))
    (list :argv (emacs-jupyter-notebook-ssh-command profile remote-command)
          :remote-command remote-command
          :connection-file connection-file
          :sidecar-file sidecar-file
          :log-file log-file
          :connection-tokens (copy-sequence connection-tokens))))

(defun emacs-jupyter-notebook-ssh-build-remote-read-pid-sidecar (profile sidecar-file)
  "Return SSH argv that reads the private PID SIDECAR-FILE without mutation."
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "cat %s" (emacs-jupyter-notebook-ssh--quote-remote-path sidecar-file))))

(defun emacs-jupyter-notebook-ssh-build-remote-inspect-pid-sidecar (profile entry)
  "Return argv that distinguishes exact ENTRY sidecar bytes from absence.
The host must emit a terminal marker.  Symlinks and non-regular objects fail
without being interpreted as either a PID or safe absence."
  (unless (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
    (error "Sidecar inspection requires a valid direct provisional entry"))
  (let ((sidecar (emacs-jupyter-notebook-ssh--quote-remote-path
                  (plist-get entry :remote-pid-sidecar))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format
      (concat "sidecar=%s; "
              "if [ -f \"$sidecar\" ] && [ ! -L \"$sidecar\" ]; then "
              "cat \"$sidecar\" && printf '__EJN_SIDECAR_DONE__\\n'; "
              "elif [ ! -e \"$sidecar\" ] && [ ! -L \"$sidecar\" ]; then "
              "printf '__EJN_SIDECAR_ABSENT__\\n__EJN_SIDECAR_DONE__\\n'; "
              "else printf '__EJN_SIDECAR_UNSAFE__\\n' >&2; exit 1; fi")
      sidecar))))

(defun emacs-jupyter-notebook-ssh-build-remote-kill (profile pid)
  "Return an SSH argv list that asks the remote shell to terminate PID."
  (emacs-jupyter-notebook-ssh-command
   profile
   (format "kill %s" (shell-quote-argument (format "%s" pid)))))

(defun emacs-jupyter-notebook-ssh--identity-token-path-count (tokens path)
  "Return the number of literal PATH occurrences across identity TOKENS."
  (cl-loop for token in tokens sum
           (let ((start 0) (count 0) (regexp (regexp-quote path)))
             (while (string-match regexp token start)
               (setq count (1+ count)
                     start (match-end 0)))
             count)))

(defun emacs-jupyter-notebook-ssh-direct-entry-valid-p (entry)
  "Return non-nil when ENTRY has the strict direct-launch identity schema."
  (let* ((session (plist-get entry :session-id))
         (path (plist-get entry :remote-connection-file))
         (sidecar (plist-get entry :remote-pid-sidecar))
         (tokens (plist-get entry :connection-file-tokens))
         (pid (plist-get entry :remote-pid)))
    (and (eq (plist-get entry :launch-kind) 'direct)
         (stringp session) (not (string-empty-p session))
         (not (string-match-p (string 0) session))
         (string-match-p "\\`[[:alnum:]_.-]+\\'" session)
         (<= (string-bytes session)
             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
         (stringp path) (file-name-absolute-p path)
         (not (string-match-p (string 0) path))
         (not (string-match-p "[\n\r]" path))
         (<= (string-bytes path)
             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
         (equal (file-name-nondirectory path) (format "kernel-%s.json" session))
         (stringp sidecar) (file-name-absolute-p sidecar)
         (not (string-match-p (string 0) sidecar))
         (not (string-match-p "[\n\r]" sidecar))
         (<= (string-bytes sidecar)
             emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
         (equal sidecar (concat (string-remove-suffix ".json" path) ".pid"))
         (listp tokens) (<= 1 (length tokens) 2)
         (cl-every (lambda (token)
                     (and (stringp token) (not (string-empty-p token))
                          (not (string-match-p (string 0) token))
                          (<= (string-bytes token)
                              emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)))
                   tokens)
         (<= (apply #'+ (mapcar #'string-bytes tokens))
             emacs-jupyter-notebook-ssh-kernelspec-max-argv-bytes)
         (= (emacs-jupyter-notebook-ssh--identity-token-path-count tokens path) 1)
         (if (= (length tokens) 2)
             (and (string-prefix-p "-" (car tokens))
                  (equal (cadr tokens) path))
           (string-match-p (regexp-quote path) (car tokens)))
         (memq (plist-get entry :provisional) '(nil t))
         (or (and (integerp pid) (> pid 0) (<= pid 2147483647))
             (and (eq (plist-get entry :provisional) t) (null pid))))))

(defun emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p (entry)
  "Return non-nil when ENTRY carries authority for exact remote cleanup.

A provisional direct entry with no promoted PID is valid durable recovery
state, but it cannot authorize a signal or deletion of the remote connection,
PID, and log files."
  (and (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
       (let ((pid (plist-get entry :remote-pid)))
         (and (integerp pid) (> pid 0)))))

(defun emacs-jupyter-notebook-ssh--identity-token-hex (tokens)
  "Return a NUL-delimited UTF-8 hex needle for contiguous TOKENS."
  (concat
   "00"
   (mapconcat
    (lambda (token)
      (mapconcat (lambda (byte) (format "%02x" byte))
                 (string-to-list (encode-coding-string token 'utf-8 t)) ""))
    tokens "00")
   "00"))

(defun emacs-jupyter-notebook-ssh-build-pid-alive (profile pid connection-tokens)
  "Return an SSH argv list probing whether PID is alive on PROFILE's host.
Uses `kill -0 <pid>' (sends no signal) but does NOT rely on the ssh exit
status to convey the answer — that conflates \"PID is gone\" with \"ssh
itself failed\" (auth, timeout, an over-long ControlPath), which would let
an infra hiccup masquerade as a dead kernel.  Instead the remote shell
always exits 0 and prints an identity-aware result for the PID,
followed by `__EJN_DONE__'.  CONNECTION-TOKENS is mandatory and identifies
the exact contiguous connection-file argument sequence.  The
remote command emits one of `__EJN_ALIVE_MATCH__', `__EJN_DEAD__',
`__EJN_ALIVE_MISMATCH__', `__EJN_INSPECT_UNAVAILABLE__', or
`__EJN_EXISTENCE_UNAVAILABLE__', then the same `__EJN_DONE__' terminator.
The last result means `kill -0' failed but `ps' did not positively prove the
PID absent, for example because signalling is not permitted.  It prefers the
NUL-delimited argv exposed by Linux /proc and falls back to `ps' only when the
expected token contains no whitespace, since `ps' cannot otherwise preserve
argument boundaries."
  (unless (and (integerp pid) (> pid 0)
               (listp connection-tokens) (<= 1 (length connection-tokens) 2)
               (cl-every (lambda (token)
                           (and (stringp token) (not (string-empty-p token))
                                (not (string-match-p (string 0) token))))
                         connection-tokens))
    (error "PID probe requires a positive PID and direct identity tokens"))
  (let ((pid (shell-quote-argument (format "%s" pid))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (let ((quoted-tokens
            (mapconcat #'shell-quote-argument connection-tokens " "))
           (hex-needle
            (shell-quote-argument
             (emacs-jupyter-notebook-ssh--identity-token-hex
              connection-tokens))))
       (format
          (concat
           "pid=%s; set -- %s; needle=%s; "
           "pid_absent() { target=$1; "
           "command -v ps >/dev/null 2>&1 || return 2; "
           "ps_self=$(ps -p \"$$\" -o pid= 2>/dev/null); self_status=$?; "
           "set -- $ps_self; "
           "[ \"$self_status\" = 0 ] && [ \"$#\" = 1 ] && [ \"$1\" = \"$$\" ] || return 2; "
           "observed=$(ps -p \"$target\" -o pid= 2>/dev/null); ps_status=$?; "
           "[ \"$ps_status\" = 1 ] && [ -z \"$observed\" ]; }; "
           "if ! kill -0 \"$pid\" 2>/dev/null; then "
           "if pid_absent \"$pid\"; then "
           "echo __EJN_DEAD__; else echo __EJN_EXISTENCE_UNAVAILABLE__; fi; "
           "elif [ -r \"/proc/$pid/cmdline\" ] && "
           "command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then "
           "actual=$(od -An -tx1 -v \"/proc/$pid/cmdline\" 2>/dev/null | tr -d ' \\n'); "
           "case \"$actual\" in *\"$needle\"*) echo __EJN_ALIVE_MATCH__;; "
           "*) echo __EJN_ALIVE_MISMATCH__;; esac; "
           "elif command -v ps >/dev/null 2>&1; then "
           "args=$(ps -p \"$pid\" -o args= 2>/dev/null) || args=; "
           "sequence=; safe=1; for expected; do "
           "case \"$expected\" in *[[:space:]]*) safe=0;; esac; "
           "sequence=\"${sequence}${sequence:+ }$expected\"; done; "
           "if [ -z \"$args\" ] || [ \"$safe\" != 1 ]; then echo __EJN_INSPECT_UNAVAILABLE__; "
           "else case \" $args \" in *\" $sequence \"*) echo __EJN_ALIVE_MATCH__;; "
           "*) echo __EJN_ALIVE_MISMATCH__;; esac; fi; "
           "else echo __EJN_INSPECT_UNAVAILABLE__; fi; echo __EJN_DONE__")
        pid quoted-tokens hex-needle)))))

(defun emacs-jupyter-notebook-ssh-build-batch-pid-alive (profile pids &optional connect-timeout)
  "Return an SSH argv classifying PIDS on PROFILE's host.
W11: the batched, per-host liveness probe behind the non-destructive
registry prune.  One ssh runs a shell loop that emits exactly one prefixed
alive/dead/unknown record per PID, then prints `__EJN_DONE__'.  A failed
`kill -0' is dead only when `ps' explicitly reports no such PID; EPERM,
missing `ps', and malformed results are unknown and therefore never pruned.
The loop always exits 0 because of the trailing sentinel `echo', so it does
not trip a non-zero-exit error path.

A bounded `ConnectTimeout' (CONNECT-TIMEOUT, default
`emacs-jupyter-notebook-prune-ssh-timeout') plus `BatchMode=yes' guarantee
an unreachable or auth-prompting host cannot hang Emacs — it fails fast
and its PIDs stay UNKNOWN (never pruned)."
  (unless (and (listp pids) pids
               (cl-every (lambda (pid)
                           (and (integerp pid) (> pid 0) (<= pid 2147483647)))
                         pids))
    (error "Batch PID probe requires positive integer PIDs"))
  (let* ((timeout
          (emacs-jupyter-notebook--effective-prune-ssh-timeout connect-timeout))
         (pid-list (mapconcat (lambda (p) (shell-quote-argument (format "%s" p)))
                              pids " "))
         (remote
          (format
           (concat
            "pid_absent() { target=$1; "
            "command -v ps >/dev/null 2>&1 || return 2; "
            "ps_self=$(ps -p \"$$\" -o pid= 2>/dev/null); self_status=$?; "
            "set -- $ps_self; "
            "[ \"$self_status\" = 0 ] && [ \"$#\" = 1 ] && [ \"$1\" = \"$$\" ] || return 2; "
            "observed=$(ps -p \"$target\" -o pid= 2>/dev/null); ps_status=$?; "
            "[ \"$ps_status\" = 1 ] && [ -z \"$observed\" ]; }; "
            "for p in %s; do "
            "if kill -0 \"$p\" 2>/dev/null; then echo \"__EJN_ALIVE__:$p\"; "
            "else if pid_absent \"$p\"; then "
            "echo \"__EJN_DEAD__:$p\"; else echo \"__EJN_UNKNOWN__:$p\"; fi; fi; "
            "done; echo __EJN_DONE__")
           pid-list))
         (argv (emacs-jupyter-notebook-ssh-command profile remote)))
    ;; Splice the bounding options in right after the ssh program name so
    ;; they apply to this one-shot probe without touching the shared
    ;; `ssh-options' customization.
    (append (list (car argv)
                  "-o" (format "ConnectTimeout=%d" timeout)
                  "-o" "BatchMode=yes")
            (cdr argv))))

(defun emacs-jupyter-notebook-ssh-build-remote-cleanup (profile entry)
  "Return explicit, PID-bound cleanup argv for direct-launch registry ENTRY.
The command never uses `pkill -f': it kills only ENTRY's recorded PID after
the persisted connection-bearing argv sequence matches Linux /proc or Darwin
`ps'.  When identity inspection is unavailable it leaves the process untouched."
  (let* ((pid (plist-get entry :remote-pid))
         (tokens (plist-get entry :connection-file-tokens))
         (connection-file (plist-get entry :remote-connection-file))
         (sidecar (plist-get entry :remote-pid-sidecar)))
    (unless (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)
      (error "Remote cleanup requires a direct entry with verified PID identity"))
    (let ((quoted-tokens (mapconcat #'shell-quote-argument tokens " "))
          (hex-needle
           (shell-quote-argument
            (emacs-jupyter-notebook-ssh--identity-token-hex tokens)))
          (remote-file (emacs-jupyter-notebook-ssh--quote-remote-path connection-file))
          (remote-log (emacs-jupyter-notebook-ssh--quote-remote-path
                       (replace-regexp-in-string "\\.json\\'" ".log" connection-file)))
          (remote-sidecar (and sidecar
                               (emacs-jupyter-notebook-ssh--quote-remote-path sidecar))))
      (emacs-jupyter-notebook-ssh-command
       profile
       (format
        (concat "pid=%s; set -- %s; needle=%s; "
                "pid_absent() { target=$1; "
                "command -v ps >/dev/null 2>&1 || return 2; "
                "ps_self=$(ps -p \"$$\" -o pid= 2>/dev/null); self_status=$?; "
                "set -- $ps_self; "
                "[ \"$self_status\" = 0 ] && [ \"$#\" = 1 ] && [ \"$1\" = \"$$\" ] || return 2; "
                "observed=$(ps -p \"$target\" -o pid= 2>/dev/null); ps_status=$?; "
                "[ \"$ps_status\" = 1 ] && [ -z \"$observed\" ]; }; "
                "cleanup() { rm -f %s %s%s && "
                "[ ! -e %s ] && [ ! -L %s ] && "
                "[ ! -e %s ] && [ ! -L %s ]%s; }; "
                "finish_cleanup() { cleanup && echo __EJN_CLEANUP_DONE__; }; "
                "if ! kill -0 \"$pid\" 2>/dev/null; then "
                "if pid_absent \"$pid\"; then "
                "finish_cleanup; exit $?; fi; "
                "echo EJN_CLEANUP_IDENTITY_UNCONFIRMED >&2; exit 1; fi; "
                "matched=0; "
                "if [ -r \"/proc/$pid/cmdline\" ] && command -v od >/dev/null 2>&1 && "
                "command -v tr >/dev/null 2>&1; then "
                "actual=$(od -An -tx1 -v \"/proc/$pid/cmdline\" 2>/dev/null | tr -d ' \\n'); "
                "case \"$actual\" in *\"$needle\"*) matched=1;; esac; "
                "elif command -v ps >/dev/null 2>&1; then "
                "args=$(ps -p \"$pid\" -o args= 2>/dev/null) || args=; "
                "sequence=; safe=1; for expected; do "
                "case \"$expected\" in *[[:space:]]*) safe=0;; esac; "
                "sequence=\"${sequence}${sequence:+ }$expected\"; done; "
                "if [ -n \"$args\" ] && [ \"$safe\" = 1 ]; then "
                "case \" $args \" in *\" $sequence \"*) matched=1;; esac; fi; fi; "
                "if [ \"$matched\" = 1 ]; then "
                "kill \"$pid\" || exit $?; waited=0; "
                "while kill -0 \"$pid\" 2>/dev/null && [ \"$waited\" -lt 50 ]; do "
                "sleep 0.1; waited=$((waited + 1)); done; "
                "if kill -0 \"$pid\" 2>/dev/null; then "
                "echo EJN_CLEANUP_PID_STILL_ALIVE >&2; exit 1; fi; "
                "if ! pid_absent \"$pid\"; then "
                "echo EJN_CLEANUP_IDENTITY_UNCONFIRMED >&2; exit 1; fi; "
                "finish_cleanup; exit $?; fi; "
                "echo EJN_CLEANUP_IDENTITY_UNCONFIRMED >&2; exit 1")
        (shell-quote-argument (format "%s" pid)) quoted-tokens hex-needle
        remote-file remote-log
        (if remote-sidecar (concat " " remote-sidecar) "")
        remote-file remote-file remote-log remote-log
        (if remote-sidecar
            (concat " && [ ! -e " remote-sidecar " ]"
                    " && [ ! -L " remote-sidecar " ]")
          ""))))))

(defun emacs-jupyter-notebook-ssh-build-remote-cat-log (profile connection-file)
  "Return an SSH argv list that prints a bounded tail for CONNECTION-FILE."
  (let ((remote-log (emacs-jupyter-notebook-ssh--quote-remote-path
                     (replace-regexp-in-string "\\.json\\'" ".log" connection-file))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (format "tail -c %d < %s"
             (emacs-jupyter-notebook-ssh--management-output-limit)
             remote-log))))

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

(defun emacs-jupyter-notebook-ssh-start-process
    (name argv &optional sentinel output-limit)
  "Start ARGV asynchronously as process NAME and return the process.
OUTPUT-LIMIT defaults to the immutable management-stream ceiling.  Keep this
constructor bounded from the `make-process' call itself: management callers
replace the initial filters with their newest-tail filter immediately after
creation, but a fast child must not get an unbounded buffer during that small
handoff window."
  (emacs-jupyter-notebook-ssh-start-bounded-process
   name argv
   (or output-limit
       ;; This function is defined below, but all callers run after this file
       ;; has finished loading and the constant is therefore available.
       emacs-jupyter-notebook-ssh--management-output-hard-limit)
   sentinel))

(defun emacs-jupyter-notebook-ssh--bounded-output-filter (process output limit owner)
  "Append OUTPUT only while OWNER remains below binary-stream LIMIT."
  (let* ((owner (or owner process))
         (buffer (process-buffer process)))
    (when (and (buffer-live-p buffer) (not (process-get owner 'ejn-output-overflow)))
      (with-current-buffer buffer
        (if (> (+ (string-bytes output)
                  (- (or (position-bytes (point-max)) (point-max))
                     (or (position-bytes (point-min)) (point-min))))
               limit)
            (progn
              (process-put owner 'ejn-output-overflow t)
              (when (process-live-p owner) (delete-process owner)))
          (goto-char (point-max))
          (insert output))))))

(defun emacs-jupyter-notebook-ssh-start-bounded-process (name argv limit sentinel)
  "Start ARGV with a strict per-stream byte LIMIT and SENTINEL.
Overflow kills the owning SSH process instead of retaining a tail, allowing a
protocol parser to distinguish truncated hostile output from a valid reply."
  (unless (and (integerp limit) (> limit 0))
    (error "Bounded process requires a positive output limit"))
  (let ((stdout-buffer (generate-new-buffer (format " *%s*" name)))
        (stderr-buffer (generate-new-buffer (format " *%s stderr*" name)))
        process)
    ;; Make the buffers unibyte before the child starts.  The resolver schema
    ;; is UTF-8 JSON, so invalid bytes must fail validation rather than being
    ;; silently decoded/replaced by Emacs's process coding layer.
    (with-current-buffer stdout-buffer (set-buffer-multibyte nil))
    (with-current-buffer stderr-buffer (set-buffer-multibyte nil))
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name name :buffer stdout-buffer :command argv
                 :connection-type 'pipe :noquery t :sentinel sentinel
                 :stderr stderr-buffer :coding 'binary
                 :filter (lambda (proc output)
                           (emacs-jupyter-notebook-ssh--bounded-output-filter
                            proc output limit process))))
          (process-put process 'emacs-jupyter-notebook-stderr-buffer stderr-buffer)
          (when-let ((stderr-process (get-buffer-process stderr-buffer)))
            ;; The stderr buffer is backed by an internal process.  Its
            ;; default sentinel may append a process-status diagnostic when
            ;; the owning SSH process is killed for output overflow, bypassing
            ;; the bounded output filter.  Silence it before returning the
            ;; child to callers.
            (set-process-sentinel stderr-process #'ignore)
            (set-process-filter
             stderr-process
             (lambda (proc output)
               (emacs-jupyter-notebook-ssh--bounded-output-filter
                proc output limit process))))
          process)
      (error
       (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
       (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
       (signal (car err) (cdr err))))))

(defun emacs-jupyter-notebook-ssh--management-buffer-string (buffer)
  "Return BUFFER contents, or the empty string when BUFFER is no longer live."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer (buffer-string))
    ""))

(defconst emacs-jupyter-notebook-ssh--management-output-fallback
  (* 1024 1024)
  "Finite per-stream output bound used when customization is invalid.")

(defconst emacs-jupyter-notebook-ssh--management-truncation-marker
  "[EJN management output truncated]\n"
  "Prefix identifying bounded management command output.")

(defun emacs-jupyter-notebook-ssh--management-output-limit ()
  "Return a positive output cap large enough to hold the truncation marker."
  (let ((limit emacs-jupyter-notebook-management-output-max-bytes)
        (minimum (1+ (string-bytes
                      emacs-jupyter-notebook-ssh--management-truncation-marker))))
    (if (and (integerp limit) (>= limit minimum))
        (min limit emacs-jupyter-notebook-ssh--management-output-hard-limit)
      emacs-jupyter-notebook-ssh--management-output-fallback)))

(defun emacs-jupyter-notebook-ssh--management-buffer-bytes ()
  "Return the byte size of the current management output buffer."
  (- (or (position-bytes (point-max)) (point-max))
     (or (position-bytes (point-min)) (point-min))))

(defun emacs-jupyter-notebook-ssh--management-trim-output (limit)
  "Trim current buffer to its newest bytes within LIMIT and add a marker."
  (let* ((marker emacs-jupyter-notebook-ssh--management-truncation-marker)
         (payload-limit (- limit (string-bytes marker)))
         (excess (max 0 (- (emacs-jupyter-notebook-ssh--management-buffer-bytes)
                           payload-limit)))
         (removed 0))
    ;; Once bounded, EXCESS is normally only the newly arrived chunk.  Walk
    ;; forward over that prefix rather than rescanning the retained tail.
    (goto-char (point-min))
    (while (and (< removed excess) (< (point) (point-max)))
      (setq removed (+ removed (string-bytes (string (char-after)))))
      (forward-char))
    (delete-region (point-min) (point))
    (goto-char (point-min))
    (insert marker)))

(defun emacs-jupyter-notebook-ssh--management-tail-string (string byte-limit)
  "Return the newest complete characters of STRING within BYTE-LIMIT bytes."
  (if (<= (string-bytes string) byte-limit)
      string
    (let ((index (length string))
          (bytes 0))
      (while (and (> index 0)
                  (let ((next
                         (string-bytes (string (aref string (1- index))))))
                    (when (<= (+ bytes next) byte-limit)
                      (setq bytes (+ bytes next))
                      t)))
        (setq index (1- index)))
      (substring string index))))

(defun emacs-jupyter-notebook-ssh--management-output-filter (process output)
  "Insert PROCESS OUTPUT while retaining a hard-bounded newest-byte tail."
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (marker emacs-jupyter-notebook-ssh--management-truncation-marker)
              (truncated (process-get process 'ejn-management-truncated))
              (limit (process-get process 'ejn-management-output-limit)))
          (when (and truncated
                     (<= (length marker) (buffer-size))
                     (equal marker
                            (buffer-substring-no-properties
                             (point-min) (+ (point-min) (length marker)))))
            (delete-region (point-min) (+ (point-min) (length marker))))
          (let ((payload-limit (- limit (string-bytes marker))))
            (when (> (string-bytes output) payload-limit)
              ;; Avoid transiently inserting a single enormous process chunk.
              (erase-buffer)
              (setq output
                    (emacs-jupyter-notebook-ssh--management-tail-string
                     output payload-limit)
                    truncated t)
              (process-put process 'ejn-management-truncated t)))
          (goto-char (point-max))
          (insert output)
          (when (or truncated
                    (> (emacs-jupyter-notebook-ssh--management-buffer-bytes)
                       limit))
            (emacs-jupyter-notebook-ssh--management-trim-output limit)
            (process-put process 'ejn-management-truncated t)))))))

(defun emacs-jupyter-notebook-ssh--management-install-output-filters (process)
  "Install bounded stdout and stderr filters for management PROCESS."
  (let* ((limit (emacs-jupyter-notebook-ssh--management-output-limit))
         (stderr-buffer
          (process-get process 'emacs-jupyter-notebook-stderr-buffer))
         (stderr-process (and (buffer-live-p stderr-buffer)
                              (get-buffer-process stderr-buffer))))
    (process-put process 'ejn-management-output-limit limit)
    (set-process-filter process
                        #'emacs-jupyter-notebook-ssh--management-output-filter)
    (when (processp stderr-process)
      (process-put stderr-process 'ejn-management-output-limit limit)
      (set-process-filter
       stderr-process #'emacs-jupyter-notebook-ssh--management-output-filter)
      (process-put process 'ejn-management-stderr-process stderr-process))))

(defun emacs-jupyter-notebook-ssh--management-dispose (process)
  "Dispose PROCESS and every timer/buffer owned by its management operation."
  (when-let* ((timer (process-get process 'ejn-management-timeout)))
    (cancel-timer timer)
    (process-put process 'ejn-management-timeout nil))
  (set-process-sentinel process #'ignore)
  (set-process-filter process #'ignore)
  (when (process-live-p process)
    (delete-process process))
  (when-let* ((stderr-process
               (process-get process 'ejn-management-stderr-process)))
    (set-process-sentinel stderr-process #'ignore)
    (set-process-filter stderr-process #'ignore)
    (when (process-live-p stderr-process)
      (delete-process stderr-process))
    (process-put process 'ejn-management-stderr-process nil))
  (dolist (buffer (list (process-buffer process)
                        (process-get
                         process 'emacs-jupyter-notebook-stderr-buffer)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (set-process-buffer process nil)
  (process-put process 'emacs-jupyter-notebook-stderr-buffer nil)
  (process-put process 'ejn-management-success nil)
  (process-put process 'ejn-management-failure nil))

(defun emacs-jupyter-notebook-ssh--management-finish (process outcome)
  "Finish PROCESS exactly once with OUTCOME.
OUTCOME is `success', `failed', `timeout', or `cancelled'."
  (unless (process-get process 'ejn-management-finished)
    (let* ((stdout (emacs-jupyter-notebook-ssh--management-buffer-string
                    (process-buffer process)))
           (stderr (emacs-jupyter-notebook-ssh--management-buffer-string
                    (process-get
                     process 'emacs-jupyter-notebook-stderr-buffer)))
           (success (process-get process 'ejn-management-success))
           (failure (process-get process 'ejn-management-failure)))
      (process-put process 'ejn-management-finished t)
      (process-put process 'ejn-management-outcome outcome)
      (emacs-jupyter-notebook-ssh--management-dispose process)
      (condition-case err
          (if (eq outcome 'success)
              (funcall success stdout)
            (funcall failure outcome stderr))
        (error
         (message "emacs-jupyter-notebook: management callback failed: %s"
                  (error-message-string err)))))))

(defun emacs-jupyter-notebook-ssh-management-cancel (process)
  "Cancel PROCESS locally and notify its failure callback exactly once."
  (when (processp process)
    (emacs-jupyter-notebook-ssh--management-finish process 'cancelled)))

(defconst emacs-jupyter-notebook-ssh--management-timeout-fallback 60
  "Finite watchdog used when the management timeout is misconfigured.")

(defconst emacs-jupyter-notebook-ssh--management-timeout-hard-limit 600
  "Absolute upper bound for one user-visible management child.")

(defun emacs-jupyter-notebook-ssh--management-timeout (timeout)
  "Return a positive management deadline for optional TIMEOUT."
  (let ((candidate (if (null timeout)
                       emacs-jupyter-notebook-management-process-timeout
                     timeout)))
    (if (and (numberp candidate) (> candidate 0)
             (or (not (floatp candidate))
                 (and (not (isnan candidate))
                      (< (abs candidate) 1.0e+INF))))
        (min candidate
             emacs-jupyter-notebook-ssh--management-timeout-hard-limit)
      emacs-jupyter-notebook-ssh--management-timeout-fallback)))

(defun emacs-jupyter-notebook-ssh-start-management-operation
    (name argv success failure &optional timeout)
  "Start bounded async SSH management ARGV and return its process.
SUCCESS receives stdout, FAILURE receives a reason symbol and stderr.  Both
callbacks run at most once; cancelling or timing out never changes durable
kernel state.  TIMEOUT defaults to
`emacs-jupyter-notebook-management-process-timeout'; invalid or non-positive
values use a finite hard fallback, so management children cannot wedge Emacs."
  (let (process setup-complete pending-outcome)
    (setq process
          (emacs-jupyter-notebook-ssh-start-process
           name argv
           (lambda (proc _event)
             (when (and (memq (process-status proc) '(exit signal))
                        (not (process-get proc 'ejn-management-finished)))
               (let ((outcome
                      (if (and (eq (process-status proc) 'exit)
                               (zerop (process-exit-status proc)))
                          'success
                        'failed)))
                 ;; A fast child can finish inside `make-process', before its
                 ;; callbacks and watchdog exist.  Record that terminal state
                 ;; until setup publishes every resource; finishing earlier
                 ;; loses the callback and leaves a stale timer behind.
                 (if setup-complete
                     (emacs-jupyter-notebook-ssh--management-finish proc outcome)
                   (setq pending-outcome outcome)))))
           (emacs-jupyter-notebook-ssh--management-output-limit)))
    ;; Publish callbacks first so any failure in filter/watchdog setup can use
    ;; the same exact-once disposal path.  Returning an already-finished
    ;; process is intentional and is supported by the higher-level management
    ;; launcher, whose callback may complete before this starter returns.
    (process-put process 'ejn-management-success success)
    (process-put process 'ejn-management-failure failure)
    (condition-case err
        (progn
          (emacs-jupyter-notebook-ssh--management-install-output-filters process)
          (process-put
           process 'ejn-management-timeout
           (run-at-time
            (emacs-jupyter-notebook-ssh--management-timeout timeout) nil
            (lambda (proc)
              (emacs-jupyter-notebook-ssh--management-finish proc 'timeout))
            process))
          (setq setup-complete t)
          (when pending-outcome
            (emacs-jupyter-notebook-ssh--management-finish
             process pending-outcome)))
      (error
       (setq setup-complete t)
       (message "emacs-jupyter-notebook: management process setup failed: %s"
                (error-message-string err))
       (emacs-jupyter-notebook-ssh--management-finish process 'failed)))
    process))

(provide 'emacs-jupyter-notebook-ssh)

;;; emacs-jupyter-notebook-ssh.el ends here
