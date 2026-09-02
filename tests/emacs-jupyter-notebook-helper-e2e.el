;;; emacs-jupyter-notebook-helper-e2e.el --- AG2 local helper E2E gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; This suite deliberately replaces only SSH transport acquisition with a
;; local pipe process.  The core still creates a real helper backend session,
;; performs hello/connect/kernel-info/finalization, and drives the real panel
;; against a TH2-owned direct local kernel.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-artifacts)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-helper-backend)

(defconst ejn-ag2--timeout 12.0)

(defun ejn-ag2--environment (name)
  "Return required AG2 environment variable NAME or signal a clear error."
  (let ((value (getenv name)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "AG2 runner did not provide %s" name))
    value))

(defun ejn-ag2--await (predicate &optional timeout)
  "Run test event processing until PREDICATE succeeds or timeout expires."
  (let ((deadline (+ (float-time) (or timeout ejn-ag2--timeout))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun ejn-ag2--await-phase (phase predicate &optional timeout)
  "Wait for PREDICATE during PHASE or fail with bounded transport facts."
  (unless (ejn-ag2--await predicate timeout)
    (let* ((client emacs-jupyter-notebook--client)
           (requests
            (and (emacs-jupyter-notebook-backend-session-p client)
                 (emacs-jupyter-notebook-backend-session-requests client)))
           operations)
      (when (hash-table-p requests)
        (maphash
         (lambda (_id request)
           (push (emacs-jupyter-notebook-backend-request-operation request)
                 operations))
         requests))
      (error "AG2 %s timed out: %S"
             phase
             (list :kernel-status emacs-jupyter-notebook--kernel-status
                   :backend-requests
                   (if (hash-table-p requests) (hash-table-count requests) 0)
                   :backend-operations (nreverse operations)
                   :active-execution
                   (emacs-jupyter-notebook--active-execution-status-snapshot)
                   :completion-pending emacs-jupyter-notebook--completion-pending-id
                   :completion-generation
                   emacs-jupyter-notebook--completion-request-counter
                   :inspect-generation emacs-jupyter-notebook--inspect-request-id
                   :helper (emacs-jupyter-notebook--helper-status-snapshot)
                   :last-error emacs-jupyter-notebook--last-bounded-error))))
  t)

(defun ejn-ag2--json-file (file)
  "Read private test JSON FILE as a string-keyed hash table."
  ;; `json-parse-file' is not present in every supported Emacs version.
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-string (buffer-string)
                       :object-type 'hash-table :array-type 'list
                       :null-object nil :false-object nil)))

(defun ejn-ag2--bridge-state ()
  "Return the bridge's current fixture state."
  (ejn-ag2--json-file (ejn-ag2--environment "EJN_E2E_STATE")))

(defun ejn-ag2--bridge-fresh-state ()
  "Return a fresh live bridge kernel state for one independent ERT."
  ;; The bridge exclusively owns this direct kernel and completes any
  ;; still-running test fixture teardown before its bounded relaunch.
  (let* ((answer (ejn-ag2--bridge-request "restart"))
         (state (gethash "state" answer)))
    (ejn-ag2--state-connection-file state)
    state))

(defun ejn-ag2--bridge-request (operation)
  "Synchronously make bounded private bridge OPERATION request.
This is test orchestration, not an EJN UI path."
  (let* ((directory (file-name-as-directory
                     (ejn-ag2--environment "EJN_E2E_CONTROL_DIR")))
         (token (ejn-ag2--environment "EJN_E2E_TOKEN"))
         (nonce (format "%x-%x" (random most-positive-fixnum) (truncate (float-time))))
         (request (expand-file-name (format "request-%s.json" nonce) directory))
         (response (expand-file-name (format "response-%s.json" nonce) directory))
         (temporary (concat request ".tmp")))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (json-encode `(("token" . ,token) ("op" . ,operation))))
            (insert "\n"))
          (set-file-modes temporary #o600)
          (rename-file temporary request)
          (unless (ejn-ag2--await (lambda () (file-regular-p response)))
            (error "AG2 bridge %s request timed out" operation))
          (let ((answer (ejn-ag2--json-file response)))
            (unless (eq (gethash "ok" answer) t)
              (error "AG2 bridge %s failed: %s" operation
                     (or (gethash "error" answer) "unknown error")))
            answer))
      (ignore-errors (delete-file temporary))
      (ignore-errors (delete-file request))
      (ignore-errors (delete-file response)))))

(defun ejn-ag2--state-connection-file (state)
  "Return validated local connection file from bridge STATE."
  (let ((file (gethash "connection_file" state)))
    (unless (and (stringp file) (file-name-absolute-p file) (file-regular-p file))
      (error "AG2 bridge returned no usable connection file"))
    file))

(defun ejn-ag2--state-pid (state)
  "Return a positive test fixture PID from bridge STATE."
  (let ((pid (gethash "kernel_pid" state)))
    (unless (and (integerp pid) (> pid 0))
      (error "AG2 bridge returned no usable kernel PID"))
    pid))

(defun ejn-ag2--make-tunnel ()
  "Create a live local process used only as the core's tunnel ownership token."
  (make-pipe-process :name (generate-new-buffer-name "ejn-ag2-tunnel")
                     :buffer nil :noquery t))

(defun ejn-ag2--restart-resolution (profile session-id)
  "Return a test-local, schema-valid resolver continuation for restart.
The public restart path normally resolves a remote kernelspec before it asks
the remote side to launch the replacement.  AG2 deliberately has no SSH
server, so this substitutes only that preflight child with a local `printf';
the real helper shutdown and the bridge-backed launch continuation still run."
  (let* ((connection-file
          (emacs-jupyter-notebook-ssh-remote-connection-file profile session-id))
         (payload
          (concat
           "EJN_CONNECTION_FILE=" connection-file "\n"
           (json-encode
            `(("kernelspecs" .
               (("python3" .
                 (("resource_dir" . "/tmp")
                  ("spec" .
                   (("argv" . ["/bin/true" ,connection-file])
                    ("env" . [])
                    ("metadata" .
                     (("ejn_connection_file" . ,connection-file)
                      ("ejn_session_id" . ,session-id))))))))))))))
    (list :connection-file connection-file
          :argv (list "sh" "-c"
                      (format "printf '%%s' %s" (shell-quote-argument payload))))))

(defun ejn-ag2--entry (state local-file)
  "Make strict direct-entry metadata for bridge STATE and LOCAL-FILE."
  (let* ((session "ag2-e2e")
         (remote (expand-file-name (format "kernel-%s.json" session)
                                   (ejn-ag2--environment "EJN_E2E_ROOT")))
         (ports (emacs-jupyter-notebook-connection-ports
                 (emacs-jupyter-notebook-connection-read-file local-file))))
    (list :profile "ag2" :remote-host "127.0.0.1" :remote-cwd "/tmp"
          :kernelspec "python3" :session-id session :launch-kind 'direct
          :remote-pid (ejn-ag2--state-pid state)
          :remote-connection-file remote
          :remote-pid-sidecar (concat (string-remove-suffix ".json" remote) ".pid")
          :connection-file-tokens (list remote)
          :remote-ports ports :local-connection-file local-file
          :local-file (buffer-file-name))))

(defun ejn-ag2--copy-connection (state destination)
  "Copy bridge STATE connection into private DESTINATION with mode 0600."
  (copy-file (ejn-ag2--state-connection-file state) destination t)
  (set-file-modes destination #o600)
  destination)

(defun ejn-ag2--attach (local-file &optional state)
  "Run the real core helper connect/finalize path using LOCAL-FILE.
STATE is the bridge fixture metadata.  Only tunnel acquisition is replaced by
a local pipe process; no SSH command is constructed or started."
  (let* ((state (or state (ejn-ag2--bridge-state)))
         (connection (emacs-jupyter-notebook-connection-read-file local-file))
         (ports (emacs-jupyter-notebook-connection-ports connection))
         (entry (ejn-ag2--entry state local-file))
         (tunnel (ejn-ag2--make-tunnel))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'connect :profile (list :profile "ag2" :host "127.0.0.1")
                   :entry entry :session-id "ag2-e2e" :origin-buffer (current-buffer)
                   :owns-kernel nil :local-file local-file :local-ports ports
                   :remote-ports ports :tunnel-process tunnel)))
    (setq emacs-jupyter-notebook--async-context context)
    (emacs-jupyter-notebook--async-connect context)
    (unless (ejn-ag2--await
             (lambda ()
               (and emacs-jupyter-notebook--client
                    (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)
                    (not emacs-jupyter-notebook--execution-setup-pending))))
      (error "AG2 helper attach did not finalize: %s"
             emacs-jupyter-notebook--async-last-error))
    (should (emacs-jupyter-notebook-backend-session-installed-p
             emacs-jupyter-notebook--client))
    entry))

(defun ejn-ag2--panel-entries (source)
  "Return SOURCE panel entries in insertion order."
  (let ((panel (emacs-jupyter-notebook-panel-buffer source)))
    (and (buffer-live-p panel)
         (with-current-buffer panel
           (mapcar #'cdr emacs-jupyter-notebook-panel--entries)))))

(defun ejn-ag2--entry-with-code (source fragment)
  "Return SOURCE panel entry whose code contains FRAGMENT."
  (cl-find-if (lambda (entry) (string-match-p (regexp-quote fragment)
                                               (plist-get entry :code)))
              (ejn-ag2--panel-entries source)))

(defun ejn-ag2--entry-terminal-p (source fragment)
  "Return non-nil when the panel entry containing FRAGMENT is terminal."
  (when-let ((entry (ejn-ag2--entry-with-code source fragment)))
    (memq (plist-get entry :status) '(ok error cancelled outcome-unknown))))

(defun ejn-ag2--send-cell-containing (fragment)
  "Move to source text FRAGMENT and invoke the public send-cell command."
  (goto-char (point-min))
  (unless (search-forward fragment nil t)
    (error "AG2 fixture source lacks %s" fragment))
  (beginning-of-line)
  (emacs-jupyter-notebook-send-cell))

(defun ejn-ag2--assert-source-pristine (source baseline modified)
  "Assert SOURCE text and modification state still equal the initial snapshot."
  (with-current-buffer source
    (should (equal (buffer-string) baseline))
    (should (eq (buffer-modified-p) modified))))

(defun ejn-ag2--first-image-position (panel)
  "Return a panel position carrying one image segment identity."
  (with-current-buffer panel
    (let ((position (point-min)) found)
      (while (and (< position (point-max)) (not found))
        (when (get-text-property position 'emacs-jupyter-notebook-segment-index)
          (setq found position))
        (setq position (1+ position)))
      found)))

(defun ejn-ag2--assert-no-local-leaks
    (source root registry local-files durable-expected)
  "Assert teardown released local resources and handled durable state exactly.
When DURABLE-EXPECTED is non-nil, mode disable must retain the registry,
connection files, and buffer-local session entry for later reconnect."
  (dolist (file local-files)
    (should (eq (file-exists-p file) (and durable-expected t))))
  ;; Shutdown removes the entry but deliberately leaves an empty registry
  ;; file; ordinary local teardown must retain the live entry.
  (should (file-exists-p registry))
  (let ((entries (emacs-jupyter-notebook-registry-load registry)))
    (if durable-expected
        (should (cl-some (lambda (entry)
                           (equal (plist-get entry :session-id) "ag2-e2e"))
                         entries))
      (should-not entries)))
  (should-not emacs-jupyter-notebook-helper--sessions)
  (should-not
   (cl-find-if (lambda (process)
                 (process-get process 'emacs-jupyter-notebook-helper-session))
               (process-list)))
  (should-not
   (cl-find-if (lambda (buffer)
                 (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer)))
               (buffer-list)))
  (should-not (cl-find-if (lambda (buffer)
                            (and (buffer-live-p buffer)
                                 (string-prefix-p " *ejn-ag2" (buffer-name buffer))))
                          (buffer-list)))
  (should-not
   (cl-find-if (lambda (process)
                 (and (process-live-p process)
                      (string-prefix-p "ejn-ag2-tunnel" (process-name process))))
               (process-list)))
  (when (buffer-live-p source)
    (with-current-buffer source
      (should-not emacs-jupyter-notebook--client)
      (should-not emacs-jupyter-notebook--tunnel-process)
      (should-not emacs-jupyter-notebook--async-context)
      (should-not emacs-jupyter-notebook--execution-active-id)
      (should-not emacs-jupyter-notebook--execution-queue)
      (should-not emacs-jupyter-notebook--execution-ledger)
      (should-not emacs-jupyter-notebook--execution-setup-timer)
      (should-not emacs-jupyter-notebook--heartbeat-timer)
      (should-not emacs-jupyter-notebook--reconnect-timer)
      (should (eq (and emacs-jupyter-notebook--session-entry t)
                  (and durable-expected t)))
      (should-not (emacs-jupyter-notebook-panel-buffer source))))
  (should-not emacs-jupyter-notebook-panel--external-image-snapshots)
  (should-not emacs-jupyter-notebook-panel--external-image-pending-cancels)
  (should (= emacs-jupyter-notebook-panel--external-image-pending-count 0))
  (should (file-directory-p root)))

(defmacro ejn-ag2--with-source (&rest body)
  "Run BODY in a fully isolated real source buffer and helper configuration."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "ejn-ag2-" t))
          (source-file (expand-file-name "e2e.py" root))
          (registry (expand-file-name "registry.el" root))
          (local-file (expand-file-name "connection.json" root))
          (source nil)
          (durable-expected t)
          (body-completed nil)
          (cleanup-error nil)
          (teardown-state nil)
          (test-artifact-capabilities nil)
          (test-artifact-roots nil)
          (emacs-jupyter-notebook-backend 'helper)
          (emacs-jupyter-notebook-helper-command
           (list (ejn-ag2--environment "EJN_E2E_HELPER") "--protocol"))
          (emacs-jupyter-notebook-registry-file registry)
          (emacs-jupyter-notebook-remote-profiles
           '(("ag2" . (:host "127.0.0.1" :remote-cwd "/tmp"
                       :remote-cache-dir "/tmp/ejn-ag2-cache"
                       :kernelspec "python3" :python-command ("python3")))))
          (emacs-jupyter-notebook-kernel-idle-timeout 0)
          (emacs-jupyter-notebook-auto-reconnect nil)
          (emacs-jupyter-notebook-heartbeat-interval 3600)
          (emacs-jupyter-notebook-check-code-completeness nil)
          (emacs-jupyter-notebook-external-image-snapshot-ttl 1)
          (emacs-jupyter-notebook-panel-external-open-function #'ignore))
     (unwind-protect
         (progn
           (with-temp-file source-file
             (insert "# %%\n"
                     "events = []\n"
                     "# %%\n"
                     "events.append('first')\n"
                     "# %%\n"
                     "events.append('second')\n"
                     "# %%\n"
                     "assert events == ['first', 'second']\n"
                     "# %%\n"
                     "import math\n"
                     "# %%\n"
                     "pri\n"
                     "# %%\n"
                     "print\n"
                     "# %%\n"
                     "from IPython.display import Image, display\n"
                     "import base64\n"
                     "display(Image(data=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9WQAAAABJRU5ErkJggg=='), format='png'))\n"
                     "# %%\n"
                     "stdin_answer = input('AG2 input: ')\n"
                     "print(stdin_answer)\n"
                     "# %%\n"
                     "import time\n"
                     "print('AG2 interrupt ready', flush=True)\n"
                     "time.sleep(30)\n"
                     "# %%\n"
                     "death_once = globals().get('death_once', 0) + 1\n"
                     "time.sleep(2)\n"
                     "# %%\n"
                     "events.append('after-interrupt')\n"
                     "# %%\n"
                     "assert death_once == 1\n"
                     "# %%\n"
                     "e2e_marker = 29\n"
                     "# %%\n"
                     "assert 'e2e_marker' not in globals()\n"))
           (setq source (find-file-noselect source-file))
           (with-current-buffer source
             (python-mode)
             (emacs-jupyter-notebook-mode 1)
             ;; Tests share one runner-owned bridge, but never kernel state.
             (let ((state (ejn-ag2--bridge-fresh-state)))
               (ejn-ag2--copy-connection state local-file)
               (ejn-ag2--attach local-file state))
             ,@body
             (setq body-completed t)))
       (when (buffer-live-p source)
         (with-current-buffer source
           (when (emacs-jupyter-notebook-backend-session-p
                  emacs-jupyter-notebook--client)
             (setq teardown-state
                   (emacs-jupyter-notebook-backend-session-data
                    emacs-jupyter-notebook--client))
             (when-let ((capability
                         (emacs-jupyter-notebook-helper-backend-state-artifact-capability
                          teardown-state)))
               (push capability test-artifact-capabilities)
               (cl-pushnew
                (emacs-jupyter-notebook-artifacts-capability-root capability)
                test-artifact-roots :test #'equal)))
           (let ((panel (emacs-jupyter-notebook-panel-buffer source)))
             (when (buffer-live-p panel)
               (with-current-buffer panel
                 (when (hash-table-p
                        emacs-jupyter-notebook-panel--published-artifact-capabilities)
                   (maphash
                    (lambda (_key capability)
                      (push capability test-artifact-capabilities)
                      (cl-pushnew
                       (emacs-jupyter-notebook-artifacts-capability-root capability)
                       test-artifact-roots :test #'equal))
                    emacs-jupyter-notebook-panel--published-artifact-capabilities)))
               (dolist (snapshot emacs-jupyter-notebook-panel--external-image-snapshots)
                 (when (eq (plist-get snapshot :panel) panel)
                   (when-let ((capability (plist-get snapshot :artifact-capability)))
                     (push capability test-artifact-capabilities))
                   (when-let ((artifact-root (plist-get snapshot :root)))
                     (cl-pushnew artifact-root test-artifact-roots :test #'equal)))))
             (when emacs-jupyter-notebook-mode
               (emacs-jupyter-notebook-mode -1))
             (when (buffer-live-p panel) (kill-buffer panel)))
           nil))
       (unless (ejn-ag2--await
                (lambda () (null emacs-jupyter-notebook-helper--sessions)) 4)
         (setq cleanup-error '(error "AG2 helper session survived teardown")))
       (unless (ejn-ag2--await
                (lambda ()
                  (or (null teardown-state)
                      (emacs-jupyter-notebook-helper-backend-state-retired
                       teardown-state)))
                4)
         (unless cleanup-error
           (setq cleanup-error '(error "AG2 helper backend state survived teardown"))))
       (unless (ejn-ag2--await
                (lambda ()
                  (and
                   (cl-every
                    (lambda (capability)
                      (not (emacs-jupyter-notebook-artifacts-capability-valid-p
                            capability)))
                    test-artifact-capabilities)
                   (cl-every (lambda (artifact-root)
                               (not (file-directory-p artifact-root)))
                             test-artifact-roots)))
                4)
         (unless cleanup-error
           (setq cleanup-error
                 (list
                  'error
                  (format
                   "AG2 test-owned artifacts survived teardown: roots=%S leases=%S"
                   (mapcar
                    (lambda (artifact-root)
                      (list artifact-root
                            :exists (file-directory-p artifact-root)
                            :leaves
                            (and (file-directory-p artifact-root)
                                 (directory-files artifact-root nil nil t))))
                    test-artifact-roots)
                   (delq nil
                         (mapcar
                          #'emacs-jupyter-notebook-artifacts-capability-lease
                          test-artifact-capabilities)))))))
       (unless cleanup-error
         (condition-case err
             (ejn-ag2--assert-no-local-leaks
              source root registry (list local-file) durable-expected)
           (error (setq cleanup-error err))))
       ;; Only the test fixture removes durable reconnect state, and only
       ;; after the assertion above proved what the public lifecycle did.
       (when (buffer-live-p source)
         (with-current-buffer source
           (setq emacs-jupyter-notebook--session-entry nil)))
       (ignore-errors (delete-file source-file))
       (ignore-errors (delete-file local-file))
       (ignore-errors (delete-file registry))
       (when (buffer-live-p source) (kill-buffer source))
       (ignore-errors (delete-directory root t))
       (when cleanup-error
         (if body-completed
             (signal (car cleanup-error) (cdr cleanup-error))
           (message "AG2 cleanup also failed: %s"
                    (error-message-string cleanup-error)))))))

(ert-deftest ejn-ag2-source-panel-aux-stdin-interrupt ()
  "Exercise source commands, panel artifacts, aux requests, stdin and interrupt."
  (ejn-ag2--with-source
    (let* ((source (current-buffer))
           (baseline (buffer-string))
           (modified (buffer-modified-p))
           opened completion inspection)
      (ejn-ag2--send-cell-containing "events = []")
      (ejn-ag2--await-phase
       "initial execution"
       (lambda () (ejn-ag2--entry-terminal-p source "events = []")))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag2--send-cell-containing "events.append('first')")
      (ejn-ag2--send-cell-containing "events.append('second')")
      (ejn-ag2--await-phase
       "FIFO execution"
       (lambda ()
         (and (ejn-ag2--entry-terminal-p source "'first'")
              (ejn-ag2--entry-terminal-p source "'second'"))))
      (ejn-ag2--send-cell-containing "assert events ==")
      (ejn-ag2--await-phase
       "kernel FIFO assertion"
       (lambda () (ejn-ag2--entry-terminal-p source "assert events ==")))
      (should (equal (ejn-panel-entry-text (ejn-ag2--entry-with-code source "'first'")) ""))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag2--send-cell-containing "import math")
      (ejn-ag2--await-phase
       "completion setup"
       (lambda () (ejn-ag2--entry-terminal-p source "import math")))
      (goto-char (point-min))
      (search-forward "pri")
      (cl-letf (((symbol-function 'completion-in-region)
                 (lambda (_beg _end candidates &rest _)
                   (setq completion (all-completions "" candidates)))))
        (emacs-jupyter-notebook-complete-at-point)
        (ejn-ag2--await-phase "completion" (lambda () completion)))
      (should (member "print" completion))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (goto-char (point-min))
      (search-forward "print")
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (text &rest _) (setq inspection text))))
        (emacs-jupyter-notebook-inspect-at-point)
        (ejn-ag2--await-phase "inspect" (lambda () inspection)))
      (should (string-match-p "print" inspection))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag2--send-cell-containing "display(Image")
      (ejn-ag2--await-phase
       "image execution"
       (lambda () (ejn-ag2--entry-terminal-p source "display(Image")))
      (let* ((entry (ejn-ag2--entry-with-code source "display(Image"))
             (images (ejn-panel-entry-images entry))
             (original (and images (plist-get (cdr (car images)) :ejn-original)))
             (panel (emacs-jupyter-notebook-panel-buffer source)))
        (should (= (length images) 1))
        (should original)
        ;; One lease belongs to the helper backend and one to this panel.
        (should
         (= 2 (length
               (directory-files
                (plist-get original :root) nil "\\`\\.ejn-live-" t))))
        (with-current-buffer panel
          (emacs-jupyter-notebook-panel-flush-now panel)
          (goto-char (or (ejn-ag2--first-image-position panel) (point-min)))
          (let ((emacs-jupyter-notebook-panel-external-open-function
                 (lambda (file) (setq opened file))))
            (emacs-jupyter-notebook-panel-open-image-externally)
            (ejn-ag2--await-phase "external image open" (lambda () opened))
            (should (file-readable-p opened))
            (cl-pushnew
             (directory-file-name (file-name-directory opened))
             test-artifact-roots :test #'equal))))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag2--send-cell-containing "stdin_answer = input")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "stdin-ok")))
        (ejn-ag2--await-phase
         "stdin" (lambda () (ejn-ag2--entry-terminal-p source "stdin_answer"))))
      (should (string-match-p "stdin-ok" (ejn-panel-entry-text
                                            (ejn-ag2--entry-with-code source "stdin_answer"))))
      (ejn-ag2--await-phase
       "stdin request settlement"
       (lambda ()
         (and (null emacs-jupyter-notebook--execution-active-id)
              (= 0 (hash-table-count
                    (emacs-jupyter-notebook-backend-session-requests
                     emacs-jupyter-notebook--client))))))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag2--send-cell-containing "time.sleep(30)")
      (ejn-ag2--await-phase
       "interrupt execution canary"
       (lambda ()
         (when-let ((entry (ejn-ag2--entry-with-code source "time.sleep(30)")))
           (string-match-p "AG2 interrupt ready" (ejn-panel-entry-text entry)))))
      (emacs-jupyter-notebook-interrupt-kernel)
      (ejn-ag2--await-phase
       "interrupt terminal"
       (lambda () (ejn-ag2--entry-terminal-p source "time.sleep(30)")))
      (ejn-ag2--send-cell-containing "after-interrupt")
      (ejn-ag2--await-phase
       "post-interrupt execution"
       (lambda () (ejn-ag2--entry-terminal-p source "after-interrupt")))
      (ejn-ag2--assert-source-pristine source baseline modified))))

(ert-deftest ejn-ag2-helper-death-reconnect-preserves-kernel ()
  "Killing the real helper yields unknown work and a fresh same-kernel attach."
  (ejn-ag2--with-source
    (let* ((source (current-buffer))
           (baseline (buffer-string))
           (modified (buffer-modified-p))
           (state (ejn-ag2--bridge-state))
           (pid (ejn-ag2--state-pid state))
           (client emacs-jupyter-notebook--client))
      (ejn-ag2--send-cell-containing "events = []")
      (ejn-ag2--await-phase
       "helper-death setup"
       (lambda () (ejn-ag2--entry-terminal-p source "events = []")))
      (ejn-ag2--send-cell-containing "death_once =")
      (ejn-ag2--await-phase
       "helper-death admission" (lambda () emacs-jupyter-notebook--execution-active-id))
      (let* ((state-object (emacs-jupyter-notebook-backend-session-data client))
             (helper (emacs-jupyter-notebook-helper-backend-state-helper state-object))
             (process (emacs-jupyter-notebook-helper-session-process helper)))
        (should (process-live-p process))
        (delete-process process))
      (ejn-ag2--await-phase
       "helper-death retirement" (lambda () (null emacs-jupyter-notebook--client)))
      (ejn-ag2--assert-source-pristine source baseline modified)
      (should (eq (plist-get (ejn-ag2--entry-with-code source "death_once =") :status)
                  'outcome-unknown))
      (should-not emacs-jupyter-notebook--reconnect-timer)
      (should (= pid (ejn-ag2--state-pid (ejn-ag2--bridge-state))))
      (let ((idle-deadline (+ (float-time) 4)))
        (ejn-ag2--await-phase
         "zero-replay observation" (lambda () (> (float-time) idle-deadline)) 5))
      (ejn-ag2--attach local-file state)
      (ejn-ag2--send-cell-containing "assert death_once == 1")
      (ejn-ag2--await-phase
       "same-kernel reconnect"
       (lambda () (ejn-ag2--entry-terminal-p source "assert death_once == 1")))
      (ejn-ag2--assert-source-pristine source baseline modified))))

(ert-deftest ejn-ag2-public-restart-and-shutdown ()
  "Run public lifecycle commands with only remote launch replaced by the bridge."
  (ejn-ag2--with-source
    (let* ((source (current-buffer))
           (baseline (buffer-string))
           (modified (buffer-modified-p))
           (old-pid (ejn-ag2--state-pid (ejn-ag2--bridge-state)))
           (remote-cleanup nil)
           (restart-continuation-called nil)
           (pre-restart-context emacs-jupyter-notebook--async-context))
      (ejn-ag2--send-cell-containing "e2e_marker = 29")
      (ejn-ag2--await-phase
       "restart setup"
       (lambda () (ejn-ag2--entry-terminal-p source "e2e_marker = 29")))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-build-kernelspec-resolution)
                 #'ejn-ag2--restart-resolution)
                ((symbol-function 'emacs-jupyter-notebook--restart-upload-seed)
                 (lambda (context)
                   ;; This is the only remote lifecycle substitution: after
                   ;; real helper-confirmed shutdown, ask the test-owned TH2
                   ;; bridge for its fresh direct kernel and resume core attach.
                   (setq restart-continuation-called t)
                   (let* ((answer (ejn-ag2--bridge-request "restart"))
                          (state (gethash "state" answer))
                          (local (plist-get context :local-file))
                          (connection (ejn-ag2--copy-connection state local))
                          (ports (emacs-jupyter-notebook-connection-ports
                                  (emacs-jupyter-notebook-connection-read-file connection)))
                          (tunnel (ejn-ag2--make-tunnel)))
                     (setq context (emacs-jupyter-notebook--async-put context :restart-seed nil))
                     (setq context (emacs-jupyter-notebook--async-put context :restart-staging-file nil))
                     (setq context (emacs-jupyter-notebook--async-put context :local-ports ports))
                     (setq context (emacs-jupyter-notebook--async-put context :remote-ports ports))
                     (setq context (emacs-jupyter-notebook--async-put context :tunnel-process tunnel))
                     (setq context (emacs-jupyter-notebook--async-put
                                    context :candidate-remote-pid (ejn-ag2--state-pid state)))
                     (emacs-jupyter-notebook--async-connect context)))))
        (emacs-jupyter-notebook-restart-kernel)
        (unless (not (eq pre-restart-context emacs-jupyter-notebook--async-context))
          (error "AG2 restart did not create an async context"))
        (unless (ejn-ag2--await
                 (lambda ()
                   (and emacs-jupyter-notebook--client
                        (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)
                        (not emacs-jupyter-notebook--execution-setup-pending)
                        (/= old-pid
                            (ejn-ag2--state-pid (ejn-ag2--bridge-state))))))
          (error "AG2 restart did not attach: old-pid=%S continuation=%S phase=%S error=%S bridge=%S"
                 old-pid restart-continuation-called
                 (plist-get emacs-jupyter-notebook--async-context :phase)
                 emacs-jupyter-notebook--async-last-error
                 (ejn-ag2--bridge-state))))
        (ejn-ag2--assert-source-pristine source baseline modified)
        (ejn-ag2--send-cell-containing "assert 'e2e_marker' not")
        (ejn-ag2--await-phase
         "post-restart execution"
         (lambda () (ejn-ag2--entry-terminal-p source "assert 'e2e_marker'")))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                 (lambda (entry) (setq remote-cleanup entry))))
        (emacs-jupyter-notebook-shutdown-kernel)
        (ejn-ag2--await-phase
         "public shutdown" (lambda () (null emacs-jupyter-notebook--client)))
        (should remote-cleanup)
        (should-not (gethash "alive" (gethash "state" (ejn-ag2--bridge-request "status"))))
        (ejn-ag2--assert-source-pristine source baseline modified)
        (setq durable-expected nil))
      (ejn-ag2--assert-source-pristine source baseline modified))))

(provide 'emacs-jupyter-notebook-helper-e2e)
;;; emacs-jupyter-notebook-helper-e2e.el ends here
