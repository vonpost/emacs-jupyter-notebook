;;; emacs-jupyter-notebook-backend-tests.el --- Async backend contract tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-events)
(require 'emacs-jupyter-notebook-jupyter)

(defvar emacs-jupyter-notebook--client)
(declare-function emacs-jupyter-notebook-restart-kernel
                  "emacs-jupyter-notebook" ())
(declare-function emacs-jupyter-notebook--inject-viewer-formatter
                  "emacs-jupyter-notebook" (&optional client))

(defconst ejn-ei1-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the EI1 backend contract tests.")

(defun ejn-ei1-test--run-timers ()
  "Let zero-delay backend callback timers run in a bounded test turn."
  (accept-process-output nil 0.01))

(defmacro ejn-ei1-test-with-fake-backend (binding &rest body)
  "Run BODY with DISPATCH installed as the selected fake backend dispatcher."
  (declare (indent 1) (debug t))
  (let ((dispatch (car binding)))
    `(let ((emacs-jupyter-notebook-backend 'ei1-fake)
           (emacs-jupyter-notebook-backend-implementations
            (cons (cons 'ei1-fake ,dispatch)
                  emacs-jupyter-notebook-backend-implementations)))
       ,@body)))

(ert-deftest ejn-ei1-contract-returns-id-before-sync-dispatch-callback ()
  "A synchronous fake reply cannot re-enter the caller or event sink."
  (let (callback event request-id)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request _operation _payload success _failure emit)
           (funcall emit '(:type fake-event))
           (funcall success 'ok)))
      (let ((session (emacs-jupyter-notebook-backend-session-create
                      (lambda (_session value) (setq event value)))))
        (setq request-id
              (emacs-jupyter-notebook-backend-aux
               session 'kernel-info nil
               (lambda (id value) (setq callback (list id value)))
               #'ignore))
        (should (integerp request-id))
        (should-not callback)
        (should-not event)
        (ejn-ei1-test--run-timers)
        (should (equal callback (list request-id 'ok)))
        (should (equal event '(:type fake-event)))))))

(ert-deftest ejn-ei1-event-sink-defers-only-reentrant-emits ()
  "Async event floods do not become an unbounded queue of delivery timers."
  (let (emit seen inside)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request _operation _payload _success _failure upstream-emit)
           (setq emit upstream-emit)
           (funcall emit '(:type during-dispatch))))
      (let ((session (emacs-jupyter-notebook-backend-session-create
                      (lambda (_session event)
                        (push (list inside event) seen)))))
        (emacs-jupyter-notebook-backend-aux session 'kernel-info nil #'ignore #'ignore)
        ;; The reentrant event is deferred until the public operation returns.
        (should-not seen)
        (ejn-ei1-test--run-timers)
        (should (= 1 (length seen)))
        ;; Events from a later backend drain run at the upstream call site;
        ;; they do not allocate one timer per frame.
        (setq seen nil)
        (dotimes (index 100)
          (setq inside index)
          (funcall emit (list :type 'async :index index))
          (should (equal (caar seen) index)))
        (should-not (emacs-jupyter-notebook-backend-session-timers session))))))

(ert-deftest ejn-ei1-event-sink-keeps-outer-dispatch-reentrant-guard ()
  "Nested dispatch cannot clear the outer dispatch-depth guard early."
  (let (seen)
    (ejn-ei1-test-with-fake-backend
        ((lambda (session _request operation _payload success _failure emit)
           (pcase operation
             (`(aux . outer)
              (emacs-jupyter-notebook-backend-aux
               session 'inner nil #'ignore #'ignore)
              (funcall emit '(:type outer-event))
              (funcall success 'outer))
             (`(aux . inner) (funcall success 'inner)))))
      (let ((session (emacs-jupyter-notebook-backend-session-create
                      (lambda (_session event) (push event seen)))))
        (emacs-jupyter-notebook-backend-aux session 'outer nil #'ignore #'ignore)
        (should-not seen)
        (should (= 0 (or (emacs-jupyter-notebook-backend-session-dispatch-depth session)
                          0)))
        (ejn-ei1-test--run-timers)
        (should (equal seen '((:type outer-event))))))))

(ert-deftest ejn-ei1-transport-failure-sink-is-owner-bound-and-exactly-once ()
  "Session-level failure survives terminal requests without duplicate delivery."
  (let ((owner (generate-new-buffer " *ejn-ei1-failure-owner*")) seen)
    (unwind-protect
        (let ((session
               (emacs-jupyter-notebook-backend-session-create
                nil owner
                (lambda (failed-session reason)
                  (push (list (current-buffer) failed-session reason) seen)))))
          (emacs-jupyter-notebook-backend-session-notify-transport-failure
           session "lost")
          (emacs-jupyter-notebook-backend-session-notify-transport-failure
           session "duplicate")
          (should (equal seen (list (list owner session "lost")))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest ejn-ei1-callbacks-and-events-run-in-the-session-owner ()
  "Timer and transport callback context cannot leak across source buffers."
  (let ((owner (generate-new-buffer " *ejn-ei1-owner-context*"))
        (other (generate-new-buffer " *ejn-ei1-other-context*"))
        emit callback-buffer event-buffer)
    (unwind-protect
        (ejn-ei1-test-with-fake-backend
            ((lambda (_session _request _operation _payload success _failure send)
               (setq emit send)
               (funcall success 'ok)))
          (let ((session
                 (with-current-buffer owner
                   (emacs-jupyter-notebook-backend-session-create
                    (lambda (_session _event) (setq event-buffer (current-buffer)))
                    owner))))
            (with-current-buffer owner
              (emacs-jupyter-notebook-backend-aux
               session 'kernel-info nil
               (lambda (&rest _ignored) (setq callback-buffer (current-buffer)))
               #'ignore))
            (with-current-buffer other
              (ejn-ei1-test--run-timers)
              (funcall emit '(:type async)))
            (should (eq callback-buffer owner))
            (should (eq event-buffer owner))))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (buffer-live-p other) (kill-buffer other)))))

(ert-deftest ejn-ei1-contract-covers-every-operation-shape ()
  "Every public backend operation has an id, terminal callback, and payload."
  (let (seen callbacks)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session request operation payload success _failure _emit)
           (push (list (emacs-jupyter-notebook-backend-request-id request)
                       operation payload)
                 seen)
           (funcall success operation)))
      (with-temp-buffer
        (let ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer))))
          (cl-labels ((record (id value) (push (list id value) callbacks)))
            (emacs-jupyter-notebook-backend-connect session "conn.json" #'record #'ignore)
            (emacs-jupyter-notebook-backend-execute session "x" '(:silent t) #'record #'ignore)
            (emacs-jupyter-notebook-backend-aux session 'complete
                                                '(:code "x" :cursor-pos 1) #'record #'ignore)
            (emacs-jupyter-notebook-backend-aux session 'inspect
                                                '(:code "x" :cursor-pos 1 :detail 0) #'record #'ignore)
            (emacs-jupyter-notebook-backend-aux session 'is-complete
                                                '(:code "x") #'record #'ignore)
            (emacs-jupyter-notebook-backend-aux session 'kernel-info nil #'record #'ignore)
            (dolist (operation '(interrupt restart shutdown))
              (emacs-jupyter-notebook-backend-control session operation nil #'record #'ignore))
            (emacs-jupyter-notebook-backend-input session "stdin-1" "answer" #'record #'ignore)
            (ejn-ei1-test--run-timers)
            (setq seen (nreverse seen))
            (should (= 10 (length seen)))
            (should (equal (mapcar #'cadr seen)
                           '(connect execute (aux . complete) (aux . inspect)
                             (aux . is-complete) (aux . kernel-info)
                             (control . interrupt) (control . restart)
                             (control . shutdown) input)))
            (should (= 10 (length callbacks)))
            (should (cl-every #'integerp (mapcar #'car callbacks)))
            (should (= 10 (length (delete-dups (mapcar #'car callbacks)))))
            (should (equal (nth 2 (nth 0 seen)) "conn.json"))
            (should (equal (nth 2 (nth 1 seen))
                           '(:code "x" :options (:silent t))))
            (should (equal (nth 2 (car (last seen)))
                           '(:request-id "stdin-1" :value "answer")))))))))

(ert-deftest ejn-ei1-contract-drops-late-callback-after-buffer-kill ()
  "A killed owner buffer consumes, but never delivers, a late fake reply."
  (let (success)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request _operation _payload _success _failure _emit)
           ;; Keep the dispatcher callback for delivery after owner retirement.
           nil))
      (let* ((buffer (generate-new-buffer " *ejn-ei1-owner*"))
             (session (with-current-buffer buffer
                        (emacs-jupyter-notebook-backend-session-create nil buffer)))
             (request-id (emacs-jupyter-notebook-backend-aux
                          session 'kernel-info nil
                          (lambda (id value) (setq success (list id value)))
                          #'ignore))
             (request (gethash request-id
                               (emacs-jupyter-notebook-backend-session-requests session))))
        (unwind-protect
            (progn
              (kill-buffer buffer)
              (emacs-jupyter-notebook-backend--finish request 'late nil)
              (ejn-ei1-test--run-timers)
              (should-not success)
              (should (emacs-jupyter-notebook-backend-request-terminal request))
              (should (= 0 (hash-table-count
                            (emacs-jupyter-notebook-backend-session-requests session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest ejn-ei1-contract-rejects-raw-legacy-clients ()
  "Every public operation requires one persistent opaque session."
  (should-error
   (emacs-jupyter-notebook-backend-execute
    'raw-legacy-client "x" nil #'ignore #'ignore)
   :type 'error)
  (should-error
   (emacs-jupyter-notebook-backend-close-local
    'raw-legacy-client #'ignore #'ignore)
   :type 'error))

(ert-deftest ejn-ei1-attached-state-is-explicit-and-not-liveness ()
  "A newly allocated session is not usable for busy fallback until attached."
  (ejn-ei1-test-with-fake-backend (#'ignore)
    (let ((session (emacs-jupyter-notebook-backend-session-create)))
      (should-not (emacs-jupyter-notebook-backend-session-attached-p session))
      (should (eq (emacs-jupyter-notebook-backend-session-mark-attached session)
                  session))
      (should (emacs-jupyter-notebook-backend-session-attached-p session)))))

(ert-deftest ejn-ei1-installed-state-is-explicit-and-local-only ()
  "Core adoption is distinct from attachment and clears on local close."
  (ejn-ei1-test-with-fake-backend
      ((lambda (_session _request operation _payload success _failure _emit)
         (when (eq operation 'close-local) (funcall success nil))))
    (let ((session (emacs-jupyter-notebook-backend-session-create)))
      (should-error (emacs-jupyter-notebook-backend-session-mark-installed session))
      (emacs-jupyter-notebook-backend-session-mark-attached session)
      (should (eq (emacs-jupyter-notebook-backend-session-mark-installed session)
                  session))
      (should (emacs-jupyter-notebook-backend-session-installed-p session))
      (emacs-jupyter-notebook-backend-close-local session #'ignore #'ignore)
      (ejn-ei1-test--run-timers)
      (should-not (emacs-jupyter-notebook-backend-session-installed-p session)))))

(ert-deftest ejn-ei1-contract-superseded-session-drops-late-callback ()
  "Closing A before creating B prevents A's retained callback reaching B."
  (let (late-success (close-calls 0))
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload success _failure _emit)
           (pcase operation
             ('close-local (cl-incf close-calls) (funcall success 'closed))
             (_ nil))))
      (with-temp-buffer
        (let* ((a (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
               (request-id (emacs-jupyter-notebook-backend-aux
                            a 'kernel-info nil
                            (lambda (_id value) (setq late-success value)) #'ignore))
               (request (gethash request-id
                                 (emacs-jupyter-notebook-backend-session-requests a))))
          (emacs-jupyter-notebook-backend-close-local a #'ignore #'ignore)
          (let ((b (emacs-jupyter-notebook-backend-session-create nil (current-buffer))))
            (should-not (eq a b))
            (emacs-jupyter-notebook-backend--finish request 'late nil)
            (ejn-ei1-test--run-timers)
            (should (= close-calls 1))
            (should (emacs-jupyter-notebook-backend-session-closed a))
            (should-not late-success)))))))

(ert-deftest ejn-ei1-close-local-is-exact-once-and-never-shutdown ()
  "Close is idempotent, defers its callback, and cannot issue remote control."
  (let ((shutdown nil) close-callbacks)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload success _failure _emit)
           (pcase operation
             ('close-local
              ;; Deliberately reply twice: consumer still gets one terminal.
              (funcall success 'first)
              (funcall success 'second))
             (`(control . shutdown) (setq shutdown t)))))
      (with-temp-buffer
        (let ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer))))
          (setf (emacs-jupyter-notebook-backend-session-data session) 'local-transport)
          (emacs-jupyter-notebook-backend-session-mark-attached session)
          (emacs-jupyter-notebook-backend-close-local
           session (lambda (id value) (push (list id value) close-callbacks)) #'ignore)
          (should-not close-callbacks)
          (emacs-jupyter-notebook-backend-close-local
           session (lambda (id value) (push (list id value) close-callbacks)) #'ignore)
          (ejn-ei1-test--run-timers)
          (should (= 2 (length close-callbacks)))
          (should-not shutdown)
          (should-not (emacs-jupyter-notebook-backend-session-data session))
          (should-not (emacs-jupyter-notebook-backend-session-attached session))
          (should-not
           (emacs-jupyter-notebook-backend-session-mark-attached session))
          (should (emacs-jupyter-notebook-backend-session-closed session)))))))

(ert-deftest ejn-ei1-close-local-preserves-delayed-failure ()
  "An asynchronous close failure cannot be overwritten by fabricated success."
  (let (fail errors successes)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload _success failure _emit)
           (when (eq operation 'close-local)
             (setq fail failure))))
      (let ((session (emacs-jupyter-notebook-backend-session-create)))
        (emacs-jupyter-notebook-backend-close-local
         session
         (lambda (&rest value) (push value successes))
         (lambda (&rest value) (push value errors)))
        (should (functionp fail))
        (should-not successes)
        (should-not errors)
        (funcall fail "close failed")
        (ejn-ei1-test--run-timers)
        (should-not successes)
        (should (equal (cadar errors) "close failed"))))))

(ert-deftest ejn-ei1-close-local-has-a-finite-acknowledgement-deadline ()
  "A broken backend cannot leave a close consumer waiting forever."
  (let ((emacs-jupyter-notebook-backend-close-timeout 0.01)
        errors)
    (ejn-ei1-test-with-fake-backend
        ((lambda (&rest _ignored) nil))
      (let ((session (emacs-jupyter-notebook-backend-session-create)))
        (emacs-jupyter-notebook-backend-close-local
         session #'ignore
         (lambda (&rest value) (push value errors)))
        (accept-process-output nil 0.03)
        (ejn-ei1-test--run-timers)
        (should (= 1 (length errors)))
        (should (string-match-p "timed out" (cadar errors)))))))

(ert-deftest ejn-ei1-restart-followup-waits-for-control-success ()
  "Kernel-info and setup cannot overtake an asynchronous restart request."
  (require 'emacs-jupyter-notebook)
  (let (restart-success operations)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload success _failure _emit)
           (push operation operations)
           (if (equal operation '(control . restart))
               (setq restart-success success)
             (funcall success 'ok))))
      (with-temp-buffer
        (let ((emacs-jupyter-notebook--client
               (emacs-jupyter-notebook-backend-session-create)))
          (emacs-jupyter-notebook-restart-kernel)
          (should (equal operations '((control . restart))))
          (funcall restart-success 'restarted)
          (ejn-ei1-test--run-timers)
          (should (equal (nreverse operations)
                         '((control . restart) (aux . kernel-info)))))))))

(ert-deftest ejn-ei1-setup-logging-follows-backend-acknowledgement ()
  "Setup reports success or failure only after its execute request terminates."
  (require 'emacs-jupyter-notebook)
  (let (success failure logs)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload on-success on-failure _emit)
           (when (eq operation 'execute)
             (setq success on-success failure on-failure))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--log-append)
                 (lambda (kind format-string &rest args)
                   (push (cons kind (apply #'format format-string args)) logs))))
        (let ((session (emacs-jupyter-notebook-backend-session-create)))
          (emacs-jupyter-notebook--inject-viewer-formatter session)
          (should-not logs)
          (funcall failure "rejected")
          (ejn-ei1-test--run-timers)
          (should (string-match-p "failed: rejected" (cdar logs))))
        (setq success nil failure nil logs nil)
        (let ((session (emacs-jupyter-notebook-backend-session-create)))
          (emacs-jupyter-notebook--inject-viewer-formatter session)
          (should-not logs)
          (funcall success nil)
          (ejn-ei1-test--run-timers)
          (should (string-match-p "injected" (cdar logs))))))))

(ert-deftest ejn-ei1-static-production-has-no-direct-jupyter-calls ()
  "Only the legacy adapter may call the emacs-jupyter public API directly."
  (let* ((root (expand-file-name ".." ejn-ei1-test--directory))
         (adapter (expand-file-name "emacs-jupyter-notebook-jupyter.el" root))
         (allowed '(emacs-jupyter-notebook-jupyter-backend-dispatch
                    emacs-jupyter-notebook-jupyter-backend-ensure
                    jupyter-cmd))
         offenders)
    (cl-labels
        ((direct-call
          (form)
          (cond
           ((atom form) nil)
           ((eq (car-safe form) 'quote) nil)
           ((and (eq (car-safe form) 'function)
                 (not (consp (cadr form))))
            nil)
           ((and (symbolp (car form))
                 (not (memq (car form) allowed))
                 (string-match-p
                  "\\`\\(?:jupyter-\\|emacs-jupyter-notebook-jupyter-\\)"
                  (symbol-name (car form))))
            (car form))
           (t (cl-some #'direct-call form)))))
      (dolist (file (directory-files root t
                                     "\\`emacs-jupyter-notebook.*\\.el\\'"))
        (unless (equal file adapter)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (condition-case nil
                (while t
                  (let ((call (direct-call (read (current-buffer)))))
                    (when call
                      (push (cons (file-name-nondirectory file) call) offenders))))
              (end-of-file nil))))))
    (should-not offenders)))

(ert-deftest ejn-ei1-backend-source-does-not-eagerly-require-legacy-adapter ()
  "Selecting a future backend must not load the legacy transport as a side effect."
  (let ((source (expand-file-name "../emacs-jupyter-notebook-backend.el"
                                  ejn-ei1-test--directory))
        eager)
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) 'require)
                         (equal (cadr form) ''emacs-jupyter-notebook-jupyter))
                (setq eager t))))
        (end-of-file nil)))
    (should-not eager)))

(defun ejn-ei1r-test--snapshot (source handle)
  "Return the user-visible event state for SOURCE and HANDLE."
  (list :text (ejn-panel-entry-text handle)
        :status (plist-get (ejn-panel-entry-snapshot handle) :status)
        :fringe (with-current-buffer source
                  (emacs-jupyter-notebook-fringe-state (plist-get handle :cell-key)))
        :kernel (with-current-buffer source emacs-jupyter-notebook--kernel-status)))

(defun ejn-ei1r-test--run-event (event &optional legacy)
  "Apply EVENT to a fresh source/panel pair, optionally via legacy translation."
  (let ((source (generate-new-buffer " *ejn-ei1r-source*")))
    (unwind-protect
        (with-current-buffer source
          (insert "# %%\nx = 1\n")
          (setq-local emacs-jupyter-notebook--kernel-status nil)
          (let* ((panel (ejn-panel-ensure source))
                 (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
                 (context (list :buffer source :entry-handle handle :request-id nil))
                 (normalized
                  (if legacy
                      (let ((content (plist-get event :legacy-content))
                            (type (plist-get event :legacy-type)))
                        (cl-letf (((symbol-function 'jupyter-message-content)
                                   (lambda (_message) content)))
                          (emacs-jupyter-notebook-jupyter--legacy-event type 'legacy)))
                    (plist-get event :normalized))))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-events--schedule-input)
                       (lambda (&rest _ignored) :scheduled)))
              (emacs-jupyter-notebook-events-dispatch context normalized))
            (ejn-ei1r-test--snapshot source handle)))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest ejn-ei1r-normalized-events-match-legacy-translation ()
  "Every normalized event has exactly one legacy translation and behavior."
  (dolist
      (event
       (list
        (list :normalized '(:type stream :name "stdout" :text "stream\n")
              :legacy-type "stream" :legacy-content '(:name "stdout" :text "stream\n") :text "stream\n")
        (list :normalized '(:type clear :wait nil)
              :legacy-type "clear_output" :legacy-content '(:wait nil) :text "")
        (list :normalized '(:type result :data (:text/plain "42"))
              :legacy-type "execute_result" :legacy-content '(:data (:text/plain "42")) :text "42")
        (list :normalized '(:type display :data (:text/plain "shown"))
              :legacy-type "display_data" :legacy-content '(:data (:text/plain "shown")) :text "shown")
        (list :normalized '(:type update-display :data (:text/plain "updated"))
              :legacy-type "update_display_data" :legacy-content '(:data (:text/plain "updated")) :text "updated")
        (list :normalized '(:type error :traceback ("one" "two"))
              :legacy-type "error" :legacy-content '(:traceback ("one" "two")) :text "one\ntwo")
        (list :normalized '(:type execute-reply :status "ok" :execution-count 3)
              :legacy-type "execute_reply" :legacy-content '(:status "ok" :execution_count 3)
              ;; EI3 owns terminal presentation only after correlated idle.
              :text "" :status 'running :fringe nil)
        (list :normalized '(:type status :execution-state "busy")
              :legacy-type "status" :legacy-content '(:execution_state "busy") :text "" :kernel 'busy)
        (list :normalized '(:type status :execution-state "idle")
              :legacy-type "status" :legacy-content '(:execution_state "idle") :text "" :kernel 'idle)
        (list :normalized '(:type input-request :prompt "value: " :password t)
              :legacy-type "input_request" :legacy-content '(:prompt "value: " :password t) :text "value: ")
        (list :normalized '(:type truncation :text "[truncated]\n")
              :legacy-type nil :legacy-content nil :text "[truncated]\n")))
    (let ((direct (ejn-ei1r-test--run-event event))
          (translated (if (plist-get event :legacy-type)
                          (ejn-ei1r-test--run-event event t)
                        (ejn-ei1r-test--run-event event))))
      (should (equal direct translated))
      (should (equal (plist-get direct :text) (plist-get event :text)))
      (should (eq (plist-get direct :status) (or (plist-get event :status) 'running)))
      (should (eq (plist-get direct :fringe) (plist-get event :fringe)))
      (should (eq (plist-get direct :kernel) (plist-get event :kernel))))))

(ert-deftest ejn-ei1r-reducer-drops-malformed-late-and-retired-events ()
  "Malformed events log; late/retired output cannot recreate presentation."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (context (list :buffer source :entry-handle handle :request-id 9
                          :backend-request-id 11
                          :panel-generation (plist-get handle :generation)))
           messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (emacs-jupyter-notebook--execution-put
         (list :id 9 :state 'dispatched :backend-request-id 11
               :generation (plist-get handle :generation)))
        (setq emacs-jupyter-notebook--execution-active-id 9)
        (should-not (emacs-jupyter-notebook-events-dispatch context '(:type display)))
        (clrhash emacs-jupyter-notebook--execution-ledger)
        (emacs-jupyter-notebook--execution-put
         (list :id 10 :state 'dispatched))
        (setq emacs-jupyter-notebook--execution-active-id 10)
        (should (equal (emacs-jupyter-notebook-events-dispatch
                        context '(:type stream :text "late"))
                       '((:action ignore))))
        (ejn-panel-clear-all panel)
        (should (equal (emacs-jupyter-notebook-events-dispatch
                        (list :buffer source :entry-handle handle)
                        '(:type display :data (:text/plain "retired")))
                       '((:action ignore))))
        (should-not
         (emacs-jupyter-notebook-events-dispatch
          (list :buffer source :entry-handle handle) '(:type unknown)))
        (should (cl-some (lambda (text) (string-match-p "event reducer failed" text))
                         messages))))))

(ert-deftest ejn-ei1r-reducer-errors-are-logged-not-swallowed ()
  "An injected reducer exception is visible in the bounded diagnostic path."
  (let (messages)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-events-reduce)
               (lambda (&rest _) (error "injected reducer failure")))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-not (emacs-jupyter-notebook-events-dispatch nil '(:type stream)))
      (should (string-match-p "injected reducer failure" (car messages))))))

(ert-deftest ejn-ei1r-clear-wait-and-input-are-deferred-and-owned ()
  "Clear wait survives, and input never reads/replies in the callback turn."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (context (list :buffer source :entry-handle handle :request-id nil))
           scheduled timer prompt reply)
      (ejn-panel-append-text handle "old")
      (emacs-jupyter-notebook-events-dispatch context '(:type clear :wait t))
      (should (equal (ejn-panel-entry-text handle) "old"))
      (should (plist-get (ejn-panel-entry-snapshot handle) :pending-clear))
      (let ((real-run-at-time (symbol-function 'run-at-time)))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat function &rest args)
                     (setq scheduled (lambda () (apply function args)))
                     (setq timer (funcall real-run-at-time 100 nil #'ignore))))
                  ((symbol-function 'read-passwd)
                   (lambda (value) (setq prompt value) "secret")))
          (emacs-jupyter-notebook-events-dispatch
           (plist-put (copy-sequence context) :input-reply
                      (lambda (value) (setq reply (copy-sequence value))))
           '(:type input-request :prompt "Password: " :password t))
          (should-not prompt)
          (should-not reply)
          (funcall scheduled)
          (should (equal prompt "Password: "))
          (should (equal reply "secret"))))
      (when (timerp timer) (cancel-timer timer)))))

(ert-deftest ejn-ei1r-result-display-and-update-have-distinct-semantics ()
  "Result replaces text, display appends, and update replaces in place."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (context (list :buffer source :entry-handle handle :request-id nil)))
      (ejn-panel-append-text handle "old")
      (emacs-jupyter-notebook-events-dispatch context '(:type result :data (:text/plain "result")))
      (should (equal (ejn-panel-entry-text handle) "result"))
      (emacs-jupyter-notebook-events-dispatch context '(:type display :data (:text/plain " display")))
      (should (equal (ejn-panel-entry-text handle) "result display"))
      (emacs-jupyter-notebook-events-dispatch context '(:type update-display :data (:text/plain "update")))
      (should (equal (ejn-panel-entry-text handle) "update")))))

(ert-deftest ejn-ei1r-watch-output-suppresses-execute-reply-error-fallback ()
  "Watch output is retained while EI3 waits for correlated idle to finish."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (context (list :buffer source :entry-handle handle :request-id nil
                          :had-result nil)))
      (emacs-jupyter-notebook-events-dispatch
       context
       '(:type execute-reply :status "error" :execution-count 4
         :watch-text "\n[watch]\nx: 1\n"
         :ename "ValueError" :evalue "boom"))
      (should (equal (ejn-panel-entry-text handle) "\n[watch]\nx: 1\n"))
      (should-not (string-match-p "ValueError" (ejn-panel-entry-text handle)))
      (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status) 'running)))))

(ert-deftest ejn-ei3-non-ok-reply-status-uses-error-presentation ()
  "Only exact Jupyter ok status suppresses the reducer's error fallback."
  (dolist (status '("error" "aborted" "invalid"))
    (should (eq (emacs-jupyter-notebook-events--reply-status
                 (list :status status))
                'error)))
  (should (eq (emacs-jupyter-notebook-events--reply-status '(:status "ok"))
              'ok)))

(ert-deftest ejn-ei1r-retired-legacy-output-logs-at-a-bounded-rate ()
  "Retired legacy output is rejected before decode with a capped diagnostic."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (stream (cadr (assoc "stream"
                                (emacs-jupyter-notebook-jupyter--callbacks source handle))))
           (emacs-jupyter-notebook-jupyter--late-callback-log-count 0)
           messages)
      (ejn-panel-clear-all panel)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)))
                ((symbol-function 'jupyter-message-content)
                 (lambda (&rest _) (ert-fail "retired output decoded"))))
        (dotimes (_ (1+ emacs-jupyter-notebook-jupyter--late-callback-log-limit))
          (funcall stream 'retired-stream))
        (should (= (length messages)
                   emacs-jupyter-notebook-jupyter--late-callback-log-limit))))))

(provide 'emacs-jupyter-notebook-backend-tests)

;;; emacs-jupyter-notebook-backend-tests.el ends here
