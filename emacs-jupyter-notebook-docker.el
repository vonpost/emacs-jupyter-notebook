;;; emacs-jupyter-notebook-docker.el --- Owned Docker kernel commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; One Linux Docker container per kernel, owned by the remote daemon.  This
;; module only constructs commands; the async lifecycle supervises SSH locally.
;; Container identity, not a host or container PID, authorizes remote actions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-ssh)

(defconst emacs-jupyter-notebook-docker--command
  "docker --host unix:///var/run/docker.sock"
  "CLI prefix pinned to the rootful daemon on the SSH host.")

(defconst emacs-jupyter-notebook-docker--session-label
  "org.emacs-jupyter-notebook.session")
(defconst emacs-jupyter-notebook-docker--profile-label
  "org.emacs-jupyter-notebook.profile")

(defun emacs-jupyter-notebook-docker--text-p (value)
  "Whether VALUE is bounded, nonempty text safe in shell arguments."
  (and (stringp value) (not (string-empty-p value))
       (<= (string-bytes value) 4096)
       (not (string-match-p "[\000\n\r]" value))))

(defun emacs-jupyter-notebook-docker--id-p (value &optional image)
  "Whether VALUE is a complete Docker ID, optionally an IMAGE ID."
  (and (stringp value)
       (string-match-p (if image "\\`sha256:[0-9a-f]\\{64\\}\\'"
                        "\\`[0-9a-f]\\{64\\}\\'") value)))

(defun emacs-jupyter-notebook-docker--options (profile)
  "Validate and copy PROFILE's bounded Docker resource/environment argv.
Only known options are admitted, so positional image/command arguments and
option abbreviations cannot override EJN's lifetime or identity controls."
  (let* ((options (plist-get profile :docker-options))
         (remaining options)
         (with-value '("--gpus" "--ipc" "--volume" "-v" "--mount"
                       "--env" "-e" "--env-file" "--device" "--group-add"
                       "--shm-size" "--memory" "-m" "--memory-swap"
                       "--cpus" "--cpu-shares" "--cpuset-cpus" "--ulimit"
                       "--security-opt" "--cap-add" "--cap-drop" "--tmpfs"))
         (flags '("--read-only")))
    (unless (and (proper-list-p options) (<= (length options) 64)
                 (cl-every #'emacs-jupyter-notebook-docker--text-p options)
                 (<= (apply #'+ (mapcar #'string-bytes options)) 16384))
      (error ":docker-options must be a bounded argv list of strings"))
    (while remaining
      (let* ((argument (pop remaining))
             (equals (string-match "=" argument))
             (option (if equals (substring argument 0 equals) argument))
             (value (and equals (substring argument (1+ equals)))))
        (cond
         ((member option with-value)
          (unless equals (setq value (pop remaining)))
          (unless (and (emacs-jupyter-notebook-docker--text-p value)
                       (not (string-prefix-p "-" value)))
            (error "Docker option %s needs a value" option))
          (when (member option '("-v" "--volume"))
            (let ((parts (split-string value ":")))
              (unless (and (<= 2 (length parts) 3)
                           (not (string-empty-p (car parts)))
                           (string-prefix-p "/" (cadr parts)))
                (error "Docker volume destination must be absolute: %s" value))))
          (when (equal option "--mount")
            (unless (string-match-p
                     "\\(?:\\`\\|,\\)\\(?:target\\|destination\\|dst\\)=/[^,]+" value)
              (error "Docker mount requires an absolute destination"))))
         ((and (member option flags) (not equals)))
         (t (error (concat "Docker option %s is reserved or unsupported; EJN manages "
                           "network, user, entrypoint, name, labels and lifetime") option)))))
    (copy-sequence options)))

(defun emacs-jupyter-notebook-docker-validate-profile (profile)
  "Validate Docker PROFILE and return it."
  (unless (and (emacs-jupyter-notebook-docker--text-p
                (plist-get profile :docker-image))
               (not (string-prefix-p "-" (plist-get profile :docker-image))))
    (error "Docker launcher requires :docker-image"))
  (unless (emacs-jupyter-notebook-docker--text-p (plist-get profile :kernelspec))
    (error "Docker launcher requires a bounded kernelspec name"))
  (emacs-jupyter-notebook-docker--options profile)
  (emacs-jupyter-notebook-ssh--python-command profile)
  (when (and (plist-get profile :docker-image-id)
             (not (emacs-jupyter-notebook-docker--id-p
                   (plist-get profile :docker-image-id) t)))
    (error "Docker pinned image identity is invalid"))
  (when (and (plist-get profile :docker-profile-key)
             (not (emacs-jupyter-notebook-docker--id-p
                   (plist-get profile :docker-profile-key))))
    (error "Docker profile ownership identity is invalid"))
  (dolist (key '(:remote-cwd :remote-cache-dir))
    (let ((path (plist-get profile key)))
      (unless (and (emacs-jupyter-notebook-docker--text-p path)
                   (or (string-prefix-p "/" path)
                       (equal path "~") (string-prefix-p "~/" path))
                   (not (string-match-p ":" path)))
        (error "Docker %s must be an absolute or home-relative path without colons" key))))
  profile)

(defun emacs-jupyter-notebook-docker--profile-key (profile)
  "Return the stable ownership label for PROFILE on this SSH host."
  (or (plist-get profile :docker-profile-key)
      (secure-hash 'sha256
                   (prin1-to-string
                    (list (plist-get profile :profile)
                          (plist-get profile :remote-cache-dir))))))

(defun emacs-jupyter-notebook-docker--name (session)
  "Allocate a unique incarnation name for SESSION before launch admission."
  (concat "ejn-" (substring (secure-hash 'sha256 session) 0 16) "-"
          (substring (secure-hash 'sha256
                                  (format "%s:%s:%s" (float-time) (emacs-pid) (random)))
                     0 20)))

(defun emacs-jupyter-notebook-docker--prepare-cache (cache cwd)
  "Return shell setup for private CACHE and container CWD."
  (format
   (concat "umask 077; cache=%s; cwd=%s; "
           "mkdir -p -- \"$cache\" || exit 1; "
           "[ -d \"$cache\" ] && [ ! -L \"$cache\" ] && "
           "[ \"$(stat -c '%%u:%%a' -- \"$cache\")\" = \"$(id -u):700\" ] || "
           "{ echo 'EJN Docker cache must be a private directory owned by the SSH user' >&2; exit 1; }; "
           "case \"$cache\" in /*) ;; *) echo 'EJN Docker cache must expand to an absolute path' >&2; exit 1;; esac; "
           "uid=$(id -u); gid=$(id -g); ")
   (emacs-jupyter-notebook-ssh--quote-remote-path cache)
   (emacs-jupyter-notebook-ssh--quote-remote-path cwd)))

(defun emacs-jupyter-notebook-docker--run-prefix (profile)
  "Return common Docker run options for resolver and kernel PROFILE."
  (concat emacs-jupyter-notebook-docker--command
          " run --rm --network host --user \"$uid:$gid\" --workdir \"$cwd\" "
          (mapconcat #'shell-quote-argument
                     (emacs-jupyter-notebook-docker--options profile) " ")
          " --volume \"$cache:$cache\" "))

(defun emacs-jupyter-notebook-docker-build-resolution (profile session)
  "Return async resolver command and provisional identity for PROFILE SESSION."
  (setq profile (emacs-jupyter-notebook-docker-validate-profile
                 (emacs-jupyter-notebook-ssh-profile profile)))
  (unless (and (stringp session) (<= (length session) 128)
               (string-match-p "\\`[[:alnum:]_.-]+\\'" session))
    (error "Docker session identity must contain 1-128 letters, digits, dots or hyphens"))
  (let* ((cache (if (plist-get profile :docker-connection-file)
                    (directory-file-name
                     (file-name-directory (plist-get profile :docker-connection-file)))
                  (emacs-jupyter-notebook-ssh--remote-join
                   (plist-get profile :remote-cache-dir) (concat "docker-" session))))
         (path (emacs-jupyter-notebook-ssh--remote-join
                cache (format "kernel-%s.json" session)))
         (_ (unless (emacs-jupyter-notebook-docker--text-p path)
              (error "Docker connection path exceeds the limit")))
         (_restart-path (when (plist-get profile :docker-connection-file)
              (unless (and (equal path (plist-get profile :docker-connection-file))
                           (emacs-jupyter-notebook-docker--text-p path)
                           (file-name-absolute-p path)
                           (not (string-match-p ":" path))
                           (equal (file-name-nondirectory cache)
                                  (concat "docker-" session)))
                (error "Docker restart requires the exact private connection path"))))
         (python (emacs-jupyter-notebook-ssh--python-command profile))
         (fields (list :launch-kind 'docker :launcher 'docker
                       :docker-container-name (emacs-jupyter-notebook-docker--name session)
                       :docker-container-id nil
                       :docker-owner session
                       :docker-profile-key (emacs-jupyter-notebook-docker--profile-key profile)
                       :docker-image (plist-get profile :docker-image)
                       :docker-options (emacs-jupyter-notebook-docker--options profile)
                       :docker-python-command python))
         (command
          (concat
           (emacs-jupyter-notebook-docker--prepare-cache cache (plist-get profile :remote-cwd))
           "[ \"$(" emacs-jupyter-notebook-docker--command " info --format '{{.OSType}}')\" = linux ] || "
           "{ echo 'EJN Docker requires access to the local Linux daemon at /var/run/docker.sock' >&2; exit 1; }; "
           "image=$(" emacs-jupyter-notebook-docker--command " image inspect --format '{{.Id}}' "
           (shell-quote-argument (or (plist-get profile :docker-image-id)
                                     (plist-get profile :docker-image))) ") || "
           "{ echo 'EJN Docker image is unavailable; pull the image on the SSH host first' >&2; exit 1; }; "
           "case \"$image\" in sha256:*) ;; *) exit 1;; esac; "
           "printf 'EJN_DOCKER_IMAGE=%s\\n' \"$image\"; "
           "connection_file=\"$cache/kernel-" session ".json\"; "
           "printf 'EJN_CONNECTION_FILE=%s\\n' \"$connection_file\"; "
           (emacs-jupyter-notebook-docker--run-prefix profile)
           "--entrypoint " (shell-quote-argument (car python)) " \"$image\" "
           (mapconcat #'shell-quote-argument
                      (append (cdr python)
                              (list "-c" emacs-jupyter-notebook-ssh--kernelspec-resolver
                                    (plist-get profile :kernelspec))) " ")
           " \"$connection_file\" " (shell-quote-argument session))))
    (list :argv (emacs-jupyter-notebook-ssh-command profile command)
          :remote-command command :connection-file path :entry-fields fields)))

(defun emacs-jupyter-notebook-docker-build-launch (profile session resolved)
  "Return detached daemon-owned launch metadata for PROFILE SESSION RESOLVED."
  (setq profile (emacs-jupyter-notebook-docker-validate-profile
                 (emacs-jupyter-notebook-ssh-profile profile)))
  ;; Reuse the direct builder's strict argv/environment/path validation only.
  (let* ((validated (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                     profile session resolved))
         (path (plist-get validated :connection-file))
         (cache (directory-file-name (file-name-directory path)))
         (fields (copy-sequence (plist-get resolved :entry-fields)))
         (image (plist-get fields :docker-image-id))
         (argv (plist-get resolved :argv))
         (command
          (concat
           (emacs-jupyter-notebook-docker--prepare-cache cache (plist-get profile :remote-cwd))
           (emacs-jupyter-notebook-docker--run-prefix profile)
           "--detach --name " (shell-quote-argument (or (plist-get fields :docker-container-name) ""))
           " --label " (shell-quote-argument
                         (concat emacs-jupyter-notebook-docker--session-label "=" session))
           " --label " (shell-quote-argument
                         (concat emacs-jupyter-notebook-docker--profile-label "="
                                 (or (plist-get fields :docker-profile-key) "")))
           " " (mapconcat (lambda (pair)
                             (concat "--env " (shell-quote-argument
                                                (concat (car pair) "=" (cdr pair)))))
                           (plist-get resolved :env) " ")
           " --entrypoint " (shell-quote-argument (car argv)) " "
           (shell-quote-argument (or image "")) " "
           (mapconcat #'shell-quote-argument (cdr argv) " ")
           " >/dev/null && printf 'EJN_LAUNCH_ADMITTED\\n'")))
    (unless (and (emacs-jupyter-notebook-docker--id-p image t)
                 (equal (plist-get fields :docker-owner) session)
                 (stringp (plist-get fields :docker-container-name))
                 (string-match-p "\\`ejn-[0-9a-f]\\{16\\}-[0-9a-f]\\{20\\}\\'"
                                 (plist-get fields :docker-container-name)))
      (error "Docker launch requires validated image and provisional container identity"))
    (list :argv (emacs-jupyter-notebook-ssh-command profile command)
          :remote-command command :connection-file path
          :sidecar-file (plist-get validated :sidecar-file)
          :log-file (plist-get validated :log-file)
          :connection-tokens (plist-get validated :connection-tokens)
          :entry-fields fields)))

(defun emacs-jupyter-notebook-docker-entry-valid-p (entry)
  "Whether ENTRY has a valid provisional or promoted Docker identity."
  (condition-case nil
      (let ((session (plist-get entry :session-id))
            (name (plist-get entry :docker-container-name))
            (id (plist-get entry :docker-container-id))
            (path (plist-get entry :remote-connection-file))
            (direct (copy-sequence entry)))
        ;; Retain existing strict connection-path/token bounds.  Docker PID is
        ;; informational and is deliberately not part of its identity schema.
        (setq direct (plist-put direct :launch-kind 'direct)
              direct (plist-put direct :remote-pid 1))
        (and (eq (plist-get entry :launch-kind) 'docker)
             (emacs-jupyter-notebook-ssh-direct-entry-valid-p direct)
             (not (string-match-p ":" path))
             (<= (length session) 128)
             (equal (plist-get entry :docker-owner) session)
             (stringp name)
             (string-match-p "\\`ejn-[0-9a-f]\\{16\\}-[0-9a-f]\\{20\\}\\'" name)
             (equal (file-name-nondirectory
                     (directory-file-name (file-name-directory path)))
                    (concat "docker-" session))
             (emacs-jupyter-notebook-docker--id-p (plist-get entry :docker-image-id) t)
             (emacs-jupyter-notebook-docker--id-p (plist-get entry :docker-profile-key))
             (or (emacs-jupyter-notebook-docker--id-p id)
                 (and (plist-get entry :provisional) (null id)))))
    (error nil)))

(defun emacs-jupyter-notebook-docker--inspect (entry)
  "Return a shell fragment binding state/id/pid for exact Docker ENTRY.
STATE is match, dead, mismatch or unknown.  Failed Docker calls alone never
mean dead: successful bounded listing must positively establish absence."
  (unless (emacs-jupyter-notebook-docker-entry-valid-p entry)
    (error "Docker operation requires valid durable container identity"))
  (let* ((name (plist-get entry :docker-container-name))
         (id (or (plist-get entry :docker-container-id) ""))
         (format-string
          (format "{{.Id}}|{{.Name}}|{{index .Config.Labels %S}}|{{index .Config.Labels %S}}|{{.State.Running}}|{{.State.Pid}}"
                  emacs-jupyter-notebook-docker--session-label
                  emacs-jupyter-notebook-docker--profile-label)))
    (concat
     "name=" (shell-quote-argument name) "; expected=" (shell-quote-argument id)
     "; owner=" (shell-quote-argument (plist-get entry :docker-owner))
     "; profile=" (shell-quote-argument (plist-get entry :docker-profile-key)) "; state=unknown; id=; "
     "inspect() { " emacs-jupyter-notebook-docker--command
     " container inspect --format " (shell-quote-argument format-string) " \"$1\"; }; "
     "if observed=$(inspect \"$name\" 2>/dev/null) || "
     "{ [ -n \"$expected\" ] && observed=$(inspect \"$expected\" 2>/dev/null); }; then "
     "saved_ifs=$IFS; IFS='|'; set -f; set -- $observed; IFS=$saved_ifs; "
     "if [ \"$#\" = 6 ]; then id=$1; actual_name=$2; actual_owner=$3; actual_profile=$4; running=$5; pid=$6; "
     "case \"$id\" in *[!0-9a-f]*|'') state=unknown;; *) "
     "if [ \"${#id}\" != 64 ]; then state=unknown; "
     "elif [ \"$actual_name\" != \"/$name\" ] || [ \"$actual_owner\" != \"$owner\" ] || "
     "[ \"$actual_profile\" != \"$profile\" ] || { [ -n \"$expected\" ] && [ \"$id\" != \"$expected\" ]; }; then state=mismatch; "
     "elif [ \"$running\" = true ]; then state=match; "
     "elif [ \"$running\" = false ]; then state=dead; fi;; esac; fi; "
     "else names=$(" emacs-jupyter-notebook-docker--command
     " container ls --all --no-trunc --filter \"name=^/$name$\" --format '{{.ID}}') && "
     "[ -z \"$names\" ] && "
     "{ [ -z \"$expected\" ] || { ids=$(" emacs-jupyter-notebook-docker--command
     " container ls --all --no-trunc --filter \"id=$expected\" --format '{{.ID}}') && [ -z \"$ids\" ]; }; } "
     "&& state=dead; fi; ")))

(defun emacs-jupyter-notebook-docker-build-probe (profile entry)
  "Return a read-only SSH identity/liveness probe for Docker ENTRY."
  (emacs-jupyter-notebook-ssh-command
   profile
   (concat (emacs-jupyter-notebook-docker--inspect entry)
           "case \"$state\" in match) echo __EJN_ALIVE_MATCH__;; dead) echo __EJN_DEAD__;; "
           "mismatch) echo __EJN_ALIVE_MISMATCH__;; *) echo __EJN_EXISTENCE_UNAVAILABLE__;; esac; echo __EJN_DONE__")))

(defun emacs-jupyter-notebook-docker-build-read-identity (profile entry &optional inspect)
  "Return identity read argv for PROFILE ENTRY; INSPECT also marks absence."
  (emacs-jupyter-notebook-ssh-command
   profile
   (concat (emacs-jupyter-notebook-docker--inspect entry)
           "if [ \"$state\" = match ]; then "
           "case \"$pid\" in *[!0-9]*|''|0) exit 1;; esac; "
           "printf 'EJN_PID=%s\\nEJN_SESSION=%s\\nEJN_CONTAINER_ID=%s\\n' \"$pid\" \"$owner\" \"$id\"; "
           (if inspect "echo __EJN_SIDECAR_DONE__; " "")
           (if inspect
               "elif [ \"$state\" = dead ]; then echo __EJN_SIDECAR_ABSENT__; echo __EJN_SIDECAR_DONE__; "
             "")
           "else echo 'EJN Docker container identity unavailable or mismatched' >&2; exit 1; fi")))

(defun emacs-jupyter-notebook-docker-parse-identity (entry output)
  "Return ENTRY with validated Docker identity in OUTPUT, or nil."
  (when (and (emacs-jupyter-notebook-docker-entry-valid-p entry)
             (stringp output) (< (string-bytes output) 4096)
             (string-match
              (concat "\\`EJN_PID=\\([0-9]+\\)\nEJN_SESSION="
                      (regexp-quote (plist-get entry :session-id))
                      "\nEJN_CONTAINER_ID=\\([0-9a-f]\\{64\\}\\)\n?\\'") output))
    (let ((pid (string-to-number (match-string 1 output)))
          (id (match-string 2 output)))
      (when (and (< 0 pid) (<= pid 2147483647)
                 (or (null (plist-get entry :docker-container-id))
                     (equal (plist-get entry :docker-container-id) id)))
        (setq entry (copy-sequence entry)
              entry (plist-put entry :remote-pid pid)
              entry (plist-put entry :docker-container-id id))
        entry))))

(defun emacs-jupyter-notebook-docker-build-cleanup (profile entry &optional preserve-files)
  "Return exact explicit cleanup for PROFILE ENTRY.
PRESERVE-FILES is the restart path: only an already-stopped container may be
removed and connection files remain untouched.  A live container fails."
  (unless (and (emacs-jupyter-notebook-docker-entry-valid-p entry)
               (emacs-jupyter-notebook-docker--id-p (plist-get entry :docker-container-id)))
    (error "Docker cleanup requires a verified immutable container ID"))
  (let* ((path (plist-get entry :remote-connection-file))
         (files (list path (plist-get entry :remote-pid-sidecar)
                      (concat (string-remove-suffix ".json" path) ".log"))))
    (emacs-jupyter-notebook-ssh-command
     profile
     (concat
      (emacs-jupyter-notebook-docker--inspect entry)
      (when preserve-files
        (concat "waited=0; while [ \"$state\" = match ] && [ \"$waited\" -lt 50 ]; do "
                "sleep 0.1; waited=$((waited + 1)); "
                (emacs-jupyter-notebook-docker--inspect entry) "done; "))
      "case \"$state\" in unknown|mismatch) echo 'EJN Docker cleanup identity unconfirmed' >&2; exit 1;; esac; "
      (if preserve-files
          "[ \"$state\" = dead ] || { echo 'EJN Docker kernel container is still running' >&2; exit 1; }; "
        (concat "if [ \"$state\" = match ]; then " emacs-jupyter-notebook-docker--command
                " stop --time 5 \"$id\" >/dev/null || exit 1; fi; "))
      ;; A stopped --rm container commonly disappears between inspect and rm.
      "if [ -n \"$id\" ]; then " emacs-jupyter-notebook-docker--command
      " container rm \"$id\" >/dev/null 2>&1 || "
      "{ ids=$(" emacs-jupyter-notebook-docker--command
      " container ls --all --no-trunc --filter \"id=$id\" --format '{{.ID}}') && [ -z \"$ids\" ]; } || exit 1; fi; "
      (unless preserve-files
        (concat "rm -f -- " (mapconcat #'shell-quote-argument files " ") " || exit 1; "))
      "echo __EJN_CLEANUP_DONE__"))))

(defun emacs-jupyter-notebook-docker-build-log (profile entry)
  "Return bounded Docker log read argv for PROFILE ENTRY."
  (emacs-jupyter-notebook-ssh-command
   profile (concat (emacs-jupyter-notebook-docker--inspect entry)
                   "[ \"$state\" = match ] || { echo 'EJN Docker logs unavailable' >&2; exit 1; }; "
                   emacs-jupyter-notebook-docker--command
                   " logs --tail 200 \"$id\" 2>&1 | tail -c "
                   (number-to-string (emacs-jupyter-notebook-ssh--management-output-limit)))))

(defun emacs-jupyter-notebook-docker-build-list (profile)
  "Return a read-only list of containers owned by Docker PROFILE."
  (setq profile (emacs-jupyter-notebook-ssh-profile profile))
  (emacs-jupyter-notebook-ssh-command
   profile (concat emacs-jupyter-notebook-docker--command
                   " container ls --all --no-trunc --filter "
                   (shell-quote-argument
                    (concat "label=" emacs-jupyter-notebook-docker--profile-label "="
                            (emacs-jupyter-notebook-docker--profile-key profile))))))

(defun emacs-jupyter-notebook-docker-build-cleanup-all (_profile)
  "Refuse unregistered Docker cleanup; registry identity is mandatory."
  (error "Docker profile-wide cleanup is unsupported; reconnect the session and use shutdown-kernel or retry-fresh-kernel"))

(provide 'emacs-jupyter-notebook-docker)
;;; emacs-jupyter-notebook-docker.el ends here
