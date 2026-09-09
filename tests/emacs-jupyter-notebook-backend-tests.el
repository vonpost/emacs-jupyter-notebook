;;; emacs-jupyter-notebook-backend-tests.el --- Async backend contract tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-events)

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
  "Run BODY with DISPATCH replacing the helper backend dispatcher."
  (declare (indent 1) (debug t))
  (let ((dispatch (car binding)))
    `(let ((emacs-jupyter-notebook-backend-implementations
            (cons (cons 'helper ,dispatch)
                  (cl-remove-if (lambda (entry) (eq (car entry) 'helper))
                                emacs-jupyter-notebook-backend-implementations))))
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

(ert-deftest ejn-ei1-reentrant-transport-failure-fences-queued-success ()
  "A transport failure latched in dispatch prevents an earlier success delivery."
  (let (seen)
    (ejn-ei1-test-with-fake-backend
        ((lambda (session _request _operation _payload success _failure _emit)
           (funcall success 'connected)
           (emacs-jupyter-notebook-backend-session-notify-transport-failure
            session "transport failed in dispatch")))
      (let ((session
             (emacs-jupyter-notebook-backend-session-create
              nil nil
              (lambda (_session reason) (push (list 'failure reason) seen)))))
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/reentrant.json"
         (lambda (_id value) (push (list 'success value) seen))
         (lambda (_id reason) (push (list 'request-failure reason) seen)))
        (should-not seen)
        (should-not (emacs-jupyter-notebook-backend-session-live-p session))
        (ejn-ei1-test--run-timers)
        (should (equal seen '((failure "transport failed in dispatch"))))))))

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

(ert-deftest ejn-ei1-contract-rejects-raw-non-session-clients ()
  "Every public operation requires one persistent opaque session."
  (should-error
   (emacs-jupyter-notebook-backend-execute
    'raw-client "x" nil #'ignore #'ignore)
   :type 'error)
  (should-error
   (emacs-jupyter-notebook-backend-close-local
    'raw-client #'ignore #'ignore)
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
        (disposed 0) errors)
    (ejn-ei1-test-with-fake-backend
        ((lambda (&rest _ignored) nil))
      (let ((session (emacs-jupyter-notebook-backend-session-create)))
        (setf (emacs-jupyter-notebook-backend-session-data session) 'local-state)
        (emacs-jupyter-notebook-backend-session-set-local-disposer
         session (lambda (_reason) (cl-incf disposed)))
        (emacs-jupyter-notebook-backend-close-local
         session #'ignore
         (lambda (&rest value) (push value errors)))
        (accept-process-output nil 0.03)
        (ejn-ei1-test--run-timers)
        (should (= disposed 1))
        (should (= 1 (length errors)))
        (should (string-match-p "timed out" (cadar errors)))))))

(ert-deftest ejn-ei1-close-deadline-setup-failure-retires-local-resources ()
  "Failure to create generic close's timer cannot strand adapter resources."
  (let ((emacs-jupyter-notebook-backend-close-timeout 0.01)
        disposed errors dispatched)
    (ejn-ei1-test-with-fake-backend
        ((lambda (&rest _ignored) (setq dispatched t)))
      (let ((session (emacs-jupyter-notebook-backend-session-create)))
        (setf (emacs-jupyter-notebook-backend-session-data session) 'local-state)
        (emacs-jupyter-notebook-backend-session-set-local-disposer
         session (lambda (reason) (push reason disposed)))
        (let ((real-run-at-time (symbol-function 'run-at-time)))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (delay repeat function &rest args)
                       (if (= delay emacs-jupyter-notebook-backend-close-timeout)
                           (error "injected generic close deadline allocation failure")
                         (apply real-run-at-time delay repeat function args)))))
            (emacs-jupyter-notebook-backend-close-local
             session #'ignore (lambda (_id reason) (push reason errors))))
        (should-not dispatched)
        (should (emacs-jupyter-notebook-backend-session-closed session))
        (should-not (emacs-jupyter-notebook-backend-session-data session))
        (should-not (emacs-jupyter-notebook-backend-session-local-disposer session))
        (should (= 1 (length disposed)))
        (ejn-ei1-test--run-timers)
        (should (= 1 (length errors)))
        (should (string-match-p "cannot arm backend local close deadline"
                                (car errors))))))))

(ert-deftest ejn-ei1-close-dispatch-error-retires-local-resources ()
  "An unexpected adapter dispatch error cannot strand its local process."
  (let ((disposed 0) errors)
    (ejn-ei1-test-with-fake-backend
        ((lambda (&rest _ignored) (error "injected close dispatch failure")))
      (let ((session (emacs-jupyter-notebook-backend-session-create)))
        (setf (emacs-jupyter-notebook-backend-session-data session) 'local-state)
        (emacs-jupyter-notebook-backend-session-set-local-disposer
         session (lambda (_reason) (cl-incf disposed)))
        (emacs-jupyter-notebook-backend-close-local
         session #'ignore (lambda (_id reason) (push reason errors)))
        (ejn-ei1-test--run-timers)
        (should (= disposed 1))
        (should (= (length errors) 1))
        (should (string-match-p "injected close dispatch failure"
                                (error-message-string (car errors))))
        (should-not (emacs-jupyter-notebook-backend-session-data session))
        (should-not
         (emacs-jupyter-notebook-backend-session-local-disposer session))))))

(ert-deftest ejn-ei1-restart-rejects-a-generic-backend-without-control ()
  "The core must not issue destructive lifecycle work through a generic backend."
  (require 'emacs-jupyter-notebook)
  (let (operations)
    (ejn-ei1-test-with-fake-backend
        ((lambda (_session _request operation _payload success _failure _emit)
           (push operation operations)
           (funcall success 'ok)))
      (with-temp-buffer
        (let ((emacs-jupyter-notebook--client
               (emacs-jupyter-notebook-backend-session-create)))
          (should-error (emacs-jupyter-notebook-restart-kernel)
                        :type 'user-error)
          (should-not operations))))))

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

(ert-deftest ejn-ei1-static-production-is-helper-only ()
  "Production source exposes no emacs-jupyter transport or selector."
  (let* ((root (expand-file-name ".." ejn-ei1-test--directory))
         (deleted-adapter "emacs-jupyter-notebook-jupyter")
         (selector 'emacs-jupyter-notebook-backend)
         offenders)
    (cl-labels
        ((record
          (file kind value)
          (push (list (file-name-nondirectory file) kind value) offenders))
         (jupyter-feature-p
          (feature)
          (and (symbolp feature)
               (string-match-p "\\`jupyter\\(?:-\\|\\'\\)"
                               (symbol-name feature))))
         (selector-target
          (form)
          (if (and (consp form) (eq (car form) 'quote))
              (cadr form)
            form))
         (walk
          (file form)
          (cond
           ((consp form)
            (let ((head (car form)))
              (when (and (symbolp head)
                         (string-match-p "\\`jupyter-" (symbol-name head)))
                (record file 'call head))
              (when (and (memq head '(defvar defconst defcustom defvar-local defvaralias))
                         (eq (selector-target (cadr form)) selector))
                (record file 'selector selector))
              (when (eq head 'require)
                (let ((feature (cadr form)))
                  (when (and (consp feature)
                             (eq (car feature) 'quote)
                             (jupyter-feature-p (cadr feature)))
                    (record file 'require (cadr feature)))))
              ;; Constants may contain dotted pairs, so recurse through the
              ;; complete cons tree rather than assuming a proper list.
              (walk file (car form))
              (walk file (cdr form)))))))
      (dolist (file (directory-files root t
                                     "\\`emacs-jupyter-notebook.*\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (when (search-forward deleted-adapter nil t)
            (record file 'deleted-adapter deleted-adapter))
          (goto-char (point-min))
          (condition-case nil
              (while t (walk file (read (current-buffer))))
            (end-of-file nil))))
    (should-not (boundp selector))
    (should-not offenders))))

(defun ejn-ei1r-test--snapshot (source handle)
  "Return the user-visible event state for SOURCE and HANDLE."
  (list :text (ejn-panel-entry-text handle)
        :status (plist-get (ejn-panel-entry-snapshot handle) :status)
        :fringe (with-current-buffer source
                  (emacs-jupyter-notebook-fringe-state (plist-get handle :cell-key)))
        :kernel (with-current-buffer source emacs-jupyter-notebook--kernel-status)))

(defun ejn-ei1r-test--run-event (event)
  "Apply normalized helper EVENT to a fresh source/panel pair."
  (let ((source (generate-new-buffer " *ejn-ei1r-source*")))
    (unwind-protect
        (with-current-buffer source
          (insert "# %%\nx = 1\n")
          (setq-local emacs-jupyter-notebook--kernel-status nil)
          (let* ((panel (ejn-panel-ensure source))
                 (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
                 (context (list :buffer source :entry-handle handle :request-id nil))
                 (normalized (plist-get event :normalized)))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-events--schedule-input)
                       (lambda (&rest _ignored) :scheduled)))
              (emacs-jupyter-notebook-events-dispatch context normalized))
            (ejn-ei1r-test--snapshot source handle)))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest ejn-ei1r-helper-normalized-events-have-expected-reducer-behavior ()
  "Every helper-normalized event has the expected direct reducer behavior."
  (dolist
      (event
       (list
        (list :normalized '(:type stream :name "stdout" :text "stream\n")
              :text "stream\n")
        (list :normalized '(:type clear :wait nil)
              :text "")
        (list :normalized '(:type result :data (:text/plain "42"))
              :text "42")
        (list :normalized '(:type display :data (:text/plain "shown"))
              :text "shown")
        (list :normalized '(:type update-display :data (:text/plain "updated"))
              :text "updated")
        (list :normalized '(:type error :traceback ("one" "two"))
              :text "one\ntwo")
        (list :normalized '(:type execute-reply :status "ok" :execution-count 3)
              ;; EI3 owns terminal presentation only after correlated idle.
              :text "" :status 'running :fringe nil)
        (list :normalized '(:type status :execution-state "busy")
              :text "" :kernel 'busy)
        (list :normalized '(:type status :execution-state "idle")
              :text "" :kernel 'idle)
        (list :normalized '(:type input-request :prompt "value: " :password t)
              :text "value: ")
        (list :normalized '(:type truncation :text "[truncated]\n")
              :text "[truncated]\n")))
    (let ((snapshot (ejn-ei1r-test--run-event event)))
      (should (equal (plist-get snapshot :text) (plist-get event :text)))
      (should (eq (plist-get snapshot :status) (or (plist-get event :status) 'running)))
      (should (eq (plist-get snapshot :fringe) (plist-get event :fringe)))
      (should (eq (plist-get snapshot :kernel) (plist-get event :kernel))))))

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
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
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
        (when (timerp timer) (cancel-timer timer))))))

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

(ert-deftest ejn-ei1r-execute-reply-error-without-result-appends-fallback ()
  "An error reply remains visible when no earlier result event explained it."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x"))
           (context (list :buffer source :entry-handle handle :request-id nil
                          :had-result nil)))
      (emacs-jupyter-notebook-events-dispatch
       context
       '(:type execute-reply :status "error" :execution-count 4
         :ename "ValueError" :evalue "boom"))
      (should (equal (ejn-panel-entry-text handle) "ValueError: boom"))
      (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status) 'running)))))

(ert-deftest ejn-ei3-non-ok-reply-status-uses-error-presentation ()
  "Only exact Jupyter ok status suppresses the reducer's error fallback."
  (dolist (status '("error" "aborted" "invalid"))
    (should (eq (emacs-jupyter-notebook-events--reply-status
                 (list :status status))
                'error)))
  (should (eq (emacs-jupyter-notebook-events--reply-status '(:status "ok"))
              'ok)))

(provide 'emacs-jupyter-notebook-backend-tests)

;;; emacs-jupyter-notebook-backend-tests.el ends here
