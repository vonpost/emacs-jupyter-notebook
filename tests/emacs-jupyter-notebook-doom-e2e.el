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

(defconst ejn-doom-e2e--command-output-limit (* 64 1024)
  "Maximum bytes retained from each bounded cleanup-command stream.")

(defconst ejn-doom-e2e--progress-output-limit (* 128 1024)
  "Maximum bytes retained in the shell harness progress file.")

(defun ejn-doom-e2e--bounded-string (value)
  "Return VALUE truncated to the E2E metric string bound."
  (let* ((unbounded (format "%s" value))
         ;; UTF-8 uses at least one byte per character.  Pre-cap before the
         ;; byte-precise loop so even a bounded command diagnostic cannot make
         ;; this helper copy a large string once per discarded character.
         (text (substring unbounded 0
                          (min (length unbounded)
                               ejn-doom-e2e--metric-string-limit)))
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
  "Return the primary E2E execution deadline in seconds.
Explicit identity-bound cleanup has its own separately bounded timeout."
  (ejn-doom-e2e--positive-number "EJN_DOOM_E2E_TIMEOUT" 90 600))

(defun ejn-doom-e2e--cleanup-timeout ()
  "Return the shared test-owned cleanup deadline in seconds."
  (ejn-doom-e2e--positive-number "EJN_DOOM_E2E_CLEANUP_TIMEOUT" 25 120))

(defun ejn-doom-e2e--wait-step (seconds)
  "Wait briefly while dispatching both process events and Emacs timers.
The live E2E runs inside one server request.  Use the event-loop primitive
directly: `sleep-for' can remain asleep when the process event which entered a
tunnel sentinel deletes that same process during an isolated daemon request."
  (accept-process-output nil (max 0.001 (min 0.2 seconds))))

(defun ejn-doom-e2e--registry-call (file starter)
  "Run registry STARTER against FILE with a bounded test-only wait.
STARTER receives SUCCESS, FAILURE, and OWNER.  This helper is used only to
coordinate optional E2E fixtures; production registry calls stay async."
  (let ((owner (emacs-jupyter-notebook-registry-owner-create))
        (done nil) (values nil) (failure nil)
        (deadline (+ (float-time) (ejn-doom-e2e--cleanup-timeout))))
    (let ((emacs-jupyter-notebook-registry-file file))
      (funcall starter
               (lambda (&rest result) (setq values result done t))
               (lambda (&rest result) (setq failure result done t))
               owner))
    (while (and (not done) (< (float-time) deadline))
      (ejn-doom-e2e--wait-step 0.02))
    (unless done
      (emacs-jupyter-notebook-registry-owner-cancel owner)
      (error "Doom E2E registry transaction timed out"))
    (emacs-jupyter-notebook-registry-owner-cancel owner)
    (if failure
        (error "Doom E2E registry transaction failed: %S" (car failure))
      (car values))))

(defun ejn-doom-e2e--registry-read (file)
  "Read FILE through the bounded asynchronous registry bridge."
  (ejn-doom-e2e--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-read-async
      success failure :owner owner
      :deadline (ejn-doom-e2e--cleanup-timeout)))))

(defun ejn-doom-e2e--registry-create (file entry)
  "Create ENTRY in FILE and return its revision-bearing persisted value."
  ;; `make-temp-file' leaves an empty file, which is intentionally corrupt in
  ;; the versioned worker format.  Test fixtures may remove only that known
  ;; empty placeholder before their first create.
  (when (and (file-exists-p file)
             (= (file-attribute-size (file-attributes file 'integer)) 0))
    (delete-file file))
  (ejn-doom-e2e--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-create-async
      entry success failure :owner owner
      :deadline (ejn-doom-e2e--cleanup-timeout)))))

(defun ejn-doom-e2e--registry-create-all (file entries)
  "Create ENTRIES sequentially in FILE, returning persisted entries."
  ;; This helper constructs a complete isolated fixture, so replacing an
  ;; existing fixture is intentional and never models production mutation.
  (when (file-exists-p file)
    (delete-file file))
  (let (persisted)
    (dolist (entry entries (nreverse persisted))
      (push (ejn-doom-e2e--registry-create file entry) persisted))))

(defun ejn-doom-e2e--registry-replace (file entry revision)
  "Replace ENTRY in FILE at exact REVISION and return persisted ENTRY."
  (ejn-doom-e2e--registry-call
   file
   (lambda (success failure owner)
     (emacs-jupyter-notebook-registry-replace-async
      entry revision success failure :owner owner
      :deadline (ejn-doom-e2e--cleanup-timeout)))))

(defun ejn-doom-e2e--cleanup-budget (deadline phase &optional maximum)
  "Return remaining cleanup time before DEADLINE for PHASE.
When MAXIMUM is non-nil, cap the returned per-operation share without granting
a new deadline."
  (let ((remaining (- deadline (float-time))))
    (unless (> remaining 0)
      (error "Doom E2E cleanup deadline expired before %s" phase))
    (min remaining (or maximum remaining))))

(defun ejn-doom-e2e--record-progress (text)
  "Record bounded diagnostic TEXT for this isolated E2E invocation."
  (message "Doom E2E phase: %s" text)
  (when-let ((progress-file (getenv "EJN_DOOM_E2E_PROGRESS_FILE")))
    (unless (and (file-name-absolute-p progress-file)
                 (not (string-match-p "[\0\n\r]" progress-file)))
      (error "EJN_DOOM_E2E_PROGRESS_FILE must be a plain absolute path"))
    ;; The runner creates this file inside its private run directory.  Do not
    ;; let a pathological retry loop turn failure diagnostics into an
    ;; unbounded file; retaining the first bounded phase sequence is enough
    ;; to identify where the run stopped.
    (let* ((attributes (file-attributes progress-file))
           (size (and attributes (file-attribute-size attributes)))
           (line (concat (ejn-doom-e2e--bounded-string text) "\n")))
      (when (and (integerp size)
                 (< size ejn-doom-e2e--progress-output-limit))
        (let* ((remaining (- ejn-doom-e2e--progress-output-limit size))
               (end (min (length line) remaining)))
          ;; `substring' counts characters while the cap counts bytes.  Walk
          ;; back only across this already-tiny line so a multibyte diagnostic
          ;; can never exceed the file cap at its final byte boundary.
          (while (> (string-bytes (substring line 0 end)) remaining)
            (setq end (1- end)))
          (write-region (substring line 0 end)
                        nil progress-file 'append 'silent))))))

(defun ejn-doom-e2e--evidence-directory ()
  "Return the runner-owned evidence directory, if one was configured.
The deterministic preflights intentionally run without it; only the live
E2E body requires a private directory so a failing run keeps its source and
registry beside bounded daemon and client diagnostics."
  (when-let ((directory (getenv "EJN_DOOM_E2E_EVIDENCE_DIR")))
    (unless (and (file-name-absolute-p directory)
                 (file-directory-p directory)
                 (not (string-match-p "[\0\n\r]" directory)))
      (error "EJN_DOOM_E2E_EVIDENCE_DIR must name an existing plain absolute directory"))
    directory))

(defun ejn-doom-e2e--make-evidence-file (prefix &optional suffix)
  "Create a private E2E evidence file named by PREFIX and optional SUFFIX."
  (if-let ((directory (ejn-doom-e2e--evidence-directory)))
      (make-temp-file (expand-file-name prefix directory) nil suffix)
    (make-temp-file prefix nil suffix)))

(defun ejn-doom-e2e--phase-budget (deadline phase)
  "Record PHASE and return its remaining share of the execution DEADLINE."
  (let ((remaining (- deadline (float-time))))
    (unless (> remaining 0)
      (error "Doom E2E execution deadline expired before %s" phase))
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
         (process nil)
         (stderr-process nil)
         (deadline (+ (float-time) limit))
         (stdout "")
         (stderr "")
         stdout-overflow stderr-overflow status)
    (unwind-protect
        (cl-labels
            ((append-output
              (stream chunk)
              (let* ((current (if (eq stream 'stdout) stdout stderr))
                     (room (- ejn-doom-e2e--command-output-limit
                              (string-bytes current)))
                     (overflow (> (string-bytes chunk) room)))
                ;; `no-conversion' makes CHUNK unibyte, so byte and character
                ;; indexes coincide and the retained prefix is allocation-safe.
                (when (> room 0)
                  (setq current
                        (concat current (substring chunk 0 (min room (length chunk))))))
                (if (eq stream 'stdout)
                    (setq stdout current stdout-overflow (or stdout-overflow overflow))
                  (setq stderr current stderr-overflow (or stderr-overflow overflow)))
                (when overflow
                  (when (and (processp process) (process-live-p process))
                    (delete-process process))))))
          (setq stderr-process
                (make-pipe-process
                 :name "ejn-doom-e2e-command-stderr" :buffer nil :noquery t
                 :coding 'no-conversion :sentinel #'ignore
                 :filter (lambda (_process chunk) (append-output 'stderr chunk))))
          (setq process
                (make-process
                 :name "ejn-doom-e2e-command" :command argv :buffer nil
                 :stderr stderr-process :connection-type 'pipe :noquery t
                 :coding 'no-conversion :sentinel #'ignore
                 :filter (lambda (_process chunk) (append-output 'stdout chunk))))
          (while (and (process-live-p process)
                      (not stdout-overflow) (not stderr-overflow)
                      (< (float-time) deadline))
            (ejn-doom-e2e--wait-step
             (min 0.1 (max 0.01 (- deadline (float-time))))))
          (when (process-live-p process)
            (delete-process process)
            (error "Doom E2E command timed out after %.1fs: %s"
                   limit (mapconcat #'shell-quote-argument argv " ")))
          (setq status (process-exit-status process))
          (cond
           ((or stdout-overflow stderr-overflow)
            (error "Doom E2E command exceeded its %d-byte output cap: %s"
                   ejn-doom-e2e--command-output-limit
                   (mapconcat #'shell-quote-argument argv " ")))
           ((not (zerop status))
            (error "Doom E2E command failed (%s): %s\n%s"
                   status (mapconcat #'shell-quote-argument argv " ")
                   (string-trim (concat stdout stderr))))
           (t stdout)))
      (when (and (processp process) (process-live-p process))
        (delete-process process))
      (when (and (processp stderr-process) (process-live-p stderr-process))
        (delete-process stderr-process)))))

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

(defconst ejn-doom-e2e--failed-entry-statuses
  '(error cancelled outcome-unknown)
  "Terminal panel statuses that make an E2E execution immediately fail.")

(defun ejn-doom-e2e--busy-cell-seconds ()
  "Return the finite remote sleep used by the busy-transport fault gate.
The default keeps routine smoke runs short.  A release gate can set
EJN_DOOM_E2E_BUSY_SECONDS to exercise a genuinely long-running cell, while the
hard ceiling keeps the isolated process tree and its cleanup deadline bounded."
  (ejn-doom-e2e--positive-number "EJN_DOOM_E2E_BUSY_SECONDS" 3 180))

(defun ejn-doom-e2e--entry-for-exact-code (buffer code)
  "Return BUFFER's sole panel entry whose submitted CODE is exactly CODE.
An E2E must not let output from a prior evaluation or unrelated cell satisfy a
current assertion.  Matching the stored code also keeps the check valid across
history/latest rendering toggles."
  (let ((panel (emacs-jupyter-notebook-panel-buffer buffer)) matches)
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (setq matches
              (cl-remove-if-not
               (lambda (cell) (equal (plist-get (cdr cell) :code) code))
               emacs-jupyter-notebook-panel--entries))))
    (when (> (length matches) 1)
      (error "Doom E2E found %d panel entries for one exact submitted code"
             (length matches)))
    (cdr (car matches))))

(defun ejn-doom-e2e--wait-for-entry-result (buffer code predicate timeout label)
  "Wait for exact submitted CODE in BUFFER to be `ok' and satisfy PREDICATE.
LABEL appears in bounded failures.  Any terminal non-success status fails at
once; waiting for unrelated global panel output would hide that failure."
  (let ((deadline (+ (float-time) timeout))
        entry)
    (while (and (not entry) (< (float-time) deadline))
      (ejn-doom-e2e--wait-step 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed while waiting for %s" label))
      (ejn-doom-e2e--check-async-error buffer)
      (let ((candidate (ejn-doom-e2e--entry-for-exact-code buffer code)))
        (when candidate
          (let ((status (plist-get candidate :status)))
            (when (memq status ejn-doom-e2e--failed-entry-statuses)
              (error "E2E %s reached terminal %S for exact code: %s"
                     label status (ejn-doom-e2e--bounded-string code)))
            (when (eq status 'ok)
              (unless (funcall predicate candidate)
                (error "E2E %s finished `ok' without its expected result for exact code: %s"
                       label (ejn-doom-e2e--bounded-string code)))
              (setq entry candidate))))))
    entry))

(defun ejn-doom-e2e--wait-for-result-text (buffer code text timeout)
  "Return exact CODE's `ok' entry when its text output includes TEXT."
  (ejn-doom-e2e--wait-for-entry-result
   buffer code
   (lambda (entry)
     (string-match-p (regexp-quote text) (ejn-panel-entry-text entry)))
   timeout (format "text output %S" text)))

(defun ejn-doom-e2e--wait-for-result-image (buffer code timeout)
  "Return exact CODE's `ok' entry when it carries a published PNG output."
  (ejn-doom-e2e--wait-for-entry-result
   buffer code
   (lambda (entry)
     (cl-some
      (lambda (image)
        (and (eq (car-safe image) 'image)
             (equal (plist-get (cdr image) :ejn-original-mime) "image/png")
             (plist-get (cdr image) :ejn-original)))
      (ejn-panel-entry-images entry)))
   timeout "published PNG panel output"))

(defun ejn-doom-e2e--busy-execution-admitted-p (entry snapshot execution-id)
  "Return non-nil when ENTRY and SNAPSHOT prove EXECUTION-ID is running.
The gate intentionally uses the public status snapshot rather than inferring
readiness from a non-nil client.  `dispatched' confirms that the exact FIFO
execution was admitted by the backend; a live helper, live tunnel, and kernel
`busy' status prove the local transport was healthy immediately before the
test injects its local-only outage."
  (and (listp entry)
       (listp snapshot)
       (eq (plist-get entry :status) 'running)
       (integerp execution-id)
       (integerp (plist-get snapshot :active-execution-id))
       (= execution-id (plist-get snapshot :active-execution-id))
       (eq (plist-get snapshot :active-execution-state) 'dispatched)
       (eq (plist-get snapshot :kernel-status) 'busy)
       (eq (plist-get snapshot :helper-state) 'ready)
       (eq (plist-get snapshot :transport-phase) 'connected)
       (eq (plist-get snapshot :tunnel-state) 'alive)))

(defun ejn-doom-e2e--wait-for-admitted-busy-cell
    (buffer code execution-id timeout)
  "Wait until exact CODE is an admitted, actively busy EXECUTION-ID in BUFFER.
Return a plist containing the exact entry and status snapshot.  A terminal
entry before this state is a failure, since it would make a following fault
injection unable to prove it interrupted a real in-flight execution."
  (let ((deadline (+ (float-time) timeout))
        admission)
    (while (and (not admission) (< (float-time) deadline))
      (ejn-doom-e2e--wait-step
       (min 0.1 (max 0.01 (- deadline (float-time)))))
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed before busy execution admission"))
      (ejn-doom-e2e--check-async-error buffer)
      (let ((entry (ejn-doom-e2e--entry-for-exact-code buffer code)))
        (when entry
          (let ((status (plist-get entry :status)))
            (when (memq status ejn-doom-e2e--failed-entry-statuses)
              (error "E2E busy cell reached terminal %S before admission: %s"
                     status (ejn-doom-e2e--bounded-string code)))
            (when (eq status 'ok)
              (error "E2E busy cell completed before its busy state was observed"))
            (with-current-buffer buffer
              (let ((snapshot (emacs-jupyter-notebook-status-snapshot)))
                (when (ejn-doom-e2e--busy-execution-admitted-p
                       entry snapshot execution-id)
                  (setq admission (list :entry entry :snapshot snapshot)))))))))
    (unless admission
      (error "Timed out after %.1fs waiting for admitted busy execution %s"
             timeout execution-id))
    admission))

(defun ejn-doom-e2e--busy-cell-spec (busy-token)
  "Return code and exact output for a finite BUSY-TOKEN state transition."
  (unless (and (stringp busy-token) (not (string-empty-p busy-token)))
    (error "Busy-cell token must be a non-empty string"))
  (let ((output (format "EJN busy cell completed: %s" busy-token)))
    (list :code
          (format (concat "import time\n"
                          "ejn_doom_e2e_busy_started = %S\n"
                          "time.sleep(%s)\n"
                          "ejn_doom_e2e_busy_completed = %S\n"
                          "print(%S)\n")
                  busy-token (ejn-doom-e2e--busy-cell-seconds) busy-token output)
          :output output)))

(defun ejn-doom-e2e--round-trip-spec (kernel-token phase nonce &optional busy-token)
  "Return exact post-recovery code/output for KERNEL-TOKEN and fresh NONCE.
When BUSY-TOKEN is non-nil, the returned code also proves the busy cell ran to
completion in this exact remote kernel before its unique round trip executes."
  (unless (and (stringp kernel-token) (not (string-empty-p kernel-token))
               (stringp phase) (not (string-empty-p phase))
               (stringp nonce) (not (string-empty-p nonce))
               (or (null busy-token)
                   (and (stringp busy-token) (not (string-empty-p busy-token)))))
    (error "Round-trip inputs must be non-empty strings"))
  (let ((output (format "EJN token verified after %s: %s" phase nonce)))
    (list :code
          (concat
           (format "assert ejn_doom_e2e_token == %S\n" kernel-token)
           (when busy-token
             (format (concat "assert ejn_doom_e2e_busy_started == %S\n"
                             "assert ejn_doom_e2e_busy_completed == %S\n")
                     busy-token busy-token))
           (format (concat "ejn_doom_e2e_last_round_trip = %S\n"
                           "assert ejn_doom_e2e_last_round_trip == %S\n"
                           "print(%S)\n")
                   nonce nonce output))
          :output output
          :nonce nonce)))

(defun ejn-doom-e2e--fresh-round-trip-nonce (kernel-token phase)
  "Return a per-invocation round-trip nonce scoped to KERNEL-TOKEN and PHASE."
  (format "%s:%s:%x:%x" kernel-token phase (emacs-pid)
          (random most-positive-fixnum)))

(defconst ejn-doom-e2e--png-signature
  (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n)
  "The eight required leading bytes of a PNG file.")

(defun ejn-doom-e2e--assert-owned-png-original (entry)
  "Assert ENTRY exposes a current, owned PNG original with valid bytes.
The helper preview can be PPM, so this deliberately validates the retained
compressed original used by the external viewer rather than the display file."
  (let* ((image
          (cl-find-if
           (lambda (candidate)
             (equal (plist-get (cdr candidate) :ejn-original-mime) "image/png"))
           (ejn-panel-entry-images entry)))
         (original (and image (plist-get (cdr image) :ejn-original)))
         (file (and (listp original) (plist-get original :file)))
         (declared-size (and (listp original) (plist-get original :size)))
         (identity (and (listp original) (plist-get original :identity)))
         (capability (and (listp original) (plist-get original :artifact-capability)))
         (attributes (and (stringp file) (file-attributes file 'integer))))
    (unless (and image (listp original) (stringp file) (file-regular-p file)
                 (integerp declared-size) (>= declared-size 8)
                 (emacs-jupyter-notebook-artifacts-capability-valid-p capability)
                 attributes
                 (= (file-attribute-size attributes) declared-size)
                 (equal (file-attribute-file-identifier attributes) identity))
      (error "Doom E2E PNG original was not a current owned helper artifact"))
    (let ((file-name-handler-alist nil)
          signature)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 8)
        (setq signature (buffer-string)))
      (unless (equal signature ejn-doom-e2e--png-signature)
        (error "Doom E2E image original is not a PNG by its 8-byte signature")))
    original))

(defun ejn-doom-e2e--assert-source-pristine (buffer baseline phase)
  "Assert BUFFER and its literal local file remain BASELINE after PHASE."
  (with-current-buffer buffer
    (unless (equal (buffer-string) baseline)
      (error "Doom E2E source text changed during %s" phase))
    (when (buffer-modified-p)
      (error "Doom E2E source buffer became modified during %s" phase))
    (unless (and buffer-file-name (file-regular-p buffer-file-name))
      (error "Doom E2E source file disappeared during %s: %S" phase buffer-file-name))
    ;; Read the bytes without file-name handlers so a local source mutation
    ;; cannot be hidden behind coding conversion or a user-installed handler.
    (let ((source-file buffer-file-name)
          (file-name-handler-alist nil)
          (expected (encode-coding-string baseline 'utf-8 t))
          actual)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally source-file)
        (setq actual (buffer-string)))
      (unless (equal actual expected)
        (error "Doom E2E source file bytes changed during %s" phase)))))

(defun ejn-doom-e2e--wait-for-client (buffer timeout)
  "Return a live backend client for BUFFER before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        client)
    (while (and (not client) (< (float-time) deadline))
      (ejn-doom-e2e--wait-step 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (with-current-buffer buffer
        (setq client emacs-jupyter-notebook--client)))
    (unless client
      (with-current-buffer buffer
        (let* ((panel (emacs-jupyter-notebook-panel-buffer buffer))
               (operation
                (plist-get emacs-jupyter-notebook--async-context
                           :registry-operation))
               (worker
                (and operation
                     (emacs-jupyter-notebook-registry-operation-process
                      operation))))
          (ejn-doom-e2e--record-progress
           (format
            "client wait expired: %s"
            (ejn-doom-e2e--bounded-string
             (list
              :panel
              (when (buffer-live-p panel)
                (with-current-buffer panel
                  (mapcar
                   (lambda (cell)
                     (let ((entry (cdr cell)))
                       (list :status (plist-get entry :status)
                             :text (ejn-doom-e2e--bounded-string
                                    (ejn-panel-entry-text entry)))))
                   emacs-jupyter-notebook-panel--entries)))
              :registry-operation
              (when operation
                (list
                 :finished
                 (emacs-jupyter-notebook-registry-operation-finished operation)
                 :process-status (and worker (process-status worker))
                 :stdout-bytes
                 (string-bytes
                  (or (emacs-jupyter-notebook-registry-operation-stdout
                       operation)
                      ""))))
              :status (emacs-jupyter-notebook-status-snapshot)
              :async-phase
              (plist-get emacs-jupyter-notebook--async-context :phase)
              :async-error
              (plist-get emacs-jupyter-notebook--async-context :error))))))))
    client))

(defun ejn-doom-e2e--wait-for-shutdown (buffer timeout)
  "Return non-nil once BUFFER has completed an explicit helper shutdown."
  (let ((deadline (+ (float-time) timeout))
        done)
    (while (and (not done) (< (float-time) deadline))
      (ejn-doom-e2e--wait-step 0.1)
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

(defun ejn-doom-e2e--same-direct-entry-p (expected candidate)
  "Return non-nil when CANDIDATE is exactly EXPECTED's direct kernel entry."
  (and (emacs-jupyter-notebook-ssh-direct-entry-valid-p expected)
       (emacs-jupyter-notebook-ssh-direct-entry-valid-p candidate)
       (equal (plist-get expected :local-file) (plist-get candidate :local-file))
       (equal (plist-get expected :profile) (plist-get candidate :profile))
       (equal (plist-get expected :remote-pid) (plist-get candidate :remote-pid))
       (equal (plist-get expected :session-id) (plist-get candidate :session-id))
       (equal (plist-get expected :remote-connection-file)
              (plist-get candidate :remote-connection-file))
       (equal (plist-get expected :remote-pid-sidecar)
              (plist-get candidate :remote-pid-sidecar))
       (equal (plist-get expected :connection-file-tokens)
              (plist-get candidate :connection-file-tokens))))

(defun ejn-doom-e2e--session-prefix-for-source (source-file)
  "Return the exact `--new-session-id' prefix produced for SOURCE-FILE."
  (concat
   (replace-regexp-in-string "[^[:alnum:]_.-]" "_"
                             (file-name-base source-file))
   "-"))

(defun ejn-doom-e2e--test-owned-direct-entry-p
    (entry source-file profile-name session-prefix)
  "Return non-nil when ENTRY belongs to this exact isolated E2E run.
Every source, live-context, and registry candidate must name SOURCE-FILE,
the run-private PROFILE-NAME, and the session prefix derived from that source
before it can become cleanup authority."
  (and (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
       (equal (plist-get entry :local-file) source-file)
       (equal (plist-get entry :profile) profile-name)
       (string-prefix-p session-prefix (plist-get entry :session-id))))

(defun ejn-doom-e2e--direct-entry-candidates (buffer registry-file &optional seeds)
  "Return all non-nil run-local entry candidates without granting ownership.
SEEDS supplies already captured entries that may have been displaced from the
live BUFFER or private REGISTRY-FILE by the regression under test."
  (let ((candidates (copy-sequence seeds)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (push emacs-jupyter-notebook--session-entry candidates)
        (push (plist-get emacs-jupyter-notebook--async-context :entry)
              candidates)))
    (dolist (entry (ejn-doom-e2e--registry-read registry-file))
      (push entry candidates))
    (cl-remove-duplicates (delq nil candidates) :test #'equal)))

(defun ejn-doom-e2e--test-owned-direct-entries
    (buffer source-file registry-file profile-name session-prefix &optional seeds)
  "Return every distinct direct entry owned by this exact isolated E2E run."
  (cl-remove-duplicates
   (cl-remove-if-not
      (lambda (candidate)
        (ejn-doom-e2e--test-owned-direct-entry-p
         candidate source-file profile-name session-prefix))
      (ejn-doom-e2e--direct-entry-candidates buffer registry-file seeds))
   :test #'ejn-doom-e2e--same-direct-entry-p))

(defun ejn-doom-e2e--recover-test-owned-direct-entry
    (buffer source-file registry-file profile-name session-prefix &optional expected)
  "Recover this E2E's direct entry, never selecting an unrelated kernel.
Look first at BUFFER's live session/context, then at the private registry for
SOURCE-FILE.  Every candidate must also carry this run's private PROFILE-NAME
and SESSION-PREFIX.  EXPECTED, when non-nil, narrows recovery to its exact
persisted PID and connection-token identity."
  (let* ((candidates
          (ejn-doom-e2e--test-owned-direct-entries
           buffer source-file registry-file profile-name session-prefix))
         (matches
          (if expected
              (cl-remove-if-not
               (lambda (candidate)
                 (ejn-doom-e2e--same-direct-entry-p expected candidate))
               candidates)
            candidates)))
    (when (> (length matches) 1)
      (error "Doom E2E found multiple direct entries for its private source file"))
    (copy-sequence (car matches))))

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
      (ejn-doom-e2e--wait-step
       (min 0.1 (max 0.01 (- deadline (float-time)))))
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
        (ejn-doom-e2e--wait-step
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

(defun ejn-doom-e2e--run-local-transport-recovery
    (buffer expected-identity kind deadline)
  "Fault exactly one local KIND process and await its automatic recovery.
KIND is `helper' or `tunnel'.  The fault remains strictly local: the exact-PID
helpers below leave the durable remote entry and remote kernel untouched.  The
returned plist contains the pre-fault and recovered process identities and a
finite elapsed duration for the E2E metrics."
  (unless (memq kind '(helper tunnel))
    (error "Unsupported local transport fault kind %S" kind))
  (let* ((label (format "%s recovery" kind))
         (before (ejn-doom-e2e--capture-identity buffer))
         (started-at (float-time)))
    (ejn-doom-e2e--phase-budget deadline (format "%s fault injection" label))
    (pcase kind
      ('helper (ejn-doom-e2e--kill-local-helper buffer before))
      ('tunnel (ejn-doom-e2e--kill-local-tunnel buffer before)))
    (let ((after
           (ejn-doom-e2e--wait-for-recovery
            buffer expected-identity
            (plist-get before :helper-pid)
            (plist-get before :tunnel-pid)
            (ejn-doom-e2e--phase-budget
             deadline (format "waiting for automatic %s" label)))))
      (list :kind kind :before before :after after
            :seconds (- (float-time) started-at)))))

(defun ejn-doom-e2e--verify-token
    (buffer token phase timeout &optional busy-token)
  "Execute a fresh token assertion in BUFFER and await its unique output.
BUSY-TOKEN additionally requires a prior busy cell to have reached both of its
kernel-side state assignments.  Every invocation carries an unpredictable
round-trip nonce, so an old panel result cannot satisfy a later recovery
check."
  (let* ((spec (ejn-doom-e2e--round-trip-spec
                token phase (ejn-doom-e2e--fresh-round-trip-nonce token phase)
                busy-token))
         (code (plist-get spec :code))
         (output (plist-get spec :output)))
    (ejn-doom-e2e--record-progress (format "dispatching token after %s" phase))
    (with-current-buffer buffer
      (emacs-jupyter-notebook--evaluate-code code nil))
    (ejn-doom-e2e--record-progress (format "waiting for token after %s" phase))
    (unless (ejn-doom-e2e--wait-for-result-text buffer code output timeout)
      (error "Kernel-side token did not survive %s" phase))
    (ejn-doom-e2e--record-progress (format "token verified after %s" phase))
    output))

(defun ejn-doom-e2e--remote-entry-dead-p (entry timeout)
  "Return non-nil when ENTRY's exact PID identity reports dead by TIMEOUT."
  (when (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)
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
                          (equal (string-trim output)
                                 "__EJN_DEAD__\n__EJN_DONE__")))
          (unless dead
            (ejn-doom-e2e--wait-step (min 0.2 remaining)))))
      dead)))

(defun ejn-doom-e2e--preserve-cleanup-entry (entry)
  "Reassert captured ENTRY at its exact revision for diagnosis.
Return a short status string suitable for an error without masking the
cleanup failure that prompted preservation."
  (condition-case err
      (progn
        (let ((file emacs-jupyter-notebook-registry-file)
              (revision (plist-get entry :registry-revision)))
          (unless (and (stringp file) (stringp revision))
            (error "captured entry lacks registry file or revision"))
          (ejn-doom-e2e--registry-replace file (copy-sequence entry) revision))
        "captured entry reasserted")
    (error
     (format "captured-entry save failed: %s"
             (ejn-doom-e2e--bounded-string (error-message-string err))))))

(defun ejn-doom-e2e--public-shutdown-disposition (buffer entry)
  "Classify whether BUFFER can safely invoke the public shutdown command.
The public command correctly asks before superseding an in-flight start or
reconnect.  A headless E2E cleanup must never enter that prompt: its positive
PID ENTRY is already independently authorized for the exact SSH cleanup
fallback.  This classifier therefore makes the decision explicit and leaves
all durable state untouched until that fallback succeeds."
  (cond
   ((not (buffer-live-p buffer)) 'no-live-buffer)
   (t
    (with-current-buffer buffer
      (cond
       ((null emacs-jupyter-notebook--session-entry) 'no-live-entry)
       ((not (ejn-doom-e2e--same-direct-entry-p
              entry emacs-jupyter-notebook--session-entry))
        'live-entry-mismatch)
       ((emacs-jupyter-notebook--async-in-progress-p) 'in-flight-attempt)
       (t 'eligible))))))

(defun ejn-doom-e2e--shutdown-test-owned-kernel (buffer entry &optional absolute-deadline)
  "Explicitly stop test-owned ENTRY, then verify its exact PID is dead.
The normal helper shutdown is preferred.  The identity-bound SSH cleanup is
only a bounded fallback when its result is unknown; it cannot target any
other kernel.  ABSOLUTE-DEADLINE, when non-nil, bounds a multi-entry cleanup."
  (let* ((timeout (ejn-doom-e2e--cleanup-timeout))
         (deadline (or absolute-deadline (+ (float-time) timeout)))
         shutdown-error)
    (unless (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)
      (error (concat "Doom E2E cleanup requires a promoted positive remote PID; "
                     "provisional recovery evidence was retained")))
    (ejn-doom-e2e--record-progress "cleanup started")
    (pcase (ejn-doom-e2e--public-shutdown-disposition buffer entry)
      ('eligible
       (with-current-buffer buffer
         (condition-case err
             (progn
               (ejn-doom-e2e--record-progress "requesting helper shutdown")
               (emacs-jupyter-notebook-shutdown-kernel :force)
               (ejn-doom-e2e--record-progress "waiting for helper shutdown")
               (unless (ejn-doom-e2e--wait-for-shutdown
                        buffer (ejn-doom-e2e--cleanup-budget
                                deadline "helper shutdown" 8))
                 (setq shutdown-error "helper shutdown acknowledgement timed out"))
               (ejn-doom-e2e--record-progress "helper shutdown wait finished"))
           (error
            ;; The bounded fallback below still owns only ENTRY's persisted
            ;; PID and connection-token identity.
            (setq shutdown-error (error-message-string err))))))
      ('in-flight-attempt
       ;; `:force' skips only the destructive-kernel confirmation; the public
       ;; command still asks `y-or-n-p' before cancelling this attempt.  Do
       ;; not cancel it here: that would change durable package state just to
       ;; satisfy a test.  The exact fallback below has its own deadline and
       ;; can terminate only ENTRY's verified PID/connection-token identity.
       (setq shutdown-error
             "public shutdown skipped because a connection attempt is in flight")
       (ejn-doom-e2e--record-progress
        "skipping public shutdown: async attempt active; using exact fallback"))
      (disposition
       (setq shutdown-error
             (format "public shutdown unavailable (%s)" disposition))
       (ejn-doom-e2e--record-progress
        (format "skipping public shutdown: %s" disposition))))
    (ejn-doom-e2e--record-progress "probing remote PID after helper shutdown")
    (unless (ejn-doom-e2e--remote-entry-dead-p
             entry (ejn-doom-e2e--cleanup-budget
                    deadline "post-shutdown PID probe" 5))
      (ejn-doom-e2e--record-progress "running identity-bound SSH cleanup fallback")
      (setq shutdown-error
            (or shutdown-error "helper shutdown left the remote PID alive")))
    ;; Run the exact cleanup even after a confirmed helper shutdown.  Its dead
    ;; PID branch is what synchronously removes the connection, sidecar, and
    ;; log files; the package's own best-effort cleanup may still be queued.
    (let (output)
      (condition-case err
          (setq output
                (ejn-doom-e2e--run-command
                 (emacs-jupyter-notebook-ssh-build-remote-cleanup
                  (emacs-jupyter-notebook--entry-profile entry) entry)
                 (ejn-doom-e2e--cleanup-budget
                  deadline "identity-bound remote cleanup")))
        (error
         (error "Remote cleanup command failed: %s; %s"
                (ejn-doom-e2e--bounded-string (error-message-string err))
                (ejn-doom-e2e--preserve-cleanup-entry entry))))
      (unless (equal (string-trim output) "__EJN_CLEANUP_DONE__")
        (error "Remote cleanup marker mismatch; raw output=%S; %s"
               (ejn-doom-e2e--bounded-string output)
               (ejn-doom-e2e--preserve-cleanup-entry entry))))
    (unless (ejn-doom-e2e--remote-entry-dead-p
             entry (ejn-doom-e2e--cleanup-budget
                    deadline "final PID probe"))
      (error "Test-owned remote kernel PID %s remained alive after bounded cleanup"
             (plist-get entry :remote-pid)))
    (ejn-doom-e2e--record-progress
     "remote PID and session-file cleanup confirmed")
    (when shutdown-error
      (message "Doom E2E helper shutdown fell back to identity-bound cleanup: %s"
               (ejn-doom-e2e--bounded-string shutdown-error)))
    t))

(defun ejn-doom-e2e--cleanup-test-owned-kernels
    (buffer captured source-file registry-file profile-name session-prefix)
  "Clean every exact test-owned kernel before allowing evidence deletion.
CAPTURED is the initial direct entry.  Re-scan BUFFER and the private registry
after each bounded cleanup so an identity drift from A to B cannot orphan B or
erase its durable evidence."
  (let ((deadline (+ (float-time) (ejn-doom-e2e--cleanup-timeout)))
        (cleaned nil)
        (round 0)
        raw pending)
    (while
        (progn
          (setq raw
                (ejn-doom-e2e--direct-entry-candidates
                 buffer registry-file (and captured (list captured))))
          ;; The registry is private to this run.  Any live/context/registry
          ;; entry that fails the source+profile+session-prefix ownership proof
          ;; is identity drift, not something this harness may signal or erase.
          (when (cl-some
                 (lambda (candidate)
                   (not (ejn-doom-e2e--test-owned-direct-entry-p
                         candidate source-file profile-name session-prefix)))
                 raw)
            (error (concat "Doom E2E found an unowned or malformed entry in its "
                           "private cleanup candidate set; evidence retained")))
          (setq pending
                (cl-remove-if
                 (lambda (candidate)
                   (cl-some
                    (lambda (done)
                      (ejn-doom-e2e--same-direct-entry-p done candidate))
                    cleaned))
                 raw))
          pending)
      (setq round (1+ round))
      (when (or (> round 8) (> (+ (length cleaned) (length pending)) 8))
        (error "Doom E2E found too many changing test-owned cleanup identities"))
      ;; A nil-PID provisional candidate is evidence but not cleanup authority.
      ;; Validate the whole round before terminating anything, so ambiguity
      ;; always retains every durable candidate.
      (dolist (entry pending)
        (unless (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)
          (error (concat "Doom E2E found test-owned provisional cleanup evidence "
                         "without a verified positive PID"))))
      (dolist (entry pending)
        (ejn-doom-e2e--shutdown-test-owned-kernel buffer entry deadline)
        (push entry cleaned)))
    (unless cleaned
      (error "No valid direct entry was captured or recoverable for test-owned cleanup"))
    t))

(defun ejn-doom-e2e--discard-success-evidence
    (source-file registry-file body-succeeded cleanup-confirmed)
  "Delete private evidence only after BODY-SUCCEEDED and CLEANUP-CONFIRMED."
  (when (and body-succeeded cleanup-confirmed)
    (when (file-exists-p source-file) (delete-file source-file))
    (when (file-exists-p registry-file) (delete-file registry-file))
    t))

(defun ejn-doom-e2e-python-cell-evaluates-on-mother ()
  "Exercise the configured remote helper path from an isolated Doom daemon.
The test proves image and text panel outputs, captures helper/tunnel/kernel
identity, kills only the local source buffer, reconnects to the same durable
kernel, and verifies an unpredictable kernel-side state token survives.
The final explicit shutdown is restricted to the captured direct-kernel
identity and is verified through an exact PID liveness probe."
  (let* ((configured-profile-name (ejn-doom-e2e--profile-name))
         (token (format "%x-%x-%x" (random most-positive-fixnum)
                        (truncate (* 1000000 (float-time))) (emacs-pid)))
         ;; Never publish the user's configured profile name into this test's
         ;; registry.  It gives every recovery candidate an additional private
         ;; ownership discriminator, without changing the user's Doom config.
         (profile-name (format "ejn-doom-e2e-%s" token))
         (profile (plist-put
                   (ejn-doom-e2e--profile-with-overrides configured-profile-name)
                   :profile profile-name))
         (source-file (ejn-doom-e2e--make-evidence-file "source-" ".py"))
         (session-prefix (ejn-doom-e2e--session-prefix-for-source source-file))
         (registry-file (ejn-doom-e2e--make-evidence-file "registry-"))
         (timeout (ejn-doom-e2e--timeout))
         (deadline (+ (float-time) timeout))
         (token-output (format "EJN token survived reconnect: %s" token))
         (buffer nil)
         (buffer2 nil)
         (source-baseline nil)
         (image-code nil)
         (state-code nil)
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
         (busy-token nil)
         (busy-code nil)
         (busy-execution-id nil)
         (busy-admission nil)
         (busy-recovery-before nil)
         (busy-recovery-after nil)
         (busy-recovery-seconds nil)
         (busy-completion-identity nil)
         (cleanup-confirmed nil)
         (cleanup-error nil)
         (body-succeeded nil)
         metrics)
    (let ((emacs-jupyter-notebook-default-profile profile-name)
          (emacs-jupyter-notebook-remote-profiles
           (list (cons profile-name profile)))
          (emacs-jupyter-notebook-registry-file registry-file)
          (emacs-jupyter-notebook-connection-retrieve-attempts 80)
          (emacs-jupyter-notebook-connection-retrieve-delay 0.25)
          ;; The isolated E2E must never wait for a password, passphrase, or
          ;; host-key prompt.  OpenSSH keeps the first value for most options,
          ;; so prepend this before both global and profile-specific options.
          (emacs-jupyter-notebook-ssh-options
           (append '("-o" "BatchMode=yes")
                   emacs-jupyter-notebook-ssh-options))
          (emacs-jupyter-notebook-ssh-batch-mode t)
          (emacs-jupyter-notebook-kernel-idle-timeout 0)
          ;; E2E deliberately exercises the production auto-reconnect path,
          ;; with only its retry delays shortened for a bounded test runtime.
          (emacs-jupyter-notebook-auto-reconnect t)
          (emacs-jupyter-notebook-reconnect-initial-delay 0.1)
          (emacs-jupyter-notebook-reconnect-max-delay 0.5)
          ;; A post-recovery request may wait behind the deliberately busy
          ;; kernel.  Keep its own watchdog beyond that bounded sleep so the
          ;; long-cell gate measures recovery rather than its test fixture.
          (emacs-jupyter-notebook-evaluation-timeout
           (+ (ejn-doom-e2e--busy-cell-seconds) 120)))
      ;; `make-temp-file' reserves a private name by creating an empty file,
      ;; while production correctly treats an existing empty registry as
      ;; corrupt.  First-run production behavior starts from a missing path.
      (delete-file registry-file)
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
            (setq source-baseline (buffer-string))
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (goto-char (point-min))
            (forward-line 1)
            (setq image-code (emacs-jupyter-notebook-cell-code))
            (emacs-jupyter-notebook-send-cell)
            ;; Capture a cleanup authority as soon as the initial connection is
            ;; live, before waiting on any panel rendering assertion that may
            ;; itself fail.
            (unless (ejn-doom-e2e--wait-for-client
                     buffer (ejn-doom-e2e--phase-budget
                             deadline "waiting for initial helper connection"))
              (error "Timed out waiting for initial helper connection on %S" profile-name))
            (setq entry-after-start
                  (ejn-doom-e2e--recover-test-owned-direct-entry
                   buffer source-file registry-file profile-name session-prefix))
            (unless entry-after-start
              (error "Doom E2E could not capture its direct entry after initial connection"))
            (let ((image-entry
                   (ejn-doom-e2e--wait-for-result-image
                    buffer image-code
                    (ejn-doom-e2e--phase-budget
                     deadline "waiting for PNG panel output"))))
              (unless image-entry
                (error "Timed out waiting for PNG panel output from %S" profile-name))
              (ejn-doom-e2e--assert-owned-png-original image-entry))
            (goto-char (point-min))
            (search-forward "# %% state")
            (forward-line 1)
            (setq state-code (emacs-jupyter-notebook-cell-code))
            (emacs-jupyter-notebook-send-cell)
            (unless (ejn-doom-e2e--wait-for-result-text
                     buffer state-code "EJN state token installed"
                     (ejn-doom-e2e--phase-budget
                      deadline "waiting for state token output"))
              (error "Timed out waiting for text panel output from %S" profile-name))
            (ejn-doom-e2e--record-progress "capturing initial transport identity")
            (setq identity-before (ejn-doom-e2e--capture-identity buffer))
            (ejn-doom-e2e--record-progress "validating captured direct entry")
            (unless (ejn-doom-e2e--same-direct-entry-p
                     entry-after-start emacs-jupyter-notebook--session-entry)
              (error "Doom E2E live entry drifted after initial execution"))
            (ejn-doom-e2e--record-progress "checking initial source integrity")
            (ejn-doom-e2e--assert-source-pristine
             buffer source-baseline "initial PNG and state executions"))
          ;; Phase 2: killing this buffer must only discard local state.
          (kill-buffer buffer)
          (setq buffer nil)
          (setq buffer2 (find-file-noselect source-file))
          (ejn-doom-e2e--phase-budget deadline "buffer reconnect")
          (with-current-buffer buffer2
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (let ((entry
                   (emacs-jupyter-notebook-registry-latest-for-file
                    source-file (ejn-doom-e2e--registry-read registry-file))))
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
            (ejn-doom-e2e--assert-source-pristine
             buffer2 source-baseline "buffer reconnect token proof")
            ;; Phase 3: kill only the actual helper subprocess.  Its process
            ;; sentinel, rather than a test-only reconnect call, must retire
            ;; local state and schedule automatic transport recovery.
            (let ((recovery (ejn-doom-e2e--run-local-transport-recovery
                             buffer2 identity-before 'helper deadline)))
              (setq helper-recovery-before (plist-get recovery :before)
                    helper-recovery-after (plist-get recovery :after)
                    helper-recovery-seconds (plist-get recovery :seconds)))
            (ejn-doom-e2e--verify-token
             buffer2 token "helper recovery"
             (ejn-doom-e2e--phase-budget
              deadline "verifying state after helper recovery"))
            (ejn-doom-e2e--assert-source-pristine
             buffer2 source-baseline "helper recovery token proof")
            ;; Phase 4: independently kill only the active SSH tunnel.  The
            ;; core is expected to rebuild both local transport processes
            ;; against the unchanged durable remote kernel identity.
            (let ((recovery (ejn-doom-e2e--run-local-transport-recovery
                             buffer2 identity-before 'tunnel deadline)))
              (setq tunnel-recovery-before (plist-get recovery :before)
                    tunnel-recovery-after (plist-get recovery :after)
                    tunnel-recovery-seconds (plist-get recovery :seconds)))
            (ejn-doom-e2e--verify-token
             buffer2 token "tunnel recovery"
             (ejn-doom-e2e--phase-budget
              deadline "verifying state after tunnel recovery"))
            (ejn-doom-e2e--assert-source-pristine
             buffer2 source-baseline "tunnel recovery token proof")
            ;; Phase 5: prove automatic recovery is safe while an execution is
            ;; genuinely running.  The admission predicate ties the exact
            ;; returned execution id to a `dispatched' ledger record, a live
            ;; helper/tunnel, and the kernel's real busy status before the
            ;; exact current tunnel PID is killed.  The post-recovery request
            ;; waits behind the busy cell if necessary and proves its state
            ;; transition completed in the same remote kernel.
            (setq busy-token
                  (format "%s-busy-%x" token (random most-positive-fixnum)))
            (let ((spec (ejn-doom-e2e--busy-cell-spec busy-token)))
              (setq busy-code (plist-get spec :code)))
            (ejn-doom-e2e--record-progress "dispatching admitted busy cell before tunnel fault")
            (setq busy-execution-id
                  (with-current-buffer buffer2
                    (emacs-jupyter-notebook--evaluate-code busy-code nil)))
            (unless (integerp busy-execution-id)
              (error "Busy E2E evaluation did not return an execution id: %S"
                     busy-execution-id))
            (setq busy-admission
                  (ejn-doom-e2e--wait-for-admitted-busy-cell
                   buffer2 busy-code busy-execution-id
                   (ejn-doom-e2e--phase-budget
                    deadline "waiting for admitted busy execution")))
            (ejn-doom-e2e--record-progress
             (format "busy execution %s admitted; injecting local tunnel fault"
                     busy-execution-id))
            (let ((recovery (ejn-doom-e2e--run-local-transport-recovery
                             buffer2 identity-before 'tunnel deadline)))
              (setq busy-recovery-before (plist-get recovery :before)
                    busy-recovery-after (plist-get recovery :after)
                    busy-recovery-seconds (plist-get recovery :seconds)))
            (ejn-doom-e2e--verify-token
             buffer2 token "busy tunnel recovery"
             (ejn-doom-e2e--phase-budget
              deadline "verifying busy kernel state after tunnel recovery")
             busy-token)
            (setq busy-completion-identity (ejn-doom-e2e--capture-identity buffer2))
            (unless (ejn-doom-e2e--same-remote-identity-p
                     identity-before busy-completion-identity)
              (error "Busy recovery completed on a different remote kernel: before=%S after=%S"
                     identity-before busy-completion-identity))
            (ejn-doom-e2e--assert-source-pristine
             buffer2 source-baseline "busy tunnel recovery completion proof")
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
                        (plist-get tunnel-recovery-after :tunnel-pid)
                        :busy-execution-id busy-execution-id
                        :busy-cell-seconds (ejn-doom-e2e--busy-cell-seconds)
                        :busy-admission-state
                        (plist-get (plist-get busy-admission :snapshot)
                                   :active-execution-state)
                        :busy-recovery-seconds busy-recovery-seconds
                        :helper-pid-before-busy-tunnel-fault
                        (plist-get busy-recovery-before :helper-pid)
                        :helper-pid-after-busy-tunnel-recovery
                        (plist-get busy-recovery-after :helper-pid)
                        :tunnel-pid-before-busy-tunnel-fault
                        (plist-get busy-recovery-before :tunnel-pid)
                        :tunnel-pid-after-busy-tunnel-recovery
                        (plist-get busy-recovery-after :tunnel-pid)
                        :busy-completion-helper-pid
                        (plist-get busy-completion-identity :helper-pid)
                        :busy-completion-tunnel-pid
                        (plist-get busy-completion-identity :tunnel-pid))))
          (setq body-succeeded t))
      ;; Cleanup must prove every run-owned candidate dead.  A regression may
      ;; have replaced the initially captured A with B; deleting this private
      ;; registry after cleaning only A would erase B's recovery authority.
      (condition-case err
          (setq cleanup-confirmed
                (ejn-doom-e2e--cleanup-test-owned-kernels
                 (or buffer2 buffer) entry-after-start source-file registry-file
                 profile-name session-prefix))
        (error
         (setq cleanup-error (error-message-string err))))
      (when (buffer-live-p buffer2) (kill-buffer buffer2))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      ;; If a test-owned remote kernel was started but identity-bound cleanup
      ;; could not prove it is gone, retain these local files for diagnosis
      ;; rather than deleting the durable reconnect evidence under it.
      (unless (and body-succeeded cleanup-confirmed)
        (ejn-doom-e2e--record-progress
         (format
          "test or cleanup failed (%s); evidence retained source=%s registry=%s"
          (or cleanup-error
              (and (not body-succeeded) "test body failed")
              "cleanup was not confirmed")
          source-file registry-file)))
      (ejn-doom-e2e--discard-success-evidence
       source-file registry-file body-succeeded cleanup-confirmed)))
    (when cleanup-error
      (error "Doom E2E test-owned kernel cleanup failed: %s; evidence retained at %S and %S"
             cleanup-error source-file registry-file))
    metrics))

(ert-deftest ejn-doom-e2e-python-cell-evaluates-on-mother-test ()
  "ERT wrapper for `ejn-doom-e2e-python-cell-evaluates-on-mother'."
  :tags '(:remote :doom :e2e)
  (ejn-doom-e2e-python-cell-evaluates-on-mother))

(ert-deftest ejn-doom-e2e-busy-execution-admission-predicate ()
  "Only an exact dispatched busy execution may authorize the fault phase."
  (let ((entry '(:status running))
        (snapshot '(:active-execution-id 41
                    :active-execution-state dispatched
                    :kernel-status busy
                    :helper-state ready
                    :transport-phase connected
                    :tunnel-state alive)))
    (should (ejn-doom-e2e--busy-execution-admitted-p entry snapshot 41))
    (should-not
     (ejn-doom-e2e--busy-execution-admitted-p
      entry (plist-put (copy-sequence snapshot) :active-execution-state 'checking) 41))
    (should-not
     (ejn-doom-e2e--busy-execution-admitted-p
      entry (plist-put (copy-sequence snapshot) :kernel-status 'idle) 41))
    (should-not
     (ejn-doom-e2e--busy-execution-admitted-p
      entry (plist-put (copy-sequence snapshot) :active-execution-id 42) 41))
    (should-not
     (ejn-doom-e2e--busy-execution-admitted-p
      '(:status queued) snapshot 41))))

(ert-deftest ejn-doom-e2e-busy-duration-is-finite-and-hard-bounded ()
  "The release gate may run a long cell but cannot create an unbounded wait."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "EJN_DOOM_E2E_BUSY_SECONDS" nil)
    (should (= (ejn-doom-e2e--busy-cell-seconds) 3))
    (setenv "EJN_DOOM_E2E_BUSY_SECONDS" "125")
    (should (= (ejn-doom-e2e--busy-cell-seconds) 125))
    (setenv "EJN_DOOM_E2E_BUSY_SECONDS" "181")
    (should-error (ejn-doom-e2e--busy-cell-seconds))))

(ert-deftest ejn-doom-e2e-wait-for-admitted-busy-cell-skips-queued-entry ()
  "The bounded busy wait does not fault until the exact execution is live."
  (let* ((snapshot '(:active-execution-id 41
                     :active-execution-state dispatched
                     :kernel-status busy
                     :helper-state ready
                     :transport-phase connected
                     :tunnel-state alive))
         (calls 0)
         result)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ejn-doom-e2e--check-async-error)
                 (lambda (&rest _args) nil))
                ((symbol-function 'ejn-doom-e2e--entry-for-exact-code)
                 (lambda (_buffer code)
                   (should (equal code "busy-code"))
                   (setq calls (1+ calls))
                   (if (= calls 1) '(:status queued) '(:status running))))
                ((symbol-function 'emacs-jupyter-notebook-status-snapshot)
                 (lambda () snapshot)))
        (setq result
              (ejn-doom-e2e--wait-for-admitted-busy-cell
               (current-buffer) "busy-code" 41 0.5))))
    (should (= calls 2))
    (should (eq (plist-get (plist-get result :entry) :status) 'running))
    (should (equal (plist-get result :snapshot) snapshot))))

(ert-deftest ejn-doom-e2e-round-trip-spec-requires-exact-state-and-nonce ()
  "Round-trip specifications bind output freshness and busy completion state."
  (let* ((first (ejn-doom-e2e--round-trip-spec
                 "kernel-token" "first recovery" "nonce-one" "busy-token"))
         (second (ejn-doom-e2e--round-trip-spec
                  "kernel-token" "second recovery" "nonce-two"))
         (first-code (plist-get first :code)))
    (should (string-match-p
             (regexp-quote "assert ejn_doom_e2e_token == \"kernel-token\"") first-code))
    (should (string-match-p
             (regexp-quote "assert ejn_doom_e2e_busy_started == \"busy-token\"")
             first-code))
    (should (string-match-p
             (regexp-quote "assert ejn_doom_e2e_busy_completed == \"busy-token\"")
             first-code))
    (should (string-match-p (regexp-quote "nonce-one") first-code))
    (should (equal (plist-get first :output)
                   "EJN token verified after first recovery: nonce-one"))
    (should-not (equal (plist-get first :code) (plist-get second :code)))
    (should-not (equal (plist-get first :output) (plist-get second :output)))))

(ert-deftest ejn-doom-e2e-recovery-rejects-foreign-entry-candidates ()
  "Only the source/profile/session-prefix-owned entry may be recovered."
  (let* ((source-file (make-temp-file "ejn-doom-owned-" nil ".py"))
         (registry-dir (make-temp-file "ejn-doom-owned-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (profile "ejn-doom-e2e-private")
         (prefix "ejn-doom-owned-")
         ;; The worker forbids two durable sessions for one local source.  Keep
         ;; those mutually exclusive registry fixtures on distinct paths; the
         ;; live/context candidates below still exercise the profile and
         ;; session-prefix ownership checks against the real SOURCE-FILE.
         (foreign-profile-file (concat source-file ".foreign-profile"))
         (foreign-prefix-file (concat source-file ".foreign-prefix"))
         (make-entry
          (lambda (local-file entry-profile session)
            (let ((connection (format "/tmp/kernel-%s.json" session)))
              (list :launch-kind 'direct :provisional nil :remote-pid 12345
                    :local-file local-file :profile entry-profile :session-id session
                    :remote-connection-file connection
                    :remote-pid-sidecar
                    (concat (string-remove-suffix ".json" connection) ".pid")
                    :connection-file-tokens (list "-f" connection)))))
         (owned (funcall make-entry source-file profile (concat prefix "owned")))
         (wrong-source (funcall make-entry "/tmp/foreign.py" profile
                               (concat prefix "wrong-source")))
         (wrong-profile (funcall make-entry foreign-profile-file "foreign-profile"
                                (concat prefix "wrong-profile")))
         (wrong-prefix (funcall make-entry foreign-prefix-file profile "foreign-session"))
         (wrong-profile-live (funcall make-entry source-file "foreign-profile"
                                          (concat prefix "wrong-profile-live")))
         (wrong-prefix-live (funcall make-entry source-file profile "foreign-session")))
    (unwind-protect
        (progn
          (let ((persisted
                 (ejn-doom-e2e--registry-create-all
                  registry-file
                  (list wrong-source wrong-profile wrong-prefix owned))))
            (setq wrong-source (nth 0 persisted)
                  wrong-profile (nth 1 persisted)
                  wrong-prefix (nth 2 persisted)
                  owned (nth 3 persisted)))
          (with-temp-buffer
            ;; These are the two non-registry recovery sources.  Both are
            ;; valid direct entries but deliberately fail a separate guard.
            (setq emacs-jupyter-notebook--session-entry wrong-profile-live
                  emacs-jupyter-notebook--async-context
                  (list :entry wrong-prefix-live))
            (should (equal
                     (ejn-doom-e2e--recover-test-owned-direct-entry
                      (current-buffer) source-file registry-file profile prefix)
                     owned)))
          (let ((persisted
                 (ejn-doom-e2e--registry-create-all
                  registry-file
                  (list wrong-source wrong-profile wrong-prefix))))
            (setq wrong-source (nth 0 persisted)
                  wrong-profile (nth 1 persisted)
                  wrong-prefix (nth 2 persisted)))
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry wrong-profile-live
                  emacs-jupyter-notebook--async-context
                  (list :entry wrong-prefix-live))
            (should-not
             (ejn-doom-e2e--recover-test-owned-direct-entry
              (current-buffer) source-file registry-file profile prefix))))
      (when (file-directory-p registry-dir) (delete-directory registry-dir t))
      (when (file-exists-p source-file) (delete-file source-file)))))

(ert-deftest ejn-doom-e2e-cleanup-covers-drifted-owned-entry ()
  "Cleanup proves both captured kernel A and a drifted test-owned kernel B."
  (let* ((source-file (make-temp-file "ejn-doom-owned-drift-" nil ".py"))
         (registry-dir (make-temp-file "ejn-doom-owned-drift-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (profile "ejn-doom-e2e-private-drift")
         (prefix (ejn-doom-e2e--session-prefix-for-source source-file))
         (make-entry
          (lambda (suffix pid)
            (let* ((session (concat prefix suffix))
                   (connection (format "/tmp/kernel-%s.json" session)))
              (list :launch-kind 'direct :provisional nil :remote-pid pid
                    :profile profile :local-file source-file :session-id session
                    :remote-connection-file connection
                    :remote-pid-sidecar
                    (concat (string-remove-suffix ".json" connection) ".pid")
                    :connection-file-tokens (list "-f" connection)))))
         (captured (funcall make-entry "captured-a" 12001))
         (drifted (funcall make-entry "drifted-b" 12002))
         cleaned)
    (unwind-protect
        (progn
          (let ((persisted
                 (ejn-doom-e2e--registry-create-all
                  registry-file (list drifted))))
            ;; The worker deliberately forbids two durable sessions for the
            ;; same source.  A is retained only as the initial captured seed;
            ;; B is the one durable, drifted current entry that cleanup must
            ;; still discover and terminate alongside A.
            (setq drifted (car persisted)))
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry drifted)
            (cl-letf (((symbol-function 'ejn-doom-e2e--shutdown-test-owned-kernel)
                       (lambda (_buffer entry _deadline) (push entry cleaned) t)))
              (should
               (ejn-doom-e2e--cleanup-test-owned-kernels
                (current-buffer) captured source-file registry-file
                profile prefix))))
          (should (= (length cleaned) 2))
          (should (cl-some
                   (lambda (entry)
                     (ejn-doom-e2e--same-direct-entry-p captured entry))
                   cleaned))
          (should (cl-some
                   (lambda (entry)
                     (ejn-doom-e2e--same-direct-entry-p drifted entry))
                   cleaned)))
      (when (file-directory-p registry-dir) (delete-directory registry-dir t))
      (when (file-exists-p source-file) (delete-file source-file)))))

(ert-deftest ejn-doom-e2e-cleanup-refuses-foreign-identity-drift ()
  "A drifted foreign B retains all evidence and authorizes no termination."
  (let* ((source-file (make-temp-file "ejn-doom-foreign-drift-" nil ".py"))
         (registry-dir (make-temp-file "ejn-doom-foreign-drift-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (profile "ejn-doom-e2e-private-foreign")
         (prefix (ejn-doom-e2e--session-prefix-for-source source-file))
         (connection-a (format "/tmp/kernel-%scaptured.json" prefix))
         (connection-b (format "/tmp/kernel-%sforeign.json" prefix))
         (captured
          (list :launch-kind 'direct :provisional nil :remote-pid 13001
                :profile profile :local-file source-file
                :session-id (concat prefix "captured")
                :remote-connection-file connection-a
                :remote-pid-sidecar
                (concat (string-remove-suffix ".json" connection-a) ".pid")
                :connection-file-tokens (list "-f" connection-a)))
         (foreign
          (list :launch-kind 'direct :provisional nil :remote-pid 13002
                :profile "foreign-profile" :local-file source-file
                :session-id (concat prefix "foreign")
                :remote-connection-file connection-b
                :remote-pid-sidecar
                (concat (string-remove-suffix ".json" connection-b) ".pid")
                :connection-file-tokens (list "-f" connection-b)))
         shutdown-called)
    (unwind-protect
        (progn
          (let ((persisted
                 (ejn-doom-e2e--registry-create-all
                  registry-file (list captured))))
            ;; A conflicting B cannot be durable under the worker's
            ;; one-local-source rule.  Keep it as the live foreign drift that
            ;; the cleanup scan must reject before it can authorize any kill.
            (setq captured (car persisted)))
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry foreign)
            (cl-letf (((symbol-function 'ejn-doom-e2e--shutdown-test-owned-kernel)
                       (lambda (&rest _) (setq shutdown-called t))))
              (should-error
               (ejn-doom-e2e--cleanup-test-owned-kernels
                (current-buffer) captured source-file registry-file
                profile prefix))))
          (should-not shutdown-called)
          (should (equal (ejn-doom-e2e--registry-read registry-file)
                         (list captured))))
      (when (file-directory-p registry-dir) (delete-directory registry-dir t))
      (when (file-exists-p source-file) (delete-file source-file)))))

(ert-deftest ejn-doom-e2e-cleanup-marker-mismatch-preserves-entry ()
  "A bad cleanup marker preserves the exact entry data with a fresh revision."
  (let* ((registry-dir (make-temp-file "ejn-doom-cleanup-registry-" t))
         (registry-file (expand-file-name "registry-v1.json" registry-dir))
         (connection "/tmp/kernel-cleanup-marker.json")
         (entry
          (list :launch-kind 'direct :provisional nil :remote-pid 12345
                :local-file "/tmp/ejn-cleanup-marker.py" :profile "private"
                :session-id "cleanup-marker"
                :remote-connection-file connection
                :remote-pid-sidecar "/tmp/kernel-cleanup-marker.pid"
                :connection-file-tokens (list "-f" connection))))
    (unwind-protect
        (let ((emacs-jupyter-notebook-registry-file registry-file))
          (setq entry (ejn-doom-e2e--registry-create registry-file entry))
          (cl-letf (((symbol-function 'ejn-doom-e2e--remote-entry-dead-p)
                     (lambda (&rest _args) t))
                    ((symbol-function
                      'emacs-jupyter-notebook-ssh-build-remote-cleanup)
                     (lambda (&rest _args) '("true")))
                    ((symbol-function 'ejn-doom-e2e--run-command)
                     (lambda (&rest _args) "unexpected cleanup output\n")))
            (with-temp-buffer
              (should-error
               (ejn-doom-e2e--shutdown-test-owned-kernel (current-buffer) entry)))
            (let ((after (car (ejn-doom-e2e--registry-read registry-file))))
              (should (ejn-doom-e2e--same-direct-entry-p entry after))
              (should
               (equal (emacs-jupyter-notebook-registry--entry-to-wire entry)
                      (emacs-jupyter-notebook-registry--entry-to-wire after)))
              ;; Reassertion is a CAS replacement, so its opaque worker
              ;; revision must advance even though the entry data is exact.
              (should (stringp (plist-get after :registry-revision)))
              (should-not (equal (plist-get entry :registry-revision)
                                 (plist-get after :registry-revision)))))))
      (when (file-directory-p registry-dir) (delete-directory registry-dir t))))

(ert-deftest ejn-doom-e2e-bounded-command-preserves-exact-stdout ()
  "Process sentinels cannot contaminate identity-bound marker output."
  (should (equal (ejn-doom-e2e--run-command
                  '("sh" "-c" "printf __EJN_CLEANUP_DONE__") 2)
                 "__EJN_CLEANUP_DONE__")))

(ert-deftest ejn-doom-e2e-bounded-command-caps-output-and-reaps-processes ()
  "Both command streams hit a hard cap without retaining local processes."
  (dolist (script
           '("while :; do printf '0123456789abcdef'; done"
             "while :; do printf '0123456789abcdef' >&2; done"))
    (let ((started (float-time)))
      (should-error (ejn-doom-e2e--run-command (list "sh" "-c" script) 2))
      (should (< (- (float-time) started) 1.0))
      (should-not (get-process "ejn-doom-e2e-command"))
      (should-not (get-process "ejn-doom-e2e-command-stderr")))))

(ert-deftest ejn-doom-e2e-bounded-command-times-out-and-reaps-processes ()
  "A silent sleeping command cannot outlive its explicit deadline."
  (let ((started (float-time)))
    (should-error
     (ejn-doom-e2e--run-command '("sh" "-c" "sleep 5") 0.05))
    (should (< (- (float-time) started) 1.0))
    (should-not (get-process "ejn-doom-e2e-command"))
    (should-not (get-process "ejn-doom-e2e-command-stderr"))))

(ert-deftest ejn-doom-e2e-failure-evidence-requires-body-and-cleanup-success ()
  "Successful cleanup alone never erases a failed body's private evidence."
  (let ((source (make-temp-file "ejn-doom-failed-source-"))
        (registry (make-temp-file "ejn-doom-failed-registry-")))
    (unwind-protect
        (progn
          (should-not
           (ejn-doom-e2e--discard-success-evidence source registry nil t))
          (should (file-exists-p source))
          (should (file-exists-p registry))
          (should
           (ejn-doom-e2e--discard-success-evidence source registry t t))
          (should-not (file-exists-p source))
          (should-not (file-exists-p registry)))
      (when (file-exists-p source) (delete-file source))
      (when (file-exists-p registry) (delete-file registry)))))

(ert-deftest ejn-doom-e2e-source-pristine-reads-owner-file ()
  "Literal disk verification keeps the source path across its temp buffer."
  (let ((file (make-temp-file "ejn-doom-source-pristine-" nil ".py"))
        buffer baseline)
    (unwind-protect
        (progn
          (with-temp-file file (insert "# %%\nprint(1)\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (setq baseline (buffer-string))
            (should-not
             (ejn-doom-e2e--assert-source-pristine
              buffer baseline "deterministic preflight")))
          (with-temp-file file (insert "# %%\nprint(2)\n"))
          (should-error
           (ejn-doom-e2e--assert-source-pristine
            buffer baseline "mutated disk preflight")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest ejn-doom-e2e-provisional-entry-cannot-trigger-cleanup ()
  "A nil-PID recovery entry is evidence, never remote cleanup authority."
  (let ((entry
         '(:launch-kind direct :remote-pid nil :provisional t
           :profile "p" :session-id "provisional"
           :remote-connection-file "/tmp/kernel-provisional.json"
           :remote-pid-sidecar "/tmp/kernel-provisional.pid"
           :connection-file-tokens ("-f" "/tmp/kernel-provisional.json")))
        public-shutdown remote-command)
    (with-temp-buffer
      (setq emacs-jupyter-notebook--session-entry entry)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-shutdown-kernel)
                 (lambda (&rest _args) (setq public-shutdown t)))
                ((symbol-function 'ejn-doom-e2e--run-command)
                 (lambda (&rest _args) (setq remote-command t))))
        (should-error (ejn-doom-e2e--shutdown-test-owned-kernel
                       (current-buffer) entry))
        (should-not public-shutdown)
        (should-not remote-command)))))

(ert-deftest ejn-doom-e2e-cleanup-skips-public-shutdown-during-attempt ()
  "A promoted entry with an active attempt reaches only exact cleanup.
This is the headless-failure state that made `shutdown-kernel' invoke
`y-or-n-p' before `:force' could take effect.  The harness must retain the
durable entry through an independently bounded remote cleanup instead."
  (let* ((session "doom-promoted")
         (connection (format "/tmp/kernel-%s.json" session))
         (entry (list :launch-kind 'direct :provisional nil :remote-pid 17171
                      :profile "doom-private" :local-file "/tmp/doom-owned.py"
                      :session-id session :remote-connection-file connection
                      :remote-pid-sidecar
                      (concat (string-remove-suffix ".json" connection) ".pid")
                      :connection-file-tokens (list "-f" connection)))
         prompt-called cleanup-argv
         (probe-count 0))
    (with-temp-buffer
      (setq emacs-jupyter-notebook--session-entry entry
            emacs-jupyter-notebook--async-context
            (list :phase 'retrieve :entry entry :origin-buffer (current-buffer)))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _args)
                   (setq prompt-called t)
                   (error "interactive prompt reached from headless cleanup")))
                ((symbol-function 'ejn-doom-e2e--remote-entry-dead-p)
                 (lambda (&rest _args)
                   (setq probe-count (1+ probe-count))
                   (> probe-count 1)))
                ((symbol-function 'emacs-jupyter-notebook-ssh-build-remote-cleanup)
                 (lambda (profile candidate)
                   (should (equal (plist-get profile :profile) "doom-private"))
                   (should (ejn-doom-e2e--same-direct-entry-p entry candidate))
                   '("exact-cleanup")))
                ((symbol-function 'ejn-doom-e2e--run-command)
                 (lambda (argv &optional _timeout)
                   (setq cleanup-argv argv)
                   "__EJN_CLEANUP_DONE__\n")))
        (should (eq (ejn-doom-e2e--public-shutdown-disposition
                     (current-buffer) entry)
                    'in-flight-attempt))
        (should (ejn-doom-e2e--shutdown-test-owned-kernel
                 (current-buffer) entry (+ (float-time) 3)))
        (should-not prompt-called)
        (should (equal cleanup-argv '("exact-cleanup")))
        (should (= probe-count 2))
        ;; The fallback receives ENTRY directly; it does not cancel the live
        ;; attempt or erase its durable authority before exact cleanup proves
        ;; the remote disposition.
        (should (ejn-doom-e2e--same-direct-entry-p
                 entry emacs-jupyter-notebook--session-entry))
        (should (ejn-doom-e2e--same-direct-entry-p
                 entry (plist-get emacs-jupyter-notebook--async-context
                                  :entry)))))))

(ert-deftest ejn-doom-e2e-progress-file-never-exceeds-byte-cap ()
  "Progress retention remains bounded even at a one-byte final boundary."
  (let* ((progress (make-temp-file "ejn-doom-progress-"))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (with-temp-file progress
            (insert (make-string (1- ejn-doom-e2e--progress-output-limit) ?x)))
          (setenv "EJN_DOOM_E2E_PROGRESS_FILE" progress)
          (ejn-doom-e2e--record-progress "final diagnostic")
          (should (= (file-attribute-size (file-attributes progress))
                     ejn-doom-e2e--progress-output-limit)))
      (when (file-exists-p progress) (delete-file progress)))))

(ert-deftest ejn-doom-e2e-wait-step-dispatches-timers ()
  "The nested daemon wait primitive must run deferred async continuations."
  (let (fired timer)
    (unwind-protect
        (progn
          (setq timer (run-at-time 0 nil (lambda () (setq fired t))))
          (ejn-doom-e2e--wait-step 0.02)
          (should fired))
      (when (timerp timer) (cancel-timer timer)))))

(ert-deftest ejn-doom-e2e-evidence-files-stay-in-owned-directory ()
  "The optional live-E2E evidence root owns its source and registry files."
  (let* ((directory (make-temp-file "ejn-doom-evidence-" t))
         (process-environment (copy-sequence process-environment))
         file)
    (unwind-protect
        (progn
          (setenv "EJN_DOOM_E2E_EVIDENCE_DIR" directory)
          (setq file (ejn-doom-e2e--make-evidence-file "source-" ".py"))
          (should (equal (file-name-directory file)
                         (file-name-as-directory directory))))
      (when (file-exists-p file) (delete-file file))
      (when (file-directory-p directory) (delete-directory directory)))))

(defun ejn-doom-e2e-run ()
  "Run deterministic harness preflights, then the remote Doom E2E body."
  (let* ((process-environment (copy-sequence process-environment))
         (_ (setenv "EJN_DOOM_E2E_PROGRESS_FILE" nil))
         (stats
          (ert-run-tests-batch
           "\\`ejn-doom-e2e-\\(bounded-command\\|busy-\\(?:duration\\|execution-admission\\)\\|evidence-files\\|failure-evidence\\|progress-file\\|recovery-rejects\\|round-trip-spec\\|wait-\\(?:for-admitted-busy-cell\\|step\\)\\|cleanup-\\(?:marker-mismatch\\|covers-drifted\\|refuses-foreign\\|skips-public-shutdown\\)\\|provisional-entry\\|source-pristine\\)")))
    (unless (zerop (ert-stats-completed-unexpected stats))
      (error "Doom E2E deterministic harness preflight failed")))
  (ejn-doom-e2e-python-cell-evaluates-on-mother))

(provide 'emacs-jupyter-notebook-doom-e2e)

;;; emacs-jupyter-notebook-doom-e2e.el ends here
