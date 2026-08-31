;;; emacs-jupyter-notebook-helper-backend-tests.el --- EI2 adapter tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook)

(defconst ejn-ei2-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun ejn-ei2-test--object (&rest pairs)
  (apply #'emacs-jupyter-notebook-helper-backend--make-object pairs))

(defun ejn-ei2-test--response (&optional result)
  (ejn-ei2-test--object "ok" t "result" (or result (make-hash-table :test #'equal))))

(defun ejn-ei2-test--attached-response ()
  (ejn-ei2-test--response (ejn-ei2-test--object "attached" t)))

(defun ejn-ei2-test--closed-response ()
  (ejn-ei2-test--response (ejn-ei2-test--object "closed" t)))

(defun ejn-ei2-test--run-timers ()
  (accept-process-output nil 0.02))

(defun ejn-ei2-test--artifact-directory ()
  "Create a test-owned private artifact directory through production setup."
  (car (emacs-jupyter-notebook-helper-backend--make-artifact-directory)))

(cl-defmacro ejn-ei2-test-with-fake-helper ((requests callbacks disposals) &body body)
  "Run BODY with a synchronous fake helper supervisor.
REQUESTS receives (OP PARAMS); CALLBACKS receives the pending request closures;
DISPOSALS receives local-only disposal reasons."
  (declare (indent 1) (debug t))
  `(let (,requests ,callbacks ,disposals)
     (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-start)
                (lambda (&rest arguments)
                  (let ((helper (list :fake-helper)))
                    (funcall (plist-get arguments :ready-callback) helper nil)
                    helper)))
               ((symbol-function 'emacs-jupyter-notebook-helper-request)
               (lambda (_helper operation params callback &rest _keys)
                  (push (list operation params) ,requests)
                  (push callback ,callbacks)
                  (format "ejn-request-test-%d" (length ,callbacks))))
               ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                (lambda (_helper reason) (push reason ,disposals))))
       ,@body)))

(defmacro ejn-ei2-test-with-session (&rest body)
  "Create an opaque helper session in a live temporary owner buffer."
  (declare (indent 0) (debug t))
  `(let ((owner (generate-new-buffer " *ejn-ei2-owner*")))
     (unwind-protect
         (let ((emacs-jupyter-notebook-backend 'helper))
           (with-current-buffer owner
             (let ((session (emacs-jupyter-notebook-backend-session-create nil owner)))
               (unwind-protect
                   (progn ,@body)
                 (when-let* ((state (emacs-jupyter-notebook-backend-session-data
                                     session)))
                   (when (emacs-jupyter-notebook-helper-backend-state-p state)
                     (emacs-jupyter-notebook-helper-backend--dispose
                      state "EI2 test cleanup")))))))
       (when (buffer-live-p owner) (kill-buffer owner)))))

(defun ejn-ei2-test--direct-entry (&optional provisional)
  "Return a minimal valid direct entry for core reconnect tests."
  (let* ((session "ei2-core")
         (connection (format "/tmp/kernel-%s.json" session)))
    (list :profile "p" :remote-host "host" :remote-cwd "/remote"
          :kernelspec "python3" :session-id session :launch-kind 'direct
          :remote-pid (unless provisional 4242)
          :provisional (and provisional t)
          :remote-connection-file connection
          :remote-pid-sidecar (concat (string-remove-suffix ".json" connection) ".pid")
          :connection-file-tokens (list connection)
          :local-connection-file "/tmp/ejn-durable.json")))

(ert-deftest ejn-ei2-connect-orders-hello-attach-verify-and-defers-success ()
  "Synchronous helper callbacks still produce ordered deferred backend success."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (connected)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/ejn-loopback.json"
         (lambda (_id value) (setq connected value))
         (lambda (_id reason) (ert-fail reason)))
        ;; `connect' arrives only after fake hello, and it carries a private
        ;; absolute artifact directory.  Its reply makes the generic session
        ;; attached before `kernel_info' begins.
        (should (equal (caar requests) "connect"))
        (let* ((params (cadar requests))
               (artifact (gethash "artifact_dir" params)))
          (should (equal (gethash "connection_file" params) "/tmp/ejn-loopback.json"))
          (should (file-directory-p artifact))
          (should (= (logand (file-modes artifact) #o777) #o700)))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (should (emacs-jupyter-notebook-backend-session-attached-p session))
        (should (equal (caar requests) "kernel_info"))
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (should-not connected)
        (ejn-ei2-test--run-timers)
        (should (eq connected session))
        (let (close-error)
          (emacs-jupyter-notebook-backend-close-local
           session #'ignore (lambda (_id error) (setq close-error error)))
          (ejn-ei2-test--run-timers)
          (should-not close-error))
        (should (equal (caar requests) "close"))
        (should (emacs-jupyter-notebook-helper-backend-state-p
                 (emacs-jupyter-notebook-backend-session-data session)))
        ;; Answer local close so its private directory does not survive this
        ;; deterministic unit test.
        (funcall (car callbacks) nil (ejn-ei2-test--closed-response) nil)
        (ejn-ei2-test--run-timers)
        (should disposals)))))

(ert-deftest ejn-ei2-fully-inline-connect-and-verify-still-defer-consumer ()
  "Inline helper connect and kernel-info replies cannot reenter core users."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-start)
             (lambda (&rest arguments)
               (let ((helper 'fake-helper))
                 (funcall (plist-get arguments :ready-callback) helper nil)
                 helper)))
            ((symbol-function 'emacs-jupyter-notebook-helper-request)
             (lambda (_helper operation _params callback &rest _keys)
               (funcall callback nil
                        (pcase operation
                          ("connect" (ejn-ei2-test--attached-response))
                          ("kernel_info" (ejn-ei2-test--response))
                          (_ (ejn-ei2-test--closed-response)))
                        nil)
               1))
            ((symbol-function 'emacs-jupyter-notebook-helper-dispose) #'ignore))
    (ejn-ei2-test-with-session
      (let (connected)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/c.json" (lambda (_id value) (setq connected value)) #'ert-fail)
        (should-not connected)
        (ejn-ei2-test--run-timers)
        (should (eq connected session))))))

(ert-deftest ejn-ei2-close-is-local-and-removes-only-artifacts ()
  "Closing a helper session sends helper `close', never `shutdown'."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (artifact state)
        (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
        (setq artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir
                        (emacs-jupyter-notebook-backend-session-data session)))
        (setq state (emacs-jupyter-notebook-backend-session-data session))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (emacs-jupyter-notebook-backend-close-local session #'ignore #'ignore)
        (should (equal (caar requests) "close"))
        (should-not (member "shutdown" (mapcar #'car requests)))
        (should (emacs-jupyter-notebook-helper-backend--close-live-p
                 session state))
        (funcall (car callbacks) nil (ejn-ei2-test--closed-response) nil)
        (should (emacs-jupyter-notebook-helper-backend-state-retired
                 state))
        (ejn-ei2-test--run-timers)
        (should-not (file-exists-p artifact))))))

(ert-deftest ejn-ei2-late-callback-after-close-cannot-revive-session ()
  "A late verification reply cannot deliver after local session retirement."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (success)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/c.json" (lambda (&rest _) (setq success t)) #'ignore)
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (let ((verify (car callbacks)))
          (emacs-jupyter-notebook-backend-close-local session #'ignore #'ignore)
          (funcall verify nil (ejn-ei2-test--response) nil)
          (funcall (car callbacks) nil (ejn-ei2-test--closed-response) nil)
          (ejn-ei2-test--run-timers)
          (should-not success))))))

(ert-deftest ejn-ei2-invalid-connect-result-retires-private-state ()
  "A malformed connect result never marks a session attached or survives."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (failure state artifact)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/c.json" #'ignore
         (lambda (_id reason) (setq failure reason)))
        (setq state (emacs-jupyter-notebook-backend-session-data session)
              artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (should (string-match-p "invalid attachment" failure))
        (should (emacs-jupyter-notebook-helper-backend-state-retired state))
        (should-not (emacs-jupyter-notebook-backend-session-attached-p session))
        (should-not (file-exists-p artifact))
        (should disposals)))))

(ert-deftest ejn-ei2-helper-failure-after-attach-ignores-late-verify ()
  "A helper death between attach and verify retires that attempt permanently."
  (let (callbacks helper-failure disposals failure)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-start)
               (lambda (&rest arguments)
                 (setq helper-failure (plist-get arguments :failure-callback))
                 (let ((helper 'fake-helper))
                   (funcall (plist-get arguments :ready-callback) helper nil)
                   helper)))
              ((symbol-function 'emacs-jupyter-notebook-helper-request)
               (lambda (_helper _operation _params callback &rest _keys)
                 (push callback callbacks)))
              ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
               (lambda (_helper reason) (push reason disposals))))
      (ejn-ei2-test-with-session
        (let (state verify)
          (emacs-jupyter-notebook-backend-connect
           session "/tmp/c.json" #'ignore (lambda (_id reason) (setq failure reason)))
          (setq state (emacs-jupyter-notebook-backend-session-data session))
          (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
          (setq verify (car callbacks))
          (funcall helper-failure nil "transport lost")
          (funcall verify nil (ejn-ei2-test--response) nil)
          (ejn-ei2-test--run-timers)
          (should (string-match-p "transport lost" failure))
          (should (emacs-jupyter-notebook-helper-backend-state-retired state))
          (should disposals))))))

(ert-deftest ejn-ei2-pre-adoption-verify-error-disposes-local-helper ()
  "A readiness error before core adoption is an ordinary connect failure."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (state artifact failure)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/c.json" #'ignore (lambda (_id reason) (setq failure reason)))
        (should requests)
        (setq state (emacs-jupyter-notebook-backend-session-data session)
              artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil nil "kernel_info timed out")
        (ejn-ei2-test--run-timers)
        (should (string-match-p "kernel_info timed out" failure))
        (should (emacs-jupyter-notebook-helper-backend-state-retired state))
        (should-not (file-exists-p artifact))
        (should (= 1 (length disposals)))))))

(ert-deftest ejn-ei2-fatal-helper-death-after-adoption-disposes-locally ()
  "A helper death after terminal verify marks core dead and schedules recovery."
  (let (callbacks helper-failure disposals failure)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-start)
               (lambda (&rest arguments)
                 (setq helper-failure (plist-get arguments :failure-callback))
                 (let ((helper 'fake-helper))
                   (funcall (plist-get arguments :ready-callback) helper nil)
                   helper)))
              ((symbol-function 'emacs-jupyter-notebook-helper-request)
               (lambda (_helper _operation _params callback &rest _keys)
                 (push callback callbacks)))
              ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
               (lambda (_helper reason) (push reason disposals))))
      (ejn-ei2-test-with-session
        (let (state artifact verify (scheduled 0))
          (emacs-jupyter-notebook-backend-connect
           session "/tmp/c.json" #'ignore (lambda (_id reason) (setq failure reason)))
          (setq state (emacs-jupyter-notebook-backend-session-data session)
                artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
          (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
          (setq verify (car callbacks))
          (emacs-jupyter-notebook-backend-session-mark-installed session)
          (setf (emacs-jupyter-notebook-backend-session-failure-sink session)
                #'emacs-jupyter-notebook--backend-transport-failed)
          ;; Model the exact wedge: busy arbitration installed this session,
          ;; then the bounded readiness request retired before helper death.
          (setq emacs-jupyter-notebook--client session
                emacs-jupyter-notebook--session-entry (ejn-ei2-test--direct-entry)
                emacs-jupyter-notebook--kernel-status 'busy
                emacs-jupyter-notebook--tunnel-dead nil
                emacs-jupyter-notebook-mode t)
          (unwind-protect
              (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                         #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                         (lambda (&rest _) (cl-incf scheduled))))
                (funcall verify nil nil "kernel_info timed out")
                (ejn-ei2-test--run-timers)
                (should (= 0 (hash-table-count
                              (emacs-jupyter-notebook-backend-session-requests session))))
                (funcall helper-failure nil "helper transport lost")
                (ejn-ei2-test--run-timers)
                (should (= scheduled 1))
                (should emacs-jupyter-notebook--tunnel-dead)
                (should-not emacs-jupyter-notebook--kernel-status)
                (should (eq emacs-jupyter-notebook--client session))
                (should (string-match-p "kernel_info timed out" failure))
                (should (emacs-jupyter-notebook-helper-backend-state-retired state))
                (should-not (file-exists-p artifact))
                (should (= 1 (length disposals))))
            (setq emacs-jupyter-notebook--client nil
                  emacs-jupyter-notebook--session-entry nil
                  emacs-jupyter-notebook--kernel-status nil
                  emacs-jupyter-notebook--tunnel-dead nil)))))))

(ert-deftest ejn-ei2-artifact-setup-cleans-up-on-chmod-failure ()
  "A mode-setting error cannot leave an untracked artifact directory behind."
  (let ((directory (make-temp-file "ejn-ei2-artifact-chmod-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'set-file-modes)
                   (lambda (&rest _) (error "chmod failed"))))
          (cl-letf (((symbol-function 'make-temp-file)
                     (lambda (&rest _) directory)))
            (should-error
             (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
            (should-not (file-exists-p directory))))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(ert-deftest ejn-ei2-artifact-setup-cleans-up-on-identity-failure ()
  "A stat/identity error cannot leave an untracked artifact directory behind."
  (let ((directory (make-temp-file "ejn-ei2-artifact-stat-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (&rest _) directory))
                  ((symbol-function 'file-attributes)
                   (lambda (&rest _) (error "stat failed"))))
          (should-error
           (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
          (should-not (file-exists-p directory)))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(ert-deftest ejn-ei4-artifact-root-uses-canonical-ancestor-spelling ()
  "Artifact roots match helper paths across aliases such as Darwin's /var."
  (let* ((base (make-temp-file "ejn-ei4-root-alias-" t))
         (real (expand-file-name "real" base))
         (alias (expand-file-name "alias" base))
         pair)
    (unwind-protect
        (progn
          (make-directory real)
          (make-symbolic-link real alias)
          (let ((temporary-file-directory (file-name-as-directory alias)))
            (setq pair
                  (emacs-jupyter-notebook-helper-backend--make-artifact-directory)))
          (should (string-prefix-p (file-name-as-directory (file-truename real))
                                   (car pair)))
          (should-not (string-prefix-p (file-name-as-directory alias) (car pair))))
      (when (and pair (file-directory-p (car pair)))
        (delete-directory (car pair) t))
      (when (file-symlink-p alias) (delete-file alias))
      (when (file-directory-p real) (delete-directory real t))
      (when (file-directory-p base) (delete-directory base t)))))

(ert-deftest ejn-ei2-retired-a-callback-cannot-affect-b ()
  "A late A reply is inert after B gets its own backend session."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (let ((owner (generate-new-buffer " *ejn-ei2-a-b*")))
      (unwind-protect
          (let ((emacs-jupyter-notebook-backend 'helper))
            (with-current-buffer owner
              (let* ((a (emacs-jupyter-notebook-backend-session-create nil owner))
                     b a-verify)
                (unwind-protect
                    (progn
                      (emacs-jupyter-notebook-backend-connect
                       a "/tmp/a.json" #'ignore #'ignore)
                      (funcall (car callbacks) nil
                               (ejn-ei2-test--attached-response) nil)
                      (setq a-verify (car callbacks))
                      (emacs-jupyter-notebook-backend-close-local
                       a #'ignore #'ignore)
                      (funcall (car callbacks) nil
                               (ejn-ei2-test--closed-response) nil)
                      (setq b (emacs-jupyter-notebook-backend-session-create nil owner))
                      (emacs-jupyter-notebook-backend-connect
                       b "/tmp/b.json" #'ignore #'ignore)
                      (funcall a-verify nil (ejn-ei2-test--response) nil)
                      (should-not
                       (emacs-jupyter-notebook-backend-session-attached-p b)))
                  (dolist (session (delq nil (list a b)))
                    (when-let* ((state (emacs-jupyter-notebook-backend-session-data
                                        session)))
                      (when (emacs-jupyter-notebook-helper-backend-state-p state)
                        (emacs-jupyter-notebook-helper-backend--dispose
                         state "EI2 test cleanup"))))))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest ejn-ei2-core-start-helper-resolution-fails-before-admission ()
  "Helper resolution rejects a start before profile, registry, or SSH work."
  (let ((source (make-temp-file "ejn-ei2-source-"))
        profile context registry ssh artifacts)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source)
          (let ((emacs-jupyter-notebook-backend 'helper))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-backend-ensure)
                       (lambda () (error "helper missing")))
                      ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
                       (lambda (&rest _) (setq profile t)))
                      ((symbol-function 'emacs-jupyter-notebook--async-start-context)
                       (lambda (&rest _) (setq context t)))
                      ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                       (lambda (&rest _) (setq registry t)))
                      ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                       (lambda (&rest _) (setq ssh t)))
                      ((symbol-function 'emacs-jupyter-notebook-helper-backend--make-artifact-directory)
                       (lambda () (setq artifacts t))))
              (should-error (emacs-jupyter-notebook-start-remote-kernel "p"))
              (should-not (buffer-modified-p))
              (should-not profile)
              (should-not context)
              (should-not registry)
              (should-not ssh)
              (should-not artifacts))))
      (when (file-exists-p source) (delete-file source)))))

(ert-deftest ejn-ei2-core-reconnect-helper-resolution-fails-before-pid-probe ()
  "Reconnect resolves helper before context/PID/SSH work or durable mutation."
  (with-temp-buffer
    (let* ((entry (ejn-ei2-test--direct-entry))
           (original (copy-tree entry))
           (cleaned nil) context probe ssh)
      (let ((emacs-jupyter-notebook-backend 'helper)
            (emacs-jupyter-notebook--session-entry entry))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--release-local-resources)
                   (lambda () (setq cleaned t)))
                  ((symbol-function 'emacs-jupyter-notebook-helper-backend-ensure)
                   (lambda () (error "helper missing")))
                  ((symbol-function 'emacs-jupyter-notebook--async-reconnect-context)
                   (lambda (&rest _) (setq context t)))
                  ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
                   (lambda (&rest _) (setq probe t)))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (&rest _) (setq ssh t))))
          (should-error (emacs-jupyter-notebook--begin-reconnect entry nil nil))
          (should cleaned)
          (should-not context)
          (should-not probe)
          (should-not ssh)
          (should (equal entry original)))))))

(ert-deftest ejn-ei2-core-helper-arbitration-precedes-verify-deadline ()
  "Helper busy arbitration stays below its bounded verification request."
  (should (< emacs-jupyter-notebook--helper-connect-arbitration-maximum
             emacs-jupyter-notebook-helper-backend--verify-timeout))
  (let ((emacs-jupyter-notebook-backend 'helper)
        (emacs-jupyter-notebook-jupyter-connect-timeout 999))
    (should (= (emacs-jupyter-notebook--connect-arbitration-timeout) 45)))
  (let ((emacs-jupyter-notebook-backend 'helper)
        (emacs-jupyter-notebook-jupyter-connect-timeout 12))
    (should (= (emacs-jupyter-notebook--connect-arbitration-timeout) 12)))
  (dolist (invalid '(nil 0 -1 invalid))
    (let ((emacs-jupyter-notebook-backend 'helper)
          (emacs-jupyter-notebook-jupyter-connect-timeout invalid))
      (should (= (emacs-jupyter-notebook--connect-arbitration-timeout) 45)))))

(ert-deftest ejn-ei2-core-busy-pid-retains-session-after-bounded-verify-error ()
  "Busy adoption retires a failed readiness probe without disposing helper."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let* ((buffer (current-buffer))
             (entry (ejn-ei2-test--direct-entry))
             (context (emacs-jupyter-notebook--async-new-context
                       :phase 'connect :profile '(:profile "p" :host "host")
                       :entry entry :session-id "ei2-core"
                       :local-ports '(:shell_port 1001) :local-file "/tmp/ei2-core.json"
                       :tunnel-process 'fake-tunnel :origin-buffer buffer))
             (verify nil) (core-failure nil))
        (setq emacs-jupyter-notebook--async-context context)
        (unwind-protect
            (cl-letf (((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-registry-save-entry) #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--heartbeat-start) #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--inject-viewer-formatter) #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--inject-idle-watchdog) #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--execution-start-setup)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                       (lambda (name _argv _limit sentinel)
                         (let* ((stderr (generate-new-buffer " *ejn-ei2-probe-stderr*"))
                                (process (make-process
                                          :name name
                                          :buffer (generate-new-buffer " *ejn-ei2-probe*")
                                          :command '("sh" "-c" "printf \"__EJN_ALIVE_MATCH__\\n__EJN_DONE__\\n\"")
                                          :connection-type 'pipe :noquery t :sentinel sentinel
                                          :stderr stderr)))
                           (process-put process 'emacs-jupyter-notebook-stderr-buffer stderr)
                           process))))
              ;; Drive production `--async-connect': it constructs the helper
              ;; session, installs the arbitration timer, and owns the actual
              ;; verified/late callback ordering.
              (emacs-jupyter-notebook--async-connect context)
              (setq context emacs-jupyter-notebook--async-context
                    session (plist-get context :client-unverified))
              (should callbacks)
              (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
              (setq verify (car callbacks))
              (should (emacs-jupyter-notebook-backend-session-attached-p session))
                (emacs-jupyter-notebook--async-connect-timeout context buffer)
                (let ((deadline (+ (float-time) 2)))
                  (while (and (not (eq emacs-jupyter-notebook--client session))
                              (< (float-time) deadline))
                    (accept-process-output nil 0.02))))
              (should (eq emacs-jupyter-notebook--client session))
              (should (eq emacs-jupyter-notebook--kernel-status 'busy))
              (should-not disposals)
              (should-not core-failure)
              ;; The same correlated request now reaches its finite helper
              ;; deadline/error.  It must retire from the generic ledger but
              ;; cannot tear down the adopted busy session or its artifacts.
              (funcall verify nil nil "kernel_info timed out")
              (ejn-ei2-test--run-timers)
              (should (eq emacs-jupyter-notebook--client session))
              (should (eq emacs-jupyter-notebook--kernel-status 'busy))
              (should-not disposals)
              (should-not (emacs-jupyter-notebook-helper-backend-state-retired
                           (emacs-jupyter-notebook-backend-session-data session)))
              (should (= 0 (hash-table-count
                            (emacs-jupyter-notebook-backend-session-requests session))))
          (setq emacs-jupyter-notebook--async-context nil
                emacs-jupyter-notebook--client nil))))))

(ert-deftest ejn-ei2-core-save-failure-preserves-provisional-durables ()
  "Core finalization failure closes helper locally but preserves durable paths."
  (with-temp-buffer
    (let* ((registry-file (make-temp-file "ejn-ei2-registry-"))
           (buffer (current-buffer))
           (entry (ejn-ei2-test--direct-entry t))
           (original (copy-tree entry))
           (artifact (ejn-ei2-test--artifact-directory))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'fake-helper :artifact-dir artifact
                   :artifact-identity (file-attribute-file-identifier
                                       (file-attributes artifact))))
           (session (emacs-jupyter-notebook-backend--make-session
                     :backend 'helper :data state :owner-buffer buffer
                     :requests (make-hash-table :test #'eql) :timers nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :local-ports '(:shell_port 1001) :local-file "/tmp/ephemeral.json"
                     :client-unverified session :origin-buffer buffer
                     :error-callback (lambda (&rest _) nil)))
           shutdown remote-cleanup disposed)
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-file registry-file))
            ;; Model the launch admission contract: this provisional entry is
            ;; already durable before the helper attachment can fail.
            (emacs-jupyter-notebook-registry-save-entry entry)
            (setq emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                       (lambda (&rest _) (error "disk full")))
                      ((symbol-function 'emacs-jupyter-notebook-helper-request)
                       (lambda (_helper operation _params callback &rest _keys)
                         (when (equal operation "close")
                           (funcall callback nil (ejn-ei2-test--closed-response) nil))))
                      ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                       (lambda (&rest _) (setq disposed t)))
                      ((symbol-function 'emacs-jupyter-notebook-backend-control)
                       (lambda (&rest _) (setq shutdown t)))
                      ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                       (lambda (&rest _) (setq remote-cleanup t))))
              (emacs-jupyter-notebook--async-connect-finalize
               context buffer entry '(:shell_port 1001) "/tmp/ephemeral.json" session)
              (ejn-ei2-test--run-timers)
              (should-not emacs-jupyter-notebook--client)
              (should disposed)
              (should-not shutdown)
              (should-not remote-cleanup)
              (should (equal entry original))
              (should (equal (emacs-jupyter-notebook-registry-load registry-file)
                             (list original)))
              (should (equal (plist-get entry :remote-connection-file)
                             (plist-get original :remote-connection-file)))
              (should (equal (plist-get entry :local-connection-file)
                             (plist-get original :local-connection-file)))))
        (setq emacs-jupyter-notebook--async-context nil
              emacs-jupyter-notebook--client nil)
        (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup")
        (when (file-exists-p registry-file)
          (delete-file registry-file))))))

(ert-deftest ejn-ei2-core-post-install-error-does-not-retain-closed-client ()
  "A local finalization error cannot leave the disposed helper looking live."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (entry (ejn-ei2-test--direct-entry))
           (artifact (ejn-ei2-test--artifact-directory))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'fake-helper :artifact-dir artifact
                   :artifact-identity (file-attribute-file-identifier
                                       (file-attributes artifact))))
           (session (emacs-jupyter-notebook-backend--make-session
                     :backend 'helper :data state :owner-buffer buffer
                     :attached t :requests (make-hash-table :test #'eql)
                     :timers nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :local-ports '(:shell_port 1001) :local-file "/tmp/ei2-core.json"
                     :client-unverified session :origin-buffer buffer
                     :error-callback (lambda (&rest _) nil)))
           disposed shutdown remote-cleanup)
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--heartbeat-start)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--execution-start-setup)
                       (lambda (&rest _) (error "formatter setup failed")))
                      ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-helper-request)
                       (lambda (_helper operation _params callback &rest _keys)
                         (when (equal operation "close")
                           (funcall callback nil (ejn-ei2-test--closed-response) nil))))
                      ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                       (lambda (&rest _) (setq disposed t)))
                      ((symbol-function 'emacs-jupyter-notebook-backend-control)
                       (lambda (&rest _) (setq shutdown t)))
                      ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                       (lambda (&rest _) (setq remote-cleanup t))))
              (emacs-jupyter-notebook--async-connect-finalize
               context buffer entry '(:shell_port 1001) "/tmp/ei2-core.json" session)
              (ejn-ei2-test--run-timers)
              (should-not emacs-jupyter-notebook--client)
              (should (emacs-jupyter-notebook-backend-session-closed session))
              (should disposed)
              (should-not (file-exists-p artifact))
              (should-not shutdown)
              (should-not remote-cleanup)))
        (setq emacs-jupyter-notebook--async-context nil
              emacs-jupyter-notebook--client nil)
        (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup")))))

(ert-deftest ejn-ei2-core-success-callback-error-keeps-installed-client ()
  "Consumer failure after commit cannot tear down a healthy helper session."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (buffer (current-buffer))
           (entry (ejn-ei2-test--direct-entry))
           (session (emacs-jupyter-notebook-backend-session-create nil buffer))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :local-ports '(:shell_port 1001) :local-file "/tmp/ei2-core.json"
                     :client-unverified session :origin-buffer buffer
                     :callback (lambda (&rest _) (error "consumer failed"))))
           (heartbeat-started 0))
      (emacs-jupyter-notebook-backend-session-mark-attached session)
      (setq emacs-jupyter-notebook--async-context context)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--heartbeat-start)
                     (lambda () (cl-incf heartbeat-started)))
                    ((symbol-function 'emacs-jupyter-notebook--inject-viewer-formatter)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--inject-idle-watchdog)
                     #'ignore))
            (should (emacs-jupyter-notebook--async-connect-finalize
                     context buffer entry '(:shell_port 1001)
                     "/tmp/ei2-core.json" session))
            (should (eq emacs-jupyter-notebook--client session))
            (should (emacs-jupyter-notebook-backend-session-installed-p session))
            (should (eq (plist-get context :phase) 'done))
            (should (= heartbeat-started 0))
            (should-not emacs-jupyter-notebook--tunnel-dead))
        (setq emacs-jupyter-notebook--async-context nil
              emacs-jupyter-notebook--client nil)))))

(ert-deftest ejn-ei2-release-local-resources-closes-helper-only ()
  "Mode-disable cleanup retires a pending verify without touching durability."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let ((entry (ejn-ei2-test--direct-entry)) artifact verify shutdown deregister)
        (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
        (setq artifact
              (emacs-jupyter-notebook-helper-backend-state-artifact-dir
               (emacs-jupyter-notebook-backend-session-data session)))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (setq verify (car callbacks))
        (emacs-jupyter-notebook-backend-session-mark-installed session)
        (setq emacs-jupyter-notebook--client session
              emacs-jupyter-notebook--session-entry entry)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                   (lambda (&rest _) (setq shutdown t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq deregister t))))
          (emacs-jupyter-notebook--release-local-resources))
        (should-not emacs-jupyter-notebook--client)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should (equal (caar requests) "close"))
        (should-not shutdown)
        (should-not deregister)
        (funcall (car callbacks) nil (ejn-ei2-test--closed-response) nil)
        (funcall verify nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (should disposals)
        (should-not (file-exists-p artifact))))))

(ert-deftest ejn-ei2-close-error-disposes-exactly-once ()
  "A helper-local close error still retires helper and artifacts once."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (state artifact close-error)
        (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
        (setq state (emacs-jupyter-notebook-backend-session-data session)
              artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (emacs-jupyter-notebook-backend-close-local
         session #'ignore (lambda (_id reason) (setq close-error reason)))
        (should (equal (caar requests) "close"))
        (funcall (car callbacks) nil nil "helper died")
        (funcall (car callbacks) nil nil "duplicate")
        (ejn-ei2-test--run-timers)
        (should (string-match-p "helper died" close-error))
        (should (emacs-jupyter-notebook-helper-backend-state-retired state))
        (should-not (file-exists-p artifact))
        (should (= 1 (length disposals)))))))

(ert-deftest ejn-ei2-artifact-cleanup-refuses-symlink-replacement ()
  "A replaced artifact path cannot recursively delete a foreign target."
  (let* ((directory (ejn-ei2-test--artifact-directory))
         (target (make-temp-file "ejn-ei2-foreign-" t))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir directory
                 :artifact-identity
                 (file-attribute-file-identifier (file-attributes directory))))
         (sentinel (expand-file-name "keep" target)))
    (unwind-protect
        (progn
          (with-temp-file sentinel (insert "foreign"))
          (delete-directory directory)
          (make-symbolic-link target directory)
          (emacs-jupyter-notebook-helper-backend--remove-artifacts state)
          (should-not (file-symlink-p directory))
          (should (file-exists-p sentinel)))
      (when (file-symlink-p directory) (delete-file directory))
      (when (file-directory-p directory) (delete-directory directory t))
      (when (file-directory-p target) (delete-directory target t)))))

(ert-deftest ejn-ei2-artifact-cleanup-refuses-identity-mismatched-directory ()
  "A real replacement directory remains untouched when its identity differs."
  (let* ((directory (ejn-ei2-test--artifact-directory))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir directory
                 :artifact-identity
                 (file-attribute-file-identifier (file-attributes directory))))
         sentinel)
    (unwind-protect
        (progn
          (delete-directory directory)
          (make-directory directory)
          (set-file-modes directory #o700)
          ;; Ensure this test models a distinct replacement even on filesystems
          ;; that immediately recycle an inode after unlink.
          (setf (emacs-jupyter-notebook-helper-backend-state-artifact-identity state)
                'foreign-replacement)
          (setq sentinel (expand-file-name "foreign" directory))
          (with-temp-file sentinel (insert "foreign"))
          (emacs-jupyter-notebook-helper-backend--remove-artifacts state)
          (should (file-exists-p sentinel)))
      (when (file-directory-p directory) (delete-directory directory t)))))

(ert-deftest ejn-ei2-artifact-stat-error-cannot-suppress-connect-failure ()
  "Conservative cleanup metadata failure still terminally retires the request."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let* ((state nil) (artifact nil) failure)
        (unwind-protect
            (progn
              (emacs-jupyter-notebook-backend-connect
               session "/tmp/c.json" #'ignore
               (lambda (_id reason) (setq failure reason)))
              (should requests)
              (setq state (emacs-jupyter-notebook-backend-session-data session)
                    artifact
                    (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
              (cl-letf (((symbol-function 'file-attributes)
                         (lambda (&rest _) (error "stat failed"))))
                (funcall (car callbacks) nil (ejn-ei2-test--response) nil))
              (ejn-ei2-test--run-timers)
              (should (string-match-p "invalid attachment result" failure))
              (should (emacs-jupyter-notebook-helper-backend-state-retired state))
              (should-not
               (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
              (should (= 1 (length disposals)))
              ;; Cleanup could not prove identity, so it correctly preserved
              ;; the pathname while still delivering the backend failure.
              (should (file-directory-p artifact)))
          (when (and artifact (file-directory-p artifact))
            (delete-directory artifact t)))))))

(ert-deftest ejn-ei2-close-retired-or-helperless-state-completes-immediately ()
  "Generic local close never waits for a helper that has already retired."
  (dolist (state (list (emacs-jupyter-notebook-helper-backend--make-state :retired t)
                       (emacs-jupyter-notebook-helper-backend--make-state)))
    (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
      (ejn-ei2-test-with-session
        (let (closed)
          (setf (emacs-jupyter-notebook-backend-session-data session) state)
          (emacs-jupyter-notebook-backend-close-local
           session (lambda (_id value) (setq closed value))
           (lambda (_id reason) (ert-fail reason)))
          (ejn-ei2-test--run-timers)
          (should (equal closed nil))
          (should-not requests))))))

(ert-deftest ejn-ei2-close-deadline-is-strictly-before-generic-deadline ()
  "Even tiny valid generic deadlines leave a distinct adapter completion turn."
  (dolist (timeout '(0.0001 0.01 0.02 5))
    (let ((emacs-jupyter-notebook-backend-close-timeout timeout))
      (should (< (emacs-jupyter-notebook-helper-backend--close-deadline)
                 (emacs-jupyter-notebook-backend--close-timeout))))))

(ert-deftest ejn-ei2-close-rejects-malformed-success-result ()
  "An `ok' helper close reply without exact `{closed:true}' is failure."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (state artifact close-error)
        (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
        (setq state (emacs-jupyter-notebook-backend-session-data session)
              artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (emacs-jupyter-notebook-backend-close-local
         session #'ignore (lambda (_id reason) (setq close-error reason)))
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (should (string-match-p "invalid result" close-error))
        (should (emacs-jupyter-notebook-helper-backend-state-retired state))
        (should-not (file-exists-p artifact))
        (should (= 1 (length disposals)))))))


(ert-deftest ejn-ei3-helper-execute-and-is-complete-use-v1-operations ()
  "EI3 admits user execute/is_complete and rejects unrelated helper operations."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           requests execute-error complete-result readiness-result control-error)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper operation params callback &rest _keys)
                   (push (list operation params) requests)
                   (funcall callback 'fake
                            (ejn-ei2-test--response
                             (if (equal operation "is_complete")
                                 (ejn-ei2-test--object "status" "complete")
                               (ejn-ei2-test--object "status" "ok"
                                                    "execution_count" 1))) nil)
                   (format "ejn-request-test-%d" (length requests)))))
        (emacs-jupyter-notebook-backend-execute
         session "user()" '(:ledger-id 7) #'ignore
         (lambda (_id error) (setq execute-error error)))
        (emacs-jupyter-notebook-backend-aux
         session 'is-complete '(:code "x")
         (lambda (_id reply) (setq complete-result reply))
         (lambda (_id error) (setq complete-result error)))
        (emacs-jupyter-notebook-backend-aux
         session 'kernel-info nil
         (lambda (_id reply) (setq readiness-result reply))
         (lambda (_id error) (setq readiness-result error)))
        (emacs-jupyter-notebook-backend-control
         session 'interrupt nil #'ignore
         (lambda (_id error) (setq control-error error)))
        (ejn-ei2-test--run-timers)
        (ejn-ei2-test--run-timers)
        (should-not execute-error)
        (should (equal complete-result '(:status "complete")))
        (should (hash-table-p readiness-result))
        (should (equal (mapcar #'car requests)
                       '("kernel_info" "is_complete" "execute")))
        (should (string-match-p "unavailable until EI5"
                                (error-message-string control-error)))))))

(ert-deftest ejn-ei2-transport-events-are-not-normalized-before-ei4 ()
  "Raw helper events do not reach the generic session event sink in EI2."
  (let (seen)
    (with-temp-buffer
      (let ((session (emacs-jupyter-notebook-backend-session-create
                      (lambda (_session event) (setq seen event)) (current-buffer)))
            (state (emacs-jupyter-notebook-helper-backend--make-state)))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (emacs-jupyter-notebook-helper-backend--event
         session state (ejn-ei2-test--object "event" "transport_error"
                                             "data" (ejn-ei2-test--object "message" "x")))
        (should-not seen)))))

(ert-deftest ejn-ei2-static-helper-path-has-no-sync-wait-or-legacy-adapter ()
  "The EI2 adapter never introduces blocking or legacy Jupyter calls."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "../emacs-jupyter-notebook-helper-backend.el"
                       ejn-ei2-test--directory))
    (should-not (re-search-forward "\\_<accept-process-output\\_>" nil t))
    (should-not (re-search-forward "emacs-jupyter-notebook-jupyter" nil t))
    (should-not (re-search-forward "emacs-jupyter-notebook-jupyter-" nil t))))

(ert-deftest ejn-ei3-helper-wire-id-map-survives-reentrant-event ()
  "A string helper wire id is mapped before a reentrant event reaches the sink."
  (let (seen)
    (with-temp-buffer
      (let* ((emacs-jupyter-notebook-backend 'helper)
             (session (emacs-jupyter-notebook-backend-session-create
                       (lambda (_session event) (setq seen event)) (current-buffer)))
             (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake)))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                   (lambda (_helper _operation _params callback &rest _keys)
                     (emacs-jupyter-notebook-helper-backend--event
                      session state
                      (ejn-ei2-test--object "event" "status"
                                            "request_id" "ejn-request-9-1"
                                            "data" (ejn-ei2-test--object "execution_state" "idle")))
                     (funcall callback 'fake
                              (ejn-ei2-test--response
                               (ejn-ei2-test--object "status" "ok"
                                                    "execution_count" 1))
                              nil)
                     "ejn-request-9-1")))
          (emacs-jupyter-notebook-backend-execute
           session "x" '(:ledger-id 19) #'ignore #'ignore)
          (ejn-ei2-test--run-timers)
          (should (eq (plist-get seen :type) 'helper-event))
          (should (= (plist-get seen :ledger-id) 19))
          (should (integerp (plist-get seen :backend-request-id)))
          (should-not (plist-get seen :panel-generation))
          (should (equal (plist-get seen :helper-request-id) "ejn-request-9-1"))
          (should (equal (plist-get (plist-get seen :event) :type) 'status))
          (should (equal (plist-get
                          (gethash "ejn-request-9-1"
                                   (emacs-jupyter-notebook-helper-backend-state-request-map state))
                         :ledger-id)
                         19))
          (should (= (hash-table-count
                      (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                     0))
          (emacs-jupyter-notebook-helper-backend-retire-ledger-id session 19)
          (should-not (gethash "ejn-request-9-1"
                               (emacs-jupyter-notebook-helper-backend-state-request-map state))))))))

(ert-deftest ejn-ei3-helper-execute-result-normalizes-abort-and-rejects-malformed ()
  "Helper terminal results preserve error/count instead of manufacturing ok."
  (let ((ok (ejn-ei2-test--object "status" "ok" "execution_count" 4))
        (aborted (ejn-ei2-test--object "status" "aborted" "execution_count" 4))
        (bad (ejn-ei2-test--object "status" "ok")))
    (should (equal (emacs-jupyter-notebook-helper-backend--execute-result ok)
                   '(:status "ok" :execution-count 4)))
    (should (equal (emacs-jupyter-notebook-helper-backend--execute-result aborted)
                   '(:status "error" :execution-count 4)))
    (should-error (emacs-jupyter-notebook-helper-backend--execute-result bad))))

(ert-deftest ejn-ei3-helper-correlation-burst-is-bounded-and-disposed ()
  "Unmapped raw-event bursts retain at most one descriptor per bounded id."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state)))
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 1)
      (dotimes (index 200)
        (emacs-jupyter-notebook-helper-backend--event
         session state
         (ejn-ei2-test--object "event" "stream"
                               "request_id" (format "ejn-request-burst-%d" index))))
      (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0)
      (should (= (hash-table-count
                  (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                 128))
      (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup")
      (should (= (hash-table-count
                  (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                     0)))))

(ert-deftest ejn-ei4-helper-normalizes-real-terminal-and-text-events ()
  "EI4 accepts only bounded helper shapes before they reach the reducer."
  (let ((state (emacs-jupyter-notebook-helper-backend--make-state)))
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
              state (ejn-ei2-test--object "event" "execute_reply"
                                          "data" (ejn-ei2-test--object
                                                    "status" "ok" "execution_count" 4)))
             '(:type execute-reply :status "ok" :execution-count 4)))
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
              state (ejn-ei2-test--object "event" "stream"
                                          "data" (ejn-ei2-test--object
                                                    "name" "stdout" "text" "x\n")))
             '(:type stream :text "x\n" :name "stdout")))
    ;; `execution_count' is legitimately absent in a canonical reply.
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
             state (ejn-ei2-test--object "event" "execute_reply"
                                          "data" (ejn-ei2-test--object "status" "ok")))
             '(:type execute-reply :status "ok" :execution-count nil)))
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
              state (ejn-ei2-test--object "event" "clear_output"
                                          "data" (ejn-ei2-test--object "wait" :false)))
             '(:type clear :wait nil)))
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
              state (ejn-ei2-test--object "event" "status"
                                          "data" (ejn-ei2-test--object
                                                    "execution_state" "busy")))
             '(:type status :execution-state "busy")))
    (should (equal
             (emacs-jupyter-notebook-helper-backend--normalize-event
              state (ejn-ei2-test--object "event" "output_truncated"
                                          "data" (ejn-ei2-test--object
                                                    "dropped_bytes" 12)))
             '(:type truncation :text "[output truncated]\n")))))

(ert-deftest ejn-ei4-normalizer-rejects-malformed-branch-shapes ()
  "Every helper output branch rejects malformed shapes before EI1R mutation."
  (let* ((state (emacs-jupyter-notebook-helper-backend--make-state))
         (metadata (ejn-ei2-test--object))
         (text-data (ejn-ei2-test--object "text/plain" "ok"))
         (rich (lambda (name &rest pairs)
                 (ejn-ei2-test--object
                  "event" name "data"
                  (apply #'ejn-ei2-test--object
                         "data" text-data "metadata" metadata pairs)))))
    (should (eq (plist-get
                 (emacs-jupyter-notebook-helper-backend--normalize-event
                  state (funcall rich "display_data"))
                 :type)
                'display))
    (should (eq (plist-get
                 (emacs-jupyter-notebook-helper-backend--normalize-event
                  state (funcall rich "execute_result"))
                 :type)
                'result))
    (dolist
        (raw
         (list
          (ejn-ei2-test--object "event" "unknown" "data" (ejn-ei2-test--object))
          (ejn-ei2-test--object "event" "stream" "data"
                                (ejn-ei2-test--object "name" "log" "text" "x"))
          (ejn-ei2-test--object "event" "clear_output" "data"
                                (ejn-ei2-test--object))
          (ejn-ei2-test--object "event" "status" "data"
                                (ejn-ei2-test--object "execution_state" 1))
          (ejn-ei2-test--object "event" "execute_reply" "data"
                                (ejn-ei2-test--object "status" "maybe"))
          (ejn-ei2-test--object "event" "input_request" "data"
                                (ejn-ei2-test--object "prompt" "unsafe"))
          (ejn-ei2-test--object "event" "display_data" "data"
                                (ejn-ei2-test--object "data" text-data))
          (funcall rich "display_data" "transient" "not-an-object")
          (funcall rich "display_data" "transient"
                   (ejn-ei2-test--object "display_id" (make-string 257 ?x)))
          (funcall rich "display_data" "data"
                   (ejn-ei2-test--object "image/png" "base64-is-not-an-artifact"))
          (funcall rich "execute_result" "update" t)))
      (should-error
       (emacs-jupyter-notebook-helper-backend--normalize-event state raw)))))

(ert-deftest ejn-ei4-reentrant-terminal-fifo-flushes-once-after-dispatch ()
  "Reply then idle from a synchronous helper fake stay FIFO and post-dispatch."
  (let (seen)
    (with-temp-buffer
      (let* ((emacs-jupyter-notebook-backend 'helper)
             (session (emacs-jupyter-notebook-backend-session-create
                       (lambda (_session event)
                         (setq seen (append seen
                                            (list (plist-get (plist-get event :event) :type))))
                         t)
                       (current-buffer)))
             (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake)))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                   (lambda (_helper _operation _params callback &rest _keys)
                     (dolist (event
                              (list
                               (ejn-ei2-test--object
                                "event" "execute_reply" "request_id" "ejn-request-ei4-1"
                                "data" (ejn-ei2-test--object "status" "ok"))
                               (ejn-ei2-test--object
                                "event" "status" "request_id" "ejn-request-ei4-1"
                                "data" (ejn-ei2-test--object "execution_state" "idle"))))
                       (emacs-jupyter-notebook-helper-backend--event session state event))
                     (funcall callback 'fake
                              (ejn-ei2-test--response
                               (ejn-ei2-test--object "status" "ok" "execution_count" 1)) nil)
                     "ejn-request-ei4-1")))
          (emacs-jupyter-notebook-backend-execute
           session "x" '(:ledger-id 29) #'ignore #'ignore)
          (should-not seen)
          (ejn-ei2-test--run-timers)
          (should (equal seen '(execute-reply status)))
          (should (= (hash-table-count
                      (emacs-jupyter-notebook-helper-backend-state-pending-events state)) 0))
          (should-not (timerp
                       (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state))))))))

(ert-deftest ejn-ei4-early-events-keep-global-order-across-helper-ids ()
  "Mapped reentrant events restore arrival order across helper request IDs."
  (let (seen)
    (with-temp-buffer
      (let* ((session (emacs-jupyter-notebook-backend-session-create
                       nil
                       (current-buffer)))
             (mapping (make-hash-table :test #'equal))
             (state (emacs-jupyter-notebook-helper-backend--make-state
                     :request-map mapping
                     :emit (lambda (event)
                             (push (cons (plist-get event :helper-request-id)
                                         (plist-get (plist-get event :event) :type))
                                   seen)
                             t))))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 1)
        (dolist (spec '(("a" "stream" "a1")
                        ("b" "stream" "b1")
                        ("a" "stream" "a2")
                        ("b" "stream" "b2")))
          (emacs-jupyter-notebook-helper-backend--event
           session state
           (ejn-ei2-test--object
            "event" (nth 1 spec) "request_id" (car spec)
            "data" (ejn-ei2-test--object "name" "stdout" "text" (nth 2 spec)))))
        (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0)
        (puthash "a" '(:ledger-id 1 :backend-request-id 11) mapping)
        (puthash "b" '(:ledger-id 2 :backend-request-id 12) mapping)
        (emacs-jupyter-notebook-helper-backend--flush-pending-events session state)
        (should (equal (nreverse seen)
                       '(("a" . stream) ("b" . stream)
                         ("a" . stream) ("b" . stream))))
        (should (= (hash-table-count
                    (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                   0))))))

(ert-deftest ejn-ei4-rejected-or-malformed-early-output-cannot-drop-terminals ()
  "One bad early output cannot suppress its later real reply and idle events."
  (let (seen messages)
    (with-temp-buffer
      (let* ((session (emacs-jupyter-notebook-backend-session-create
                       nil
                       (current-buffer)))
             (mapping (make-hash-table :test #'equal))
             (state (emacs-jupyter-notebook-helper-backend--make-state
                     :request-map mapping
                     :emit (lambda (event)
                             (let ((type (plist-get (plist-get event :event) :type)))
                               (push type seen)
                               (not (eq type 'update-display)))))))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 1)
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (dolist (event
                   (list
                    (ejn-ei2-test--object
                     "event" "display_data" "request_id" "wire"
                     "data" (ejn-ei2-test--object
                              "data" (ejn-ei2-test--object "text/plain" "bad update")
                              "metadata" (ejn-ei2-test--object)
                              "update" t))
                    ;; This malformed item must be isolated rather than aborting
                    ;; the remainder of the bounded FIFO.
                    (ejn-ei2-test--object "event" "display_data"
                                          "request_id" "wire"
                                          "data" (ejn-ei2-test--object))
                    (ejn-ei2-test--object
                     "event" "execute_reply" "request_id" "wire"
                     "data" (ejn-ei2-test--object "status" "ok"))
                    (ejn-ei2-test--object
                     "event" "status" "request_id" "wire"
                     "data" (ejn-ei2-test--object "execution_state" "idle"))))
            (emacs-jupyter-notebook-helper-backend--event session state event))
          (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0)
          (puthash "wire" '(:ledger-id 1 :backend-request-id 11) mapping)
          (emacs-jupyter-notebook-helper-backend--flush-pending-events session state))
        (should (equal (nreverse seen) '(update-display execute-reply status)))
        (should (= (length messages) 1))
        (should (string-match-p "rejected early helper event" (car messages)))
        (should (= (hash-table-count
                    (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                   0))))))

(ert-deftest ejn-ei4-unaccepted-helper-publications-are-discarded-safely ()
  "Rejected and malformed helper publications do not accumulate on disk."
  (let* ((pair (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
         (root (car pair))
         (identity (cdr pair))
         (mapping '(:ledger-id 1 :backend-request-id 11))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir root :artifact-identity identity :emit #'ignore))
         (make-event
          (lambda (path &optional malformed)
            (ejn-ei2-test--object
             "event" "display_data" "request_id" "wire"
             "data" (ejn-ei2-test--object
                      "data" (ejn-ei2-test--object
                              "image/png"
                              (ejn-ei2-test--object
                               "path" path "bytes" 4
                               "sha256" (make-string 64 ?a)))
                      "metadata" (if malformed "bad" (ejn-ei2-test--object)))))))
    (unwind-protect
        (progn
          (dolist (malformed '(nil t))
            (let ((path (expand-file-name
                         (format "ejn-artifact-%032x" (if malformed 2 1)) root)))
              (with-temp-file path (insert "data"))
              (set-file-modes path #o600)
              (if malformed
                  (should-error
                   (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
                    state "wire" mapping (funcall make-event path t)))
                (should-not
                 (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
                  state "wire" mapping (funcall make-event path))))
              (should-not (file-exists-p path))))
          ;; Even an unaccepted event cannot ask the adapter to delete a file
          ;; outside the exact helper publication namespace.
          (let ((unrelated (expand-file-name "unrelated" root)))
            (with-temp-file unrelated (insert "keep"))
            (set-file-modes unrelated #o600)
            (should-not
             (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
              state "wire" mapping (funcall make-event unrelated)))
            (should (file-exists-p unrelated))))
      (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup")
      (when (file-directory-p root) (delete-directory root t)))))

(ert-deftest ejn-ei4-retired-wire-events-never-reenter-early-buffer ()
  "Late events for a tombstoned helper ID consume no pending-event capacity."
  (let* ((pair (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
         (root (car pair))
         (path (expand-file-name
                "ejn-artifact-00000000000000000000000000000009" root))
         seen state)
    (unwind-protect
        (with-temp-buffer
          (let* ((mapping (make-hash-table :test #'equal))
                 (session (emacs-jupyter-notebook-backend-session-create nil (current-buffer))))
            (setq state
                  (emacs-jupyter-notebook-helper-backend--make-state
                   :artifact-dir root :artifact-identity (cdr pair)
                   :request-map mapping
                   :pending-events (make-hash-table :test #'equal)
                   :emit (lambda (event) (push event seen))))
            (setf (emacs-jupyter-notebook-backend-session-data session) state)
            (puthash "retired-wire" '(:ledger-id 9 :backend-request-id 19) mapping)
            (emacs-jupyter-notebook-helper-backend-retire-ledger-id session 9)
            (dolist (name '("stream" "status" "display_data"))
              (emacs-jupyter-notebook-helper-backend--event
               session state
               (ejn-ei2-test--object "event" name "request_id" "retired-wire"
                                     "data" (ejn-ei2-test--object))))
            (with-temp-file path (insert "late"))
            (set-file-modes path #o600)
            (emacs-jupyter-notebook-helper-backend--event
             session state
             (ejn-ei2-test--object
              "event" "display_data" "request_id" "retired-wire"
              "data" (ejn-ei2-test--object
                       "data" (ejn-ei2-test--object
                               "image/png" (ejn-ei2-test--object
                                            "path" path "bytes" 4
                                            "sha256" (make-string 64 ?a)))
                       "metadata" (ejn-ei2-test--object))))
            (should-not (file-exists-p path))
            (should-not seen)
            (should (= (hash-table-count
                        (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                       0))
            (should (gethash
                     "retired-wire"
                     (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state)))))
      (when state (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup"))
      (when (file-directory-p root) (delete-directory root t)))))

(ert-deftest ejn-ei4-helper-dispose-removes-only-partial-staging ()
  "Adapter cleanup preserves publications without retaining an unbounded map."
  (let* ((root (ejn-ei2-test--artifact-directory))
         (publication (expand-file-name "ejn-artifact-published" root))
         (staging (expand-file-name ".ejn-partial-staging" root))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir root
                 :artifact-identity (file-attribute-file-identifier (file-attributes root)))))
    (unwind-protect
        (progn
          (with-temp-file publication (insert "published"))
          (set-file-modes publication #o600)
          (with-temp-file staging (insert "staging"))
          (emacs-jupyter-notebook-helper-backend--dispose state "test")
          (should (file-exists-p publication))
          (should-not (file-exists-p staging)))
      (ignore-errors (delete-file publication))
      (ignore-errors (delete-directory root)))))

(ert-deftest ejn-ei4-normalizes-ht9-display-update-and-id ()
  "HT9's display_data/update flag retains the bounded display identity."
  (let* ((state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir "/tmp/ejn-ei4-root"
                 :artifact-identity '(7 . 11)))
         (payload (ejn-ei2-test--object "text/plain" "new"))
         (transient (ejn-ei2-test--object "display_id" "plot-1"))
         (raw (ejn-ei2-test--object
               "event" "display_data"
               "data" (ejn-ei2-test--object
                        "data" payload "metadata" (ejn-ei2-test--object)
                        "transient" transient "update" t)))
         (normalized (emacs-jupyter-notebook-helper-backend--normalize-event
                      state raw)))
    (should (eq (plist-get normalized :type) 'update-display))
    (should (equal (plist-get normalized :data) '(:text/plain "new")))
    (should (equal (plist-get normalized :display-id) "plot-1"))
    (should (eq (plist-get normalized :require-display-id) t))
    (should (equal (gethash "display_id" (plist-get normalized :transient))
                   "plot-1"))
    (let* ((artifact (ejn-ei2-test--object
                      "path" "/tmp/ejn-ei4-root/ejn-artifact-1"
                      "bytes" 12 "sha256" (make-string 64 ?a)))
           (artifact-event
            (ejn-ei2-test--object
             "event" "display_data"
             "data" (ejn-ei2-test--object
                      "data" (ejn-ei2-test--object "image/png" artifact)
                      "metadata" (ejn-ei2-test--object))))
           (publication
            (plist-get
             (plist-get
              (emacs-jupyter-notebook-helper-backend--normalize-event
               state artifact-event)
              :data)
             :ejn-published-image)))
      (should (equal (plist-get publication :root) "/tmp/ejn-ei4-root"))
      (should (equal (plist-get publication :root-identity) '(7 . 11)))
      (should (equal (plist-get publication :path)
                     "/tmp/ejn-ei4-root/ejn-artifact-1"))
      (should (= (plist-get publication :size) 12)))
    (puthash "update" "not-a-boolean" (gethash "data" raw))
    (should-error
     (emacs-jupyter-notebook-helper-backend--normalize-event state raw))))

(provide 'emacs-jupyter-notebook-helper-backend-tests)

;;; emacs-jupyter-notebook-helper-backend-tests.el ends here
