;;; emacs-jupyter-notebook-eval-recovery-tests.el --- Acquire then evaluate -*- lexical-binding: t; -*-

;;; Commentary:
;; CC26 exercises the real acquisition and execution FIFO with mocked external
;; boundaries.  A successful reconnect must not discard the initiating cell.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defun ejn-cc26--entry ()
  "Return a valid durable kernel identity for a local acquisition test."
  '(:profile "cc26" :remote-host "test.invalid" :remote-cwd "/work"
    :kernelspec "python3" :session-id "cc26" :launch-kind direct
    :remote-pid 1234 :remote-connection-file "/cache/kernel-cc26.json"
    :remote-pid-sidecar "/cache/kernel-cc26.pid"
    :connection-file-tokens ("/cache/kernel-cc26.json")
    :registry-revision "cc26-revision"
    :local-file "/tmp/cc26.py"
    :remote-ports (:shell_port 41000 :iopub_port 41001 :stdin_port 41002
                   :hb_port 41003 :control_port 41004)))

(defmacro ejn-cc26--with-source (&rest body)
  "Run BODY with the real FIFO, local cleanup and asynchronous acquisition."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name "/tmp/cc26.py"
           emacs-jupyter-notebook-mode t)
     (insert "# %%\nfirst()\n")
     (set-buffer-modified-p nil)
     (let ((emacs-jupyter-notebook-check-code-completeness nil)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           (emacs-jupyter-notebook-auto-reconnect nil)
           (emacs-jupyter-notebook--session-entry (copy-tree (ejn-cc26--entry)))
           (original-processes (process-list))
           (original-timers (copy-sequence timer-list))
           probes executions prompts starts removals)
       (cl-letf (((symbol-function 'emacs-jupyter-notebook--runtime-ready-p)
                  (lambda () t))
                 ((symbol-function 'emacs-jupyter-notebook--entry-profile)
                  (lambda (_entry) '(:profile "cc26" :host "test.invalid")))
                 ((symbol-function 'emacs-jupyter-notebook--ensure-selected-backend)
                  #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
                  (lambda (context) (push context probes)))
                 ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                  (lambda (_session code _context _success _failure)
                    (push code executions)
                    (length executions)))
                 ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                  (lambda (session &rest _args)
                    (setf (emacs-jupyter-notebook-backend-session-closed session) t)))
                 ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-invalidate) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-execution-finished)
                  #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-ui-defer)
                  (lambda (_source guard function &rest _args)
                    (push (cons guard function) prompts)))
                 ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore))
         (unwind-protect
             (progn ,@body
                    (should (equal (buffer-string) "# %%\nfirst()\n"))
                    (should-not (buffer-modified-p)))
           (emacs-jupyter-notebook--release-local-resources)
           (emacs-jupyter-notebook--kill-panel)
           (should-not (cl-set-difference (process-list) original-processes))
           (should-not
            (cl-remove-if
             (lambda (timer) (eq (timer--function timer) #'undo-auto--boundary-timer))
             (cl-set-difference timer-list original-timers))))))))

(defun ejn-cc26--connected (context)
  "Complete acquisition CONTEXT as if the external helper attached."
  (setq emacs-jupyter-notebook--client
        (emacs-jupyter-notebook-backend-session-create nil (current-buffer))
        emacs-jupyter-notebook--tunnel-dead nil)
  (emacs-jupyter-notebook-backend-session-mark-attached
   emacs-jupyter-notebook--client)
  (emacs-jupyter-notebook--async-cancel-overall-timer context)
  (plist-put context :phase 'done)
  (funcall (plist-get context :callback) context))

(ert-deftest ejn-cc26-single-eval-survives-reconnect-cleanup ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (let ((id (emacs-jupyter-notebook--evaluate-code "first()" nil)))
      (should (= (length probes) 1))
      (should (emacs-jupyter-notebook--execution-record id))
      (ejn-cc26--connected (car probes))
      (should (equal executions '("first()")))
      ;; A duplicate success cannot re-admit the same source.
      (funcall (plist-get (car probes) :callback) (car probes))
      (should (equal executions '("first()"))))))

(ert-deftest ejn-cc26-two-evals-share-reconnect-and-keep-fifo ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (let ((first (emacs-jupyter-notebook--evaluate-code "first()" nil))
          (second (emacs-jupyter-notebook--evaluate-code "second()" nil)))
      (should (= (length probes) 1))
      (should (equal emacs-jupyter-notebook--execution-queue (list first second)))
      (ejn-cc26--connected (car probes))
      (should (equal executions '("first()")))
      (emacs-jupyter-notebook--execution-finish
       (emacs-jupyter-notebook--execution-record first) 'ok)
      (should (equal executions '("second()" "first()"))))))

(ert-deftest ejn-cc26-retired-client-reconnects-before-execute ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (setf (emacs-jupyter-notebook-backend-session-closed
           emacs-jupyter-notebook--client) t)
    (emacs-jupyter-notebook--evaluate-code "first()" nil)
    (should (= (length probes) 1))
    (should-not executions)
    (ejn-cc26--connected (car probes))
    (should (equal executions '("first()")))))

(ert-deftest ejn-cc26-live-local-client-checks-stale-remote-before-eval ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (emacs-jupyter-notebook-backend-session-mark-attached emacs-jupyter-notebook--client)
    (emacs-jupyter-notebook-backend-session-mark-installed emacs-jupyter-notebook--client)
    (setq emacs-jupyter-notebook--kernel-verified-at 0)
    (let ((client emacs-jupyter-notebook--client))
      (emacs-jupyter-notebook--evaluate-code "first()" nil)
      (should (= (length probes) 1))
      (should-not executions)
      (funcall (plist-get (car probes) :probe-success) (car probes))
      (should (eq client emacs-jupyter-notebook--client))
      (should (equal executions '("first()"))))))

(ert-deftest ejn-cc26-confirmed-dead-eval-retires-exact-row-then-runs-once ()
  (dolist (kind '(kernel-dead kernel-mismatch))
    (ejn-cc26--with-source
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
                 (lambda (key revision success _failure &rest _)
                   (push (list key revision success) removals)))
                ((symbol-function 'emacs-jupyter-notebook--start-remote-kernel-admitted)
                 (lambda (profile _success _failure context &rest _)
                   (push (list profile context) starts)))
                ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                 (lambda (&rest _) (ert-fail "Remote cleanup is forbidden"))))
        (let ((id (emacs-jupyter-notebook--evaluate-code "first()" nil)))
          (emacs-jupyter-notebook--async-fail
           (emacs-jupyter-notebook--async-put (car probes) :error-kind kind) "gone")
          (should (emacs-jupyter-notebook--execution-current-p id))
          (should (= (length prompts) 1))
          (should-not removals)
          (should (funcall (caar prompts)))
          (funcall (cdar prompts))
          (should (equal (caar removals) "cc26"))
          (should (equal (cadar removals) "cc26-revision"))
          (should-not starts)
          (funcall (nth 2 (car removals)) "cc26" nil)
          (should (= (length starts) 1))
          (should (equal (caar starts) "cc26"))
          (ejn-cc26--connected (cadar starts))
          (should (equal executions '("first()"))))))))

(ert-deftest ejn-cc26-cancelled-eval-invalidates-dead-kernel-prompt ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (emacs-jupyter-notebook--evaluate-code "first()" nil)
    (emacs-jupyter-notebook--async-fail
     (emacs-jupyter-notebook--async-put (car probes) :error-kind 'kernel-dead) "gone")
    (emacs-jupyter-notebook-cancel-operation)
    (should-not (funcall (caar prompts)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
               (lambda (&rest _) (ert-fail "Stale prompt removed metadata"))))
      (funcall (cdar prompts)))
    (should-not executions)))

(ert-deftest ejn-cc26-registry-conflict-never-starts-replacement ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
               (lambda (_key _revision _success failure &rest _)
                 (funcall failure '(:kind conflict :message "newer revision") nil)))
              ((symbol-function 'emacs-jupyter-notebook--start-remote-kernel-admitted)
               (lambda (&rest _) (ert-fail "Launched after CAS conflict"))))
      (emacs-jupyter-notebook--evaluate-code "first()" nil)
      (emacs-jupyter-notebook--async-fail
       (emacs-jupyter-notebook--async-put (car probes) :error-kind 'kernel-dead) "gone")
      (funcall (cdar prompts))
      (should (equal emacs-jupyter-notebook--session-entry (ejn-cc26--entry)))
      (should-not emacs-jupyter-notebook--execution-queue))))

(ert-deftest ejn-cc26-unknown-probe-failure-never-offers-fresh-kernel ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (emacs-jupyter-notebook--evaluate-code "first()" nil)
    (emacs-jupyter-notebook--async-fail
     (emacs-jupyter-notebook--async-put (car probes) :error-kind 'probe-unreachable) "network down")
    (should-not prompts)
    (should (equal emacs-jupyter-notebook--session-entry (ejn-cc26--entry)))
    (should-not executions)))

(ert-deftest ejn-cc26-nested-teardown-does-not-resurrect-unsent-work ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (let ((id (emacs-jupyter-notebook--evaluate-code "first()" nil)))
      ;; Model a reserved, definitely unsent record before local teardown.
      (let ((record (emacs-jupyter-notebook--execution-record id)))
        (emacs-jupyter-notebook--execution-cancel-timer record)
        (plist-put record :state 'checking)
        (plist-put record :backend-request-id nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                 (lambda (&rest _)
                   (setq emacs-jupyter-notebook--client nil
                         emacs-jupyter-notebook-mode nil)
                   (emacs-jupyter-notebook--release-local-resources))))
        (emacs-jupyter-notebook--preserve-unsent-executions
         #'emacs-jupyter-notebook--release-local-resources))
      (should-not emacs-jupyter-notebook--execution-queue)
      (should-not (emacs-jupyter-notebook--execution-record id)))))

(ert-deftest ejn-cc26-start-then-eval-attaches-to-live-pid-probe ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (emacs-jupyter-notebook-start-remote-kernel "cc26")
    (emacs-jupyter-notebook--evaluate-code "first()" nil)
    (should (= (length probes) 1))
    (should-not executions)
    (funcall (plist-get (car probes) :probe-success) (car probes) 'alive)
    (should (equal executions '("first()")))))

(ert-deftest ejn-cc26-decline-or-quit-cancels-all-waiting-cells ()
  (dolist (quitp '(nil t))
    (ejn-cc26--with-source
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (emacs-jupyter-notebook--evaluate-code "first()" nil)
      (emacs-jupyter-notebook--evaluate-code "second()" nil)
      (emacs-jupyter-notebook--async-fail
       (emacs-jupyter-notebook--async-put (car probes) :error-kind 'kernel-dead) "gone")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (if quitp (signal 'quit nil) nil))))
        (funcall (cdar prompts)))
      (should-not emacs-jupyter-notebook--execution-queue)
      (should (= (length probes) 1))
      (should (= (length prompts) 1))
      (should-not executions))))

(ert-deftest ejn-cc26-unverified-pid-needs-kernel-info-before-execution ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (emacs-jupyter-notebook-backend-session-mark-attached emacs-jupyter-notebook--client)
    (emacs-jupyter-notebook-backend-session-mark-installed emacs-jupyter-notebook--client)
    (let (reply)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client operation _payload success _failure)
                   (should (eq operation 'kernel-info))
                   (setq reply success))))
        (emacs-jupyter-notebook--evaluate-code "first()" nil)
        (funcall (plist-get (car probes) :probe-success) (car probes) 'unverified)
        (should-not executions)
        (should-not emacs-jupyter-notebook--kernel-verified-at)
        (funcall reply 1 '(:implementation "ipython"))
        (should (equal executions '("first()")))))))

(ert-deftest ejn-cc26-dead-retirement-settles-before-expired-start ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
               (lambda (_key _revision success _failure &rest _)
                 (push success removals)))
              ((symbol-function 'emacs-jupyter-notebook--start-remote-kernel-admitted)
               (lambda (&rest _) (ert-fail "Started after deadline"))))
      (emacs-jupyter-notebook--evaluate-code "first()" nil)
      (emacs-jupyter-notebook--async-fail
       (emacs-jupyter-notebook--async-put (car probes) :error-kind 'kernel-dead) "gone")
      (funcall (cdar prompts))
      (let ((context emacs-jupyter-notebook--async-context))
        (should (eq (plist-get context :phase) 'registry-dead-retirement))
        (emacs-jupyter-notebook-cancel-operation)
        (should (emacs-jupyter-notebook--async-context-live-p context))
        (plist-put context :overall-deadline 0)
        (funcall (car removals) "cc26" nil)
        (should (eq (plist-get context :phase) 'error))
        (should-not emacs-jupyter-notebook--session-entry)
        (should-not executions)))))

(ert-deftest ejn-cc26-dead-retirement-does-not-mutate-after-timer-failure ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (emacs-jupyter-notebook--evaluate-code "first()" nil)
    (emacs-jupyter-notebook--async-fail
     (emacs-jupyter-notebook--async-put (car probes) :error-kind 'kernel-dead) "gone")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'run-at-time) (lambda (&rest _) (error "no timer")))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
               (lambda (&rest _) (ert-fail "Mutation after deadline allocation failed"))))
      (funcall (cdar prompts)))
    (should (equal emacs-jupyter-notebook--session-entry (ejn-cc26--entry)))
    (should-not emacs-jupyter-notebook--execution-queue)))

(ert-deftest ejn-cc26-dead-tunnel-process-is-detected-before-sentinel ()
  (ejn-cc26--with-source
    (setq emacs-jupyter-notebook--client
          (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
    (let ((process (make-pipe-process :name "cc26-dead-tunnel" :noquery t)))
      (unwind-protect
          (progn
            (set-process-sentinel process #'ignore)
            (delete-process process)
            (setq emacs-jupyter-notebook--tunnel-process process)
            (emacs-jupyter-notebook--evaluate-code "first()" nil)
            (should (= (length probes) 1))
            (should-not executions)
            (ejn-cc26--connected (car probes))
            (should (equal executions '("first()"))))
        (when (process-live-p process) (delete-process process))))))

(provide 'emacs-jupyter-notebook-eval-recovery-tests)
;;; emacs-jupyter-notebook-eval-recovery-tests.el ends here
