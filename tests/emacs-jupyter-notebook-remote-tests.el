;;; emacs-jupyter-notebook-remote-tests.el --- Optional remote smoke tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; These tests require an explicitly configured remote host.  They do not
;; run as part of normal unit tests.  The emacs-jupyter integration smoke
;; test skips unless emacs-jupyter is on `load-path'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-result)

(declare-function jupyter-eval "jupyter-client" (code &optional mime))
(defvar jupyter-current-client)
(defvar jupyter-default-timeout)

(defconst ejn-remote-tests--command-timeout 25
  "Hard deadline in seconds for one optional smoke-test command.")

(defconst ejn-remote-tests--command-output-max-bytes (* 64 1024)
  "Maximum retained bytes for each stdout or stderr smoke-test stream.")

(defconst ejn-remote-tests--connect-timeout 8
  "SSH connect timeout forced by the optional remote test suite.")

(defmacro ejn-remote-tests--with-bounded-transport (&rest body)
  "Run BODY with noninteractive, finite test-local remote transport bounds."
  (declare (indent 0) (debug t))
  `(let ((emacs-jupyter-notebook-ssh-options
          (append (list "-o" "BatchMode=yes"
                        "-o" (format "ConnectTimeout=%d"
                                     ejn-remote-tests--connect-timeout))
                  emacs-jupyter-notebook-ssh-options))
         (emacs-jupyter-notebook-ssh-batch-mode t)
         (emacs-jupyter-notebook-ssh-connect-timeout
          ejn-remote-tests--connect-timeout)
         (emacs-jupyter-notebook-ssh-process-timeout
          ejn-remote-tests--command-timeout)
         (emacs-jupyter-notebook-management-process-timeout
          ejn-remote-tests--command-timeout)
         (emacs-jupyter-notebook-connection-attempt-timeout 60)
         (emacs-jupyter-notebook-jupyter-connect-timeout 20))
     ,@body))

(defun ejn-remote-tests--run-command (argv &optional timeout)
  "Run test-only ARGV via a capped, deadline-bound `make-process' child.
Both streams are retained independently up to
`ejn-remote-tests--command-output-max-bytes'.  This helper is deliberately
for optional smoke tests only; production UI paths remain asynchronous."
  (unless (and (listp argv) argv
               (cl-every (lambda (part)
                           (and (stringp part) (not (string-empty-p part))))
                         argv))
    (error "Remote smoke command refused malformed argv: %S" argv))
  (let* ((limit (or timeout ejn-remote-tests--command-timeout))
         (deadline (+ (float-time) limit))
         (name (format "ejn-remote-test-command-%x" (random most-positive-fixnum)))
         (stdout "")
         (stderr "")
         stdout-overflow stderr-overflow process stderr-process timed-out)
    (unless (and (numberp limit) (> limit 0))
      (error "Remote smoke command timeout must be positive: %S" limit))
    (cl-labels
        ((append-output
          (stream chunk)
          (let* ((current (if (eq stream 'stdout) stdout stderr))
                 (room (- ejn-remote-tests--command-output-max-bytes
                          (string-bytes current)))
                 (overflow (> (string-bytes chunk) room)))
            ;; `no-conversion' makes CHUNK unibyte.  Retain only the remaining
            ;; byte budget, never materializing CURRENT+CHUNK past the cap.
            (when (> room 0)
              (setq current
                    (concat current
                            (substring chunk 0 (min room (length chunk))))))
            (if (eq stream 'stdout)
                (setq stdout current
                      stdout-overflow (or stdout-overflow overflow))
              (setq stderr current
                    stderr-overflow (or stderr-overflow overflow)))
            (when overflow
              (when (and (processp process) (process-live-p process))
                (delete-process process))
              (when (and (processp stderr-process) (process-live-p stderr-process))
                (delete-process stderr-process))))))
      (unwind-protect
          (progn
            (setq stderr-process
                  (make-pipe-process
                   :name (concat name "-stderr") :buffer nil :noquery t
                   :coding 'no-conversion
                   :filter (lambda (_process chunk) (append-output 'stderr chunk))))
            (setq process
                  (make-process
                   :name name :command argv :buffer nil :stderr stderr-process
                   :connection-type 'pipe :noquery t :coding 'no-conversion
                   :filter (lambda (_process chunk) (append-output 'stdout chunk))))
            (while (and (process-live-p process)
                        (not stdout-overflow) (not stderr-overflow)
                        (< (float-time) deadline))
              (accept-process-output process
                                     (min 0.1 (max 0.01 (- deadline (float-time))))))
            (when (process-live-p process)
              (setq timed-out t)
              (delete-process process))
            ;; Let the stderr pipe flush a final bounded fragment after the
            ;; command exits, then discard it rather than retaining a reader.
            (let ((drain-deadline (+ (float-time) 0.2)))
              (while (and (processp stderr-process) (process-live-p stderr-process)
                          (< (float-time) drain-deadline))
                (accept-process-output nil 0.02)))
            (cond
             ((or stdout-overflow stderr-overflow)
              (error "Remote smoke command exceeded %d-byte %s cap: %s"
                     ejn-remote-tests--command-output-max-bytes
                     (cond ((and stdout-overflow stderr-overflow) "stdout/stderr")
                           (stdout-overflow "stdout") (t "stderr"))
                     (mapconcat #'shell-quote-argument argv " ")))
             (timed-out
              (error "Remote smoke command timed out after %.1fs: %s"
                     limit (mapconcat #'shell-quote-argument argv " ")))
             ((not (and (eq (process-status process) 'exit)
                        (zerop (process-exit-status process))))
              (error "Remote smoke command failed (%s): %s; stdout=%S stderr=%S"
                     (process-exit-status process)
                     (mapconcat #'shell-quote-argument argv " ") stdout stderr))
             (t stdout)))
        (when (and (processp process) (process-live-p process))
          (delete-process process))
        (when (and (processp stderr-process) (process-live-p stderr-process))
          (delete-process stderr-process))))))

(defun ejn-remote-tests--capture-cleanup-entry (buffer)
  "Return BUFFER's exact positive-PID direct entry, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p
             emacs-jupyter-notebook--session-entry)
        (copy-sequence emacs-jupyter-notebook--session-entry)))))

(ert-deftest ejn-remote-run-command-is-exact-and-output-bounded ()
  "The optional runner has inert sentinels and kills output at its byte cap."
  (should (equal (ejn-remote-tests--run-command
                  '("sh" "-c" "printf __EJN_DONE__") 2)
                 "__EJN_DONE__"))
  (let (message-text)
    (condition-case err
        (ejn-remote-tests--run-command
         '("sh" "-c" "while :; do printf 0123456789abcdef; done") 2)
      (error (setq message-text (error-message-string err))))
    (should (string-match-p "exceeded [0-9]+-byte" message-text))))

(defun ejn-remote-tests--exact-pid-dead-p (profile entry timeout)
  "Return non-nil only after ENTRY's exact PID probe reports dead by TIMEOUT.
An alive mismatch or unavailable process identity is ambiguity, not proof that
cleanup reached the test-owned kernel."
  (let ((deadline (+ (float-time) timeout))
        last-output last-error dead ambiguous)
    (while (and (not dead) (not ambiguous) (< (float-time) deadline))
      (let ((remaining (max 0.1 (- deadline (float-time)))))
        (condition-case err
            (let ((output
                   (ejn-remote-tests--run-command
                    (emacs-jupyter-notebook-ssh-build-pid-alive
                     profile (plist-get entry :remote-pid)
                     (plist-get entry :connection-file-tokens))
                    (min 5 remaining))))
              (setq last-output output)
              (cond
               ((equal (string-trim output) "__EJN_DEAD__\n__EJN_DONE__")
                (setq dead t))
               ((member (string-trim output)
                        '("__EJN_ALIVE_MISMATCH__\n__EJN_DONE__"
                          "__EJN_INSPECT_UNAVAILABLE__\n__EJN_DONE__"))
                (setq ambiguous (string-trim output)))))
          (error (setq last-error (error-message-string err)))))
      (unless dead
        (accept-process-output nil 0.1)))
    (unless dead
      (error "Remote smoke cleanup did not prove PID %s dead; ambiguity=%S last-output=%S last-error=%S"
             (plist-get entry :remote-pid) ambiguous last-output last-error))
    t))

(defun ejn-remote-tests--cleanup-entry (profile entry)
  "Clean test-owned ENTRY on PROFILE and require marker plus PID-death proof."
  (unless (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)
    (error "Remote smoke cleanup has no promoted positive-PID entry"))
  (let ((output
         (ejn-remote-tests--run-command
          (emacs-jupyter-notebook-ssh-build-remote-cleanup profile entry))))
    (unless (equal (string-trim output) "__EJN_CLEANUP_DONE__")
      (error "Remote smoke cleanup returned no exact file-removal marker: %S" output)))
  ;; The production cleanup marker means its remote shell completed, but this
  ;; independent identity-aware probe is the test's authority to discard local
  ;; registry/connection evidence.
  (ejn-remote-tests--exact-pid-dead-p profile entry 10)
  t)

(defun ejn-remote-tests--recover-promoted-entry (profile provisional timeout)
  "Boundedly promote PROVISIONAL from its exact remote PID sidecar.
Return nil when the sidecar cannot yet prove a positive PID.  The caller keeps
the provisional registry evidence in that case rather than guessing at broad
remote cleanup."
  (unless (emacs-jupyter-notebook-ssh-direct-entry-valid-p provisional)
    (error "Remote smoke recovery has no valid provisional direct entry"))
  (let ((deadline (+ (float-time) timeout))
        promoted)
    (while (and (not promoted) (< (float-time) deadline))
      (let ((remaining (max 0.1 (- deadline (float-time))))
            output)
        (condition-case nil
            (progn
              (setq output
                    (ejn-remote-tests--run-command
                     (emacs-jupyter-notebook-ssh-build-remote-read-pid-sidecar
                      profile (plist-get provisional :remote-pid-sidecar))
                     (min 5 remaining)))
              (let ((pid (emacs-jupyter-notebook--parse-pid-sidecar
                          output (plist-get provisional :session-id))))
                (when (and (integerp pid) (> pid 0))
                  (setq promoted (copy-sequence provisional))
                  (setq promoted (plist-put promoted :remote-pid pid))
                  (setq promoted (plist-put promoted :provisional nil)))))
          (error nil)))
      (unless promoted
        (accept-process-output nil 0.1)))
    promoted))

(defun ejn-remote-tests--host ()
  "Return the configured remote test host, or nil."
  (getenv "EJN_REMOTE_TEST_HOST"))

(defun ejn-remote-tests--profile ()
  "Return the remote smoke-test profile plist."
  (list :profile "remote-smoke"
        :host (or (ejn-remote-tests--host)
                  (ert-skip "Set EJN_REMOTE_TEST_HOST to run remote smoke tests"))
         :remote-cwd (or (getenv "EJN_REMOTE_TEST_CWD") "~")
         :remote-cache-dir (or (getenv "EJN_REMOTE_TEST_CACHE")
                               "~/.cache/emacs-jupyter-notebook-smoke")
         :kernelspec (or (getenv "EJN_REMOTE_TEST_KERNELSPEC") "python3")
         :python-command (list (or (getenv "EJN_REMOTE_TEST_PYTHON") "python3"))))

(defun ejn-remote-tests--session-id ()
  "Return a unique session id for a remote smoke test."
  (format "ert-%s-%s" (emacs-pid) (format-time-string "%Y%m%d%H%M%S")))

(defun ejn-remote-tests--wait-for-local-port (port timeout)
  "Return non-nil when PORT accepts a local TCP connection within TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        connected)
    (while (and (not connected) (< (float-time) deadline))
      (condition-case nil
          (let ((proc (open-network-stream
                       (format "ejn-remote-port-%s" port) nil "127.0.0.1" port)))
            (setq connected t)
            (delete-process proc))
        (error (sleep-for 0.1))))
    connected))

(defun ejn-remote-tests--wait-for-phase (buffer phase timeout)
  "Wait until BUFFER's async context reaches PHASE within TIMEOUT seconds."
  (let ((deadline (+ (float-time) timeout))
        current error)
    (while (and (< (float-time) deadline)
                (not (memq current (list phase 'error))))
      (accept-process-output nil 0.1)
      (with-current-buffer buffer
        (setq current (plist-get emacs-jupyter-notebook--async-context :phase))
        (setq error (plist-get emacs-jupyter-notebook--async-context :error))))
    (when (eq current 'error)
      (ert-fail (format "Async operation failed: %s" error)))
    (eq current phase)))

(defun ejn-remote-tests--wait-for-result-text (buffer text timeout)
  "Return non-nil when BUFFER's output panel has an entry containing TEXT.
W2+: results live in the side-panel buffer's entries, not in source-buffer
overlays."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (let ((panel (emacs-jupyter-notebook-panel-buffer buffer)))
        (when (buffer-live-p panel)
          (with-current-buffer panel
            (setq found
                  (cl-some
                   (lambda (entry)
                     (string-match-p (regexp-quote text)
                                     (ejn-panel-entry-text (cdr entry))))
                   emacs-jupyter-notebook-panel--entries))))))
    found))

(ert-deftest ejn-remote-start-retrieve-and-tunnel-smoke ()
  "Start a remote kernel, retrieve its connection file, and open tunnels."
  :tags '(:remote)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (session-id (ejn-remote-tests--session-id))
         (resolution (emacs-jupyter-notebook-ssh-build-kernelspec-resolution profile session-id))
         resolved launch remote-file
         (local-copy (make-temp-file "ejn-remote-connection-" nil ".json"))
         (registry-file (let ((file (make-temp-file "ejn-remote-direct-registry-")))
                          (delete-file file)
                          file))
         pid provisional-entry cleanup-entry cleanup-confirmed cleanup-error
         tunnel connection local-ports remote-ports)
    (unwind-protect
        (progn
          (setq resolved
                (emacs-jupyter-notebook--parse-resolved-kernelspec
                 (ejn-remote-tests--run-command
                  (plist-get resolution :argv)) session-id
                 (plist-get profile :kernelspec)
                 (plist-get resolution :connection-file)))
          (setq launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                        profile session-id resolved)
                remote-file (plist-get launch :connection-file))
          ;; The launch command can be admitted remotely even when this local
          ;; test loses the reply or cannot read the PID sidecar.  Persist its
          ;; exact provisional identity before sending the command so failure
          ;; leaves recoverable, session-bound evidence rather than an orphan.
          (setq provisional-entry
                (list :launch-kind 'direct :provisional t :remote-pid nil
                      :profile (plist-get profile :profile)
                      :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                      :remote-cwd (plist-get profile :remote-cwd)
                      :kernelspec (plist-get profile :kernelspec)
                      :local-file local-copy :session-id session-id
                      :connection-file-tokens (plist-get launch :connection-tokens)
                      :remote-connection-file remote-file
                      :remote-pid-sidecar (plist-get launch :sidecar-file)))
          (emacs-jupyter-notebook-registry-save-entry provisional-entry registry-file)
          (should (string-match-p "EJN_LAUNCH_ADMITTED"
                                  (ejn-remote-tests--run-command
                                   (plist-get launch :argv))))
          (setq pid (emacs-jupyter-notebook--parse-pid-sidecar
                     (ejn-remote-tests--run-command
                      (emacs-jupyter-notebook-ssh-build-remote-read-pid-sidecar
                       profile (plist-get launch :sidecar-file)))
                     session-id))
          (should (integerp pid))
          (setq cleanup-entry
                (plist-put
                 (plist-put (copy-sequence provisional-entry) :remote-pid pid)
                 :provisional nil))
          (setq cleanup-entry
                (plist-put cleanup-entry :local-connection-file local-copy))
          (emacs-jupyter-notebook-registry-save-entry cleanup-entry registry-file)
          (should (eq 'alive
                      (emacs-jupyter-notebook--classify-pid-probe
                       (ejn-remote-tests--run-command
                        (emacs-jupyter-notebook-ssh-build-pid-alive
                         profile pid (plist-get launch :connection-tokens))))))
          ;; W4.7 removed the sync `--retrieve-connection-file'; retrieve
          ;; inline via scp + read, polling until the kernel has written it.
          (let ((deadline (+ (float-time) 30)))
            (while (and (not connection) (< (float-time) deadline))
              (ignore-errors
                (ejn-remote-tests--run-command
                 (emacs-jupyter-notebook-ssh-scp-from-command
                  profile remote-file local-copy))
                (setq connection
                      (emacs-jupyter-notebook-connection-read-file local-copy)))
              (unless connection (sleep-for 0.25))))
          (should (equal (plist-get connection :transport) "tcp"))
          (should (plist-get connection :shell_port))
          ;; The kernel binds all ZMQ ports at startup, so the tunnel/port
          ;; checks below need no remote-side poke (which would require a
          ;; bare `python3' on the remote PATH — not present under nix).
          (setq remote-ports
                (emacs-jupyter-notebook-connection-ports connection))
          (setq local-ports
                (emacs-jupyter-notebook-connection-allocate-local-ports))
          (setq tunnel
                (emacs-jupyter-notebook--start-tunnel
                 profile remote-ports local-ports session-id))
          (dolist (key emacs-jupyter-notebook-connection-port-keys)
            (should (ejn-remote-tests--wait-for-local-port
                     (plist-get local-ports key) 10))))
      (when (and tunnel (process-live-p tunnel))
        (delete-process tunnel))
      (unless cleanup-entry
        (setq cleanup-entry
              (and provisional-entry
                   (ejn-remote-tests--recover-promoted-entry
                    profile provisional-entry 10)))
        (when cleanup-entry
          (emacs-jupyter-notebook-registry-save-entry cleanup-entry registry-file)))
      (when cleanup-entry
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-remote-tests--cleanup-entry profile cleanup-entry))
          (error (setq cleanup-error (error-message-string err)))))
      (unless cleanup-entry
        (setq cleanup-error
              (or cleanup-error
                  "could not promote the admitted direct launch from its PID sidecar")))
      (if cleanup-confirmed
          (progn
            (when (file-exists-p local-copy) (delete-file local-copy))
            (when (file-exists-p registry-file) (delete-file registry-file)))
        (message (concat "Remote smoke cleanup unconfirmed; retained connection %s, "
                         "registry %s for session %s: %s")
                 local-copy registry-file session-id
                 (or cleanup-error "no cleanup entry"))))
      (when cleanup-error
        (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-async-start-connect-and-evaluate ()
  "Start, connect, and evaluate through the interactive async command path."
  :tags '(:remote :emacs-jupyter :async)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
          (buffer (generate-new-buffer " *ejn-remote-async*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                 (emacs-jupyter-notebook-backend 'legacy)
                 (emacs-jupyter-notebook-remote-profiles
                  `((,(plist-get profile :profile) . ,profile)))
                 (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                 (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-async.py")
            (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
            (should (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                        'resolve))
            (should (ejn-remote-tests--wait-for-phase buffer 'done 60))
            (setq cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer))
            (should cleanup-entry)
            (let ((jupyter-current-client emacs-jupyter-notebook--client)
                  (jupyter-default-timeout 30))
              (should (equal (string-trim (jupyter-eval "6 * 7")) "42")))))
      (setq cleanup-entry
            (or cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer)))
      (when cleanup-entry
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-remote-tests--cleanup-entry profile cleanup-entry))
          (error (setq cleanup-error (error-message-string err)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (if cleanup-confirmed
          (when (file-exists-p registry-file) (delete-file registry-file))
        (message "Remote legacy smoke cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-evaluate-cell-command ()
  "Test that the send-cell command works with real evaluation."
  :tags '(:remote :emacs-jupyter :evaluation)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
          (buffer (generate-new-buffer " *ejn-remote-eval-cell*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                 (emacs-jupyter-notebook-backend 'legacy)
                 (emacs-jupyter-notebook-remote-profiles
                  `((,(plist-get profile :profile) . ,profile)))
                 (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                 (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-eval-cell.py")
            ;; Insert code cell
            (insert "# %%\n6 * 7\n")
            (goto-char (point-min))
            (forward-line 1)
            ;; Evaluate using the actual command; it should start the kernel.
            (emacs-jupyter-notebook-send-cell)
            (should (ejn-remote-tests--wait-for-result-text buffer "42" 80))
            (setq cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer))
            (should cleanup-entry)))
      (setq cleanup-entry
            (or cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer)))
      (when cleanup-entry
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-remote-tests--cleanup-entry profile cleanup-entry))
          (error (setq cleanup-error (error-message-string err)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (if cleanup-confirmed
          (when (file-exists-p registry-file) (delete-file registry-file))
        (message "Remote legacy smoke cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-reconnect-prefers-current-file-kernel ()
  "Start a kernel, then reconnect from another buffer visiting the same file."
  :tags '(:remote :emacs-jupyter :reconnect)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
         (source-file (make-temp-file "ejn-source-" nil ".py"))
         (first-buffer (generate-new-buffer " *ejn-remote-reconnect-a*"))
          (second-buffer (generate-new-buffer " *ejn-remote-reconnect-b*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (progn
           (with-current-buffer first-buffer
             (setq buffer-file-name source-file)
             (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                   (emacs-jupyter-notebook-backend 'legacy)
                   (emacs-jupyter-notebook-remote-profiles
                    `((,(plist-get profile :profile) . ,profile)))
                   (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                   (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
              (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
              (should (ejn-remote-tests--wait-for-phase first-buffer 'done 60))
              (setq cleanup-entry
                    (ejn-remote-tests--capture-cleanup-entry first-buffer))
              (should cleanup-entry)
              (when (process-live-p emacs-jupyter-notebook--tunnel-process)
                (delete-process emacs-jupyter-notebook--tunnel-process))
              (setq emacs-jupyter-notebook--tunnel-process nil)))
          (with-current-buffer second-buffer
            (setq buffer-file-name source-file)
            (insert "# %%\n6 * 7\n")
            (goto-char (point-min))
            (forward-line 1)
            (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                  (emacs-jupyter-notebook-backend 'legacy)
                  (emacs-jupyter-notebook-remote-profiles
                   `((,(plist-get profile :profile) . ,profile)))
                  (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                  (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
              (emacs-jupyter-notebook-send-cell)
              (should (ejn-remote-tests--wait-for-result-text second-buffer "42" 80)))))
      (setq cleanup-entry
            (or cleanup-entry
                (ejn-remote-tests--capture-cleanup-entry second-buffer)
                (ejn-remote-tests--capture-cleanup-entry first-buffer)))
      (when cleanup-entry
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-remote-tests--cleanup-entry profile cleanup-entry))
          (error (setq cleanup-error (error-message-string err)))))
      (when (buffer-live-p first-buffer)
        (kill-buffer first-buffer))
      (when (buffer-live-p second-buffer)
        (kill-buffer second-buffer))
      (if cleanup-confirmed
          (progn
            (when (file-exists-p registry-file) (delete-file registry-file))
            (when (file-exists-p source-file) (delete-file source-file)))
        (message (concat "Remote legacy reconnect cleanup unconfirmed; retained "
                         "registry %s and source %s: %s")
                 registry-file source-file
                 (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-default-adapters-parse-real-replies ()
  "Exercise the DEFAULT complete/inspect/is-complete/kernel-info adapter
impls against a REAL kernel, with NO adapter-var stubs.  Guards the seam
every unit test mocks: the real `jupyter-*-request' construction, the
reply-type strings, and the `jupyter-message-content' shapes.  This is the
W8-class coverage — the adapters that PRODUCE the parsed replies are never
run in the deterministic suite."
  :tags '(:remote :emacs-jupyter :adapters)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((f (make-temp-file "ejn-registry-"))) (delete-file f) f))
         (buffer (generate-new-buffer " *ejn-remote-adapters*"))
         cleanup-entry cleanup-confirmed cleanup-error
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (with-current-buffer buffer
          (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                ;; This test covers the direct emacs-jupyter adapter seam.
                ;; Keep that backend choice local so helper remains the default
                ;; for the rest of the remote suite and normal operation.
                (emacs-jupyter-notebook-backend 'legacy)
                (emacs-jupyter-notebook-remote-profiles
                 `((,(plist-get profile :profile) . ,profile)))
                (emacs-jupyter-notebook-connection-retrieve-attempts 120)
                (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-adapters.py")
            (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
            (should (ejn-remote-tests--wait-for-phase buffer 'done 120))
            (setq cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer))
            (should cleanup-entry)
            (let ((client emacs-jupyter-notebook--client)
                  reply done)
              (should client)
              (cl-flet ((await (fn)
                          (setq reply nil done nil)
                          (funcall fn (lambda (r _e) (setq reply r done t)))
                          (let ((deadline (+ (float-time) 30)))
                            (while (and (not done) (< (float-time) deadline))
                              (accept-process-output nil 0.1)))
                          (should done)))
                ;; kernel_info_reply — the heartbeat's dependency.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-kernel-info client cb)))
                (should reply)
                (should (or (plist-get reply :implementation)
                            (plist-get reply :language_info)))
                ;; complete_reply — real :matches (a vector), real offsets.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-complete client "prin" 4 cb)))
                (should reply)
                (should (member "print" (append (plist-get reply :matches) nil)))
                (should (integerp (plist-get reply :cursor_start)))
                (should (integerp (plist-get reply :cursor_end)))
                ;; inspect_reply — found symbol has non-empty text/plain.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-inspect client "print" 5 0 cb)))
                (should reply)
                (should (eq (plist-get reply :found) t))
                (should (plist-get (plist-get reply :data) :text/plain))
                ;; is_complete_reply — incomplete vs complete.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-is-complete client "if True:" cb)))
                (should reply)
                (should (member (plist-get reply :status) '("incomplete" "invalid")))
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-is-complete client "1 + 1" cb)))
                (should reply)
                (should (equal (plist-get reply :status) "complete"))))))
      (setq cleanup-entry
            (or cleanup-entry (ejn-remote-tests--capture-cleanup-entry buffer)))
      (when cleanup-entry
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-remote-tests--cleanup-entry profile cleanup-entry))
          (error (setq cleanup-error (error-message-string err)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (if cleanup-confirmed
          (when (file-exists-p registry-file) (delete-file registry-file))
        (message "Remote legacy adapter cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(provide 'emacs-jupyter-notebook-remote-tests)

;;; emacs-jupyter-notebook-remote-tests.el ends here
