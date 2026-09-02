;;; emacs-jupyter-notebook-lifecycle-deadline-tests.el --- Lifecycle deadline tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Deterministic local tests for lifecycle wall-clock expiry and registry
;; settlement.  Every remote boundary is replaced with a failing test double.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook)

(defun ejn-lifecycle-deadline-test--entry ()
  "Return a direct-launch entry sufficient for restart deadline tests."
  '(:profile "profile"
    :remote-host "example.test"
    :remote-cwd "/srv/notebook"
    :kernelspec "python3"
    :remote-connection-file "/srv/cache/kernel-deadline.json"
    :remote-pid 4242
    :created-at "2026-09-02T00:00:00+0000"
    :tunnel-ports (:shell_port 51001 :iopub_port 51002)
    :remote-ports (:shell_port 41001 :iopub_port 41002)
    :connection-file-tokens ("-f" "/srv/cache/kernel-deadline.json")
    :launch-kind direct
    :provisional t
    :session-id "deadline"
    :registry-revision "0123456789abcdef0123456789abcdef"))

(defun ejn-lifecycle-deadline-test--expired-context (buffer)
  "Return an expired but otherwise active restart context for BUFFER."
  (emacs-jupyter-notebook--async-new-context
   :phase 'restart-resolve
   :origin-buffer buffer
   :profile '(:profile "profile" :host "example.test" :python-command ("python3"))
   :entry (ejn-lifecycle-deadline-test--entry)
   :session-id "deadline"
   :restart-operation t
   :restart-client 'deadline-client
   :restart-epoch 7
   :transition-admitted t
   :overall-deadline (1- (float-time))))

(ert-deftest ejn-lifecycle-deadline-blocks-every-restart-dispatch-boundary ()
  "An expired restart starts no reader, resolver, control, upload, publish, or launch."
  (with-temp-buffer
    (let ((failures 0)
          (emacs-jupyter-notebook--client 'deadline-client)
          (emacs-jupyter-notebook--execution-setup-epoch 7))
      (cl-letf
          (((symbol-function 'emacs-jupyter-notebook--async-fail)
            (lambda (_context _reason) (cl-incf failures)))
           ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
            (lambda (&rest _) (ert-fail "expired restart started a process")))
           ((symbol-function 'emacs-jupyter-notebook-backend-control)
            (lambda (&rest _) (ert-fail "expired restart sent backend control")))
           ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
            (lambda (&rest _) (ert-fail "expired restart mutated registry"))))
        (dolist
            (dispatch
             (list #'emacs-jupyter-notebook--restart-read-seed-async
                   #'emacs-jupyter-notebook--async-resolve-kernelspec
                   #'emacs-jupyter-notebook--restart-preflight-ready
                   #'emacs-jupyter-notebook--restart-upload-seed
                   #'emacs-jupyter-notebook--restart-publish-seed
                   #'emacs-jupyter-notebook--restart-admit-launch
                   #'emacs-jupyter-notebook--async-launch))
          (let ((context (ejn-lifecycle-deadline-test--expired-context
                          (current-buffer))))
            (setq emacs-jupyter-notebook--async-context context)
            (funcall dispatch context)))
        (should (= failures 7))))))

(ert-deftest ejn-lifecycle-deadline-blocks-expired-reconnect-dispatch ()
  "An expired reconnect cannot start a late resolver process."
  (with-temp-buffer
    (let ((failures 0)
          (context
           (emacs-jupyter-notebook--async-new-context
            :phase 'reconnect-resolve :origin-buffer (current-buffer)
            :profile '(:profile "profile" :host "example.test")
            :session-id "reconnect-deadline"
            :overall-deadline (1- (float-time)))))
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf
          (((symbol-function 'emacs-jupyter-notebook--async-fail)
            (lambda (_context _reason) (cl-incf failures)))
           ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
            (lambda (&rest _) (ert-fail "expired reconnect started a process"))))
        (emacs-jupyter-notebook--async-resolve-kernelspec context))
      (should (= failures 1)))))

(ert-deftest ejn-lifecycle-deadline-adopts-exact-restart-lease-before-returning ()
  "Expiry after terminal restart proof preserves the exact durable lease."
  (with-temp-buffer
    (let* ((client 'deadline-client)
           (epoch 7)
           (entry (emacs-jupyter-notebook--transition-lease
                   (ejn-lifecycle-deadline-test--entry)
                   'restart "deadline-token" 'kernel-dead))
           (context
            (emacs-jupyter-notebook--async-new-context
             :phase 'restart-upload :origin-buffer (current-buffer)
             :profile '(:profile "profile" :host "example.test")
             :entry entry :session-id "deadline" :restart-operation t
             :restart-client client :restart-epoch epoch
             :restart-shutdown-sent t :overall-deadline (1- (float-time))))
           started retired released)
      (setq emacs-jupyter-notebook--client client
            emacs-jupyter-notebook--execution-setup-epoch epoch
            emacs-jupyter-notebook--async-context context)
      (cl-letf
          (((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
            (lambda (&rest _) (setq started t)))
           ((symbol-function 'emacs-jupyter-notebook--lifecycle-retire-local-transport)
            (lambda (value) (setq retired value)))
           ((symbol-function 'emacs-jupyter-notebook--execution-release-unattached-gate)
            (lambda (value) (setq released value)))
           ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore)
           ((symbol-function 'display-warning) #'ignore)
           ((symbol-function 'emacs-jupyter-notebook--async-fail)
            (lambda (&rest _) (ert-fail "expired exact lease fell through to async fail"))))
        (emacs-jupyter-notebook--restart-upload-seed context))
      (should-not started)
      (should (equal retired client))
      (should (equal released epoch))
      (should (equal emacs-jupyter-notebook--session-entry entry))
      (should (equal emacs-jupyter-notebook--transition-token "deadline-token"))
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error)))))

(ert-deftest ejn-lifecycle-deadline-keeps-queued-work-off-old-client ()
  "A settled pre-destructive lease holds queued work for explicit recovery."
  (with-temp-buffer
    (let* ((client 'deadline-client)
           (epoch 7)
           (entry (emacs-jupyter-notebook--transition-lease
                   (ejn-lifecycle-deadline-test--entry)
                   'restart "admitted-token" 'admitted))
           (context
            (emacs-jupyter-notebook--async-new-context
             :phase 'registry-transition-admission :origin-buffer (current-buffer)
             :entry entry :session-id "deadline" :restart-operation t
             :restart-client client :restart-epoch epoch))
           (record '(:id 1 :state queued :code "queued()" :terminal nil))
           (executed 0))
      (setq emacs-jupyter-notebook--client client
            emacs-jupyter-notebook--execution-setup-pending t
            emacs-jupyter-notebook--execution-setup-epoch epoch
            emacs-jupyter-notebook--execution-queue '(1)
            emacs-jupyter-notebook--execution-active-id nil
            emacs-jupyter-notebook--execution-ledger (make-hash-table :test #'eql)
            emacs-jupyter-notebook--async-context context)
      (puthash 1 record emacs-jupyter-notebook--execution-ledger)
      (cl-letf
          (((symbol-function 'emacs-jupyter-notebook-backend-execute)
            (lambda (&rest _) (cl-incf executed)))
           ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore)
           ((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--lifecycle-deadline-settled
         context client epoch entry "Kernel restart" nil)
        ;; A later local pump attempt must still respect the retained gate.
        (emacs-jupyter-notebook--execution-pump))
      (should emacs-jupyter-notebook--execution-setup-pending)
      (should (equal emacs-jupyter-notebook--execution-queue '(1)))
      (should (eq (plist-get (gethash 1 emacs-jupyter-notebook--execution-ledger)
                             :state)
                  'queued))
      (should (= executed 0)))))

(ert-deftest ejn-lifecycle-deadline-keeps-registry-settlement-owned ()
  "Overall expiry marks settlement non-dispatching without cancelling its owner."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-connection-attempt-timeout 0.01)
          cancelled)
      (let ((context
             (emacs-jupyter-notebook--async-new-context
              :phase 'registry-transition-admission
              :origin-buffer (current-buffer))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf
            (((symbol-function 'emacs-jupyter-notebook--async-fail)
              (lambda (&rest _) (ert-fail "deadline cancelled lifecycle settlement")))
             ((symbol-function 'emacs-jupyter-notebook-registry-owner-cancel)
              (lambda (&rest _) (setq cancelled t))))
          (setq context
                (emacs-jupyter-notebook--async-arm-overall-timeout context))
          (let ((deadline (+ (float-time) 0.5)))
            (while (and (not (plist-get context :lifecycle-deadline-reached))
                        (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should (plist-get context :lifecycle-deadline-reached))
          (should (eq (plist-get context :phase) 'registry-transition-admission))
          (should-not cancelled)
          (emacs-jupyter-notebook--async-cancel-overall-timer context))))))

(ert-deftest ejn-lifecycle-deadline-generic-cleanup-never-starts-staging-ssh ()
  "Failure and local teardown leave a private restart staging artifact alone."
  (with-temp-buffer
    (let* ((entry (emacs-jupyter-notebook--transition-lease
                   (ejn-lifecycle-deadline-test--entry)
                   'restart "staging-token" 'kernel-dead))
           (context
            (emacs-jupyter-notebook--async-new-context
             :phase 'restart-upload :origin-buffer (current-buffer)
             :profile '(:profile "profile" :host "example.test")
             :entry entry :session-id "deadline"
             :restart-staging-file
             "/srv/cache/kernel-deadline.json.restart-staging-token"))
           cleanup-started)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf
          (((symbol-function 'emacs-jupyter-notebook-ssh-start-management-operation)
            (lambda (&rest _) (setq cleanup-started t)))
           ((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail context "test failure")
        (should-not cleanup-started)
        (emacs-jupyter-notebook--cancel-async-context-locally context)
        (should-not cleanup-started)))))

(provide 'emacs-jupyter-notebook-lifecycle-deadline-tests)
;;; emacs-jupyter-notebook-lifecycle-deadline-tests.el ends here
