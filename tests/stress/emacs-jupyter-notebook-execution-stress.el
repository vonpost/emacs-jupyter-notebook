;;; emacs-jupyter-notebook-execution-stress.el --- AG3 execution boundaries -*- lexical-binding: t; -*-

;; This is intentionally loaded after `emacs-jupyter-notebook-stress'.  The
;; real fixture owns one direct kernel; the table below drives only the core
;; ledger states where a kernel cannot add evidence (pre-write and late-event
;; boundaries).  It never reimplements the production state machine.

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-stress)

(defvar ejn-ag3-execution--token-sequence 0)

(defun ejn-ag3-execution--token (prefix)
  "Return one deterministic-within-run Python identifier for PREFIX."
  (format "ag3_%s_%d" prefix (cl-incf ejn-ag3-execution--token-sequence)))

(defun ejn-ag3-execution--append-public-cells (source cells)
  "Append CELLS to SOURCE before taking its source-pristine baseline.

The cells are test fixture setup.  Every assertion below compares against the
post-setup contents and modified flag, so the test still proves that public
evaluation itself never mutates a source buffer.
"
  (with-current-buffer source
    (goto-char (point-max))
    (dolist (cell cells)
      (insert "\n# %%\n" cell "\n"))
    (set-buffer-modified-p nil)
    (cons (buffer-string) (buffer-modified-p))))

(defun ejn-ag3-execution--send-public-cell (source fragment)
  "Invoke the public send-cell command for SOURCE cell containing FRAGMENT."
  (with-current-buffer source
    (ejn-ag2--send-cell-containing fragment)))

(defun ejn-ag3-execution--entry-status (source fragment)
  "Return the rendered-panel status for SOURCE entry containing FRAGMENT."
  (let ((entry (ejn-ag2--entry-with-code source fragment)))
    (and entry (plist-get entry :status))))

(defun ejn-ag3-execution--metric (name &rest facts)
  "Write optional AG3 metrics when running under the AG3 supervisor."
  (when (getenv "EJN_AG3_METRICS")
    (apply #'ejn-ag3--metric name facts)))

(defun ejn-ag3-execution--admitted-active-p ()
  "Return the current real helper ledger record once its write is admitted."
  (let* ((id emacs-jupyter-notebook--execution-active-id)
         (record (and id (emacs-jupyter-notebook--execution-record id)))
         (client emacs-jupyter-notebook--client))
    (and record client
         (eq (plist-get record :state) 'dispatched)
         (timerp (plist-get record :timer))
         (emacs-jupyter-notebook-helper-backend-ledger-id-admitted-p
          client id (plist-get record :backend-request-id))
         record)))

(ert-deftest ejn-ag3-execution-real-fifo-crash-is-unknown-and-never-replays ()
  "Two public sends are FIFO; a helper crash cannot replay ambiguous work.

The first request has crossed the actual helper write/admission boundary.  The
second is only queued.  Killing the real helper must leave the first request
outcome-unknown, cancel the second before dispatch, and leave its kernel-side
counter at zero after a same-kernel reattach.  Only a fresh public send may
increment that counter.
"
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source _ignored-baseline _ignored-modified)
    (let* ((first-key (ejn-ag3-execution--token "first"))
           (second-key (ejn-ag3-execution--token "second"))
           (first-fragment (format "globals()['%s']" first-key))
           (second-fragment (format "globals()['%s']" second-key))
           (assert-none-fragment (format "assert 0 <= globals().get('%s', 0) <= 1" first-key))
           (assert-once-fragment (format "assert globals().get('%s', 0) == 1" second-key))
           (first-code
            (format "import time\ntime.sleep(1.2)\nglobals()['%s'] = globals().get('%s', 0) + 1"
                    first-key first-key))
           (second-code
            (format "globals()['%s'] = globals().get('%s', 0) + 1"
                    second-key second-key))
           (assert-none
            (format "assert 0 <= globals().get('%s', 0) <= 1 and globals().get('%s', 0) == 0"
                    first-key second-key))
           (assert-once
            (format "assert globals().get('%s', 0) == 1 and 0 <= globals().get('%s', 0) <= 1"
                    second-key first-key))
           (snapshot
            (ejn-ag3-execution--append-public-cells
             source (list first-code second-code assert-none assert-once)))
           (baseline (car snapshot))
           (modified (cdr snapshot))
           (ticks 0)
           (canary (run-at-time 0 0.05 (lambda () (cl-incf ticks))))
           first-id second-id)
      (unwind-protect
          (progn
            ;; These are intentionally back-to-back public commands.  The
            ;; helper/kernel are real; no send or completion callback is
            ;; substituted.
            (ejn-ag3-execution--send-public-cell source first-fragment)
            (setq first-id emacs-jupyter-notebook--execution-active-id)
            (should first-id)
            (ejn-ag3-execution--send-public-cell source second-fragment)
            (setq second-id (car (last emacs-jupyter-notebook--execution-queue)))
            (should (and second-id (/= first-id second-id)))
            (let ((queued (emacs-jupyter-notebook--execution-record second-id)))
              (should (eq (plist-get queued :state) 'queued))
              ;; This is the critical anti-wedge invariant: B cannot time out
              ;; while it has not reached the backend.
              (should-not (timerp (plist-get queued :timer))))
            (ejn-ag2--await-phase
             "AG3 real helper admission"
             #'ejn-ag3-execution--admitted-active-p 6)
            (let ((active (emacs-jupyter-notebook--execution-record first-id)))
              (should (eq (plist-get active :state) 'dispatched))
              (should (timerp (plist-get active :timer))))
            ;; The live helper adapter mapping is the post-write evidence.
            ;; Destruction therefore has to classify A as ambiguous, while B
            ;; has no dispatch evidence and must not be replayed.
            (let* ((client emacs-jupyter-notebook--client)
                   (state (emacs-jupyter-notebook-backend-session-data client))
                   (helper (emacs-jupyter-notebook-helper-backend-state-helper state))
                   (process (emacs-jupyter-notebook-helper-session-process helper)))
              (should (process-live-p process))
              (delete-process process))
            (ejn-ag2--await-phase
             "AG3 helper death transition"
             (lambda () (null emacs-jupyter-notebook--client)) 6)
            (should (eq (ejn-ag3-execution--entry-status source first-fragment)
                        'outcome-unknown))
            (should (eq (ejn-ag3-execution--entry-status source second-fragment)
                        'cancelled))
            ;; Leave the kernel enough time to finish a request which may
            ;; already have begun.  Reattachment itself must not resend either
            ;; user request.
            (ejn-ag3--drain-for 1.5)
            (let ((state (ejn-ag3--bridge-state)))
              (ejn-ag2--copy-connection state local-file)
              (ejn-ag2--attach local-file state))
            (ejn-ag3--drain-for 0.3)
            (ejn-ag3-execution--send-public-cell source assert-none-fragment)
            (ejn-ag2--await-phase
             "AG3 no automatic replay"
             (lambda () (ejn-ag2--entry-terminal-p source assert-none-fragment)) 10)
            (should (eq (ejn-ag3-execution--entry-status source assert-none-fragment) 'ok))
            ;; The only permitted retry is a new public command.  The exact
            ;; kernel-side counter makes accidental queued replay observable.
            (ejn-ag3-execution--send-public-cell source second-fragment)
            (ejn-ag2--await-phase
             "AG3 explicit second send"
             (lambda ()
               (let ((entries (cl-remove-if-not
                               (lambda (entry)
                                 (string-match-p (regexp-quote second-fragment)
                                                 (plist-get entry :code)))
                               (ejn-ag2--panel-entries source))))
                 (and (>= (length entries) 2)
                      (eq (plist-get (car (last entries)) :status) 'ok))))
             10)
            (ejn-ag3-execution--send-public-cell source assert-once-fragment)
            (ejn-ag2--await-phase
             "AG3 exact-once counter"
             (lambda () (ejn-ag2--entry-terminal-p source assert-once-fragment)) 10)
            (should (eq (ejn-ag3-execution--entry-status source assert-once-fragment) 'ok))
            (ejn-ag2--assert-source-pristine source baseline modified)
            (should (>= ticks 20))
            (ejn-ag3-execution--metric
             "execution-real-boundary"
             (cons "canary_ticks" ticks)
             (cons "first_id" first-id)
             (cons "second_id" second-id)
             (cons "first_outcome" "outcome-unknown")
             (cons "second_outcome" "cancelled")))
        (cancel-timer canary)))))

(ert-deftest ejn-ag3-execution-real-second-timeout-begins-at-dispatch ()
  "Two rapid public sends complete FIFO, and B's timer starts only at dispatch."
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source _ignored-baseline _ignored-modified)
    (let* ((first-key (ejn-ag3-execution--token "fifo_first"))
           (second-key (ejn-ag3-execution--token "fifo_second"))
           (first-fragment (format "globals()['%s']" first-key))
           (second-fragment (format "globals()['%s']" second-key))
           (assert-fragment (format "assert globals().get('%s', 0) == 1" first-key))
           (first-code
            (format "import time\ntime.sleep(0.45)\nglobals()['%s'] = globals().get('%s', 0) + 1"
                    first-key first-key))
           (second-code
            (format "import time\ntime.sleep(0.45)\nglobals()['%s'] = globals().get('%s', 0) + 1"
                    second-key second-key))
           (assert-code
            (format "assert globals().get('%s', 0) == 1 and globals().get('%s', 0) == 1"
                    first-key second-key))
           (snapshot
            (ejn-ag3-execution--append-public-cells
             source (list first-code second-code assert-code)))
           (baseline (car snapshot))
           (modified (cdr snapshot))
           (ticks 0)
           (canary (run-at-time 0 0.05 (lambda () (cl-incf ticks))))
           first-id second-id second-state second-timer)
      (unwind-protect
          (progn
            (ejn-ag3-execution--send-public-cell source first-fragment)
            (setq first-id emacs-jupyter-notebook--execution-active-id)
            (ejn-ag3-execution--send-public-cell source second-fragment)
            (setq second-id (car (last emacs-jupyter-notebook--execution-queue)))
            (should (and first-id second-id (/= first-id second-id)))
            (let ((queued (emacs-jupyter-notebook--execution-record second-id)))
              (should (eq (plist-get queued :state) 'queued))
              (should-not (timerp (plist-get queued :timer))))
            ;; This advice observes the actual production dispatch return.  It
            ;; reads the ledger rather than its argument because the dispatcher
            ;; deliberately replaces the record plist as it installs the timer.
            (let ((observer
                   (lambda (record)
                     (when (= (plist-get record :id) second-id)
                       (let ((current
                              (emacs-jupyter-notebook--execution-record second-id)))
                         (setq second-state (plist-get current :state)
                               second-timer (plist-get current :timer)))))))
              (advice-add #'emacs-jupyter-notebook--execution-dispatch :after observer)
              (unwind-protect
                  (ejn-ag2--await-phase
                   "AG3 FIFO terminality"
                   (lambda ()
                     (and (ejn-ag2--entry-terminal-p source first-fragment)
                          (ejn-ag2--entry-terminal-p source second-fragment)))
                   10)
                (advice-remove #'emacs-jupyter-notebook--execution-dispatch observer)))
            (should (eq second-state 'dispatched))
            (should (timerp second-timer))
            (should (eq (ejn-ag3-execution--entry-status source first-fragment) 'ok))
            (should (eq (ejn-ag3-execution--entry-status source second-fragment) 'ok))
            (ejn-ag3-execution--send-public-cell source assert-fragment)
            (ejn-ag2--await-phase
             "AG3 FIFO exact-once assertion"
             (lambda () (ejn-ag2--entry-terminal-p source assert-fragment)) 10)
            (should (eq (ejn-ag3-execution--entry-status source assert-fragment) 'ok))
            (ejn-ag2--assert-source-pristine source baseline modified)
            (should (>= ticks 15))
            (ejn-ag3-execution--metric
             "execution-fifo"
             (cons "canary_ticks" ticks)
             (cons "first_id" first-id)
             (cons "second_id" second-id)
             (cons "second_timer_at_dispatch" t)))
        (cancel-timer canary)))))

(defun ejn-ag3-execution--case-context (request-id backend-id generation)
  "Build one exact core event context for REQUEST-ID/BACKEND-ID/GENERATION."
  (list :request-id request-id :backend-request-id backend-id
        :panel-generation generation))

(defun ejn-ag3-execution--apply-boundary-events (record events)
  "Apply real terminal EVENTS to RECORD using its captured ownership identity."
  (let ((context (ejn-ag3-execution--case-context
                  (plist-get record :id) (plist-get record :backend-request-id)
                  (plist-get record :generation))))
    (dolist (event events)
      (emacs-jupyter-notebook--execution-note-event context event))))

(defun ejn-ag3-execution--run-boundary-case (case)
  "Run one CASE through the real ledger and transport-loss transition.

CASE is `(NAME STATE ADMITTED EVENTS EXPECTED)'.  The only stubs are external
close/reconnect hooks: there is no real local process in these reducer-only
states.  Admission still comes from the actual helper request-map API, and all
state transitions are production functions.
"
  (pcase-let* ((`(,name ,state ,admitted ,events ,expected) case)
               (source (current-buffer))
               (panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel (list "ag3-boundary.py" name)
                                              (symbol-name name)))
               (generation (plist-get handle :generation))
               (request-id 4101)
               (backend-id 8101)
               (mapping (make-hash-table :test #'equal))
               (adapter-state
                (emacs-jupyter-notebook-helper-backend--make-state :request-map mapping))
               (client (emacs-jupyter-notebook-backend-session-create nil source))
               (record (list :id request-id :state state :panel-entry handle
                             :backend-request-id backend-id :generation generation
                             :reply-seen nil :idle-seen nil))
               (scheduled 0))
    (unwind-protect
        (progn
          (setf (emacs-jupyter-notebook-backend-session-backend client) 'helper
                (emacs-jupyter-notebook-backend-session-data client) adapter-state)
          (when admitted
            (puthash "ag3-boundary-wire"
                     (list :ledger-id request-id :backend-request-id backend-id
                           :panel-generation generation)
                     mapping))
          (emacs-jupyter-notebook--execution-put record)
          (setq emacs-jupyter-notebook--client client
                emacs-jupyter-notebook--execution-active-id request-id
                emacs-jupyter-notebook--execution-queue (list request-id))
          (ejn-ag3-execution--apply-boundary-events record events)
          ;; A fully terminal record was removed by the actual reducer before
          ;; this loss.  Every other case remains a live request when the
          ;; production transport-loss routine classifies it.
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                     (lambda (&rest _) nil))
                    ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                     (lambda () (cl-incf scheduled)))
                    ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel) #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--completion-cancel-idle-timer)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore))
            (emacs-jupyter-notebook--transport-lost (symbol-name name) client nil))
          (should (= scheduled 1))
          (should (eq (plist-get (car (ejn-ag2--panel-entries source)) :status) expected))
          (should-not (emacs-jupyter-notebook--execution-record request-id))
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should-not emacs-jupyter-notebook--execution-queue)
          ;; The terminal case is the regression guard for a reply/idle pair
          ;; followed by duplicate/late callbacks after its wire id was retired.
          (when (eq name 'terminal-late-event)
            (let ((before (ejn-panel-entry-text handle))
                  (context (ejn-ag3-execution--case-context request-id backend-id generation)))
              (emacs-jupyter-notebook--execution-note-event
               context '(:type execute-reply :status "ok" :execution-count 99))
              (emacs-jupyter-notebook--execution-note-event
               context '(:type status :execution-state "idle"))
              (should (equal
                       (emacs-jupyter-notebook-events-dispatch
                        (append (list :buffer source :entry-handle handle) context)
                        '(:type stream :name "stdout" :text "late"))
                       '((:action ignore))))
              (should (equal (ejn-panel-entry-text handle) before))
              (should (eq (plist-get (car (ejn-ag2--panel-entries source)) :status) 'ok)))))
      (when (buffer-live-p panel)
        (ejn-panel-clear-all panel)
        (kill-buffer panel))
      (when (emacs-jupyter-notebook-helper-backend-state-p adapter-state)
        (emacs-jupyter-notebook-helper-backend--dispose adapter-state "AG3 boundary cleanup")))))

(ert-deftest ejn-ag3-execution-boundary-table-preserves-admission-and-terminality ()
  "Transport loss at every execution boundary has one finite, exact outcome."
  (setq ejn-ag3--started-at (float-time))
  (with-temp-buffer
    (insert "# ordinary source text remains untouched\n")
    (set-buffer-modified-p nil)
    (let ((baseline (buffer-string))
          (modified (buffer-modified-p))
          ;; NAME, core state, helper-map admission, terminal events, result.
          ;; `reply-before-idle' and `idle-before-reply' remain ambiguous
          ;; because neither ordering alone settles the real ledger.
          (cases
           '((queued-before-dispatch queued nil nil cancelled)
             (pre-write-not-admitted dispatched nil nil cancelled)
             (admission-post-write dispatched t nil outcome-unknown)
             (reply-before-idle dispatched t
                                ((:type execute-reply :status "ok" :execution-count 1))
                                outcome-unknown)
             (idle-before-reply dispatched t
                                ((:type status :execution-state "idle"))
                                outcome-unknown)
             (terminal-late-event dispatched t
                                  ((:type execute-reply :status "ok" :execution-count 1)
                                   (:type status :execution-state "idle"))
                                  ok))))
      (dolist (case cases) (ejn-ag3-execution--run-boundary-case case))
      (should (equal (buffer-string) baseline))
      (should (eq (buffer-modified-p) modified))
      (ejn-ag3-execution--metric "execution-boundary-table"
                                 (cons "cases" (length cases))
                                 (cons "late_events" 3)))))

(provide 'emacs-jupyter-notebook-execution-stress)
;;; emacs-jupyter-notebook-execution-stress.el ends here
