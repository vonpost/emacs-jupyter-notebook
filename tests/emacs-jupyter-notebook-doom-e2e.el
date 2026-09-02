;;; emacs-jupyter-notebook-doom-e2e.el --- Doom end-to-end test  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Optional end-to-end test helpers intended to run inside an Emacs instance
;; that has already loaded the user's Doom configuration.  Use
;; tests/run-doom-e2e.sh to start an isolated daemon and invoke this file.
;; Nothing here targets the user's live Emacs or a non-test-owned kernel.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-result)

(defconst ejn-doom-e2e--metric-string-limit 512
  "Maximum UTF-8 byte length retained for one E2E metric string.")

(defun ejn-doom-e2e--bounded-string (value)
  "Return VALUE truncated to the E2E metric string bound."
  (let ((text (format "%s" value))
        (end nil))
    (setq end (length text))
    (if (<= (string-bytes text) ejn-doom-e2e--metric-string-limit)
        text
      (while (> (string-bytes (substring text 0 end))
                ejn-doom-e2e--metric-string-limit)
        (setq end (1- end)))
      (substring text 0 end))))

(defun ejn-doom-e2e--positive-number (environment default maximum)
  "Read a finite positive number from ENVIRONMENT or return DEFAULT.
Reject values above MAXIMUM so optional test orchestration cannot silently
turn into an unbounded wait."
  (let ((raw (getenv environment)))
    (if (or (null raw) (string-empty-p raw))
        default
      (let ((value (string-to-number raw)))
        (unless (and (numberp value)
                     (> value 0)
                     (<= value maximum))
          (error "%s must be a positive number no greater than %s" environment maximum))
        value))))

(defun ejn-doom-e2e--timeout ()
  "Return the overall E2E timeout in seconds."
  (ejn-doom-e2e--positive-number "EJN_DOOM_E2E_TIMEOUT" 90 600))

(defun ejn-doom-e2e--cleanup-timeout ()
  "Return the bounded command and shutdown cleanup timeout in seconds."
  (ejn-doom-e2e--positive-number "EJN_DOOM_E2E_CLEANUP_TIMEOUT" 25 120))

(defun ejn-doom-e2e--record-progress (text)
  "Record bounded diagnostic TEXT for this isolated E2E invocation."
  (message "Doom E2E phase: %s" text)
  (when-let ((progress-file (getenv "EJN_DOOM_E2E_PROGRESS_FILE")))
    (unless (and (file-name-absolute-p progress-file)
                 (not (string-match-p "[\0\n\r]" progress-file)))
      (error "EJN_DOOM_E2E_PROGRESS_FILE must be a plain absolute path"))
    (write-region (concat (ejn-doom-e2e--bounded-string text) "\n")
                  nil progress-file 'append 'silent)))

(defun ejn-doom-e2e--phase-budget (deadline phase)
  "Record PHASE and return its remaining share of the overall DEADLINE."
  (let ((remaining (- deadline (float-time))))
    (unless (> remaining 0)
      (error "Doom E2E overall deadline expired before %s" phase))
    (ejn-doom-e2e--record-progress
     (format "%s %.1fs remaining" phase remaining))
    remaining))

(defun ejn-doom-e2e--profile-name ()
  "Return the configured E2E profile name."
  (or (getenv "EJN_DOOM_E2E_PROFILE")
      emacs-jupyter-notebook-default-profile
      "mother"))

(defun ejn-doom-e2e--run-command (argv &optional timeout)
  "Run test-only ARGV synchronously under a finite TIMEOUT and return stdout.
The process is only used for identity-bound remote cleanup and liveness
checks.  It is deliberately not an EJN UI path."
  (unless (and (listp argv) argv
               (cl-every (lambda (part)
                           (and (stringp part) (not (string-empty-p part))))
                         argv))
    (error "Doom E2E refused malformed command argv: %S" argv))
  (let* ((limit (or timeout (ejn-doom-e2e--cleanup-timeout)))
         (stdout (generate-new-buffer " *ejn-doom-e2e-stdout*"))
         (stderr (generate-new-buffer " *ejn-doom-e2e-stderr*"))
         (process nil)
         (deadline (+ (float-time) limit))
         status output)
    (unwind-protect
        (progn
          (setq process
                (make-process :name "ejn-doom-e2e-command"
                              :command argv :buffer stdout :stderr stderr
                              :connection-type 'pipe :noquery t))
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process (min 0.1 (max 0.01 (- deadline (float-time))))))
          (when (process-live-p process)
            (delete-process process)
            ;; A killed local test command gets one short, bounded chance to
            ;; reap its sentinel before we discard its private buffers.
            (accept-process-output process 0.1)
            (error "Doom E2E command timed out after %.1fs: %s"
                   limit (mapconcat #'shell-quote-argument argv " ")))
          (setq status (process-exit-status process)
                output (with-current-buffer stdout (buffer-string)))
          (unless (zerop status)
            (error "Doom E2E command failed (%s): %s\n%s"
                   status (mapconcat #'shell-quote-argument argv " ")
                   (string-trim
                    (concat output
                            (with-current-buffer stderr (buffer-string))))))
          output)
      (when (and (processp process) (process-live-p process))
        (delete-process process))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(defun ejn-doom-e2e--plist-without (plist key)
  "Return PLIST without KEY, preserving all other property pairs."
  (let (result)
    (while plist
      (let ((candidate (pop plist))
            (value (pop plist)))
        (unless (eq candidate key)
          (setq result (append result (list candidate value))))))
    result))

(defun ejn-doom-e2e--python-command-override ()
  "Return the optional JSON `:python-command' override after strict checks.
`EJN_DOOM_E2E_PYTHON_COMMAND_JSON' is a JSON string array, never a shell
fragment.  It is intentionally test-local so an old Doom `:jupyter-command'
profile can be exercised without editing the user's configuration."
  (when-let ((raw (getenv "EJN_DOOM_E2E_PYTHON_COMMAND_JSON")))
    (unless (string-empty-p raw)
      (let ((argv
             (condition-case err
                 (json-parse-string raw :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)
               (error
                (error "EJN_DOOM_E2E_PYTHON_COMMAND_JSON must be a JSON argv array: %s"
                       (error-message-string err))))))
        (unless (and (listp argv) argv
                     (cl-every (lambda (part)
                                 (and (stringp part) (not (string-empty-p part))
                                      (not (string-match-p "[\0\n\r]" part))))
                               argv))
          (error "EJN_DOOM_E2E_PYTHON_COMMAND_JSON must be a non-empty JSON array of plain strings"))
        ;; Share the production bound and argv validation rather than copying
        ;; its limits into this test harness.
        (condition-case err
            (emacs-jupyter-notebook-ssh--python-command
             (list :python-command argv))
          (error
           (error "EJN_DOOM_E2E_PYTHON_COMMAND_JSON is not a valid :python-command argv: %s"
                  (error-message-string err))))))))

(defun ejn-doom-e2e--host-override ()
  "Return the optional validated test-local remote host override."
  (when-let ((host (getenv "EJN_DOOM_E2E_HOST")))
    (unless (and (not (string-empty-p host))
                 (not (string-match-p "[[:space:]\0]" host)))
      (error "EJN_DOOM_E2E_HOST must be a non-empty host string without whitespace"))
    host))

(defun ejn-doom-e2e--ssh-config-override ()
  "Return `(-F FILE)' from the optional validated local SSH config override."
  (when-let ((file (getenv "EJN_DOOM_E2E_SSH_CONFIG")))
    (unless (and (file-name-absolute-p file)
                 (file-regular-p file)
                 (file-readable-p file)
                 (not (string-match-p "[\0\n\r]" file)))
      (error (concat "EJN_DOOM_E2E_SSH_CONFIG must name a readable absolute "
                     "regular file")))
    (list "-F" file)))

(defun ejn-doom-e2e--profile-with-overrides (profile-name)
  "Return PROFILE-NAME after applying only structured E2E environment overrides."
  (let* ((stored (assoc profile-name emacs-jupyter-notebook-remote-profiles))
         (python-command (ejn-doom-e2e--python-command-override))
         (host (ejn-doom-e2e--host-override))
         (ssh-config (ejn-doom-e2e--ssh-config-override)))
    (unless (and stored (listp (cdr stored)))
      (error "No Doom E2E profile named %S; set EJN_DOOM_E2E_PROFILE to a configured profile"
             profile-name))
    (let ((profile (copy-sequence (cdr stored))))
      (when python-command
        ;; The production profile validator rejects legacy entries on sight.
        ;; An explicit structured override deliberately replaces only that
        ;; stale command representation for this isolated test daemon.
        (setq profile (ejn-doom-e2e--plist-without profile :jupyter-command))
        (setq profile (plist-put profile :python-command python-command)))
      (when host
        (setq profile (plist-put profile :host host)))
      (when ssh-config
        (let ((options (plist-get profile :ssh-options)))
          (unless (or (null options) (listp options))
            (error "Doom E2E profile %S has a malformed :ssh-options value" profile-name))
          (setq profile (plist-put profile :ssh-options
                                   (append options ssh-config)))))
      (condition-case err
          (progn
            (emacs-jupyter-notebook-ssh-profile profile)
            (emacs-jupyter-notebook-ssh-destination profile)
            profile)
        (error
         (error (concat "Doom E2E profile %S is invalid after test-local overrides: %s. "
                        "Configure a valid :python-command or set "
                        "EJN_DOOM_E2E_PYTHON_COMMAND_JSON to a JSON argv array")
                profile-name (error-message-string err)))))))

(defun ejn-doom-e2e--check-async-error (buffer)
  "Signal if BUFFER's async setup reached the `error' phase."
  (with-current-buffer buffer
    (when (eq (plist-get emacs-jupyter-notebook--async-context :phase)
              'error)
      (error "Notebook async setup failed: %s"
             (ejn-doom-e2e--bounded-string
              (plist-get emacs-jupyter-notebook--async-context :error))))))

(defun ejn-doom-e2e--panel-entries-for (buffer)
  "Return BUFFER's raw panel entries while rendering through public accessors."
  (let ((panel (emacs-jupyter-notebook-panel-buffer buffer)))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (mapcar #'cdr emacs-jupyter-notebook-panel--entries)))))

(defun ejn-doom-e2e--wait-for-result-text (buffer text timeout)
  "Return non-nil when BUFFER's panel text output matches TEXT by TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (setq found
            (cl-some (lambda (entry)
                       (string-match-p (regexp-quote text)
                                       (ejn-panel-entry-text entry)))
                     (ejn-doom-e2e--panel-entries-for buffer))))
    found))

(defun ejn-doom-e2e--wait-for-result-image (buffer timeout)
  "Return non-nil when BUFFER's panel has an output image by TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (setq found
            (cl-some (lambda (entry) (ejn-panel-entry-images entry))
                     (ejn-doom-e2e--panel-entries-for buffer))))
    found))

(defun ejn-doom-e2e--wait-for-client (buffer timeout)
  "Return a live backend client for BUFFER before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        client)
    (while (and (not client) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (with-current-buffer buffer
        (setq client emacs-jupyter-notebook--client)))
    client))

(defun ejn-doom-e2e--wait-for-shutdown (buffer timeout)
  "Return non-nil once BUFFER has completed an explicit helper shutdown."
  (let ((deadline (+ (float-time) timeout))
        done)
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                    'error)
            (error "Test-owned helper shutdown failed: %s"
                   (ejn-doom-e2e--bounded-string
                    (plist-get emacs-jupyter-notebook--async-context :error))))
          (setq done (and (null emacs-jupyter-notebook--session-entry)
                          (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                              'done))))))
    done))

(defun ejn-doom-e2e--capture-identity (buffer)
  "Capture bounded, non-secret helper, tunnel, and remote identity facts."
  (with-current-buffer buffer
    (let* ((client emacs-jupyter-notebook--client)
           (entry emacs-jupyter-notebook--session-entry)
           (tunnel emacs-jupyter-notebook--tunnel-process)
           (snapshot (emacs-jupyter-notebook-status-snapshot))
           (helper-pid (plist-get snapshot :helper-pid))
           (helper-protocol (plist-get snapshot :helper-protocol))
           (helper-state (plist-get snapshot :helper-state))
           (tunnel-pid (and (processp tunnel) (process-live-p tunnel)
                            (process-id tunnel))))
      (unless (eq emacs-jupyter-notebook-backend 'helper)
        (error "Doom E2E requires emacs-jupyter-notebook-backend to be helper"))
      (unless (and (emacs-jupyter-notebook-backend-session-p client)
                   (eq (emacs-jupyter-notebook-backend-session-backend client) 'helper))
        (error "Doom E2E did not attach a helper backend session"))
      (unless (and (integerp helper-pid) (> helper-pid 0)
                   (integerp helper-protocol) (> helper-protocol 0)
                   (eq helper-state 'ready)
                   (integerp tunnel-pid) (> tunnel-pid 0)
                   (eq (plist-get snapshot :transport-phase) 'connected)
                   (eq (plist-get snapshot :tunnel-state) 'alive)
                   (listp entry)
                   (integerp (plist-get entry :remote-pid))
                   (> (plist-get entry :remote-pid) 0)
                   (stringp (plist-get entry :session-id))
                   (not (string-empty-p (plist-get entry :session-id)))
                   (stringp (plist-get entry :remote-connection-file))
                   (file-name-absolute-p (plist-get entry :remote-connection-file)))
        (error "Doom E2E observed incomplete helper/session identity: %S"
               (list :helper-pid helper-pid :helper-protocol helper-protocol
                     :helper-state helper-state :tunnel-pid tunnel-pid
                     :transport-phase (plist-get snapshot :transport-phase)
                     :tunnel-state (plist-get snapshot :tunnel-state)
                     :remote-pid (plist-get entry :remote-pid)
                     :session-id (plist-get entry :session-id)
                     :remote-connection-file (plist-get entry :remote-connection-file))))
      (list :helper-pid helper-pid
            :helper-protocol helper-protocol
            :helper-state helper-state
            :tunnel-pid tunnel-pid
            :remote-pid (plist-get entry :remote-pid)
            :session-id (plist-get entry :session-id)
            :remote-connection-file (plist-get entry :remote-connection-file)))))

(defun ejn-doom-e2e--same-remote-identity-p (before after)
  "Return non-nil when reconnect identity AFTER still names BEFORE's kernel."
  (cl-every (lambda (key)
              (equal (plist-get before key) (plist-get after key)))
            '(:remote-pid :session-id :remote-connection-file)))

(defun ejn-doom-e2e--entry-remote-identity (entry)
  "Return ENTRY's durable remote identity fields for an E2E comparison."
  (unless (listp entry)
    (error "Doom E2E expected a durable session entry, got %S" entry))
  (list :remote-pid (plist-get entry :remote-pid)
        :session-id (plist-get entry :session-id)
        :remote-connection-file (plist-get entry :remote-connection-file)))

(defun ejn-doom-e2e--check-recovery-state (buffer expected-identity)
  "Reject terminal recovery failure or durable identity drift in BUFFER.
EXPECTED-IDENTITY is the exact remote kernel identity captured before a local
fault injection.  A transient reconnect is allowed to be in progress, but an
async error is deliberately terminal for this controlled E2E scenario: the
remote is known to be reachable immediately before the local-only fault."
  (unless (buffer-live-p buffer)
    (error "E2E source buffer was killed during automatic recovery"))
  (with-current-buffer buffer
    (unless emacs-jupyter-notebook-mode
      (error "Notebook mode was disabled during automatic recovery"))
    (let* ((entry emacs-jupyter-notebook--session-entry)
           (context emacs-jupyter-notebook--async-context)
           (snapshot (emacs-jupyter-notebook-status-snapshot)))
      (unless (and entry
                   (ejn-doom-e2e--same-remote-identity-p
                    expected-identity (ejn-doom-e2e--entry-remote-identity entry)))
        (error "Automatic recovery changed the durable remote identity: expected=%S actual=%S"
               expected-identity entry))
      (when (eq (plist-get context :phase) 'error)
        (error "Automatic recovery entered async error (%S): %s"
               (plist-get context :error-kind)
               (ejn-doom-e2e--bounded-string (plist-get context :error))))
      ;; A confirmed-dead/mismatched PID probe cancels its retry timer.  Make
      ;; that terminal state explicit rather than waiting out the E2E timeout.
      (when (and emacs-jupyter-notebook--tunnel-dead
                 (not emacs-jupyter-notebook--client)
                 (not (plist-get snapshot :async-live))
                 (not (plist-get snapshot :retry-scheduled)))
        (error "Automatic recovery gave up without a ready local transport: %S"
               (list :last-error (plist-get snapshot :last-error)
                     :retry-count (plist-get snapshot :retry-count)
                     :transport-phase (plist-get snapshot :transport-phase))))
      snapshot)))

(defun ejn-doom-e2e--wait-for-recovery
    (buffer expected-identity old-helper-pid old-tunnel-pid timeout)
  "Wait for automatic recovery of BUFFER under a finite TIMEOUT.
The recovered helper and SSH tunnel must be freshly installed, while
EXPECTED-IDENTITY must still identify the exact same remote kernel.  After
readiness, drain a short bounded quiet period so a queued sentinel or timer
from either retired local process cannot silently contaminate the next fault
injection phase."
  (let ((deadline (+ (float-time) timeout))
        recovery)
    (while (and (not recovery) (< (float-time) deadline))
      (accept-process-output nil (min 0.1 (max 0.01 (- deadline (float-time)))))
      (ejn-doom-e2e--check-recovery-state buffer expected-identity)
      (with-current-buffer buffer
        (when (and emacs-jupyter-notebook--client
                   (not emacs-jupyter-notebook--tunnel-dead)
                   (not (emacs-jupyter-notebook--async-in-progress-p)))
          (let ((identity (ejn-doom-e2e--capture-identity buffer)))
            (unless (ejn-doom-e2e--same-remote-identity-p
                     expected-identity identity)
              (error "Automatic recovery attached a different remote kernel: expected=%S actual=%S"
                     expected-identity identity))
            (unless (/= old-helper-pid (plist-get identity :helper-pid))
              (error "Automatic recovery retained retired helper PID %s" old-helper-pid))
            (unless (/= old-tunnel-pid (plist-get identity :tunnel-pid))
              (error "Automatic recovery retained retired tunnel PID %s" old-tunnel-pid))
            (setq recovery identity)))))
    (unless recovery
      (error "Timed out after %.1fs waiting for automatic local transport recovery"
             timeout))
    ;; All helper/tunnel filters and sentinels schedule their callbacks at
    ;; zero delay.  Keep accepting events briefly, and repeatedly require the
    ;; same ready process identities, to detect stale-local-state regressions.
    (let ((quiet-deadline (min deadline (+ (float-time) 0.4))))
      (while (< (float-time) quiet-deadline)
        (accept-process-output nil
                               (min 0.05 (max 0.01 (- quiet-deadline (float-time)))))
        (ejn-doom-e2e--check-recovery-state buffer expected-identity)
        (let ((current (ejn-doom-e2e--capture-identity buffer)))
          (unless (and (ejn-doom-e2e--same-remote-identity-p recovery current)
                       (= (plist-get recovery :helper-pid)
                          (plist-get current :helper-pid))
                       (= (plist-get recovery :tunnel-pid)
                          (plist-get current :tunnel-pid)))
            (error "Late local callback disturbed recovered transport: ready=%S current=%S"
                   recovery current)))))
    recovery))

(defun ejn-doom-e2e--kill-local-helper (buffer identity)
  "Kill only BUFFER's exact local helper process, preserving the remote kernel."
  (with-current-buffer buffer
    (let* ((session emacs-jupyter-notebook--helper-session)
           (process (and (emacs-jupyter-notebook-helper-session-p session)
                         (emacs-jupyter-notebook-helper-session-process session)))
           (expected-pid (plist-get identity :helper-pid)))
      (unless (and (processp process) (process-live-p process)
                   (= expected-pid (process-id process)))
        (error "Refusing helper fault injection without exact local helper PID %S"
               expected-pid))
      ;; Do not dispose the enclosing backend session here.  Its actual process
      ;; sentinel must drive the production transport-loss and auto-reconnect
      ;; path, while the durable remote entry remains untouched.
      (delete-process process)
      process)))

(defun ejn-doom-e2e--kill-local-tunnel (buffer identity)
  "Kill only BUFFER's exact local SSH tunnel, preserving the remote kernel."
  (with-current-buffer buffer
    (let ((process emacs-jupyter-notebook--tunnel-process)
          (expected-pid (plist-get identity :tunnel-pid)))
      (unless (and (processp process) (process-live-p process)
                   (= expected-pid (process-id process)))
        (error "Refusing tunnel fault injection without exact local tunnel PID %S"
               expected-pid))
      ;; The installed tunnel sentinel owns the real transition.  In
      ;; particular, do not clear its sentinel or call local cleanup directly.
      (delete-process process)
      process)))

(defun ejn-doom-e2e--verify-token (buffer token phase timeout)
  "Execute a token assertion in BUFFER and await fresh PHASE output.
The phase-unique history execution proves a fresh round trip without modifying
the visited source or allowing an old panel result to satisfy the check."
  (let ((output (format "EJN token verified after %s: %s" phase token)))
    (ejn-doom-e2e--record-progress (format "dispatching token after %s" phase))
    (with-current-buffer buffer
      (emacs-jupyter-notebook--evaluate-code
       (format "assert ejn_doom_e2e_token == %S\nprint(%S)\n" token output)
       nil))
    (ejn-doom-e2e--record-progress (format "waiting for token after %s" phase))
    (unless (ejn-doom-e2e--wait-for-result-text buffer output timeout)
      (error "Kernel-side token did not survive %s" phase))
    (ejn-doom-e2e--record-progress (format "token verified after %s" phase))
    output))

(defun ejn-doom-e2e--remote-entry-dead-p (entry timeout)
  "Return non-nil when ENTRY's exact PID identity reports dead by TIMEOUT."
  (when (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
    (let ((deadline (+ (float-time) timeout))
          dead)
      (while (and (not dead) (< (float-time) deadline))
        (let* ((remaining (max 0.1 (- deadline (float-time))))
               (argv (emacs-jupyter-notebook-ssh-build-pid-alive
                      (emacs-jupyter-notebook--entry-profile entry)
                      (plist-get entry :remote-pid)
                      (plist-get entry :connection-file-tokens)))
               (output (ignore-errors
                         (ejn-doom-e2e--run-command argv (min 5 remaining)))))
          (setq dead (and (stringp output)
                          (string-match-p "__EJN_DEAD__" output)))
          (unless dead
            (accept-process-output nil (min 0.2 remaining)))))
      dead)))

(defun ejn-doom-e2e--shutdown-test-owned-kernel (buffer entry)
  "Explicitly stop test-owned ENTRY, then verify its exact PID is dead.
The normal helper shutdown is preferred.  The identity-bound SSH cleanup is
only a bounded fallback when its result is unknown; it cannot target any
other kernel."
  (let ((timeout (ejn-doom-e2e--cleanup-timeout))
        shutdown-error)
    (ejn-doom-e2e--record-progress "cleanup started")
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emacs-jupyter-notebook--session-entry
          (condition-case err
              (progn
                (ejn-doom-e2e--record-progress "requesting helper shutdown")
                (emacs-jupyter-notebook-shutdown-kernel :force)
                (ejn-doom-e2e--record-progress "waiting for helper shutdown")
                (ejn-doom-e2e--wait-for-shutdown buffer timeout)
                (ejn-doom-e2e--record-progress "helper shutdown wait finished"))
            (error
             ;; A bounded, explicit SSH fallback below still owns only this
             ;; entry's persisted PID and connection-token identity.
             (setq shutdown-error (error-message-string err)))))))
    (unless (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
      (error "Doom E2E has no valid test-owned direct kernel identity for cleanup"))
    (ejn-doom-e2e--record-progress "probing remote PID after helper shutdown")
    (unless (ejn-doom-e2e--remote-entry-dead-p entry timeout)
      (ejn-doom-e2e--record-progress "running identity-bound SSH cleanup fallback")
      (ejn-doom-e2e--run-command
       (emacs-jupyter-notebook-ssh-build-remote-cleanup
        (emacs-jupyter-notebook--entry-profile entry) entry)
       timeout)
      (unless (ejn-doom-e2e--remote-entry-dead-p entry timeout)
        (error "Test-owned remote kernel PID %s remained alive after bounded cleanup"
               (plist-get entry :remote-pid))))
    (ejn-doom-e2e--record-progress "remote PID cleanup confirmed")
    (when shutdown-error
      (message "Doom E2E helper shutdown fell back to identity-bound cleanup: %s"
               (ejn-doom-e2e--bounded-string shutdown-error)))
    t))

(defun ejn-doom-e2e-python-cell-evaluates-on-mother ()
  "Exercise the configured remote helper path from an isolated Doom daemon.
The test proves image and text panel outputs, captures helper/tunnel/kernel
identity, kills only the local source buffer, reconnects to the same durable
kernel, and verifies an unpredictable kernel-side state token survives.
The final explicit shutdown is restricted to the captured direct-kernel
identity and is verified through an exact PID liveness probe."
  (let* ((profile-name (ejn-doom-e2e--profile-name))
         (profile (ejn-doom-e2e--profile-with-overrides profile-name))
         (source-file (make-temp-file "ejn-doom-e2e-" nil ".py"))
         (registry-file (make-temp-file "ejn-doom-e2e-registry-"))
         (timeout (ejn-doom-e2e--timeout))
         (deadline (+ (float-time) timeout))
         (token (format "%x-%x-%x" (random most-positive-fixnum)
                        (truncate (* 1000000 (float-time))) (emacs-pid)))
         (token-output (format "EJN token survived reconnect: %s" token))
         (buffer nil)
         (buffer2 nil)
         (entry-after-start nil)
         (identity-before nil)
         (identity-after nil)
         (reconnect-seconds nil)
         (helper-recovery-before nil)
         (helper-recovery-after nil)
         (helper-recovery-seconds nil)
         (tunnel-recovery-before nil)
         (tunnel-recovery-after nil)
         (tunnel-recovery-seconds nil)
         (cleanup-confirmed nil)
         (cleanup-error nil)
         metrics)
    (unless (eq emacs-jupyter-notebook-backend 'helper)
      (error "Doom E2E requires helper backend; current value is %S"
             emacs-jupyter-notebook-backend))
    (let ((emacs-jupyter-notebook-default-profile profile-name)
          (emacs-jupyter-notebook-remote-profiles
           (list (cons profile-name profile)))
          (emacs-jupyter-notebook-registry-file registry-file)
          (emacs-jupyter-notebook-connection-retrieve-attempts 80)
          (emacs-jupyter-notebook-connection-retrieve-delay 0.25)
          (emacs-jupyter-notebook-kernel-idle-timeout 0)
          ;; E2E deliberately exercises the production auto-reconnect path,
          ;; with only its retry delays shortened for a bounded test runtime.
          (emacs-jupyter-notebook-auto-reconnect t)
          (emacs-jupyter-notebook-reconnect-initial-delay 0.1)
          (emacs-jupyter-notebook-reconnect-max-delay 0.5))
      (unwind-protect
          (progn
          ;; Phase 1: cold-start, actual PNG output, then a stateful text cell.
          (ejn-doom-e2e--phase-budget deadline "cold start and PNG execution")
          (setq buffer (find-file-noselect source-file))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "# %% image\n"
                    "import matplotlib.pyplot as plt\n"
                    "import numpy as np\n"
                    "plt.imshow(np.random.uniform(size=(64, 64)))\n"
                    "plt.show()\n"
                    "# %% state\n"
                    (format "ejn_doom_e2e_token = %S\n" token)
                    "print('EJN state token installed')\n"
                    "# %% verify\n"
                    (format "assert ejn_doom_e2e_token == %S\n" token)
                    (format "print(%S)\n" token-output))
            (save-buffer)
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (goto-char (point-min))
            (forward-line 1)
            (emacs-jupyter-notebook-send-cell)
            (unless (ejn-doom-e2e--wait-for-result-image
                     buffer (ejn-doom-e2e--phase-budget
                             deadline "waiting for PNG panel output"))
              (error "Timed out waiting for PNG panel output from %S" profile-name))
            (goto-char (point-min))
            (search-forward "# %% state")
            (forward-line 1)
            (emacs-jupyter-notebook-send-cell)
            (unless (ejn-doom-e2e--wait-for-result-text
                     buffer "EJN state token installed"
                     (ejn-doom-e2e--phase-budget
                      deadline "waiting for state token output"))
              (error "Timed out waiting for text panel output from %S" profile-name))
            (setq entry-after-start (copy-sequence emacs-jupyter-notebook--session-entry)
                  identity-before (ejn-doom-e2e--capture-identity buffer)))
          ;; Phase 2: killing this buffer must only discard local state.
          (kill-buffer buffer)
          (setq buffer nil)
          (setq buffer2 (find-file-noselect source-file))
          (ejn-doom-e2e--phase-budget deadline "buffer reconnect")
          (with-current-buffer buffer2
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
              (unless entry
                (error "No registry entry for %S after local buffer kill" source-file))
              (unless (ejn-doom-e2e--same-remote-identity-p
                       identity-before
                       (list :remote-pid (plist-get entry :remote-pid)
                             :session-id (plist-get entry :session-id)
                             :remote-connection-file
                             (plist-get entry :remote-connection-file)))
                (error "Registry identity changed after local buffer kill: %S" entry))
              (let ((started-at (float-time)))
                (emacs-jupyter-notebook-reconnect-remote-kernel entry)
                (unless (ejn-doom-e2e--wait-for-client
                         buffer2 (ejn-doom-e2e--phase-budget
                                  deadline "waiting for reconnected client"))
                  (error "Timed out waiting for helper reconnect on %S" profile-name))
                (setq reconnect-seconds (- (float-time) started-at))))
            (setq identity-after (ejn-doom-e2e--capture-identity buffer2))
            (unless (ejn-doom-e2e--same-remote-identity-p
                     identity-before identity-after)
              (error "Reconnect attached a different remote kernel: before=%S after=%S"
                     identity-before identity-after))
            ;; The dynamic token is a stronger same-kernel proof than registry
            ;; equality: a fresh replacement cannot synthesize its value.
            (ejn-doom-e2e--verify-token
             buffer2 token "buffer reconnect"
             (ejn-doom-e2e--phase-budget
              deadline "verifying state after buffer reconnect"))
            ;; Phase 3: kill only the actual helper subprocess.  Its process
            ;; sentinel, rather than a test-only reconnect call, must retire
            ;; local state and schedule automatic transport recovery.
            (setq helper-recovery-before (ejn-doom-e2e--capture-identity buffer2))
            (ejn-doom-e2e--phase-budget deadline "helper fault injection")
            (let ((started-at (float-time)))
              (ejn-doom-e2e--kill-local-helper buffer2 helper-recovery-before)
              (setq helper-recovery-after
                    (ejn-doom-e2e--wait-for-recovery
                     buffer2 identity-before
                     (plist-get helper-recovery-before :helper-pid)
                     (plist-get helper-recovery-before :tunnel-pid)
                     (ejn-doom-e2e--phase-budget
                      deadline "waiting for automatic helper recovery"))
                    helper-recovery-seconds (- (float-time) started-at)))
            (ejn-doom-e2e--verify-token
             buffer2 token "helper recovery"
             (ejn-doom-e2e--phase-budget
              deadline "verifying state after helper recovery"))
            ;; Phase 4: independently kill only the active SSH tunnel.  The
            ;; core is expected to rebuild both local transport processes
            ;; against the unchanged durable remote kernel identity.
            (setq tunnel-recovery-before (ejn-doom-e2e--capture-identity buffer2))
            (ejn-doom-e2e--phase-budget deadline "tunnel fault injection")
            (let ((started-at (float-time)))
              (ejn-doom-e2e--kill-local-tunnel buffer2 tunnel-recovery-before)
              (setq tunnel-recovery-after
                    (ejn-doom-e2e--wait-for-recovery
                     buffer2 identity-before
                     (plist-get tunnel-recovery-before :helper-pid)
                     (plist-get tunnel-recovery-before :tunnel-pid)
                     (ejn-doom-e2e--phase-budget
                      deadline "waiting for automatic tunnel recovery"))
                    tunnel-recovery-seconds (- (float-time) started-at)))
            (ejn-doom-e2e--verify-token
             buffer2 token "tunnel recovery"
             (ejn-doom-e2e--phase-budget
              deadline "verifying state after tunnel recovery"))
            (setq metrics
                  (list :status 'ok
                        :profile profile-name
                        :remote-pid (plist-get identity-after :remote-pid)
                        :session-id (ejn-doom-e2e--bounded-string
                                     (plist-get identity-after :session-id))
                        :remote-connection-file (ejn-doom-e2e--bounded-string
                                                 (plist-get identity-after :remote-connection-file))
                        :helper-pid-before (plist-get identity-before :helper-pid)
                        :helper-pid-after (plist-get identity-after :helper-pid)
                        :helper-protocol (plist-get identity-after :helper-protocol)
                        :helper-state (plist-get identity-after :helper-state)
                        :tunnel-pid-before (plist-get identity-before :tunnel-pid)
                        :tunnel-pid-after (plist-get identity-after :tunnel-pid)
                        :reconnect-seconds reconnect-seconds
                        :helper-recovery-seconds helper-recovery-seconds
                        :helper-pid-before-helper-fault
                        (plist-get helper-recovery-before :helper-pid)
                        :helper-pid-after-helper-recovery
                        (plist-get helper-recovery-after :helper-pid)
                        :tunnel-pid-before-helper-fault
                        (plist-get helper-recovery-before :tunnel-pid)
                        :tunnel-pid-after-helper-recovery
                        (plist-get helper-recovery-after :tunnel-pid)
                        :tunnel-recovery-seconds tunnel-recovery-seconds
                        :helper-pid-before-tunnel-fault
                        (plist-get tunnel-recovery-before :helper-pid)
                        :helper-pid-after-tunnel-recovery
                        (plist-get tunnel-recovery-after :helper-pid)
                        :tunnel-pid-before-tunnel-fault
                        (plist-get tunnel-recovery-before :tunnel-pid)
                        :tunnel-pid-after-tunnel-recovery
                        (plist-get tunnel-recovery-after :tunnel-pid)))))
      ;; Explicit test-owned cleanup happens before deleting any evidence.
      (when entry-after-start
        (condition-case err
            (setq cleanup-confirmed
                  (ejn-doom-e2e--shutdown-test-owned-kernel buffer2 entry-after-start))
          (error
           (setq cleanup-error (error-message-string err)))))
      (when (buffer-live-p buffer2) (kill-buffer buffer2))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      ;; If a test-owned remote kernel was started but identity-bound cleanup
      ;; could not prove it is gone, retain these local files for diagnosis
      ;; rather than deleting the durable reconnect evidence under it.
      (when (or (null entry-after-start) cleanup-confirmed)
        (when (file-exists-p source-file) (delete-file source-file))
        (when (file-exists-p registry-file) (delete-file registry-file)))))
    (when cleanup-error
      (error "Doom E2E test-owned kernel cleanup failed: %s; evidence retained at %S and %S"
             cleanup-error source-file registry-file))
    metrics))

(ert-deftest ejn-doom-e2e-python-cell-evaluates-on-mother-test ()
  "ERT wrapper for `ejn-doom-e2e-python-cell-evaluates-on-mother'."
  :tags '(:remote :doom :e2e)
  (ejn-doom-e2e-python-cell-evaluates-on-mother))

(defun ejn-doom-e2e-run ()
  "Run the Doom E2E test and return bounded structured metrics."
  (ejn-doom-e2e-python-cell-evaluates-on-mother))

(provide 'emacs-jupyter-notebook-doom-e2e)

;;; emacs-jupyter-notebook-doom-e2e.el ends here
