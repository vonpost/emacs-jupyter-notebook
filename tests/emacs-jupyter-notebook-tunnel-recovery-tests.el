;;; emacs-jupyter-notebook-tunnel-recovery-tests.el --- Recover executing cells -*- lexical-binding: t; -*-

;;; Commentary:
;; Deterministic CC21 regressions use the real execution FIFO and result panel.
;; Only the helper wire and SSH boundaries are replaced; no kernel is needed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'python)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-helper-backend)

(defun ejn-cc21-test--entry ()
  "Return durable metadata for one reconnectable test kernel."
  '(:profile "cc21" :remote-host "test.invalid" :remote-cwd "/work"
    :kernelspec "python3" :session-id "cc21-session" :launch-kind direct
    :remote-pid 4242 :remote-connection-file "/cache/kernel-cc21-session.json"
    :remote-pid-sidecar "/cache/kernel-cc21-session.pid"
    :connection-file-tokens ("/cache/kernel-cc21-session.json")
    :local-connection-file "/tmp/ejn-cc21-connection.json"
    :registry-revision "cc21-revision"
    :remote-ports (:shell_port 41000 :iopub_port 41001 :stdin_port 41002
                   :hb_port 41003 :control_port 41004)
    :tunnel-ports (:shell_port 42000 :iopub_port 42001 :stdin_port 42002
                   :hb_port 42003 :control_port 42004)))

(defmacro ejn-cc21-test--with-source (&rest body)
  "Run BODY with an installed helper, a real FIFO and a real result panel.
Bind SESSION, REQUESTS, SUSPENDS, CLOSES and SCHEDULED for assertions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (python-mode)
     (insert "# %% first\nfirst()\n# %% second\nsecond()\n# %% third\nthird()\n")
     (goto-char (point-min))
     (set-buffer-modified-p nil)
     (emacs-jupyter-notebook-cell-tracking-enable)
     (let* ((source-text (buffer-string))
            (source-modified (buffer-modified-p))
            (original-processes (process-list))
            (original-timers (copy-sequence timer-list))
            (original-idle-timers (copy-sequence timer-idle-list))
            (session (emacs-jupyter-notebook-backend-session-create
                      nil (current-buffer)
                      #'emacs-jupyter-notebook--backend-transport-failed))
            (state (emacs-jupyter-notebook-helper-backend--make-state
                    :helper 'cc21-fake-helper
                    :request-map (make-hash-table :test #'equal)
                    :retired-request-ids (make-hash-table :test #'equal)))
            (emacs-jupyter-notebook-check-code-completeness nil)
            (emacs-jupyter-notebook-reconnect-initial-delay 60)
            (schedule-function (symbol-function
                                'emacs-jupyter-notebook--schedule-auto-reconnect))
            requests suspends closes
            (scheduled 0))
       (setf (emacs-jupyter-notebook-backend-session-data session) state)
       (emacs-jupyter-notebook-backend-session-mark-attached session)
       (emacs-jupyter-notebook-backend-session-mark-installed session)
       (setq emacs-jupyter-notebook-mode t
             emacs-jupyter-notebook--client session
             emacs-jupyter-notebook--session-entry (copy-tree (ejn-cc21-test--entry))
             emacs-jupyter-notebook--kernel-status 'busy)
       (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                  (lambda (_helper operation params callback &rest _keys)
                    (let ((wire-id (format "cc21-wire-%d" (1+ (length requests)))))
                      (push (list operation params wire-id callback) requests)
                      wire-id)))
                 ((symbol-function 'emacs-jupyter-notebook-backend-suspend)
                  (lambda (client &rest _args) (push client suspends)))
                 ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                  (lambda (client &rest _args)
                    (push client closes)
                    (emacs-jupyter-notebook-helper-backend--dispose
                     (emacs-jupyter-notebook-backend-session-data client)
                     "CC21 fixture close")
                    (setf (emacs-jupyter-notebook-backend-session-closed client) t)))
                 ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                  (lambda (callback &rest _args) (funcall callback nil)))
                 ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                  (lambda (&rest args)
                    (let ((previous emacs-jupyter-notebook--reconnect-schedule-token))
                      (prog1 (apply schedule-function args)
                        (when (and emacs-jupyter-notebook--reconnect-schedule-token
                                   (not (eq previous
                                            emacs-jupyter-notebook--reconnect-schedule-token)))
                          (cl-incf scheduled))))))
                 ((symbol-function 'emacs-jupyter-notebook--heartbeat-start) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-invalidate) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-execution-finished)
                  #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore))
         (unwind-protect
             (progn
               ,@body
               (should (equal source-text (buffer-string)))
               (should (eq source-modified (buffer-modified-p))))
           (emacs-jupyter-notebook--release-local-resources)
           (emacs-jupyter-notebook-cell-tracking-disable)
           (emacs-jupyter-notebook--kill-panel)
           (should-not (cl-set-difference (process-list) original-processes))
           ;; Panel edits can start Emacs's own global undo-boundary timer.
           ;; Every EJN-owned timer must already have been reclaimed.
           (should-not
            (cl-remove-if
             (lambda (timer) (eq (timer--function timer) #'undo-auto--boundary-timer))
             (cl-set-difference timer-list original-timers)))
           (should-not (cl-set-difference timer-idle-list original-idle-timers)))))))

(defun ejn-cc21-test--evaluate (cell code)
  "Queue CODE for source CELL and return its actual core ledger record."
  (goto-char (point-min))
  (search-forward (concat "# %% " cell))
  (let ((id (emacs-jupyter-notebook--evaluate-code
             code (emacs-jupyter-notebook--cell-key-for (line-beginning-position)))))
    (emacs-jupyter-notebook--execution-record id)))

(defun ejn-cc21-test--event (record event)
  "Deliver one correlated normalized EVENT to RECORD's real result panel."
  (emacs-jupyter-notebook-events-dispatch
   (list :buffer (current-buffer)
         :entry-handle (plist-get record :panel-entry)
         :request-id (plist-get record :id)
         :backend-request-id (plist-get record :backend-request-id)
         :panel-generation (plist-get record :generation))
   event))

(defun ejn-cc21-test--resume-context (session)
  "Install a minimal live tunnel recovery context retaining SESSION."
  (emacs-jupyter-notebook--cancel-auto-reconnect)
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (tunnel (make-pipe-process :name "ejn-cc21-recovered-tunnel" :noquery t))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'connect :origin-buffer (current-buffer)
                   :entry entry :profile '(:host "test.invalid")
                   :session-id (plist-get entry :session-id)
                   :tunnel-process tunnel
                   :resume-client session
                   :local-file (plist-get entry :local-connection-file)
                   :local-ports (plist-get entry :tunnel-ports)
                   :remote-ports (plist-get entry :remote-ports))))
    (setq emacs-jupyter-notebook--async-context context
          emacs-jupyter-notebook--tunnel-process tunnel)
    context))

(ert-deftest ejn-cc21-tunnel-loss-preserves-admitted-execution-and-fifo ()
  "A recoverable tunnel loss keeps A's correlation and never admits B or C."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (timer (plist-get first :timer))
           (second (ejn-cc21-test--evaluate "second" "second()"))
           (third (ejn-cc21-test--evaluate "third" "third()"))
           (entry (copy-tree emacs-jupyter-notebook--session-entry)))
      (should (= (length requests) 1))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (should (eq emacs-jupyter-notebook--client session))
      (should (eq emacs-jupyter-notebook--tunnel-suspended session))
      (should emacs-jupyter-notebook--tunnel-dead)
      (should (equal emacs-jupyter-notebook--execution-queue
                     (mapcar (lambda (record) (plist-get record :id))
                             (list first second third))))
      (should (eq first (emacs-jupyter-notebook--execution-record
                         (plist-get first :id))))
      (should (eq (plist-get first :state) 'dispatched))
      (should (plist-get first :backend-request-id))
      (should-not (memq timer timer-list))
      (should (eq (plist-get (ejn-panel-entry-snapshot
                             (plist-get first :panel-entry)) :status) 'running))
      (should (eq (plist-get second :state) 'queued))
      (should (eq (plist-get third :state) 'queued))
      (should (equal suspends (list session)))
      (should-not closes)
      (should (= scheduled 1))
      (should (equal entry emacs-jupyter-notebook--session-entry))
      (emacs-jupyter-notebook--tunnel-lost "duplicate tunnel event" session nil)
      (should (= scheduled 1))
      (should (equal suspends (list session)))
      (should (= (length requests) 1)))))

(ert-deftest ejn-cc21-offline-completion-presents-completed-and-resumes-fifo ()
  "Completion proved after an outage advances B exactly once after recovery."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()"))
           (third (ejn-cc21-test--evaluate "third" "third()"))
           (handle (plist-get first :panel-entry)))
      (ejn-cc21-test--event first '(:type stream :name "stdout" :text "before outage\n"))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (let ((context (ejn-cc21-test--resume-context session)))
        (ejn-cc21-test--event
         first '(:type truncation :text "[output may be missing during disconnection]\n"))
        (ejn-cc21-test--event first '(:type execute-reply :status "completed"))
        (ejn-cc21-test--event first '(:type status :execution-state "idle"))
        (should-not (emacs-jupyter-notebook--execution-record (plist-get first :id)))
        (should-not emacs-jupyter-notebook--execution-active-id)
        (should (equal emacs-jupyter-notebook--execution-queue
                       (list (plist-get second :id) (plist-get third :id))))
        (should (= (length requests) 1))
        (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status) 'completed))
        (should (eq (emacs-jupyter-notebook-fringe-state
                     (plist-get first :cell-key)) 'completed))
        (let* ((overlay (emacs-jupyter-notebook-fringe-overlay
                         (plist-get first :cell-key)))
               (before (overlay-get overlay 'before-string))
               (display (get-text-property 0 'display before)))
          (should (equal (car display) '(margin left-margin)))
          (should (string-prefix-p "✓" (cadr display))))
        (emacs-jupyter-notebook-panel-flush-now (plist-get handle :panel))
        (with-current-buffer (plist-get handle :panel)
          (should (string-match-p "completed" (buffer-string)))
          (should (string-match-p "before outage" (buffer-string)))
          (should (string-match-p "output may be missing" (buffer-string))))
        (emacs-jupyter-notebook--async-resume-client-finish context session)
        (should-not emacs-jupyter-notebook--tunnel-suspended)
        (should-not emacs-jupyter-notebook--tunnel-dead)
        (should (equal emacs-jupyter-notebook--execution-active-id (plist-get second :id)))
        (should (= (length requests) 2))
        (should (equal (gethash "code" (cadar requests)) "second()"))
        (should (eq (plist-get third :state) 'queued))
        ;; A stale resume callback and A's duplicate terminal events cannot
        ;; finish B, admit C, or replay A.
        (emacs-jupyter-notebook--async-resume-client-finish context session)
        (ejn-cc21-test--event first '(:type status :execution-state "idle"))
        (should (= (length requests) 2))
        (should (equal emacs-jupyter-notebook--execution-active-id (plist-get second :id)))))))

(ert-deftest ejn-cc21-running-cell-resumes-output-before-queued-cell-dispatch ()
  "A still-running cell retains its output entry and blocks its queued successor."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()"))
           (handle (plist-get first :panel-entry))
           (backend-id (plist-get first :backend-request-id)))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (emacs-jupyter-notebook--async-resume-client-finish
       (ejn-cc21-test--resume-context session) session)
      (should (equal backend-id (plist-get first :backend-request-id)))
      (should (= (length requests) 1))
      (should (timerp (plist-get first :timer)))
      (ejn-cc21-test--event first '(:type stream :name "stdout" :text "after recovery\n"))
      (ejn-cc21-test--event first '(:type execute-reply :status "ok" :execution-count 7))
      (should (= (length requests) 1))
      (ejn-cc21-test--event first '(:type status :execution-state "idle"))
      (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status) 'ok))
      (should (equal emacs-jupyter-notebook--execution-active-id (plist-get second :id)))
      (should (= (length requests) 2))
      (emacs-jupyter-notebook-panel-flush-now (plist-get handle :panel))
      (with-current-buffer (plist-get handle :panel)
        (should (string-match-p "after recovery" (buffer-string)))))))

(ert-deftest ejn-cc21-recovery-reuses-forwarded-ports-and-skips-metadata-rewrite ()
  "The surviving helper reconnects through its original five local endpoints."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()"))
           (entry emacs-jupyter-notebook--session-entry)
           probed started waited resume-success)
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
                 (lambda (context)
                   (setq probed context)
                   (emacs-jupyter-notebook--async-retrieve context)))
                ((symbol-function 'emacs-jupyter-notebook--start-tunnel)
                 (lambda (profile remote local session-id)
                   (setq started (list profile remote local session-id))
                   (make-pipe-process :name "ejn-cc21-pipeline-tunnel" :noquery t)))
                ((symbol-function 'emacs-jupyter-notebook--async-wait-tunnel-tick)
                 (lambda (context)
                   (setq waited context)
                   (emacs-jupyter-notebook--async-connect context)))
                ((symbol-function 'emacs-jupyter-notebook-backend-resume)
                 (lambda (client success _failure)
                   (should (eq client session))
                   (setq resume-success success)))
                ((symbol-function 'emacs-jupyter-notebook-connection-allocate-local-ports)
                 (lambda () (ert-fail "Recovery allocated different helper endpoints")))
                ((symbol-function 'emacs-jupyter-notebook-connection-write-file)
                 (lambda (&rest _args) (ert-fail "Recovery rewrote durable metadata")))
                ((symbol-function 'emacs-jupyter-notebook-connection-read-file)
                 (lambda (&rest _args) (ert-fail "Recovery unnecessarily read metadata")))
                ((symbol-function 'emacs-jupyter-notebook--async-retrieve-attempt)
                 (lambda (&rest _args) (ert-fail "Recovery unnecessarily ran SCP"))))
        (emacs-jupyter-notebook--begin-reconnect entry nil nil 'automatic)
        (should probed)
        (should (eq (plist-get probed :resume-client) session))
        (should (equal (plist-get probed :local-ports) (plist-get entry :tunnel-ports)))
        (should (equal (plist-get probed :remote-ports) (plist-get entry :remote-ports)))
        (should (equal (plist-get probed :local-file)
                       (plist-get entry :local-connection-file)))
        (should (eq probed waited))
        (should (eq (plist-get probed :phase) 'connect))
        (should resume-success)
        (should (equal (nth 1 started) (plist-get entry :remote-ports)))
        (should (equal (nth 2 started) (plist-get entry :tunnel-ports)))
        (should (equal (nth 3 started) (plist-get entry :session-id)))
        (should (eq first (emacs-jupyter-notebook--execution-record
                           (plist-get first :id))))
        (should (eq emacs-jupyter-notebook--client session))
        (should-not closes)
        (should (= (length requests) 1))
        (funcall resume-success 'cc21-resume nil)
        (should (eq (plist-get probed :phase) 'done))
        (should-not emacs-jupyter-notebook--tunnel-suspended)
        (should (= (length requests) 1))
        (ejn-cc21-test--event first '(:type execute-reply :status "ok"))
        (ejn-cc21-test--event first '(:type status :execution-state "idle"))
        (should (equal emacs-jupyter-notebook--execution-active-id (plist-get second :id)))
        (should (= (length requests) 2))
        (funcall resume-success 'cc21-resume nil)
        (should (= (length requests) 2))))))

(ert-deftest ejn-cc21-helper-death-during-recovery-still-marks-unknown-without-replay ()
  "A lost helper cannot recover request evidence merely by restoring SSH."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()"))
           (entry (copy-tree emacs-jupyter-notebook--session-entry)))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (let ((context (ejn-cc21-test--resume-context session)))
        (emacs-jupyter-notebook-backend-session-notify-transport-failure
         session "helper exited during recovery")
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--tunnel-suspended)
        (should-not emacs-jupyter-notebook--execution-active-id)
        (should-not emacs-jupyter-notebook--execution-queue)
        (should (eq (plist-get (ejn-panel-entry-snapshot
                               (plist-get first :panel-entry)) :status) 'outcome-unknown))
        (should (eq (plist-get (ejn-panel-entry-snapshot
                               (plist-get second :panel-entry)) :status) 'cancelled))
        (should (equal closes (list session)))
        (should (equal entry emacs-jupyter-notebook--session-entry))
        (emacs-jupyter-notebook--async-resume-client-finish context session)
        (ejn-cc21-test--event first '(:type execute-reply :status "completed"))
        (ejn-cc21-test--event first '(:type status :execution-state "idle"))
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--execution-queue)
        (should (= (length requests) 1))))))

(ert-deftest ejn-cc21-mode-disable-fences-late-recovery-and-keeps-durable-session ()
  "Disabling mode releases the suspended helper and every local timer."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (_second (ejn-cc21-test--evaluate "second" "second()"))
           (entry (copy-tree emacs-jupyter-notebook--session-entry)))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (let ((context (ejn-cc21-test--resume-context session))
            (reconnect-timer emacs-jupyter-notebook--reconnect-timer))
        (emacs-jupyter-notebook-mode -1)
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--tunnel-suspended)
        (should-not emacs-jupyter-notebook--execution-ledger)
        (should-not emacs-jupyter-notebook--reconnect-timer)
        (should-not (memq reconnect-timer timer-list))
        (should (equal entry emacs-jupyter-notebook--session-entry))
        (should (equal closes (list session)))
        (emacs-jupyter-notebook--async-resume-client-finish context session)
        (ejn-cc21-test--event first '(:type status :execution-state "idle"))
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--execution-queue)
        (should (= (length requests) 1))))))

(ert-deftest ejn-cc21-late-interrupt-grace-cannot-retire-suspended-execution ()
  "An already queued timeout callback cannot turn SSH recovery into helper loss."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()")))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--interrupt-active-execution)
                 #'ignore))
        (emacs-jupyter-notebook--evaluation-on-timeout (plist-get first :id)))
      (let* ((timer (plist-get first :interrupt-grace-timer))
             (callback (timer--function timer))
             (args (timer--args timer)))
        (should (eq (plist-get first :state) 'cancelling))
        (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
        (apply callback args)
        (emacs-jupyter-notebook--evaluation-on-timeout (plist-get first :id))
        (should (eq emacs-jupyter-notebook--client session))
        (should (eq emacs-jupyter-notebook--tunnel-suspended session))
        (should (eq first (emacs-jupyter-notebook--execution-record
                           (plist-get first :id))))
        (should (eq (plist-get second :state) 'queued))
        (should-not closes)
        (should (= (length requests) 1))))))

(ert-deftest ejn-cc21-failed-resuspend-cannot-skip-attempt-cleanup ()
  "A local suspend initiation failure still disposes the failed retry attempt."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (_second (ejn-cc21-test--evaluate "second" "second()"))
           (failures 0))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (let* ((context (ejn-cc21-test--resume-context session))
             (tunnel (plist-get context :tunnel-process))
             (timer (run-at-time 60 nil #'ignore))
             (overall (run-at-time 60 nil #'ignore)))
        (emacs-jupyter-notebook--async-put context :timer timer)
        (emacs-jupyter-notebook--async-put context :overall-timer overall)
        (emacs-jupyter-notebook--async-put
         context :error-callback (lambda (_context _reason) (cl-incf failures)))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-suspend)
                   (lambda (&rest _args) (error "helper unavailable"))))
          (emacs-jupyter-notebook--async-fail context "restored tunnel failed"))
        (should (= failures 1))
        (should-not (process-live-p tunnel))
        (should-not (memq timer timer-list))
        (should-not (memq overall timer-list))
        (should-not emacs-jupyter-notebook--async-context)
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--tunnel-suspended)
        (should-not emacs-jupyter-notebook--execution-queue)
        (should (eq (plist-get (ejn-panel-entry-snapshot
                               (plist-get first :panel-entry)) :status) 'outcome-unknown))
        (should (= (length requests) 1))))))

(ert-deftest ejn-cc21-failed-tunnel-attempt-retains-fifo-and-fences-old-success ()
  "A second recovery attempt retains A and cannot accept the first callback."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (second (ejn-cc21-test--evaluate "second" "second()")))
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (let* ((old (ejn-cc21-test--resume-context session))
             (old-tunnel (plist-get old :tunnel-process)))
        (emacs-jupyter-notebook--async-put
         old :error-callback
         (lambda (context reason)
           (emacs-jupyter-notebook--handle-reconnect-failure context reason nil)))
        (emacs-jupyter-notebook--async-fail old "temporary forward failure")
        (should-not (process-live-p old-tunnel))
        (should (eq emacs-jupyter-notebook--client session))
        (should (eq emacs-jupyter-notebook--tunnel-suspended session))
        (should (= scheduled 2))
        (should (= (length suspends) 2))
        (should-not closes)
        (should (= (length requests) 1))
        (let ((current (ejn-cc21-test--resume-context session)))
          (emacs-jupyter-notebook--async-resume-client-finish old session)
          (should (eq emacs-jupyter-notebook--async-context current))
          (should (eq emacs-jupyter-notebook--tunnel-suspended session))
          (should (= (length requests) 1))
          (emacs-jupyter-notebook--async-resume-client-finish current session)
          (should-not emacs-jupyter-notebook--tunnel-suspended)
          (should (eq first (emacs-jupyter-notebook--execution-record
                             (plist-get first :id))))
          (should (eq (plist-get second :state) 'queued))
          (ejn-cc21-test--event first '(:type execute-reply :status "completed"))
          (ejn-cc21-test--event first '(:type status :execution-state "idle"))
          (should (equal emacs-jupyter-notebook--execution-active-id (plist-get second :id)))
          (should (= (length requests) 2)))))))

(ert-deftest ejn-cc21-pending-input-is-not-transmitted-during-suspension ()
  "A submitted old stdin lease stays inert until the helper requests fresh input."
  (ejn-cc21-test--with-source
    (let* ((first (ejn-cc21-test--evaluate "first" "first()"))
           (request-id (plist-get first :id))
           (reply (emacs-jupyter-notebook--helper-input-reply
                   session request-id "cc21-wire-1" "input-before-outage"))
           inputs)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-input)
                 (lambda (client lease value &rest _args)
                   (push (list client lease value) inputs))))
        (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
        (funcall reply "cc21-offline-value")
        (should-not inputs)
        (should (= (length requests) 1))
        (should-not (string-match-p "cc21-offline-value" (format "%S" requests)))
        (emacs-jupyter-notebook--async-resume-client-finish
         (ejn-cc21-test--resume-context session) session)
        ;; The old closure is single-use even if a deferred UI callback repeats.
        (funcall reply "cc21-stale-after-resume")
        (should-not inputs)
        (let ((fresh (emacs-jupyter-notebook--helper-input-reply
                      session request-id "cc21-wire-1" "input-after-resume")))
          (funcall fresh "cc21-fresh-value")
          (funcall fresh "cc21-duplicate-value"))
        (should (equal inputs
                       (list (list session '("cc21-wire-1" . "input-after-resume")
                                   "cc21-fresh-value"))))))))

(ert-deftest ejn-cc21-transition-entry-is-rejected-before-retained-helper-reuse ()
  "A durable lifecycle transition fences recovery even when identity matches."
  (ejn-cc21-test--with-source
    (let* ((_first (ejn-cc21-test--evaluate "first" "first()"))
           (entry (plist-put (copy-tree emacs-jupyter-notebook--session-entry)
                             :transition-kind 'restart))
           failures)
      (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--begin-tunnel-recovery)
                 (lambda (&rest _args)
                   (ert-fail "Retained helper bypassed the lifecycle transition")))
                ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
                 (lambda (&rest _args)
                   (ert-fail "A transition entry admitted remote recovery"))))
        (emacs-jupyter-notebook--begin-reconnect
         entry nil (lambda (context _reason) (push context failures)) 'automatic)
        (should (= (length failures) 1))
        (should (eq (plist-get (car failures) :error-kind) 'transition-active))
        (should (eq (plist-get (car failures) :phase) 'error))
        (should-not (plist-get (car failures) :resume-client))
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should (= (length requests) 1))))))

(ert-deftest ejn-cc21-changed-remote-identity-or-ports-disposes-retained-helper ()
  "Matching session names cannot reuse sockets tied to different remote metadata."
  (dolist (change '(:remote-host :remote-pid :remote-connection-file
                   :tunnel-ports :remote-ports))
    (ert-info ((format "changed recovery metadata: %s" change))
      (ejn-cc21-test--with-source
        (let* ((_first (ejn-cc21-test--evaluate "first" "first()"))
               (_second (ejn-cc21-test--evaluate "second" "second()"))
               (entry (copy-tree emacs-jupyter-notebook--session-entry))
               probed)
          (pcase change
            (:remote-host (setq entry (plist-put entry change "different.invalid")))
            (:remote-pid (setq entry (plist-put entry change 4343)))
            (:remote-connection-file
             (let ((path "/different-cache/kernel-cc21-session.json"))
               (setq entry (plist-put entry change path))
               (setq entry (plist-put entry :remote-pid-sidecar
                                      "/different-cache/kernel-cc21-session.pid"))
               (setq entry (plist-put entry :connection-file-tokens (list path)))))
            (_ (setq entry (plist-put entry change
                                      (plist-put (plist-get entry change)
                                                 :shell_port 43000)))))
          (should (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry))
          (emacs-jupyter-notebook--tunnel-lost "SSH connection closed" session nil)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-selected-backend)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--begin-tunnel-recovery)
                     (lambda (&rest _args)
                       (ert-fail "Changed metadata reused the retained helper")))
                    ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
                     (lambda (context) (setq probed context))))
            (emacs-jupyter-notebook--begin-reconnect entry nil nil 'automatic)
            (should probed)
            (should-not (plist-get probed :resume-client))
            (should (equal (plist-get probed :entry) entry))
            (should (equal closes (list session)))
            (should-not emacs-jupyter-notebook--client)
            (should-not emacs-jupyter-notebook--tunnel-suspended)
            ;; The admitted first execution is never replayed.  The second
            ;; was still unsent, so acquisition preserves its exact FIFO id.
            (should (equal emacs-jupyter-notebook--execution-queue
                           (list (plist-get _second :id))))
            (should (= (length requests) 1))))))))

(provide 'emacs-jupyter-notebook-tunnel-recovery-tests)
;;; emacs-jupyter-notebook-tunnel-recovery-tests.el ends here
