;;; emacs-jupyter-notebook-remote-tests.el --- Optional remote smoke tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; These tests require an explicitly configured remote host.  They do not
;; run as part of normal unit tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-result)

(defconst ejn-remote-tests--command-timeout 25
  "Hard deadline in seconds for one optional smoke-test command.")

(defconst ejn-remote-tests--command-output-max-bytes (* 64 1024)
  "Maximum retained bytes for each stdout or stderr smoke-test stream.")

(defconst ejn-remote-tests--connect-timeout 8
  "SSH connect timeout forced by the optional remote test suite.")

(defconst ejn-remote-tests--registry-timeout 10
  "Finite deadline for one optional registry test transaction.")

(defun ejn-remote-tests--registry-call (file starter)
  "Run registry STARTER against FILE, bounded for optional test orchestration.
STARTER receives SUCCESS, FAILURE, and OWNER arguments.  This deliberately
waits only in the test process; production registry calls remain asynchronous.
Return the first SUCCESS value, or signal on timeout/failure."
  (let ((owner (emacs-jupyter-notebook-registry-owner-create))
        (done nil) (values nil) (failure nil)
        (deadline (+ (float-time) ejn-remote-tests--registry-timeout)))
    (let ((emacs-jupyter-notebook-registry-file file))
      (funcall starter
               (lambda (&rest result) (setq values result done t))
               (lambda (&rest result) (setq failure result done t))
               owner))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless done
      (emacs-jupyter-notebook-registry-owner-cancel owner)
      (error "Remote test registry transaction timed out"))
    (emacs-jupyter-notebook-registry-owner-cancel owner)
    (if failure
        (error "Remote test registry transaction failed: %S" (car failure))
      (car values))))

(defun ejn-remote-tests--registry-create (file entry)
  "Create ENTRY in FILE and return its revision-bearing persisted entry."
  (ejn-remote-tests--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-create-async
      entry success failure :owner owner
      :deadline ejn-remote-tests--registry-timeout))))

(defun ejn-remote-tests--registry-replace (file entry revision)
  "Replace FILE's ENTRY at exact REVISION and return persisted ENTRY."
  (ejn-remote-tests--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-replace-async
      entry revision success failure :owner owner
      :deadline ejn-remote-tests--registry-timeout))))

(defun ejn-remote-tests--registry-read (file)
  "Read FILE through the bounded asynchronous registry bridge."
  (ejn-remote-tests--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-read-async
      success failure :owner owner
      :deadline ejn-remote-tests--registry-timeout))))

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
         (emacs-jupyter-notebook-connect-arbitration-timeout 20))
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

(ert-deftest ejn-remote-management-timeout-is-finite-and-bounded ()
  "Management watchdog values remain finite while sane values are preserved."
  (let ((emacs-jupyter-notebook-management-process-timeout 17))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout nil) 17))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout 23.5) 23.5))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout 601)
               emacs-jupyter-notebook-ssh--management-timeout-hard-limit))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout
                most-positive-fixnum)
               emacs-jupyter-notebook-ssh--management-timeout-hard-limit))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout
                1.0e+INF)
               emacs-jupyter-notebook-ssh--management-timeout-fallback)))
  (let ((emacs-jupyter-notebook-management-process-timeout 1.0e+INF))
    (should (= (emacs-jupyter-notebook-ssh--management-timeout nil)
               emacs-jupyter-notebook-ssh--management-timeout-fallback))))

(defun ejn-remote-tests--local-shell-script (argv)
  "Run the remote shell script in ARGV locally, without invoking SSH.
Return a cons of the process status and combined stdout/stderr.  This is a
test-only harness for command builders whose final argv element is the
remote shell script."
  (with-temp-buffer
    (let ((status (call-process "sh" nil t nil "-c"
                                (concat (car (last argv)) " 2>&1"))))
      (cons status (buffer-string)))))

(ert-deftest ejn-remote-inspect-pid-sidecar-has-exact-terminal-protocol ()
  "The sidecar inspector distinguishes present, absent, and unsafe objects.
Run its generated remote script through a local POSIX shell so this remains
deterministic and never requires an SSH host."
  (let* ((directory (make-temp-file "ejn-sidecar-inspect-" t))
         (session "sidecar-test")
         (connection-file (expand-file-name (format "kernel-%s.json" session)
                                            directory))
         (sidecar (concat (string-remove-suffix ".json" connection-file)
                          ".pid"))
         (entry (list :launch-kind 'direct :provisional t
                      :session-id session
                      :remote-connection-file connection-file
                      :remote-pid-sidecar sidecar
                      :connection-file-tokens (list connection-file)
                      :remote-pid nil))
         (profile '(:profile "sidecar-test" :host "example.invalid"
                    :python-command ("python3")))
         (argv (emacs-jupyter-notebook-ssh-build-remote-inspect-pid-sidecar
                profile entry))
         (script (car (last argv))))
    (unwind-protect
        (progn
          (should (string-match-p
                   "printf '__EJN_SIDECAR_DONE__\\\\n'" script))
          (should (string-match-p
                   "printf '__EJN_SIDECAR_ABSENT__\\\\n__EJN_SIDECAR_DONE__"
                   script))
          (should (string-match-p
                   "printf '__EJN_SIDECAR_UNSAFE__" script))
          (pcase-let ((`(,status . ,output)
                       (ejn-remote-tests--local-shell-script argv)))
            (should (zerop status))
            (should (equal output
                           "__EJN_SIDECAR_ABSENT__\n__EJN_SIDECAR_DONE__\n")))
          (with-temp-file sidecar
            (insert (format "EJN_PID=4242\nEJN_SESSION=%s\n" session)))
          (pcase-let ((`(,status . ,output)
                       (ejn-remote-tests--local-shell-script argv)))
            (should (zerop status))
            (should (equal output
                           (format "EJN_PID=4242\nEJN_SESSION=%s\n__EJN_SIDECAR_DONE__\n"
                                   session)))
            (should (string-suffix-p "__EJN_SIDECAR_DONE__\n" output)))
          (delete-file sidecar)
          (make-symbolic-link "/dev/null" sidecar)
          (pcase-let ((`(,status . ,output)
                       (ejn-remote-tests--local-shell-script argv)))
            (should-not (zerop status))
            (should (string-match-p "__EJN_SIDECAR_UNSAFE__" output)))
          (delete-file sidecar)
          (make-directory sidecar)
          (pcase-let ((`(,status . ,output)
                       (ejn-remote-tests--local-shell-script argv)))
            (should-not (zerop status))
            (should (string-match-p "__EJN_SIDECAR_UNSAFE__" output))))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(ert-deftest ejn-remote-transition-rows-are-unknown-and-retained-by-liveness ()
  "A durable lifecycle row never reaches a destructive liveness probe."
  (let* ((transition-entry
          (list :profile "transition-test" :remote-host "example.invalid"
                :remote-pid 4242 :transition-kind 'retry-fresh
                :transition-token "token" :transition-stage 'admitted
                :transition-expires-at (+ (floor (float-time)) 3600)))
         (probe-called nil)
         (classification
          (emacs-jupyter-notebook--classify-registry-liveness
           (list transition-entry)
           (lambda (_profile _pids)
             (setq probe-called t)
             (list :answered t :alive nil :dead '(4242)))))
         async-classification async-reason
         (summary
          (emacs-jupyter-notebook--registry-liveness-result
           (list transition-entry) classification)))
    (should-not probe-called)
    (should (eq (emacs-jupyter-notebook--liveness-status
                 transition-entry classification)
                'unknown))
    (should (= (plist-get summary :pruned) 0))
    (should (equal (plist-get summary :pruned-entries) nil))
    (should (equal (plist-get summary :kept-entries)
                   (list transition-entry)))
    (with-temp-buffer
      (setq emacs-jupyter-notebook--management-operation
            (list :token 'ejn-remote-transition-test))
      (emacs-jupyter-notebook--classify-registry-liveness-async
       (list transition-entry) 'ejn-remote-transition-test
       (lambda (result reason)
         (setq async-classification result
               async-reason reason)))
      (should (equal async-reason nil))
      (should (eq (emacs-jupyter-notebook--liveness-status
                   transition-entry async-classification)
                  'unknown))
      (should (equal async-classification
                     (list (cons transition-entry 'unknown)))))))

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
         (registry-dir (make-temp-file "ejn-remote-direct-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
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
          (setq provisional-entry
                (ejn-remote-tests--registry-create registry-file provisional-entry))
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
          (setq cleanup-entry
                (ejn-remote-tests--registry-replace
                 registry-file cleanup-entry
                 (plist-get provisional-entry :registry-revision)))
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
          (setq cleanup-entry
                (ejn-remote-tests--registry-replace
                 registry-file cleanup-entry
                 (plist-get provisional-entry :registry-revision)))))
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
            (when (file-exists-p registry-file) (delete-file registry-file))
            (when (file-directory-p registry-dir) (delete-directory registry-dir t)))
        (message (concat "Remote smoke cleanup unconfirmed; retained connection %s, "
                         "registry %s for session %s: %s")
                 local-copy registry-file session-id
                 (or cleanup-error "no cleanup entry"))))
      (when cleanup-error
        (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-async-start-connect-and-evaluate ()
  "Start, connect, and evaluate through the interactive async command path."
  :tags '(:remote :helper :async)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-dir (make-temp-file "ejn-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
          (buffer (generate-new-buffer " *ejn-remote-async*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
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
            (emacs-jupyter-notebook--evaluate-code "6 * 7" nil)
            (should (ejn-remote-tests--wait-for-result-text buffer "42" 30))))
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
          (progn
            (when (file-exists-p registry-file) (delete-file registry-file))
            (when (file-directory-p registry-dir) (delete-directory registry-dir t)))
        (message "Remote smoke cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-evaluate-cell-command ()
  "Test that the send-cell command works with real evaluation."
  :tags '(:remote :helper :evaluation)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-dir (make-temp-file "ejn-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
          (buffer (generate-new-buffer " *ejn-remote-eval-cell*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
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
          (progn
            (when (file-exists-p registry-file) (delete-file registry-file))
            (when (file-directory-p registry-dir) (delete-directory registry-dir t)))
        (message "Remote smoke cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-reconnect-prefers-current-file-kernel ()
  "Start a kernel, then reconnect from another buffer visiting the same file."
  :tags '(:remote :helper :reconnect)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-dir (make-temp-file "ejn-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (source-file (make-temp-file "ejn-source-" nil ".py"))
         (first-buffer (generate-new-buffer " *ejn-remote-reconnect-a*"))
          (second-buffer (generate-new-buffer " *ejn-remote-reconnect-b*"))
          cleanup-entry cleanup-confirmed cleanup-error
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (progn
           (with-current-buffer first-buffer
             (setq buffer-file-name source-file)
             (emacs-jupyter-notebook-mode 1)
             (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                   (emacs-jupyter-notebook-remote-profiles
                    `((,(plist-get profile :profile) . ,profile)))
                   (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                   (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
              (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
              (should (ejn-remote-tests--wait-for-phase first-buffer 'done 60))
              (setq cleanup-entry
                    (ejn-remote-tests--capture-cleanup-entry first-buffer))
              (should cleanup-entry)))
           ;; The supported reconnect model has one source buffer per kernel.
           ;; Killing the first source retires only its local helper/tunnel;
           ;; the durable registry row and remote kernel remain available.
           (kill-buffer first-buffer)
          (with-current-buffer second-buffer
            (setq buffer-file-name source-file)
            (emacs-jupyter-notebook-mode 1)
            (insert "# %%\n6 * 7\n")
            (goto-char (point-min))
            (forward-line 1)
            (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
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
            (when (file-directory-p registry-dir) (delete-directory registry-dir t))
            (when (file-exists-p source-file) (delete-file source-file)))
        (message (concat "Remote reconnect cleanup unconfirmed; retained "
                         "registry %s and source %s: %s")
                 registry-file source-file
                 (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(ert-deftest ejn-remote-helper-parses-real-auxiliary-replies ()
  "Exercise helper complete/inspect/is-complete/kernel-info against a real kernel."
  :tags '(:remote :helper :auxiliary)
  (ejn-remote-tests--with-bounded-transport
    (let* ((profile (ejn-remote-tests--profile))
         (registry-dir (make-temp-file "ejn-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (buffer (generate-new-buffer " *ejn-remote-adapters*"))
         cleanup-entry cleanup-confirmed cleanup-error
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (with-current-buffer buffer
          (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
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
                  reply failure done)
              (should client)
              (cl-flet ((await (fn)
                          (setq reply nil failure nil done nil)
                          (funcall fn
                                   (lambda (_id result) (setq reply result done t))
                                   (lambda (_id reason)
                                     (setq failure reason done t)))
                          (let ((deadline (+ (float-time) 30)))
                            (while (and (not done) (< (float-time) deadline))
                              (accept-process-output nil 0.1)))
                          (should done)
                          (when failure
                            (ert-fail (format "helper auxiliary failed: %s"
                                              failure)))))
                ;; kernel_info_reply — the heartbeat's dependency.
                (await (lambda (success failure)
                         (emacs-jupyter-notebook-backend-aux
                          client 'kernel-info nil success failure)))
                (should reply)
                (should (gethash "implementation" reply))
                (should (gethash "language_info" reply))
                ;; complete_reply — real :matches (a vector), real offsets.
                (await (lambda (success failure)
                         (emacs-jupyter-notebook-backend-aux
                          client 'complete '(:code "prin" :cursor-pos 4)
                          success failure)))
                (should reply)
                (should (member "print" (append (plist-get reply :matches) nil)))
                (should (integerp (plist-get reply :cursor_start)))
                (should (integerp (plist-get reply :cursor_end)))
                ;; inspect_reply — found symbol has non-empty text/plain.
                (await (lambda (success failure)
                         (emacs-jupyter-notebook-backend-aux
                          client 'inspect '(:code "print" :cursor-pos 5 :detail 0)
                          success failure)))
                (should reply)
                (should (eq (plist-get reply :found) t))
                (should (plist-get (plist-get reply :data) :text/plain))
                ;; is_complete_reply — incomplete vs complete.
                (await (lambda (success failure)
                         (emacs-jupyter-notebook-backend-aux
                          client 'is-complete '(:code "if True:") success failure)))
                (should reply)
                (should (member (plist-get reply :status) '("incomplete" "invalid")))
                (await (lambda (success failure)
                         (emacs-jupyter-notebook-backend-aux
                          client 'is-complete '(:code "1 + 1") success failure)))
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
          (progn
            (when (file-exists-p registry-file) (delete-file registry-file))
            (when (file-directory-p registry-dir) (delete-directory registry-dir t)))
          (message "Remote helper cleanup unconfirmed; retained registry %s: %s"
                 registry-file (or cleanup-error "no promoted cleanup entry"))))
      (when cleanup-error (ert-fail cleanup-error)))))

(provide 'emacs-jupyter-notebook-remote-tests)

;;; emacs-jupyter-notebook-remote-tests.el ends here
