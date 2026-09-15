;;; emacs-jupyter-notebook-helper-backend-tests.el --- EI2 adapter tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-artifacts)

(defconst ejn-ei2-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar ejn-ei2-test--artifact-capabilities (make-hash-table :test #'equal))

(defun ejn-ei2-test--object (&rest pairs)
  (apply #'emacs-jupyter-notebook-helper-backend--make-object pairs))

(defun ejn-ei4d-test--image-descriptor (path bytes sha256 &optional preview)
  "Return the required nested helper image descriptor for test fixtures."
  (let ((original (ejn-ei2-test--object
                   "path" path "bytes" bytes "sha256" sha256)))
    (if preview
        (ejn-ei2-test--object "original" original "preview" preview)
      (ejn-ei2-test--object "original" original))))

(defun ejn-ei2-test--response (&optional result)
  (ejn-ei2-test--object "ok" t "result" (or result (make-hash-table :test #'equal))))

(defun ejn-ei2-test--attached-response ()
  (ejn-ei2-test--response (ejn-ei2-test--object "attached" t)))

(defun ejn-ei2-test--closed-response ()
  (ejn-ei2-test--response (ejn-ei2-test--object "closed" t)))

(defun ejn-ei2-test--kernel-info-result ()
  "Return the minimum structurally useful helper kernel-info fixture."
  (ejn-ei2-test--object
   "protocol_version" "5.3" "implementation" "ipython"
   "language_info" (ejn-ei2-test--object "name" "python")))

(defun ejn-ei2-test--kernel-info-response ()
  (ejn-ei2-test--response (ejn-ei2-test--kernel-info-result)))

(defun ejn-ei2-test--input-response ()
  (ejn-ei2-test--response (ejn-ei2-test--object "accepted" t)))

(defun ejn-ei2-test--run-timers ()
  (accept-process-output nil 0.02))

(defun ejn-ei2-test--registry-replace-succeeds
    (entry _expected-revision success _failure &rest _keys)
  "Return a deferred successful CAS for lifecycle tests.

Production callbacks are necessarily asynchronous because each transaction is
owned by a child worker.  Keeping this mock deferred catches code which
incorrectly assumes an inline persistence callback."
  (let ((persisted (copy-tree entry)))
    (setq persisted (plist-put persisted :registry-revision "ei2-next-revision"))
    (run-at-time 0 nil (lambda () (funcall success persisted nil)))
    'ejn-ei2-test-registry-operation))

(defun ejn-ei2-test--registry-replace-fails
    (_entry _expected-revision _success failure &rest _keys)
  "Return a deferred durable failure for lifecycle tests."
  (run-at-time
   0 nil
   (lambda ()
     (funcall failure
              '(:kind durability-uncertain :code "test-disk-full"
                :message "test worker persistence failure")
              nil)))
  'ejn-ei2-test-registry-operation)

(defun ejn-ei2-test--artifact-directory ()
  "Create a test-owned private helper artifact directory and retain its cap."
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability)))
    (puthash root capability ejn-ei2-test--artifact-capabilities)
    root))

(defun ejn-ei2-test--artifact-capability (root)
  "Return the creation capability retained for fixture ROOT."
  (gethash root ejn-ei2-test--artifact-capabilities))

(defun ejn-ei2-test--artifact-leaf (root token)
  "Return a strict helper publication leaf path derived from TOKEN."
  (expand-file-name
   (format "ejn-artifact-%s" (secure-hash 'md5 (format "%s" token))) root))

(defun ejn-ei2-test--partial-leaf (root token)
  "Return a strict helper staging leaf path derived from TOKEN."
  (expand-file-name
   (format ".ejn-partial-%s" (secure-hash 'md5 (format "%s" token))) root))

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
         (with-current-buffer owner
           (let ((session (emacs-jupyter-notebook-backend-session-create nil owner)))
             (unwind-protect
                 (progn ,@body)
               (when-let* ((state (emacs-jupyter-notebook-backend-session-data
                                   session)))
                 (when (emacs-jupyter-notebook-helper-backend-state-p state)
                   (emacs-jupyter-notebook-helper-backend--dispose
                    state "EI2 test cleanup"))))))
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
          :remote-ports (list :shell_port 41000 :iopub_port 41001
                              :stdin_port 41002 :hb_port 41003
                              :control_port 41004)
          :local-connection-file "/tmp/ejn-durable.json"
          :registry-revision "ei2-current-revision")))

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
        (funcall (car callbacks) nil (ejn-ei2-test--kernel-info-response) nil)
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
                          ("kernel_info" (ejn-ei2-test--kernel-info-response))
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
        (funcall (car callbacks) nil (ejn-ei2-test--kernel-info-response) nil)
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
          (funcall verify nil (ejn-ei2-test--kernel-info-response) nil)
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
          (funcall verify nil (ejn-ei2-test--kernel-info-response) nil)
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
        (let* ((entry (ejn-ei2-test--direct-entry))
               state artifact verify (scheduled 0))
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
                emacs-jupyter-notebook--session-entry entry
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
                (should-not emacs-jupyter-notebook--client)
                (should (equal emacs-jupyter-notebook--session-entry entry))
                (should (string-match-p "kernel_info timed out" failure))
                (should (emacs-jupyter-notebook-helper-backend-state-retired state))
                (should-not (file-exists-p artifact))
                (should (= 1 (length disposals))))
            (setq emacs-jupyter-notebook--client nil
                  emacs-jupyter-notebook--session-entry nil
                  emacs-jupyter-notebook--kernel-status nil
                  emacs-jupyter-notebook--tunnel-dead nil)))))))

(ert-deftest ejn-ei4-artifact-root-uses-canonical-ancestor-spelling ()
  "Artifact roots match helper paths across aliases such as Darwin's /var."
  (let* ((base (make-temp-file "ejn-ei4-root-alias-" t))
         (real (expand-file-name "real" base))
         (alias (expand-file-name "alias" base))
         capability root)
    (unwind-protect
        (progn
          (make-directory real)
          (make-symbolic-link real alias)
          (let ((temporary-file-directory (file-name-as-directory alias)))
            (setq capability
                  (emacs-jupyter-notebook-artifacts-create 'helper)
                  root
                  (emacs-jupyter-notebook-artifacts-capability-root capability)))
          (should (string-prefix-p (file-name-as-directory (file-truename real))
                                   root))
          (should-not (string-prefix-p (file-name-as-directory alias) root)))
      (when capability
        (ignore-errors
          (emacs-jupyter-notebook-artifacts-retire capability)))
      (when (file-symlink-p alias) (delete-file alias))
      (when (file-directory-p real) (delete-directory real t))
      (when (file-directory-p base) (delete-directory base t)))))

(ert-deftest ejn-ei2-retired-a-callback-cannot-affect-b ()
  "A late A reply is inert after B gets its own backend session."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (let ((owner (generate-new-buffer " *ejn-ei2-a-b*")))
      (unwind-protect
          (progn
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
                      (funcall a-verify nil (ejn-ei2-test--kernel-info-response) nil)
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
        profile context returned-context ssh failure)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source)
          (progn
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-backend-ensure)
                       (lambda (&rest _) (error "helper missing")))
                      ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
                       (lambda (&rest _) (setq profile t)))
                      ((symbol-function 'emacs-jupyter-notebook--async-start-context)
                       (lambda (&rest _) (setq context t)))
                      ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                       (lambda (&rest _) (setq ssh t)))
                      ((symbol-function 'emacs-jupyter-notebook-registry-read-async)
                       (lambda (success _failure &rest _keys)
                         (run-at-time 0 nil (lambda () (funcall success nil nil)))
                         'ejn-ei2-test-registry-operation)))
              (setq returned-context
                    (emacs-jupyter-notebook-start-remote-kernel
                     "p" nil (lambda (_context reason) (setq failure reason))))
              (let ((deadline (+ (float-time) 2)))
                (while (and (not failure) (< (float-time) deadline))
                  (accept-process-output nil 0.01)))
              (should failure)
              (should (eq (plist-get returned-context :phase) 'error))
              (should-not (buffer-modified-p))
              (should-not profile)
              (should-not context)
              (should-not ssh))))
      (when (file-exists-p source) (delete-file source)))))

(ert-deftest ejn-ei2-core-reconnect-helper-resolution-fails-before-pid-probe ()
  "Reconnect resolves helper before context/PID/SSH work or durable mutation."
  (with-temp-buffer
    (let* ((entry (ejn-ei2-test--direct-entry))
           (original (copy-tree entry))
           (release (symbol-function 'emacs-jupyter-notebook--release-local-resources))
           (cleaned nil) context probe ssh)
      (let ((emacs-jupyter-notebook--session-entry entry))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--release-local-resources)
                   (lambda () (setq cleaned t) (funcall release)))
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
  (let ((emacs-jupyter-notebook-connect-arbitration-timeout 999))
    (should (= (emacs-jupyter-notebook--connect-arbitration-timeout) 45)))
  (let ((emacs-jupyter-notebook-connect-arbitration-timeout 12))
    (should (= (emacs-jupyter-notebook--connect-arbitration-timeout) 12)))
  (dolist (invalid '(nil 0 -1 invalid))
    (let ((emacs-jupyter-notebook-connect-arbitration-timeout invalid))
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
                       :remote-ports (plist-get entry :remote-ports)
                       :local-ports '(:shell_port 1001 :iopub_port 1002
                                      :stdin_port 1003 :hb_port 1004
                                      :control_port 1005)
                       :local-file "/tmp/ei2-core.json"
                       :tunnel-process 'fake-tunnel :origin-buffer buffer))
             (verify nil) (core-failure nil))
        (setq emacs-jupyter-notebook--async-context context)
        (unwind-protect
            (cl-letf (((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                       #'ejn-ei2-test--registry-replace-succeeds)
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
                                       (file-attributes artifact))
                   :artifact-capability
                   (ejn-ei2-test--artifact-capability artifact)))
           (session (emacs-jupyter-notebook-backend--make-session
                     :backend 'helper :data state :owner-buffer buffer
                     :requests (make-hash-table :test #'eql) :timers nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :remote-ports (plist-get entry :remote-ports)
                     :local-ports '(:shell_port 1001 :iopub_port 1002
                                    :stdin_port 1003 :hb_port 1004
                                    :control_port 1005)
                     :local-file "/tmp/ephemeral.json"
                     :client-unverified session :origin-buffer buffer
                     :error-callback (lambda (&rest _) nil)))
           shutdown remote-cleanup disposed)
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-file registry-file))
            ;; Model the admission contract: the context already carries the
            ;; exact worker revision that authorizes final promotion.
            (setq emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                       #'ejn-ei2-test--registry-replace-fails)
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
               context buffer entry
               '(:shell_port 1001 :iopub_port 1002 :stdin_port 1003
                 :hb_port 1004 :control_port 1005)
               "/tmp/ephemeral.json" session)
              (ejn-ei2-test--run-timers)
              (should-not emacs-jupyter-notebook--client)
              (should disposed)
              (should-not shutdown)
              (should-not remote-cleanup)
              (should (equal entry original))
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
                                       (file-attributes artifact))
                   :artifact-capability
                   (ejn-ei2-test--artifact-capability artifact)))
           (session (emacs-jupyter-notebook-backend--make-session
                     :backend 'helper :data state :owner-buffer buffer
                     :attached t :requests (make-hash-table :test #'eql)
                     :timers nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :remote-ports (plist-get entry :remote-ports)
                     :local-ports '(:shell_port 1001 :iopub_port 1002
                                    :stdin_port 1003 :hb_port 1004
                                    :control_port 1005)
                     :local-file "/tmp/ei2-core.json"
                     :client-unverified session :origin-buffer buffer
                     :error-callback (lambda (&rest _) nil)))
           disposed shutdown remote-cleanup)
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                       #'ejn-ei2-test--registry-replace-succeeds)
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
               context buffer entry
               '(:shell_port 1001 :iopub_port 1002 :stdin_port 1003
                 :hb_port 1004 :control_port 1005)
               "/tmp/ei2-core.json" session)
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
    (let* ((buffer (current-buffer))
           (entry (ejn-ei2-test--direct-entry))
           (session (emacs-jupyter-notebook-backend-session-create nil buffer))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "ei2-core"
                     :remote-ports (plist-get entry :remote-ports)
                     :local-ports '(:shell_port 1001 :iopub_port 1002
                                    :stdin_port 1003 :hb_port 1004
                                    :control_port 1005)
                     :local-file "/tmp/ei2-core.json"
                     :client-unverified session :origin-buffer buffer
                     :callback (lambda (&rest _) (error "consumer failed"))))
           (heartbeat-started 0))
      (emacs-jupyter-notebook-backend-session-mark-attached session)
      (setq emacs-jupyter-notebook--async-context context)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                     #'ejn-ei2-test--registry-replace-succeeds)
                    ((symbol-function 'emacs-jupyter-notebook--heartbeat-start)
                     (lambda () (cl-incf heartbeat-started)))
                    ((symbol-function 'emacs-jupyter-notebook--inject-viewer-formatter)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--inject-idle-watchdog)
                     #'ignore))
            (should (emacs-jupyter-notebook--async-connect-finalize
                     context buffer entry
                     '(:shell_port 1001 :iopub_port 1002 :stdin_port 1003
                       :hb_port 1004 :control_port 1005)
                     "/tmp/ei2-core.json" session))
            (ejn-ei2-test--run-timers)
            (should (eq emacs-jupyter-notebook--client session))
            (should (emacs-jupyter-notebook-backend-session-installed-p session))
            (should (eq (plist-get context :phase) 'done))
            ;; EI5 routes helper kernel-info through the common heartbeat.
            (should (= heartbeat-started 1))
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
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
                   (lambda (&rest _) (setq deregister t))))
          (emacs-jupyter-notebook--release-local-resources))
        (should-not emacs-jupyter-notebook--client)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should (equal (caar requests) "close"))
        (should-not shutdown)
        (should-not deregister)
        (funcall (car callbacks) nil (ejn-ei2-test--closed-response) nil)
        (funcall verify nil (ejn-ei2-test--kernel-info-response) nil)
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
        (funcall (car callbacks) nil (ejn-ei2-test--kernel-info-response) nil)
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
  "A replaced artifact path cannot delete a foreign symlink target."
  (let* ((directory (ejn-ei2-test--artifact-directory))
         (target (make-temp-file "ejn-ei2-foreign-" t))
         (original (concat directory "-original"))
         (capability (emacs-jupyter-notebook-artifacts-capture
                      'helper directory nil :no-lease))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir directory
                 :artifact-identity
                 (file-attribute-file-identifier (file-attributes directory))
                 :artifact-capability capability))
         (sentinel (expand-file-name "keep" target)))
    (unwind-protect
        (progn
          (with-temp-file sentinel (insert "foreign"))
          (rename-file directory original)
          (make-symbolic-link target directory)
          (emacs-jupyter-notebook-helper-backend--remove-artifacts state)
          (should (file-symlink-p directory))
          (should (file-exists-p sentinel)))
      (when (file-symlink-p directory) (delete-file directory))
      (when (file-directory-p directory) (delete-directory directory t))
      (when (file-directory-p original) (delete-directory original t))
      (when (file-directory-p target) (delete-directory target t)))))

(ert-deftest ejn-ei2-artifact-cleanup-refuses-identity-mismatched-directory ()
  "A real replacement directory remains untouched when its identity differs."
  (let* ((directory (ejn-ei2-test--artifact-directory))
         (original (concat directory "-original"))
         (capability (emacs-jupyter-notebook-artifacts-capture
                      'helper directory nil :no-lease))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir directory
                 :artifact-identity
                 (file-attribute-file-identifier (file-attributes directory))
                 :artifact-capability capability))
         sentinel)
    (unwind-protect
        (progn
          (rename-file directory original)
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
      (when (file-directory-p directory) (delete-directory directory t))
      (when (file-directory-p original) (delete-directory original t)))))

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

(ert-deftest ejn-ei2-close-deadline-setup-failure-retires-helper-and-artifacts ()
  "A close ownership publication with no deadline disposes local state now."
  (let ((emacs-jupyter-notebook-backend-close-timeout 0.02))
    (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
      (ejn-ei2-test-with-session
        (let (state artifact close-error)
          (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
          (setq state (emacs-jupyter-notebook-backend-session-data session)
                artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
          (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
          (funcall (car callbacks) nil (ejn-ei2-test--kernel-info-response) nil)
          (ejn-ei2-test--run-timers)
          (let ((real-run-at-time (symbol-function 'run-at-time)))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (delay repeat function &rest args)
                         (if (= delay
                                (emacs-jupyter-notebook-helper-backend--close-deadline))
                             (error "injected helper close deadline allocation failure")
                           (apply real-run-at-time delay repeat function args)))))
              (emacs-jupyter-notebook-backend-close-local
               session #'ignore (lambda (_id reason) (setq close-error reason)))))
          (ejn-ei2-test--run-timers)
          (should (string-match-p "cannot arm helper local close deadline" close-error))
          (should (emacs-jupyter-notebook-helper-backend-state-retired state))
          (should-not (file-exists-p artifact))
          (should (= 1 (length disposals)))
          (should-not (cl-find "close" requests :key #'car :test #'equal)))))))

(ert-deftest ejn-ei2-close-rejects-malformed-success-result ()
  "An `ok' helper close reply without exact `{closed:true}' is failure."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (state artifact close-error)
        (emacs-jupyter-notebook-backend-connect session "/tmp/c.json" #'ignore #'ignore)
        (setq state (emacs-jupyter-notebook-backend-session-data session)
              artifact (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil (ejn-ei2-test--kernel-info-response) nil)
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
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           requests execute-error complete-result readiness-result control-error)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper operation params callback &rest _keys)
                   (push (list operation params) requests)
                   (funcall callback 'fake
                            (ejn-ei2-test--response
                             (pcase operation
                               ("is_complete"
                                (ejn-ei2-test--object "status" "complete"))
                               ("kernel_info" (ejn-ei2-test--kernel-info-result))
                               ("interrupt" (ejn-ei2-test--object "interrupted" t))
                               (_ (ejn-ei2-test--object
                                   "status" "ok" "execution_count" 1)))) nil)
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
                       '("interrupt" "kernel_info" "is_complete" "execute")))
        (should-not control-error)))))

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
      (let* ((session (emacs-jupyter-notebook-backend-session-create
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
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
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
      (let* ((session (emacs-jupyter-notebook-backend-session-create
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

(ert-deftest ejn-ei4-malformed-early-output-invalidates-later-terminals ()
  "A malformed early event invalidates later terminal claims in its stream."
  (let (seen failures)
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
        (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state)
              (lambda (reason) (push reason failures)))
        (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session) 1)
        (dolist (event
                 (list
                  (ejn-ei2-test--object
                   "event" "display_data" "request_id" "wire"
                   "data" (ejn-ei2-test--object
                            "data" (ejn-ei2-test--object "text/plain" "bad update")
                            "metadata" (ejn-ei2-test--object)
                            "update" t))
                  ;; A malformed framed item makes every later item in the
                  ;; same stream untrustworthy, including apparent terminal
                  ;; evidence.
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
        (emacs-jupyter-notebook-helper-backend--flush-pending-events session state)
        (should (equal (nreverse seen) '(update-display)))
        (should (= (length failures) 1))
        (should (string-match-p "malformed" (car failures)))
        (should (= (hash-table-count
                    (emacs-jupyter-notebook-helper-backend-state-pending-events state))
                   0))))))

(ert-deftest ejn-ei4-unaccepted-helper-publications-are-discarded-safely ()
  "Rejected and malformed helper publications do not accumulate on disk."
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability))
         (identity (emacs-jupyter-notebook-artifacts-capability-root-identity
                    capability))
         (mapping '(:ledger-id 1 :backend-request-id 11))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir root :artifact-identity identity
                 :artifact-capability capability
                 :emit #'ignore))
         (make-event
          (lambda (path &optional malformed)
            (ejn-ei2-test--object
             "event" "display_data" "request_id" "wire"
             "data" (ejn-ei2-test--object
                      "data" (ejn-ei2-test--object
                              "image/png"
                              (ejn-ei4d-test--image-descriptor
                               path 4 (make-string 64 ?a)))
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

(ert-deftest ejn-v4-rejected-numerical-publication-is-disposed ()
  "Numerical leaves join the same confined rollback path as existing images."
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir root :artifact-capability capability
                 :artifact-identity
                 (emacs-jupyter-notebook-artifacts-capability-root-identity capability)
                 :emit #'ignore)))
    (unwind-protect
        (dolist (name '("ejn-artifact-00000000000000000000000000000001" "unrelated"))
          (let* ((path (expand-file-name name root))
                 (event (ejn-ei2-test--object
                         "event" "display_data" "request_id" "wire"
                         "data" (ejn-ei2-test--object
                                 "data" (ejn-ei2-test--object
                                         "application/x-ejn-array-group"
                                         (ejn-ei2-test--object
                                          "path" path "bytes" 4
                                          "sha256" (make-string 64 ?a)
                                          "manifest" :false))
                                 "metadata" (ejn-ei2-test--object)))))
            (with-temp-file path (insert "data"))
            (set-file-modes path #o600)
            (should (equal
                     (emacs-jupyter-notebook-helper-backend--raw-publication-paths event)
                     (list path)))
            (should-error
             (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
              state "wire" '(:ledger-id 1 :backend-request-id 11) event))
            (should (eq (file-exists-p path) (equal name "unrelated")))))
      (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup")
      (when (file-directory-p root) (delete-directory root t)))))

(ert-deftest ejn-ei4-retired-wire-events-never-reenter-early-buffer ()
  "Late events for a tombstoned helper ID consume no pending-event capacity."
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability))
         (image-path (expand-file-name
                      "ejn-artifact-00000000000000000000000000000009" root))
         (pickle-path (expand-file-name
                       "ejn-artifact-0000000000000000000000000000000a" root))
         seen state)
    (unwind-protect
        (with-temp-buffer
          (let* ((mapping (make-hash-table :test #'equal))
                 (session (emacs-jupyter-notebook-backend-session-create nil (current-buffer))))
            (setq state
                  (emacs-jupyter-notebook-helper-backend--make-state
                   :artifact-dir root
                   :artifact-identity
                   (emacs-jupyter-notebook-artifacts-capability-root-identity
                    capability)
                   :artifact-capability capability
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
            (dolist (pair `((,image-path . "late-image")
                            (,pickle-path . "late-pickle")))
              (with-temp-file (car pair) (insert (cdr pair)))
              (set-file-modes (car pair) #o600))
            (emacs-jupyter-notebook-helper-backend--event
             session state
             (ejn-ei2-test--object
              "event" "display_data" "request_id" "retired-wire"
              "data" (ejn-ei2-test--object
                       "data" (ejn-ei2-test--object
                               "image/png"
                               (ejn-ei4d-test--image-descriptor
                                image-path 10 (make-string 64 ?a))
                               "application/x-ejn-mpl-pickle"
                               (ejn-ei2-test--object
                                "path" pickle-path "bytes" 11
                                "sha256" (make-string 64 ?b)))
                       "metadata" (ejn-ei2-test--object))))
            (should-not (file-exists-p image-path))
            (should-not (file-exists-p pickle-path))
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
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability))
         (publication (ejn-ei2-test--artifact-leaf root "published"))
         (staging (ejn-ei2-test--partial-leaf root "staging"))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir root
                 :artifact-identity (file-attribute-file-identifier (file-attributes root))
                 :artifact-capability capability)))
    (unwind-protect
        (progn
          (with-temp-file publication (insert "published"))
          (set-file-modes publication #o600)
          (with-temp-file staging (insert "staging"))
          (set-file-modes staging #o600)
          (emacs-jupyter-notebook-helper-backend--dispose state "test")
          (should (file-exists-p publication))
          (should-not (file-exists-p staging)))
      (ignore-errors (delete-file publication))
      (ignore-errors (emacs-jupyter-notebook-artifacts-retire capability))
      (when (file-directory-p root) (delete-directory root t)))))

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
    (let* ((artifact (ejn-ei4d-test--image-descriptor
                      "/tmp/ejn-ei4-root/ejn-artifact-1"
                      12 (make-string 64 ?a)))
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
      (should (equal (plist-get (plist-get publication :original) :path)
                     "/tmp/ejn-ei4-root/ejn-artifact-1"))
      (should (= (plist-get (plist-get publication :original) :size) 12)))
    (puthash "update" "not-a-boolean" (gethash "data" raw))
    (should-error
     (emacs-jupyter-notebook-helper-backend--normalize-event state raw))))

(ert-deftest ejn-ei4v-normalizes-dual-artifacts-without-payload-bytes ()
  "One helper rich event carries independent image and pickle descriptors."
  (let* ((state (emacs-jupyter-notebook-helper-backend--make-state
                 :artifact-dir "/tmp/ejn-ei4v-root" :artifact-identity '(7 11)))
         (sha (make-string 64 ?a))
         (leaf (lambda (name bytes)
                 (ejn-ei2-test--object
                  "path" (concat "/tmp/ejn-ei4v-root/" name)
                  "bytes" bytes "sha256" sha)))
         (raw (ejn-ei2-test--object
               "event" "display_data"
               "data" (ejn-ei2-test--object
                       "data" (ejn-ei2-test--object
                               "image/png"
                               (ejn-ei2-test--object
                                "original"
                                (funcall leaf
                                         "ejn-artifact-11111111111111111111111111111111"
                                         4))
                               "application/x-ejn-mpl-pickle"
                               (funcall leaf
                                        "ejn-artifact-22222222222222222222222222222222"
                                        6))
                       "metadata" (ejn-ei2-test--object))))
         (data (plist-get (emacs-jupyter-notebook-helper-backend--normalize-event state raw)
                          :data)))
    (should (equal (plist-get (plist-get (plist-get data :ejn-published-image)
                                          :original)
                              :size)
                   4))
    (should (equal (plist-get (plist-get data :ejn-published-pickle) :size) 6))
    (should-not (string-match-p "base64" (prin1-to-string data)))))

(ert-deftest ejn-ei4d-image-descriptors-require-exact-bounded-metadata ()
  "Helper image descriptors require an original and validate PPM previews."
  (let ((state (emacs-jupyter-notebook-helper-backend--make-state
                :artifact-dir "/tmp/ejn-ei4d-root" :artifact-identity '(7 . 11))))
    (cl-labels
        ((raw (descriptor &optional mime)
           (ejn-ei2-test--object
            "event" "display_data"
            "data" (ejn-ei2-test--object
                    "data" (ejn-ei2-test--object
                            (or mime "image/png")
                            descriptor)
                    "metadata" (ejn-ei2-test--object)))))
      (let* ((original (ejn-ei2-test--object
                        "path" "/tmp/ejn-ei4d-root/ejn-artifact-11111111111111111111111111111111"
                        "bytes" 4 "sha256" (make-string 64 ?a)))
             (preview (ejn-ei2-test--object
                       "path" "/tmp/ejn-ei4d-root/ejn-artifact-22222222222222222222222222222222"
                       "bytes" 17 "sha256" (make-string 64 ?b)
                       "mime" "image/x-portable-pixmap" "width" 2 "height" 1))
             (descriptor (ejn-ei2-test--object "original" original "preview" preview))
             (publication
              (plist-get
               (plist-get (emacs-jupyter-notebook-helper-backend--normalize-event
                           state (raw descriptor))
                          :data)
               :ejn-published-image)))
        (should (equal (plist-get (plist-get publication :original) :size) 4))
        (should (equal (plist-get (plist-get publication :preview) :mime)
                       "image/x-portable-pixmap"))
        (dolist (bad (list
                      (ejn-ei2-test--object)
                      (ejn-ei2-test--object
                       "original"
                       (ejn-ei2-test--object
                        "path" "/tmp/ejn-ei4d-root/ejn-artifact-uppercase"
                        "bytes" 4 "sha256" (make-string 64 ?A)))
                      (ejn-ei2-test--object "original" original "preview"
                                            (ejn-ei2-test--object "path" "x"))
                      (ejn-ei2-test--object "original" original "preview"
                                            (ejn-ei2-test--object
                                             "path" "/tmp/x" "bytes" 1
                                             "sha256" (make-string 64 ?a)
                                             "mime" "image/png" "width" 1 "height" 1)))))
          (should-error
           (emacs-jupyter-notebook-helper-backend--normalize-event state (raw bad)))))))

(ert-deftest ejn-ei5-helper-auxiliary-operations-use-bounded-v1-requests ()
  "Completion, inspect, completeness, and stdin use exact helper operations."
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           requests complete inspect incomplete input)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper operation params callback &rest keys)
                   (push (list operation params (plist-get keys :timeout)) requests)
                   (funcall callback 'fake
                            (ejn-ei2-test--response
                             (pcase operation
                               ("complete" (ejn-ei2-test--object
                                            "matches" ["print"] "cursor_start" 0
                                            "cursor_end" 3 "status" "ok"))
                               ("inspect" (ejn-ei2-test--object
                                           "found" t "data"
                                           (ejn-ei2-test--object "text/plain" "docs")))
                               ("is_complete" (ejn-ei2-test--object "status" "complete"))
                               (_ (ejn-ei2-test--object "accepted" t)))) nil)
                   (format "wire-%d" (length requests)))))
        (emacs-jupyter-notebook-backend-aux
         session 'complete '(:code "pri" :cursor-pos 3)
         (lambda (_id value) (setq complete value)) #'ert-fail)
        (emacs-jupyter-notebook-backend-aux
         session 'inspect '(:code "pri" :cursor-pos 3 :detail 1)
         (lambda (_id value) (setq inspect value)) #'ert-fail)
        (emacs-jupyter-notebook-backend-aux
         session 'is-complete '(:code "x")
         (lambda (_id value) (setq incomplete value)) #'ert-fail)
        (emacs-jupyter-notebook-backend-input
         session (cons "wire-execute" (make-string 32 ?a)) "answer"
         (lambda (_id value) (setq input value)) #'ert-fail)
        (ejn-ei2-test--run-timers)
        (should (equal complete '(:matches ("print") :cursor_start 0 :cursor_end 3 :status "ok")))
        (should (equal (plist-get (plist-get inspect :data) :text/plain) "docs"))
        (should (equal incomplete '(:status "complete")))
        (should-not input)
        (should (equal (mapcar #'car (nreverse requests))
                       '("complete" "inspect" "is_complete" "input_reply")))
        (dolist (request requests)
          (should (= (nth 2 request) emacs-jupyter-notebook-helper-backend--aux-timeout)))))))

(ert-deftest ejn-ei5-input-normalization-and-lease-validation-are-strict ()
  "Prompt events and input replies reject malformed or oversized secrets."
  (let* ((state (emacs-jupyter-notebook-helper-backend--make-state))
         (id (make-string 32 ?a))
         (event (ejn-ei2-test--object "event" "input_request" "data"
                                      (ejn-ei2-test--object
                                       "input_id" id "prompt" "Password: " "password" t))))
    (should (equal (emacs-jupyter-notebook-helper-backend--normalize-event state event)
                   (list :type 'input-request :input-id id :prompt "Password: " :password t)))
    (puthash "input_id" "wrong" (gethash "data" event))
    (should-error (emacs-jupyter-notebook-helper-backend--normalize-event state event))
    (should-error
     (emacs-jupyter-notebook-helper-backend--input-payload-object
      (list :request-id (cons "wire" id) :value (make-string 65537 ?x))))))

(ert-deftest ejn-ei5-helper-heartbeat-failure-enters-existing-dead-path-once ()
  "An idle helper kernel-info failure takes the normal one-shot retry path."
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           (emacs-jupyter-notebook--client session)
           (emacs-jupyter-notebook-mode t)
           (emacs-jupyter-notebook--kernel-status 'idle)
           (emacs-jupyter-notebook--tunnel-dead nil)
           (emacs-jupyter-notebook-heartbeat-misses-allowed 1)
           (scheduled 0))
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper operation _params callback &rest _keys)
                   (should (equal operation "kernel_info"))
                   (funcall callback 'fake nil "kernel-info unavailable")
                   "heartbeat-wire"))
                ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                 (lambda (&rest _) (cl-incf scheduled)))
                ((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-tick)
        (should-not emacs-jupyter-notebook--tunnel-dead)
        (ejn-ei2-test--run-timers)
        (should emacs-jupyter-notebook--tunnel-dead)
        (should (= scheduled 1))
        ;; The stale callback/token cannot schedule a second retry.
        (ejn-ei2-test--run-timers)
        (should (= scheduled 1))))))

(ert-deftest ejn-ei5-helper-heartbeat-is-single-flight-and-busy-safe ()
  "Helper heartbeats neither overlap nor count long execution silence."
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create
                     nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'fake))
           (emacs-jupyter-notebook--client session)
           (emacs-jupyter-notebook--kernel-status 'busy)
           (emacs-jupyter-notebook--heartbeat-misses 1)
           calls)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (&rest _)
                   (cl-incf calls)
                   "unexpected-heartbeat")))
        (emacs-jupyter-notebook--heartbeat-tick)
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (should-not calls)
        (should (= emacs-jupyter-notebook--heartbeat-misses 0))
        (should-not emacs-jupyter-notebook--tunnel-dead)
        ;; Even while idle, a custom interval cannot start a second probe
        ;; before the first token reaches its bounded reply or timeout.
        (setq emacs-jupyter-notebook--kernel-status 'idle
              emacs-jupyter-notebook--heartbeat-inflight 'existing-probe)
        (emacs-jupyter-notebook--heartbeat-tick)
        (should-not calls)
        (should (eq emacs-jupyter-notebook--heartbeat-inflight
                    'existing-probe))))))

(ert-deftest ejn-ei5-heartbeat-timeout-timer-setup-failure-does-not-wedge-probes ()
  "A failed per-probe timer is one miss, with no phantom single-flight token."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'heartbeat-client)
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--heartbeat-misses 0)
          (emacs-jupyter-notebook-heartbeat-misses-allowed 3)
          (timer-failures 0)
          (probes 0)
          timeout-timer)
      (unwind-protect
          (let ((real-run-with-timer (symbol-function 'run-with-timer)))
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (&rest args)
                         (if (= (cl-incf timer-failures) 1)
                             (error "injected heartbeat timer failure")
                           (apply real-run-with-timer args))))
                      ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                       (lambda (&rest _args)
                         (cl-incf probes)
                         'heartbeat-request))
                      ((symbol-function 'emacs-jupyter-notebook--log-append)
                       #'ignore))
              (emacs-jupyter-notebook--heartbeat-tick)
              (should (= probes 0))
              (should (= emacs-jupyter-notebook--heartbeat-misses 1))
              (should-not emacs-jupyter-notebook--heartbeat-inflight)
              (should-not emacs-jupyter-notebook--heartbeat-timeout-timer)
              ;; A subsequent tick can create and own a new bounded probe.
              (emacs-jupyter-notebook--heartbeat-tick)
              (setq timeout-timer emacs-jupyter-notebook--heartbeat-timeout-timer)
              (should (= probes 1))
              (should emacs-jupyter-notebook--heartbeat-inflight)
              (should (timerp timeout-timer))
              (should-not emacs-jupyter-notebook--tunnel-dead)))
        (when (timerp timeout-timer) (cancel-timer timeout-timer))))))

(ert-deftest ejn-ei5-heartbeat-eager-timeout-never-sends-a-probe ()
  "An eager heartbeat deadline retires its provisional token before send."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'heartbeat-client)
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--heartbeat-misses 0)
          (emacs-jupyter-notebook-heartbeat-misses-allowed 3)
          (probes 0)
          cancelled timer)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (_seconds _repeat function &rest args)
                   (apply function args)
                   (setq timer (timer-create))))
                ((symbol-function 'cancel-timer)
                 (lambda (value) (setq cancelled value)))
                ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (&rest _args) (cl-incf probes)))
                ((symbol-function 'emacs-jupyter-notebook--log-append)
                 #'ignore))
        (emacs-jupyter-notebook--heartbeat-tick)
        (should (= probes 0))
        (should (= emacs-jupyter-notebook--heartbeat-misses 1))
        (should-not emacs-jupyter-notebook--heartbeat-inflight)
        (should-not emacs-jupyter-notebook--heartbeat-timeout-timer)
        (should (eq cancelled timer))))))

(ert-deftest ejn-ei5-stdin-prompts-defer-and-clear-passwords ()
  "Normal, password, and quit replies leave the filter turn without prompting."
  (save-window-excursion
    (dolist (case '((normal nil "answer") (password t "secret") (quit nil quit)))
      (let ((source (generate-new-buffer " *ejn-ei5-input*")) seen secret)
        (unwind-protect
            (with-current-buffer source
              (set-window-buffer (selected-window) source)
              (let ((session 'helper-session)
                    (emacs-jupyter-notebook--client 'helper-session))
                (setq secret (copy-sequence (if (eq (nth 2 case) 'quit)
                                                "" (nth 2 case))))
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-input-current-p)
                           (lambda (_id) t))
                          ((symbol-function 'emacs-jupyter-notebook-backend-input)
                           (lambda (_client lease value &rest _)
                             (setq seen (list lease (copy-sequence value)))))
                          ((symbol-function 'read-string)
                           (lambda (_prompt)
                             (if (eq (nth 2 case) 'quit) (signal 'quit nil) secret)))
                          ((symbol-function 'read-passwd)
                           (lambda (_prompt) secret)))
                         (emacs-jupyter-notebook-events--schedule-input
                          (list :buffer source :request-id nil
                                :input-reply (emacs-jupyter-notebook--helper-input-reply
                                              session 1 "wire" (make-string 32 ?a)))
                          "Prompt: " (nth 1 case))
                         (should-not seen)
                         ;; Drain from another buffer: the lease closure must re-enter
                         ;; SOURCE rather than reading arbitrary buffer-local state.
                         (with-temp-buffer (accept-process-output nil 0.15))
                         (should (equal (caar seen) "wire"))
                         (should (equal (cadr seen)
                                        (if (eq (nth 2 case) 'quit) "" (nth 2 case))))
                         (when (nth 1 case)
                           (should-not (equal secret "secret"))))))
          (when (buffer-live-p source) (kill-buffer source)))))))

(ert-deftest ejn-ei5-helper-complete-inspect-real-replies-and-deadlines ()
  "The fake helper exercises successful, malformed, and bounded aux replies."
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil
                                                                    (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           requests pending complete inspect failures)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper operation params callback &rest keys)
                   (push (list operation params (plist-get keys :timeout)) requests)
                   (push (list operation callback) pending)
                   (format "ei5-aux-%d" (length requests)))))
        (emacs-jupyter-notebook-backend-aux
         session 'complete '(:code "pri" :cursor-pos 3)
         (lambda (_id value) (setq complete value))
         (lambda (_id reason) (push reason failures)))
        (emacs-jupyter-notebook-backend-aux
         session 'inspect '(:code "pri" :cursor-pos 3 :detail 1)
         (lambda (_id value) (setq inspect value))
         (lambda (_id reason) (push reason failures)))
        (dolist (request pending)
          (pcase (car request)
            ("complete"
             (funcall (cadr request) 'fake
                      (ejn-ei2-test--response
                       (ejn-ei2-test--object
                        "matches" ["print"] "cursor_start" 0 "cursor_end" 3
                        "status" "ok")) nil))
            ("inspect"
             (funcall (cadr request) 'fake
                      (ejn-ei2-test--response
                       (ejn-ei2-test--object
                        "found" t "data"
                        (ejn-ei2-test--object "text/plain" "docs"))) nil))))
        (ejn-ei2-test--run-timers)
        (should (equal complete
                       '(:matches ("print") :cursor_start 0 :cursor_end 3
                         :status "ok")))
        (should (equal (plist-get (plist-get inspect :data) :text/plain) "docs"))
        (should (= (length requests) 2))
        (dolist (request requests)
          (should (= (nth 2 request)
                     emacs-jupyter-notebook-helper-backend--aux-timeout)))
        ;; A malformed result must fail the operation, not reach the caller as
        ;; a successful nil/partial plist.
        (setq pending nil)
        (emacs-jupyter-notebook-backend-aux
         session 'complete '(:code "x" :cursor-pos 1) #'ignore
         (lambda (_id reason) (push reason failures)))
        (funcall (cadar pending) 'fake
                 (ejn-ei2-test--response
                  (ejn-ei2-test--object "matches" ["x"] "cursor_start" 4
                                        "cursor_end" 1 "status" "ok")) nil)
        (emacs-jupyter-notebook-backend-aux
         session 'inspect '(:code "x" :cursor-pos 1) #'ignore
         (lambda (_id reason) (push reason failures)))
        (funcall (cadar pending) 'fake
                 (ejn-ei2-test--response
                  (ejn-ei2-test--object "found" t "data" "not-an-object")) nil)
        (ejn-ei2-test--run-timers)
        (should (= (length failures) 2))))))

(ert-deftest ejn-ei5-malformed-kernel-info-fails-connect-and-heartbeat ()
  "A successful envelope cannot make malformed readiness data healthy."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let (failure)
        (emacs-jupyter-notebook-backend-connect
         session "/tmp/c.json" #'ignore
         (lambda (_id reason) (setq failure reason)))
        (funcall (car callbacks) nil (ejn-ei2-test--attached-response) nil)
        (funcall (car callbacks) nil (ejn-ei2-test--response) nil)
        (ejn-ei2-test--run-timers)
        (should (string-match-p "invalid result" failure))
        (should disposals))))
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create
                     nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'fake))
           (emacs-jupyter-notebook--client session)
           (emacs-jupyter-notebook--kernel-status 'idle)
           (emacs-jupyter-notebook-heartbeat-misses-allowed 1)
           scheduled)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper _operation _params callback &rest _)
                   (funcall callback 'fake (ejn-ei2-test--response) nil)
                   "malformed-heartbeat"))
                ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                 (lambda (&rest _) (setq scheduled t)))
                ((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-tick)
        (ejn-ei2-test--run-timers)
        (should emacs-jupyter-notebook--tunnel-dead)
        (should scheduled)))))

(ert-deftest ejn-ei5-malformed-input-acknowledgement-is-a-failure ()
  "Only an exact accepted=true result acknowledges a stdin reply."
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create
                     nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'fake))
           (results (list (ejn-ei2-test--object "accepted" :false)
                          (ejn-ei2-test--object "accepted" t "extra" t)))
           failures
           successes)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                 (lambda (_helper _operation _params callback &rest _)
                   (funcall callback 'fake
                            (ejn-ei2-test--response (pop results)) nil)
                   "malformed-input-ack")))
        (dotimes (_ 2)
          (emacs-jupyter-notebook-backend-input
           session (cons "wire-execute" (make-string 32 ?a)) "value"
           (lambda (&rest _) (cl-incf successes))
           (lambda (_id reason) (push reason failures))))
        (ejn-ei2-test--run-timers)
        (should (= (length failures) 2))
        (should-not successes)))))

(ert-deftest ejn-ei5-capf-with-helper-session-returns-under-five-ms ()
  "A helper-backed CAPF miss only schedules work and never waits for it."
  (with-temp-buffer
    (python-mode)
    (insert "# %%\nvalue.pri\n")
    (goto-char (point-min))
    (search-forward "pri")
    (let ((emacs-jupyter-notebook-mode t)
          (emacs-jupyter-notebook--client
           (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'self-insert-command)
          scheduled)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--completion-schedule-request)
                 (lambda (&rest _) (setq scheduled t))))
        (let ((started (float-time)))
          (should-not (emacs-jupyter-notebook-completion-at-point))
          (should (< (- (float-time) started) 0.005)))
        (should scheduled)))))

(ert-deftest ejn-ei5-completion-cache-rejects-edited-cell-and-replaced-client ()
  "A cache key cannot make a reply valid after cell or client ownership changes."
  (with-temp-buffer
    (python-mode)
    (insert "# %%\nobj.pri\nother\n")
    (goto-char (point-min))
    (search-forward "pri")
    (let* ((emacs-jupyter-notebook-mode t)
           (emacs-jupyter-notebook--client 'client-a)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key))
           (reply '(:matches ("print") :cursor_start 0 :cursor_end 3)))
      (emacs-jupyter-notebook--completion-cache-put key reply)
      ;; This edit is after point, so the old key is intentionally unchanged.
      (goto-char (point-max))
      (insert "edited\n")
      (emacs-jupyter-notebook--completion-after-change)
      (search-backward "pri")
      (should-not (emacs-jupyter-notebook--completion-result))
      ;; A reply owned by the replaced client cannot repopulate the cache.
      (let* ((live-key (emacs-jupyter-notebook--completion-key))
             (context (emacs-jupyter-notebook--completion-context))
             (request-id (cl-incf emacs-jupyter-notebook--completion-request-counter)))
        (setq emacs-jupyter-notebook--completion-pending-key live-key
              emacs-jupyter-notebook--completion-pending-id request-id
              emacs-jupyter-notebook--client 'client-b)
        (emacs-jupyter-notebook--completion-on-reply
         (current-buffer) 'client-a live-key request-id nil context reply nil)
        (should (or (null emacs-jupyter-notebook--completion-cache)
                    (= 0 (hash-table-count
                          emacs-jupyter-notebook--completion-cache))))))))

(ert-deftest ejn-ei5-duplicate-completion-keeps-original-reply-live ()
  "A de-duplicated request must not invalidate its in-flight owner."
  (with-temp-buffer
    (python-mode)
    (insert "# %%\nobj.pri\n")
    (goto-char (point-min))
    (search-forward "pri")
    (let ((emacs-jupyter-notebook--client 'client-a)
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          callback
          (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _operation _payload success _failure)
                   (cl-incf calls)
                   (setq callback success))))
        (emacs-jupyter-notebook--request-completion)
        (let ((owner emacs-jupyter-notebook--completion-pending-id))
          (emacs-jupyter-notebook--request-completion)
          (should (= calls 1))
          (should (= owner emacs-jupyter-notebook--completion-request-counter))
          (should (= owner emacs-jupyter-notebook--completion-pending-id))
          (funcall callback 1
                   '(:matches ("print") :cursor_start 0 :cursor_end 3))
          (should-not emacs-jupyter-notebook--completion-pending-id)
          (should (emacs-jupyter-notebook--completion-result)))))))

(ert-deftest ejn-ei5-explicit-completion-drops-late-context-replies ()
  "Explicit completion accepts only the newest reply for the live context."
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (python-mode)
      (insert "# %%\nobj.pri\n")
      (goto-char (point-min))
      (search-forward "pri")
      (let ((emacs-jupyter-notebook-mode t)
            (emacs-jupyter-notebook--client 'client-a)
            callbacks refreshes)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _operation _payload success _failure)
                     (push success callbacks)))
                  ((symbol-function 'completion-in-region)
                   (lambda (&rest _) (setq refreshes (1+ (or refreshes 0))))))
                 (emacs-jupyter-notebook--complete-explicit-now)
                 (emacs-jupyter-notebook--complete-explicit-now)
                 (let ((newest (car callbacks)) (older (cadr callbacks)))
                   (funcall older 1
                            '(:matches ("old") :cursor_start 0 :cursor_end 3))
                   (should-not refreshes)
                   (funcall newest 2
                            '(:matches ("new") :cursor_start 0 :cursor_end 3))
                   (should-not refreshes)
                   (accept-process-output nil 0.15)
                   (should (= refreshes 1))))))))

(ert-deftest ejn-ei5-explicit-completion-drops-moved-edited-and-replaced-context ()
  "Explicit completion replies are no-ops after point, text, or client changes."
  (dolist (mutation '(move edit client))
    (with-temp-buffer
      (python-mode)
      (insert "# %%\nobj.pri\n")
      (goto-char (point-min))
      (search-forward "pri")
      (let ((emacs-jupyter-notebook-mode t)
            (emacs-jupyter-notebook--client 'client-a)
            callback refreshes)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _operation _payload success _failure)
                     (setq callback success)))
                  ((symbol-function 'completion-in-region)
                   (lambda (&rest _) (setq refreshes (1+ (or refreshes 0))))))
          (emacs-jupyter-notebook--complete-explicit-now)
          (pcase mutation
            ('move (forward-char -1))
            ('edit (goto-char (point-max)) (insert "changed\n")
                   (search-backward "pri"))
            ('client (setq emacs-jupyter-notebook--client 'client-b)))
          (funcall callback 1
                   '(:matches ("stale") :cursor_start 0 :cursor_end 3))
          (should-not refreshes))))))

(ert-deftest ejn-ei5-inspect-drops-older-reply ()
  "Inspect only displays the newest reply for a repeated request."
  (with-temp-buffer
    (python-mode)
    (insert "# %%\nrange(5)\n")
    (goto-char (point-min))
    (search-forward "range")
    (let ((emacs-jupyter-notebook-mode t)
          (emacs-jupyter-notebook--client 'client-a)
          callbacks displayed)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _operation _payload success _failure)
                   (push success callbacks)))
                ((symbol-function 'display-message-or-buffer)
                 (lambda (text &rest _) (push text displayed))))
        (emacs-jupyter-notebook-inspect-at-point)
        (emacs-jupyter-notebook-inspect-at-point)
        (funcall (cadr callbacks) 1 '(:found t :data (:text/plain "old")))
        (should-not displayed)
        (funcall (car callbacks) 2 '(:found t :data (:text/plain "new")))
        (should (= (length displayed) 1))))))

(ert-deftest ejn-ei5-inspect-drops-moved-edited-and-replaced-context ()
  "Inspect replies are no-ops after point, text, or client changes."
  (dolist (mutation '(move edit client))
    (with-temp-buffer
      (python-mode)
      (insert "# %%\nrange(5)\n")
      (goto-char (point-min))
      (search-forward "range")
      (let ((emacs-jupyter-notebook-mode t)
            (emacs-jupyter-notebook--client 'client-a)
            callback displayed)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _operation _payload success _failure)
                     (setq callback success)))
                  ((symbol-function 'display-message-or-buffer)
                   (lambda (text &rest _) (push text displayed))))
          (emacs-jupyter-notebook-inspect-at-point)
          (pcase mutation
            ('move (forward-char 1))
            ('edit (goto-char (point-max))
                   (insert "changed\n")
                   (search-backward "range"))
            ('client (setq emacs-jupyter-notebook--client 'client-b)))
          (funcall callback 1 '(:found t :data (:text/plain "stale")))
          (should-not displayed))))))

(ert-deftest ejn-ei5-is-complete-late-client-and-id-are-no-ops ()
  "Completeness replies cannot dispatch an old request while it is pending."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'client-a)
          (emacs-jupyter-notebook--is-complete-request-id 7)
          (emacs-jupyter-notebook--execution-active-id 41)
          (emacs-jupyter-notebook--execution-queue '(41))
          (emacs-jupyter-notebook--execution-ledger
           (make-hash-table :test #'eql))
          dispatched failed)
      (emacs-jupyter-notebook--execution-put
       '(:id 41 :state checking :is-complete-request-id 7))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-dispatch)
                 (lambda (&rest _) (setq dispatched t)))
                ((symbol-function 'emacs-jupyter-notebook--execution-fail)
                 (lambda (&rest _) (setq failed t))))
        (emacs-jupyter-notebook--execution-after-completeness
         41 'client-old 7 '(:status "complete"))
        (emacs-jupyter-notebook--execution-after-completeness
         41 'client-a 6 '(:status "complete"))
        (should-not dispatched)
        (should-not failed)
        (should (eq (plist-get (emacs-jupyter-notebook--execution-record 41)
                               :state)
                    'checking))))))

(ert-deftest ejn-ei5-helper-input-event-replies-after-filter-with-exact-lease ()
  "Mapped helper stdin events prompt later and send one exact input_reply."
  (save-window-excursion
    (dolist (case '((nil "answer") (t "password-canary") (nil quit)))
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (python-mode)
        (insert "# %%\ninput()\n")
        (let* ((session (emacs-jupyter-notebook-backend-session-create
                         nil (current-buffer)))
               (state (emacs-jupyter-notebook-helper-backend--make-state
                       :helper 'fake))
               (panel (ejn-panel-ensure (current-buffer)))
               (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
               (generation (plist-get handle :generation))
               (input-id (make-string 32 ?a))
               (requests nil)
               (prompted nil)
               (secret (copy-sequence (if (eq (cadr case) 'quit)
                                          "" (cadr case)))))
          (setf (emacs-jupyter-notebook-backend-session-data session) state
                (emacs-jupyter-notebook-helper-backend-state-emit state)
                (lambda (event)
                  (emacs-jupyter-notebook--backend-event session event)))
          ;; These values must be actual buffer-local state: the deferred event
          ;; timer runs after the dynamic extent that admitted the helper event.
          (setq emacs-jupyter-notebook--client session
                emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--execution-active-id 1
                emacs-jupyter-notebook--execution-queue '(1)
                emacs-jupyter-notebook--execution-ledger
                (make-hash-table :test #'eql))
          (let (messages)
            (emacs-jupyter-notebook--execution-put
             (list :id 1 :state 'dispatched :backend-request-id 9
                   :generation generation :panel-entry handle))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                       (lambda (_helper operation params callback &rest _keys)
                         (let ((snapshot (copy-hash-table params)))
                           ;; The real supervisor serializes synchronously before
                           ;; the UI unwind clears its password string.
                           (when-let ((value (gethash "value" snapshot)))
                             (puthash "value" (copy-sequence value) snapshot))
                           (push (list operation snapshot) requests))
                         (funcall callback 'fake
                                  (ejn-ei2-test--response
                                   (ejn-ei2-test--object "accepted" t)) nil)
                         "input-reply-wire"))
                      ((symbol-function 'read-string)
                       (lambda (_prompt) (setq prompted t)
                         (if (eq (cadr case) 'quit)
                             (signal 'quit nil)
                           secret)))
                      ((symbol-function 'read-passwd)
                       (lambda (_prompt) (setq prompted t) secret))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages)))
                      ((symbol-function 'emacs-jupyter-notebook--log-append)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
                     (should
                      (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
                       state "wire-execute"
                       (list :ledger-id 1 :backend-request-id 9 :panel-generation generation)
                       (ejn-ei2-test--object
                        "event" "input_request" "request_id" "wire-execute"
                        "data" (ejn-ei2-test--object
                                "input_id" input-id "prompt" "Prompt: "
                                "password" (if (car case) t :false)))))
                     ;; The helper process callback/filter turn never enters a prompt.
                     (should-not prompted)
                     (accept-process-output nil 0.15)
                     (should prompted)
                     (should (= (length requests) 1))
                     (should (equal (caar requests) "input_reply"))
                     (should (equal (gethash "request_id" (cadar requests))
                                    "wire-execute"))
                     (should (equal (gethash "input_id" (cadar requests)) input-id))
                     (should (equal (gethash "value" (cadar requests))
                                    (if (eq (cadr case) 'quit) "" (cadr case))))
                     (dolist (message messages)
                       (should-not (string-match-p "password-canary" message))))))))))

(ert-deftest ejn-ei5-helper-input-reply-rejects-stale-and-duplicate-leases ()
  "A stale or already-consumed stdin lease must not send another request."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'client-a)
          (emacs-jupyter-notebook-mode t)
          (calls 0)
          (reply (emacs-jupyter-notebook--helper-input-reply
                  'client-a 1 "wire" (make-string 32 ?a))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-input-current-p)
                 (lambda (_id) t))
                ((symbol-function 'emacs-jupyter-notebook-backend-input)
                 (lambda (&rest _) (cl-incf calls))))
        (funcall reply "once")
        (funcall reply "twice")
        (should (= calls 1))
        (setq emacs-jupyter-notebook--client 'client-b)
        (funcall reply "stale")
        (should (= calls 1))))))

(ert-deftest ejn-ei5-stdin-cancellation-blocks-late-event-and-prompt ()
  "Cancellation before delivery or timer execution cannot prompt or reply."
  (with-temp-buffer
    (python-mode)
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (generation (plist-get handle :generation))
           (context (list :buffer (current-buffer) :request-id 1
                          :backend-request-id 9 :panel-generation generation
                          :entry-handle handle :input-reply
                          (lambda (_value) (setq replied t))))
           (event '(:type input-request :prompt "Prompt: " :password nil))
           (emacs-jupyter-notebook--execution-active-id 1)
           (emacs-jupyter-notebook--execution-queue '(1))
           (emacs-jupyter-notebook--execution-ledger
            (make-hash-table :test #'eql))
           prompted replied)
      (emacs-jupyter-notebook--execution-put
       (list :id 1 :state 'dispatched :backend-request-id 9
             :generation generation :panel-entry handle))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (setq prompted t) "late")))
        ;; Admit while dispatched, then cancel before the zero-delay prompt.
        (should (emacs-jupyter-notebook-events-dispatch context event))
        (let ((record (emacs-jupyter-notebook--execution-record 1)))
          (emacs-jupyter-notebook--execution-put
           (plist-put record :state 'cancelling)))
        (ejn-ei2-test--run-timers)
        (should-not prompted)
        (should-not replied)
        ;; A prompt arriving after cancellation is rejected at admission too.
        (should (equal (emacs-jupyter-notebook-events-dispatch context event)
                       '((:action ignore))))
        (ejn-ei2-test--run-timers)
        (should-not prompted)
        (should-not replied)))))

(ert-deftest ejn-ei6-helper-control-results-are-exact-and-restart-is-rejected ()
  "EI6 admits only exact interrupt/shutdown acknowledgements, never restart."
  (dolist (case '((interrupt "interrupted") (shutdown "shutdown")))
    (let ((result (ejn-ei2-test--object (cadr case) t)))
      (should-not
       (condition-case nil
           (emacs-jupyter-notebook-helper-backend--control-result
            result (cadr case))
         (error nil)))
      (dolist (bad (list (ejn-ei2-test--object (cadr case) :false)
                         (ejn-ei2-test--object (cadr case) t "extra" t)
                         (ejn-ei2-test--object)))
        (should-error
         (emacs-jupyter-notebook-helper-backend--control-result
          bad (cadr case))))))
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let ((state (emacs-jupyter-notebook-helper-backend--make-state
                    :helper 'fake)))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (emacs-jupyter-notebook-backend-session-mark-attached session)
        (let (failure)
          (emacs-jupyter-notebook-backend-control
           session 'restart nil #'ignore
           (lambda (_id reason) (setq failure reason)))
          (ejn-ei2-test--run-timers)
          (should (string-match-p "Unsupported helper backend operation"
                                  (format "%s" failure)))
          (should-not requests)
          (should-not callbacks))
        (let (failure)
          (emacs-jupyter-notebook-backend-control
           session 'interrupt '(:unexpected t) #'ignore
           (lambda (_id reason) (setq failure reason)))
          (ejn-ei2-test--run-timers)
          (should (string-match-p "payload" (format "%s" failure)))
          (should-not requests))))))

(ert-deftest ejn-ei6-helper-control-dispatches-interrupt-and-shutdown ()
  "EI6 maps both admitted controls to bounded helper requests."
  (ejn-ei2-test-with-fake-helper (requests callbacks disposals)
    (ejn-ei2-test-with-session
      (let ((state (emacs-jupyter-notebook-helper-backend--make-state
                    :helper 'fake))
            results)
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (dolist (operation '(interrupt shutdown))
          (emacs-jupyter-notebook-backend-control
           session operation nil
           (lambda (_id value) (push value results))
           #'ert-fail)
          (funcall (car callbacks)
                   nil
                   (ejn-ei2-test--response
                    (ejn-ei2-test--object
                     (if (eq operation 'interrupt) "interrupted" "shutdown") t))
                   nil))
        (ejn-ei2-test--run-timers)
        (should (= 2 (length results)))
        (should (equal (mapcar #'car (nreverse requests))
                       '("interrupt" "shutdown")))))))

;; EI7 transport ambiguity tests deliberately exercise the public backend
;; failure boundary.  The fake helper never starts SSH or Jupyter; its request
;; log is the dispatch evidence used to distinguish accepted from queued work.

(defun ejn-ei7-test--session (owner)
  "Return an installed helper SESSION with no remote resources."
  (let* ((session (emacs-jupyter-notebook-backend-session-create
                     nil owner #'emacs-jupyter-notebook--backend-transport-failed))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'ei7-fake
                   :request-map (make-hash-table :test #'equal)
                   :retired-request-ids (make-hash-table :test #'equal))))
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state)
            (lambda (reason)
              (emacs-jupyter-notebook-backend-session-notify-transport-failure
               session reason)))
      (emacs-jupyter-notebook-backend-session-mark-attached session)
      (emacs-jupyter-notebook-backend-session-mark-installed session)
      session))

(defun ejn-ei7-test--record (id state &optional backend-id timer)
  "Return an EI7 ledger record with stable correlation metadata."
  (list :id id :state state :backend-request-id backend-id :generation 1
        :timer timer :reply-seen nil :idle-seen nil
        :terminal (memq state '(terminal-ok terminal-error))
        :panel-entry (list :ei7-entry id)
        :cell-key (cons "ei7-test.py" id)))

(cl-defmacro ejn-ei7-test-with-presentations ((finished fringe text) &body body)
  "Run BODY with deterministic panel/fringe presentation spies."
  (declare (indent 1) (debug t))
  `(let (,finished ,fringe ,text)
     (cl-letf (((symbol-function 'ejn-panel-entry-live-p)
                (lambda (_handle) t))
               ((symbol-function 'ejn-panel-append-text)
                (lambda (_handle value &rest _face) (push value ,text)))
               ((symbol-function 'ejn-panel-finish-entry)
                (lambda (_handle status &rest _count) (push status ,finished)))
               ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                (lambda (_key status &rest _count) (push status ,fringe)))
               ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                #'ignore))
       ,@body)))

(cl-defmacro ejn-ei7-test-with-fake-requests ((requests callbacks) &body body)
  "Run BODY with a request log and callback table for EI7."
  (declare (indent 1) (debug t))
  `(let (,requests ,callbacks)
     (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                (lambda (_helper operation params callback &rest _keys)
                  (let ((wire-id (format "ei7-wire-%d" (1+ (length ,callbacks)))))
                    (push (list operation params wire-id) ,requests)
                    (push callback ,callbacks)
                    wire-id))))
       ,@body)))

(ert-deftest ejn-ei7-failure-before-send-cancels-unaccepted-work ()
  "A queued record has no outcome ambiguity when transport dies pre-dispatch."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (record (ejn-ei7-test--record 1 'queued))
           (scheduled 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id nil
            emacs-jupyter-notebook--execution-queue '(1))
      (emacs-jupyter-notebook--execution-put record)
      (ejn-ei7-test-with-fake-requests (requests callbacks)
        (ejn-ei7-test-with-presentations (finished fringe text)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                     (lambda () (cl-incf scheduled)))
                    ((symbol-function 'emacs-jupyter-notebook--log-append)
                     #'ignore))
            (emacs-jupyter-notebook-backend-session-notify-transport-failure
             session "before send")
            (should (= scheduled 1))
            (should-not requests)
            (should (equal finished '(cancelled)))
            (should (equal fringe '(cancelled)))
            (should-not (emacs-jupyter-notebook--execution-record 1))
            (should-not emacs-jupyter-notebook--execution-active-id)
            (should-not callbacks)))))))

(ert-deftest ejn-ei7-helper-death-after-send-marks-unknown-and-cancels-timer ()
  "Helper death after accepted send marks only that execution unknown."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (timer (run-at-time 300 nil #'ignore))
           (scheduled 0) (success-called nil) (failure-called nil)
           backend-id)
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1))
            (ejn-ei7-test-with-fake-requests (requests callbacks)
              (ejn-ei7-test-with-presentations (finished fringe text)
                (setq backend-id
                      (emacs-jupyter-notebook-backend-execute
                       session "accepted()" '(:ledger-id 1 :entry-handle (:generation 1))
                       (lambda (&rest _) (setq success-called t))
                       (lambda (&rest _) (setq failure-called t))))
                (emacs-jupyter-notebook--execution-put
                 (ejn-ei7-test--record 1 'dispatched backend-id timer))
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                           (lambda () (cl-incf scheduled)))
                          ((symbol-function 'emacs-jupyter-notebook--log-append)
                           #'ignore))
                  (emacs-jupyter-notebook-backend-session-notify-transport-failure
                   session "helper died")
                  ;; A duplicate lifecycle signal must not admit a second retry.
                  (emacs-jupyter-notebook-backend-session-notify-transport-failure
                   session "helper died again")
                  (should (= scheduled 1))
                  (should (equal finished '(outcome-unknown)))
                  (should (equal fringe '(outcome-unknown)))
                  (should-not (emacs-jupyter-notebook--execution-record 1))
                  (should-not (memq timer timer-list))
                  (should-not success-called)
                  (should-not failure-called)
                  (should (= 1 (length requests)))
                  (should (= 1 (length callbacks)))))))
        (when (timerp timer) (cancel-timer timer))))))

(ert-deftest ejn-ei7-busy-failure-cancels-queued-without-replay ()
  "A busy accepted head becomes unknown; unaccepted FIFO work is cancelled."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (timer (run-at-time 300 nil #'ignore))
           (scheduled 0))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1 2))
            (emacs-jupyter-notebook--execution-put
             (ejn-ei7-test--record 1 'busy "wire-a" timer))
            (emacs-jupyter-notebook--execution-put
             (ejn-ei7-test--record 2 'queued))
            (puthash "wire-a" (list :ledger-id 1 :backend-request-id "wire-a"
                                     :panel-generation 1)
                     (emacs-jupyter-notebook-helper-backend-state-request-map
                      (emacs-jupyter-notebook-backend-session-data session)))
            (ejn-ei7-test-with-presentations (finished fringe text)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                         #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                         #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                         (lambda () (cl-incf scheduled)))
                        ((symbol-function 'emacs-jupyter-notebook--log-append)
                         #'ignore))
                (emacs-jupyter-notebook--backend-transport-failed
                 session "tunnel died")
                (should (= scheduled 1))
                (should (equal finished '(cancelled outcome-unknown)))
                (should (equal fringe '(cancelled outcome-unknown)))
                (should-not emacs-jupyter-notebook--execution-active-id))))
        (when (timerp timer) (cancel-timer timer))))))

(ert-deftest ejn-ei7-reply-before-idle-is-unknown-and-late-idle-is-inert ()
  "Transport death after reply but before idle cannot be completed by late idle."
  (with-temp-buffer
    (let* ((session-a (ejn-ei7-test--session (current-buffer)))
           (timer (run-at-time 300 nil #'ignore))
           (scheduled 0))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client session-a
                  emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1))
            (emacs-jupyter-notebook--execution-put
             (ejn-ei7-test--record 1 'dispatched "wire-a" timer))
            (puthash "wire-a" (list :ledger-id 1 :backend-request-id "wire-a"
                                     :panel-generation 1)
                     (emacs-jupyter-notebook-helper-backend-state-request-map
                      (emacs-jupyter-notebook-backend-session-data session-a)))
            (emacs-jupyter-notebook--execution-note-event
             '(:request-id 1 :backend-request-id "wire-a" :panel-generation 1)
             '(:type execute-reply :status "ok"))
            (ejn-ei7-test-with-presentations (finished fringe text)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                         #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                         #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                         (lambda () (cl-incf scheduled)))
                        ((symbol-function 'emacs-jupyter-notebook--log-append)
                         #'ignore))
                (emacs-jupyter-notebook--backend-transport-failed
                 session-a "heartbeat died")
                (should (= scheduled 1))
                (should (equal finished '(outcome-unknown)))
                (should (equal fringe '(outcome-unknown)))
                ;; The record was retired, so a late idle cannot settle it.
                (emacs-jupyter-notebook--execution-note-event
                 '(:request-id 1 :backend-request-id "wire-a" :panel-generation 1)
                 '(:type status :execution-state "idle"))
                (should-not (emacs-jupyter-notebook--execution-record 1))))))
        (when (timerp timer) (cancel-timer timer)))))

(ert-deftest ejn-ei7-terminal-work-is-not-replayed-after-protocol-failure ()
  "A terminal record stays terminal while a protocol failure reconnects once."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (scheduled 0)
           (record (ejn-ei7-test--record 1 'terminal-ok "wire-terminal")))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id nil
            emacs-jupyter-notebook--execution-queue nil)
      (emacs-jupyter-notebook--execution-put record)
      (puthash "wire-terminal"
               (list :ledger-id 1 :backend-request-id "wire-terminal"
                     :panel-generation 1)
               (emacs-jupyter-notebook-helper-backend-state-request-map
                (emacs-jupyter-notebook-backend-session-data session)))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          ;; A malformed event is a protocol failure, not a user execution.
          (emacs-jupyter-notebook-helper-backend--event
           session (emacs-jupyter-notebook-backend-session-data session)
           (ejn-ei2-test--object "event" "not-a-real-event"
                                 "request_id" "wire-terminal"
                                 "data" (ejn-ei2-test--object)))
          (should (= scheduled 1))
          (should-not finished)
          (should-not fringe)
          (should-not text)
          ;; Terminal state is intentionally absent from the transport-loss
          ;; presentation, so a protocol failure cannot rewrite its result.
          (should (eq (plist-get (emacs-jupyter-notebook--execution-record 1)
                                 :state)
                      'terminal-ok)))))))

(ert-deftest ejn-ei7-reconnect-does-not-replay-and-new-execution-succeeds ()
  "A retired helper cannot replay old code; a new helper accepts new code."
  (with-temp-buffer
    (let* ((session-a (ejn-ei7-test--session (current-buffer)))
           (session-b (ejn-ei7-test--session (current-buffer)))
           (state-a (emacs-jupyter-notebook-backend-session-data session-a))
           (state-b (emacs-jupyter-notebook-backend-session-data session-b))
           successes)
      (ejn-ei7-test-with-fake-requests (requests callbacks)
        (let ((old-id nil) (new-id nil))
          (setq old-id
                (emacs-jupyter-notebook-backend-execute
                 session-a "old()" '(:ledger-id 1 :entry-handle (:generation 1))
                 (lambda (&rest _) (push 'old successes))
                 (lambda (&rest _) (push 'old-error successes))))
          ;; Reconnect replaces the local helper; it must not resend OLD.
          (emacs-jupyter-notebook-helper-backend--dispose state-a "transport lost")
          (setq new-id
                (emacs-jupyter-notebook-backend-execute
                 session-b "new()" '(:ledger-id 2 :entry-handle (:generation 1))
                 (lambda (&rest _) (push 'new successes))
                 (lambda (&rest _) (push 'new-error successes))))
          (should (integerp old-id))
          (should (integerp new-id))
          (should (< old-id new-id))
          ;; The newest callback is B's; its successful response is accepted.
          (funcall (car callbacks) 'fake
                   (ejn-ei2-test--response
                    (ejn-ei2-test--object "status" "ok" "execution_count" 1))
                   nil)
          ;; A late response from retired A must be inert.
          (funcall (car (last callbacks)) 'fake
                   (ejn-ei2-test--response
                    (ejn-ei2-test--object "status" "ok" "execution_count" 1))
                   nil)
          (ejn-ei2-test--run-timers)
          (should (equal successes '(new)))
          (should (equal (mapcar #'car (nreverse requests))
                         '("execute" "execute")))))
      (emacs-jupyter-notebook-helper-backend--dispose state-b "EI7 test cleanup"))))

(ert-deftest ejn-ei7-setup-callback-after-transport-loss-cannot-pump ()
  "A setup callback from a retired transport cannot release the FIFO."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (timer (run-at-time 300 nil #'ignore))
           (pumps 0) (scheduled 0))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-setup-pending t
                  emacs-jupyter-notebook--execution-setup-timer timer
                  emacs-jupyter-notebook--execution-setup-epoch 7)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                       (lambda () (cl-incf scheduled)))
                      ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                       (lambda () (cl-incf pumps)))
                      ((symbol-function 'emacs-jupyter-notebook--log-append)
                       #'ignore))
              (emacs-jupyter-notebook--transport-lost
               "setup transport lost" session nil)
              ;; This is the callback already queued by the old setup request.
              (emacs-jupyter-notebook--execution-setup-finish session 7 nil)
              (should (= scheduled 1))
              (should (= pumps 0))
              (should-not emacs-jupyter-notebook--execution-setup-pending)
              (should-not emacs-jupyter-notebook--execution-setup-timer)
              (should (= emacs-jupyter-notebook--execution-setup-epoch 8))))
        (when (timerp timer) (cancel-timer timer))
        (ignore-errors
          (emacs-jupyter-notebook-helper-backend--dispose
           (emacs-jupyter-notebook-backend-session-data session)
           "EI7 test cleanup"))))))

(ert-deftest ejn-ei7-helper-tunnel-heartbeat-signals-schedule-once ()
  "Concurrent lifecycle signals settle once and admit one reconnect loop."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (record (ejn-ei7-test--record 1 'queued))
           (scheduled 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-queue '(1))
      (emacs-jupyter-notebook--execution-put record)
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          (emacs-jupyter-notebook-backend-session-notify-transport-failure
           session "helper")
          (emacs-jupyter-notebook--transport-lost "tunnel" session nil)
          (emacs-jupyter-notebook--transport-lost "heartbeat" session nil)
          (should (= scheduled 1))
          (should (equal finished '(cancelled)))
          (should (equal fringe '(cancelled)))
          (should (string-match-p "transport lost" (car text))))))))

(ert-deftest ejn-ei7-stale-tunnel-sentinel-cannot-retire-replacement ()
  "An old tunnel process must not affect the replacement process."
  (let* ((buffer (generate-new-buffer " *ejn-ei7-sentinel*"))
         (old (start-process "ejn-ei7-old-tunnel" nil "true"))
         (current (start-process "ejn-ei7-current-tunnel" nil "sleep" "30"))
         (scheduled 0))
    (unwind-protect
        (progn
          (while (process-live-p old) (accept-process-output old 0.01))
          (with-current-buffer buffer
            (setq emacs-jupyter-notebook--tunnel-process current)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                       (lambda () (cl-incf scheduled)))
                      ((symbol-function 'emacs-jupyter-notebook--transport-lost)
                       (lambda (&rest _) (cl-incf scheduled))))
              (emacs-jupyter-notebook--install-tunnel-sentinel old buffer)
              (should (eq emacs-jupyter-notebook--tunnel-process current))
              (should (= scheduled 0)))))
      (when (process-live-p old) (delete-process old))
      (when (process-live-p current) (delete-process current))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ejn-ei7-transport-loss-never-touches-durable-or-remote-state ()
  "Local transport loss does not control the kernel or mutate its registry."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (record (ejn-ei7-test--record 1 'queued))
           (controls 0) (remote-cleanups 0) (registry-removals 0)
           (scheduled 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--session-entry '(:session-id "durable")
            emacs-jupyter-notebook--execution-queue '(1))
      (emacs-jupyter-notebook--execution-put record)
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                   (lambda (&rest _) (cl-incf controls)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (cl-incf remote-cleanups)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-create-async)
                   (lambda (&rest _) (cl-incf registry-removals)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                   (lambda (&rest _) (cl-incf registry-removals)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
                   (lambda (&rest _) (cl-incf registry-removals)))
                  ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          (emacs-jupyter-notebook--transport-lost "local only" session nil)
          (should (= scheduled 1))
          (should (= controls 0))
          (should (= remote-cleanups 0))
          (should (= registry-removals 0))
          (should (equal emacs-jupyter-notebook--session-entry
                         '(:session-id "durable"))))))))

(ert-deftest ejn-ei7-sync-write-failure-is-not-admission-evidence ()
  "A generic id returned after a failed write must classify as cancelled."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (scheduled 0) request-id)
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                   (lambda (_helper _operation _params callback &rest _keys)
                     (funcall callback 'fake nil "local write failed")
                     "wire-after-failure"))
                  ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          (setq request-id
                (emacs-jupyter-notebook-backend-execute
                 session "write-fails()" '(:ledger-id 1)
                 #'ignore #'ignore))
          (should (integerp request-id))
          (should-not
           (emacs-jupyter-notebook-helper-backend-ledger-id-admitted-p
            session 1 request-id))
          (emacs-jupyter-notebook--execution-put
           (ejn-ei7-test--record 1 'dispatched request-id))
          (emacs-jupyter-notebook--transport-lost "write failed" session nil)
          (should (= scheduled 1))
          (should (equal finished '(cancelled)))
          (should (equal fringe '(cancelled))))))))

(ert-deftest ejn-ei7-valid-helper-transport-error-retires-admitted-and-queued-work ()
  "A valid helper transport frame settles admitted A and queued B once."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (scheduled 0) (closed 0) backend-id)
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2)
            emacs-jupyter-notebook--kernel-status 'busy)
      (ejn-ei7-test-with-fake-requests (requests callbacks)
        (setq backend-id
              (emacs-jupyter-notebook-backend-execute
               session "A()" '(:ledger-id 1 :entry-handle (:generation 1))
               #'ignore #'ignore))
        (emacs-jupyter-notebook--execution-put
         (ejn-ei7-test--record 1 'busy backend-id))
        (emacs-jupyter-notebook--execution-put
         (ejn-ei7-test--record 2 'queued))
        (ejn-ei7-test-with-presentations (finished fringe text)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                     (lambda (&rest _) (cl-incf closed)))
                    ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                     (lambda () (cl-incf scheduled)))
                    ((symbol-function 'emacs-jupyter-notebook--log-append)
                     #'ignore))
            ;; This is a valid post-write helper response.  `admitted' is the
            ;; helper's evidence that the execute reached Jupyter; the shared
            ;; transport-loss path must classify A as ambiguous.
            (funcall (car callbacks) 'fake
                     (ejn-ei2-test--object
                      "ok" :false
                      "error" (ejn-ei2-test--object
                                "code" "transport-error"
                                "message" "helper lost the channel"
                                "admitted" t))
                     nil)
            (should (= scheduled 1))
            (should (= closed 1))
            (should (= 1 (length requests)))
            (should (equal finished '(cancelled outcome-unknown)))
            (should (equal fringe '(cancelled outcome-unknown)))
            (should (= 1 (hash-table-count
                          (emacs-jupyter-notebook-backend-session-requests session))))
            (should-not emacs-jupyter-notebook--execution-active-id)
            (should-not emacs-jupyter-notebook--client)
            (should (cl-some (lambda (line)
                               (string-match-p "outcome unknown" line))
                             text))))))))

(ert-deftest ejn-ei7-post-send-helper-timeout-with-busy-kernel-is-unknown ()
  "A helper timeout after dispatch does not replay busy work or pump B."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (timer (run-at-time 300 nil #'ignore))
           (scheduled 0) backend-id)
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1 2)
                  emacs-jupyter-notebook--kernel-status 'busy)
            (ejn-ei7-test-with-fake-requests (requests callbacks)
              (setq backend-id
                    (emacs-jupyter-notebook-backend-execute
                     session "busy-A()" '(:ledger-id 1 :entry-handle (:generation 1))
                     #'ignore #'ignore))
              (emacs-jupyter-notebook--execution-put
               (ejn-ei7-test--record 1 'busy backend-id timer))
              (emacs-jupyter-notebook--execution-put
               (ejn-ei7-test--record 2 'queued))
              (ejn-ei7-test-with-presentations (finished fringe text)
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                           (lambda () (cl-incf scheduled)))
                          ((symbol-function 'emacs-jupyter-notebook--log-append)
                           #'ignore))
                  ;; A timeout is delivered through the helper request
                  ;; callback after the execute frame has been written.
                  (funcall (car callbacks) 'fake nil
                           "helper execute request timed out")
                  (should (= scheduled 1))
                  (should (= 1 (length requests)))
                  (should (equal finished '(cancelled outcome-unknown)))
                  (should (equal fringe '(cancelled outcome-unknown)))
                  (should-not (memq timer timer-list))
                  (should-not emacs-jupyter-notebook--execution-active-id))))))
        (when (timerp timer) (cancel-timer timer)))))

(ert-deftest ejn-ei7-pre-admission-rejection-remains-ordinary-error ()
  "A valid admitted:false helper error does not retire the transport."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (failure nil) (transport-failed nil))
      (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state)
            (lambda (_reason) (setq transport-failed t)))
      (ejn-ei7-test-with-fake-requests (requests callbacks)
        (emacs-jupyter-notebook-backend-execute
         session "rejected()" '(:ledger-id 1)
         #'ignore (lambda (_id reason) (setq failure reason)))
        (funcall (car callbacks) 'fake
                 (ejn-ei2-test--object
                  "ok" :false
                  "error" (ejn-ei2-test--object
                            "code" "invalid-request"
                            "message" "rejected before backend admission"
                            "admitted" :false))
                 nil)
        (ejn-ei2-test--run-timers)
        (should (= 1 (length requests)))
        (should (string-match-p "invalid-request" failure))
        (should-not transport-failed)
        (should-not (emacs-jupyter-notebook-helper-backend-state-retired state))
        ;; An explicit pre-admission rejection is ordinary operation failure,
        ;; but its wire id is retired synchronously so a racing loss cannot
        ;; reinterpret it as an admitted execution.
        (should-not (emacs-jupyter-notebook-helper-backend-ledger-id-admitted-p
                     session 1 nil))
        (should (gethash
                 "ei7-wire-1"
                 (emacs-jupyter-notebook-helper-backend-state-retired-request-ids
                  state)))))))

(ert-deftest ejn-ei7-malformed-early-event-flush-is-fatal-transport-loss ()
  "An early event that fails normalization must trigger transport recovery."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (scheduled 0) backend-id)
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                   (lambda (_helper _operation _params _callback &rest _keys)
                     ;; The public dispatch depth makes this an early event;
                     ;; the mapping is installed only after this returns.
                     (emacs-jupyter-notebook-helper-backend--event
                      session state
                      (ejn-ei2-test--object
                       "event" "execute_reply"
                       "request_id" "early-malformed"
                       "data" (ejn-ei2-test--object "unexpected" t)))
                     "early-malformed"))
                  ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          (setq backend-id
                (emacs-jupyter-notebook-backend-execute
                 session "early()" '(:ledger-id 1 :entry-handle (:generation 1))
                 #'ignore #'ignore))
          (emacs-jupyter-notebook--execution-put
           (ejn-ei7-test--record 1 'dispatched backend-id))
          (ejn-ei2-test--run-timers)
          (should (= scheduled 1))
          (should (equal finished '(outcome-unknown)))
          (should (equal fringe '(outcome-unknown)))
          (should-not emacs-jupyter-notebook--client))))))

(ert-deftest ejn-ei7-retry-cycle-admits-only-new-work-after-transport-loss ()
  "Retry callback restores a new helper without resending A or queued B."
  (with-temp-buffer
    (let* ((session-a (ejn-ei7-test--session (current-buffer)))
           (session-c (ejn-ei7-test--session (current-buffer)))
           (entry (ejn-ei2-test--direct-entry))
           (attempts 0) (backend-id))
      (setq emacs-jupyter-notebook--client session-a
            emacs-jupyter-notebook--session-entry entry
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2)
            emacs-jupyter-notebook--kernel-status 'busy
            emacs-jupyter-notebook-mode t)
      (ejn-ei7-test-with-fake-requests (requests callbacks)
        (setq backend-id
              (emacs-jupyter-notebook-backend-execute
               session-a "A()" '(:ledger-id 1 :entry-handle (:generation 1))
               #'ignore #'ignore))
        (emacs-jupyter-notebook--execution-put
         (ejn-ei7-test--record 1 'busy backend-id))
        (emacs-jupyter-notebook--execution-put
         (ejn-ei7-test--record 2 'queued))
        (ejn-ei7-test-with-presentations (finished fringe text)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--log-append)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
                     (lambda (_entry callback _error-callback &optional _owner)
                       (cl-incf attempts)
                       (setq emacs-jupyter-notebook--client session-c
                             emacs-jupyter-notebook--tunnel-dead nil)
                       (funcall callback (list :phase 'done))))
                    ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                     #'ignore))
            (emacs-jupyter-notebook--transport-lost "retry cycle" session-a nil)
            (should (= 1 (length requests)))
            (let ((token emacs-jupyter-notebook--reconnect-schedule-token))
              (should token)
              (emacs-jupyter-notebook--auto-reconnect-fire (current-buffer) token)
              (should (= attempts 1))
              (should-not emacs-jupyter-notebook--reconnect-schedule-token)
              ;; The consumed token cannot admit a second reconnect attempt.
              (emacs-jupyter-notebook--auto-reconnect-fire (current-buffer) token)
              (should (= attempts 1)))
            (should (eq emacs-jupyter-notebook--client session-c))
            (emacs-jupyter-notebook-backend-execute
             session-c "C()" '(:ledger-id 3 :entry-handle (:generation 1))
             #'ignore #'ignore)
            (should
             (equal
              (mapcar (lambda (request) (gethash "code" (cadr request)))
                      (nreverse requests))
              '("A()" "C()")))
            (should (equal finished '(cancelled outcome-unknown)))
            (should (equal fringe '(cancelled outcome-unknown)))))))))

(ert-deftest ejn-ei7-execute-response-without-terminal-events-expires-grace-in-owner ()
  "An execute response alone cannot cancel the core terminal grace timer."
  (let ((owner (generate-new-buffer " *ejn-ei7-grace-owner*"))
        (other (generate-new-buffer " *ejn-ei7-grace-other*"))
        grace)
    (unwind-protect
        (with-current-buffer owner
          (let* ((session (ejn-ei7-test--session owner))
                 (state (emacs-jupyter-notebook-backend-session-data session))
                 (interrupts 0) (scheduled 0) backend-id)
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1))
            (ejn-ei7-test-with-fake-requests (requests callbacks)
              (setq backend-id
                    (emacs-jupyter-notebook-backend-execute
                     session "long_cell()" '(:ledger-id 1 :entry-handle (:generation 1))
                     #'ignore #'ignore))
              (emacs-jupyter-notebook--execution-put
               (ejn-ei7-test--record 1 'dispatched backend-id))
              ;; The helper's successful request response may arrive before
              ;; the queued execute_reply/status frames.  It is not terminal
              ;; ledger evidence and must leave the core timeout in force.
              (funcall (car callbacks) 'fake
                       (ejn-ei2-test--response
                        (ejn-ei2-test--object "status" "ok" "execution_count" 1))
                       nil)
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record 1)
                                     :state)
                          'dispatched))
              (ejn-ei7-test-with-presentations (finished fringe text)
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--interrupt-active-execution)
                           (lambda (_client) (cl-incf interrupts)))
                          ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                           (lambda () (cl-incf scheduled)))
                          ((symbol-function 'emacs-jupyter-notebook--log-append)
                           #'ignore))
                  (let ((emacs-jupyter-notebook-evaluation-timeout 30))
                    (emacs-jupyter-notebook--evaluation-on-timeout 1))
                  (setq grace (plist-get (emacs-jupyter-notebook--execution-record 1)
                                         :interrupt-grace-timer))
                  (should (= interrupts 1))
                  (should (timerp grace))
                  ;; The timer must use OWNER's buffer-local session even
                  ;; though another source buffer is current when it fires.
                  (with-current-buffer other
                    (apply (timer--function grace) (timer--args grace)))
                  (should (= scheduled 1))
                  (should (equal finished '(outcome-unknown)))
                  (should (equal fringe '(outcome-unknown)))
                  (should-not emacs-jupyter-notebook--client)
                  (should-not (emacs-jupyter-notebook--execution-record 1))))
            (ignore-errors
              (emacs-jupyter-notebook-helper-backend--dispose state "EI7 grace cleanup"))))
      (when (timerp grace) (cancel-timer grace))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest ejn-ei7-timeout-interrupt-synchronous-loss-creates-no-phantom-record ()
  "A synchronous interrupt failure may retire the record before grace setup."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (scheduled 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 1 'dispatched "wire-a"))
      (puthash "wire-a" (list :ledger-id 1 :backend-request-id "wire-a"
                               :panel-generation 1)
               (emacs-jupyter-notebook-helper-backend-state-request-map state))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--interrupt-active-execution)
                 (lambda (client)
                   (emacs-jupyter-notebook--transport-lost
                    "synchronous interrupt transport loss" client nil)))
                ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                 (lambda () (cl-incf scheduled)))
                ((symbol-function 'emacs-jupyter-notebook--log-append)
                 #'ignore))
        (let ((emacs-jupyter-notebook-evaluation-timeout 30))
          (emacs-jupyter-notebook--evaluation-on-timeout 1))
        (should (= scheduled 1))
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--execution-active-id)
        (should (= (hash-table-count emacs-jupyter-notebook--execution-ledger) 0))
        (should-not (gethash nil emacs-jupyter-notebook--execution-ledger))))))

(ert-deftest ejn-ei7-timeout-grace-timer-setup-failure-terminally-recovers ()
  "A cancelling execution cannot wedge when its post-interrupt timer fails."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (scheduled 0)
           (interrupts 0)
           (remote-controls 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2)
            emacs-jupyter-notebook--kernel-status 'idle)
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 1 'dispatched "wire-grace"))
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 2 'queued))
      ;; The accepted head must retain its ambiguous outcome while the queued
      ;; tail is cancelled by the exact existing transport-loss transition.
      (puthash "wire-grace"
               (list :ledger-id 1 :backend-request-id "wire-grace"
                     :panel-generation 1)
               (emacs-jupyter-notebook-helper-backend-state-request-map state))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--interrupt-active-execution)
                   (lambda (_client) (cl-incf interrupts)))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest _args)
                     (error "injected interrupt-grace timer failure")))
                  ((symbol-function 'emacs-jupyter-notebook-backend-control)
                   (lambda (&rest _args) (cl-incf remote-controls)))
                  ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore))
          (let ((emacs-jupyter-notebook-evaluation-timeout 30))
            (emacs-jupyter-notebook--evaluation-on-timeout 1))
          (should (= interrupts 1))
          (should (= scheduled 1))
          (should (= remote-controls 0))
          (should-not emacs-jupyter-notebook--client)
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should-not emacs-jupyter-notebook--execution-queue)
          (should (= (hash-table-count emacs-jupyter-notebook--execution-ledger) 0))
          (should (member 'outcome-unknown finished))
          (should (member 'cancelled finished))
          (should (member 'outcome-unknown fringe))
          (should (member 'cancelled fringe))
          ;; Later timeout/event delivery for the retired identity is inert.
          (emacs-jupyter-notebook--evaluation-on-timeout 1)
          (should (= scheduled 1)))))))

(ert-deftest ejn-ei7-dispatch-deadline-construction-failure-never-sends ()
  "A user execution is terminally rejected before send without its deadline."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (record (ejn-ei7-test--record 1 'checking))
           (sent 0) (pumps 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (emacs-jupyter-notebook--execution-put record)
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 2 'queued))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (&rest _args)
                     (error "injected evaluation deadline failure")))
                  ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                   (lambda (&rest _args) (cl-incf sent)))
                  ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                   (lambda () (cl-incf pumps))))
          (emacs-jupyter-notebook--execution-dispatch record)
          (should (= sent 0))
          (should (= pumps 1))
          (should-not (emacs-jupyter-notebook--execution-record 1))
          (should (emacs-jupyter-notebook--execution-record 2))
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should (equal emacs-jupyter-notebook--execution-queue '(2)))
          (should (equal finished '(error)))
          (should (equal fringe '(error)))
          (should (equal text '("\ncannot schedule evaluation deadline"))))))))

(ert-deftest ejn-ei7-dispatch-eager-deadline-callback-never-sends ()
  "An eager deadline callback retires its pre-send record without a phantom."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (record (ejn-ei7-test--record 1 'checking))
           (sent 0) (pumps 0))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (emacs-jupyter-notebook--execution-put record)
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 2 'queued))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_seconds _repeat function &rest args)
                     (apply function args)
                     (timer-create)))
                  ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                   (lambda (&rest _args) (cl-incf sent)))
                  ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                   (lambda () (cl-incf pumps))))
          (emacs-jupyter-notebook--execution-dispatch record)
          (should (= sent 0))
          (should (= pumps 1))
          (should-not (emacs-jupyter-notebook--execution-record 1))
          (should (emacs-jupyter-notebook--execution-record 2))
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should (equal emacs-jupyter-notebook--execution-queue '(2)))
          (should (equal finished '(error)))
          (should (equal fringe '(error)))
          (should (equal text
                         '("\nevaluation deadline elapsed before execution was sent"))))))))

(ert-deftest ejn-ei7-reentrant-admitted-error-defers-until-wire-map-exists ()
  "A reentrant admitted error waits for mapping before settling transport."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (record (ejn-ei7-test--record 1 'dispatched))
           (scheduled 0) (closed 0) (backend-id nil))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2)
            emacs-jupyter-notebook--kernel-status 'busy)
      (emacs-jupyter-notebook--execution-put record)
      (emacs-jupyter-notebook--execution-put
       (ejn-ei7-test--record 2 'queued))
      (ejn-ei7-test-with-presentations (finished fringe text)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                   (lambda (_helper operation _params callback &rest _keys)
                     (should (equal operation "execute"))
                     ;; This callback runs while generic dispatch depth is
                     ;; nonzero, before the adapter can install its map.
                     (funcall callback 'fake
                              (ejn-ei2-test--object
                               "ok" :false
                               "error" (ejn-ei2-test--object
                                         "code" "transport-error"
                                         "message" "write was accepted then lost"
                                         "admitted" t))
                              nil)
                     "reentrant-wire"))
                  ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                   (lambda (&rest _) (cl-incf closed)))
                  ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                   (lambda () (cl-incf scheduled)))
                  ((symbol-function 'emacs-jupyter-notebook--log-append)
                   #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                   #'ignore))
          (setq backend-id
                (emacs-jupyter-notebook-backend-execute
                 session "A()" '(:ledger-id 1 :entry-handle (:generation 1))
                 #'ignore #'ignore))
          ;; The deferred transport callback must observe this post-return
          ;; backend id and the helper's newly-installed wire mapping.
          (emacs-jupyter-notebook--execution-put
           (plist-put record :backend-request-id backend-id))
          (should (emacs-jupyter-notebook-helper-backend-ledger-id-admitted-p
                   session 1 backend-id))
          (should (= scheduled 0))
          (should-not finished)
          (ejn-ei2-test--run-timers)
          (should (= scheduled 1))
          (should (= closed 1))
          (should (equal finished '(cancelled outcome-unknown)))
          (should (equal fringe '(cancelled outcome-unknown)))
          (should-not (emacs-jupyter-notebook--execution-record 1))
          (should-not (emacs-jupyter-notebook--execution-record 2))
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should (cl-some (lambda (line)
                             (string-match-p "outcome unknown" line))
                           text)))))))

(ert-deftest ejn-ei7-setup-and-user-execute-use-distinct-helper-deadlines ()
  "Setup executes use the bounded auxiliary deadline, unlike user work."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (requests nil) (callbacks nil)
           (emacs-jupyter-notebook-evaluation-timeout 17))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                     (lambda (_helper operation _params callback &rest keys)
                       (push (list operation
                                   (plist-get keys :timeout)
                                   (plist-get keys :allow-long-timeout))
                             requests)
                       (push callback callbacks)
                       (format "ei7-deadline-%d" (length requests)))))
            (emacs-jupyter-notebook-backend-execute
             session "setup()" '(:setup t) #'ignore #'ignore)
            (emacs-jupyter-notebook-backend-execute
             session "user()" '(:ledger-id 1) #'ignore #'ignore)
            (should (= (length callbacks) 2))
            (should
             (equal (nreverse requests)
                    '(("execute" 30 nil)
                      ("execute" 35 t)))))
        (emacs-jupyter-notebook-helper-backend--dispose state
                                                        "EI7 deadline cleanup")))))

(ert-deftest ejn-ei7-post-send-setup-timeout-signals-transport-loss ()
  "A setup timeout after send is fatal and cannot release or pump work."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (callbacks nil) (requests nil) (transport-failures 0)
           (success-called nil) (failure-called nil) (pumps 0))
      (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state)
            (lambda (_reason) (cl-incf transport-failures)))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                     (lambda (_helper operation _params callback &rest _keys)
                       (push operation requests)
                       (push callback callbacks)
                       "ei7-setup-timeout-wire"))
                    ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                     (lambda () (cl-incf pumps))))
            (emacs-jupyter-notebook-backend-execute
             session "setup()" '(:setup t)
             (lambda (&rest _) (setq success-called t))
             (lambda (&rest _) (setq failure-called t)))
            ;; This callback is post-send: the helper request has already
            ;; returned its wire id, so a local timeout is transport evidence,
            ;; not an ordinary setup failure that may release the FIFO.
            (funcall (car callbacks) 'ei7-fake nil "setup timed out")
            (should (= (length requests) 1))
            (should (= transport-failures 1))
            (should (= pumps 0))
            (should-not success-called)
            (should-not failure-called))
        (emacs-jupyter-notebook-helper-backend--dispose state
                                                        "EI7 setup timeout cleanup")))))

(ert-deftest ejn-ei7-pre-admission-rejection-wins-transport-race ()
  "A pre-admission rejection cannot become outcome-unknown via a late loss."
  (with-temp-buffer
    (let* ((session (ejn-ei7-test--session (current-buffer)))
           (state (emacs-jupyter-notebook-backend-session-data session))
           (callbacks nil) (requests nil) (scheduled 0) (backend-id nil))
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1)
            emacs-jupyter-notebook--kernel-status 'busy)
      (unwind-protect
          (ejn-ei7-test-with-presentations (finished fringe text)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                       (lambda (_helper operation _params callback &rest _keys)
                         (push operation requests)
                         (push callback callbacks)
                         "ei7-race-wire"))
                      ((symbol-function 'emacs-jupyter-notebook--heartbeat-cancel)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook-backend-close-local)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                       (lambda () (cl-incf scheduled)))
                      ((symbol-function 'emacs-jupyter-notebook--log-append)
                       #'ignore)
                      ((symbol-function 'emacs-jupyter-notebook--execution-pump)
                       #'ignore))
              (setq backend-id
                    (emacs-jupyter-notebook-backend-execute
                     session "race()" '(:ledger-id 1 :entry-handle (:generation 1))
                     #'ignore
                     (lambda (_id reason)
                       (when-let ((record
                                   (emacs-jupyter-notebook--execution-record 1)))
                         (emacs-jupyter-notebook--execution-fail record reason)))))
              (emacs-jupyter-notebook--execution-put
               (ejn-ei7-test--record 1 'dispatched backend-id))
              ;; The exact admitted:false envelope queues the ordinary
              ;; consumer failure on the generic backend's zero-delay timer.
              (funcall (car callbacks) 'ei7-fake
                       (ejn-ei2-test--object
                        "ok" :false
                        "error" (ejn-ei2-test--object
                                  "code" "invalid-request"
                                  "message" "rejected before admission"
                                  "admitted" :false))
                       nil)
              ;; Race the queued ordinary failure with an uncorrelated loss.
              ;; It must not reinterpret this already-rejected execution as
              ;; an admitted remote execution.
              (emacs-jupyter-notebook-helper-backend--event
               session state
               (ejn-ei2-test--object
                "event" "transport_error"
                "data" (ejn-ei2-test--object "message" "late channel loss")))
              (should (= scheduled 1))
              (should (equal finished '(cancelled)))
              (should (equal fringe '(cancelled)))
              (should-not (cl-some (lambda (status) (eq status 'outcome-unknown))
                                   finished))
              (should-not (gethash "ei7-race-wire"
                                   (emacs-jupyter-notebook-helper-backend-state-request-map
                                    state)))
              (should (gethash "ei7-race-wire"
                               (emacs-jupyter-notebook-helper-backend-state-retired-request-ids
                                state)))
              ;; A correlated event after retirement must be inert.
              (emacs-jupyter-notebook-helper-backend--event
               session state
               (ejn-ei2-test--object
                "event" "status" "request_id" "ei7-race-wire"
                "data" (ejn-ei2-test--object "execution_state" "idle")))
              (should (equal finished '(cancelled)))
              (should-not (emacs-jupyter-notebook--execution-record 1)))
            ;; Run the ordinary rejected-request callback after the race; it
            ;; must observe the already-retired ledger and remain inert.
            (ejn-ei2-test--run-timers))
        (when (emacs-jupyter-notebook-helper-backend-state-p state)
          (emacs-jupyter-notebook-helper-backend--dispose state "EI7 race cleanup"))))))

;; EI8 status/log tests use only local pipe processes and fake backend sessions.

(defun ejn-ei8-test--fake-helper (owner state)
  "Create a local fake helper process/session for EI8 status tests."
  (let* ((stderr (generate-new-buffer " *ejn-ei8-stderr*"))
         (process (make-process :name "ejn-ei8-helper"
                                :command '("cat")
                                :buffer nil
                                :connection-type 'pipe
                                :noquery t))
         (session (emacs-jupyter-notebook-helper--make-session
                   :id (cl-incf emacs-jupyter-notebook-helper--next-id)
                   :owner-buffer owner :process process
                   :stderr-process process :stderr-buffer stderr
                   :state state :requests (make-hash-table :test #'equal)
                   :protocol-version ejn-helper-protocol-version
                   :decoder (ejn-helper-protocol-make-decoder
                             ejn-helper-protocol-max-to-emacs-frame))))
    (process-put process 'emacs-jupyter-notebook-helper-session session)
    session))

(ert-deftest ejn-ei8-status-snapshot-and-text-expose-helper-request-truth ()
  "Status contains bounded helper, active-request, queue, and retry state."
  (with-temp-buffer
    (let* ((owner (current-buffer))
           (helper (ejn-ei8-test--fake-helper owner 'ready))
           (now (float-time))
           (entry (list :profile "ei8-profile" :session-id "ei8-session"
                        :remote-host "ei8-host" :remote-pid 8080
                        :remote-connection-file "/remote/ei8.json"
                        :local-connection-file "/tmp/ei8.json"
                        :tunnel-ports '(:shell_port 1 :iopub_port 2
                                        :stdin_port 3 :hb_port 4
                                        :control_port 5)))
           (context (list :phase 'tunnel :started-at (- now 11.0)
                          :session-id "ei8-session"
                          :entry entry
                          :error (make-string 900 ?E)))
           (retry-timer (run-at-time 300 nil #'ignore))
           (record (list :id 1 :state 'dispatched
                         :started-at (- now 7.0)
                         :backend-request-id 42 :terminal nil))
           snapshot text)
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook--helper-session helper
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--async-context context
                        emacs-jupyter-notebook--kernel-status 'busy
                        emacs-jupyter-notebook--tunnel-dead nil
                        emacs-jupyter-notebook--reconnect-attempt 3
                        emacs-jupyter-notebook--reconnect-timer retry-timer
                        emacs-jupyter-notebook--reconnect-schedule-token 'ei8-token
                        emacs-jupyter-notebook--reconnect-next-at (+ now 9.0)
                        emacs-jupyter-notebook--execution-active-id 1
                        emacs-jupyter-notebook--execution-queue '(1 2 3))
            (emacs-jupyter-notebook--execution-put record)
            (setq snapshot (emacs-jupyter-notebook-status-snapshot)
                  text (emacs-jupyter-notebook--status-snapshot-text snapshot))
            (should (= (plist-get snapshot :helper-pid)
                       (process-id (emacs-jupyter-notebook-helper-session-process helper))))
            (should (eq (plist-get snapshot :helper-state) 'ready))
            (should (= (plist-get snapshot :helper-protocol)
                       ejn-helper-protocol-version))
            (should (eq (plist-get snapshot :active-execution-state) 'dispatched))
            (should (<= 6.0 (plist-get snapshot :active-execution-age) 8.5))
            ;; The active FIFO head is not counted as queued work.
            (should (= (plist-get snapshot :queue-length) 2))
            (should (eq (plist-get snapshot :kernel-status) 'busy))
            (should (eq (plist-get snapshot :transport-phase) 'tunnel))
            (should (= (plist-get snapshot :retry-count) 3))
            (should (<= 7.0 (plist-get snapshot :retry-countdown) 10.0))
            (should (stringp (plist-get snapshot :last-error)))
            (should (<= (string-bytes (plist-get snapshot :last-error)) 512))
            (dolist (label '("Helper PID:" "Helper state:" "Helper protocol:"
                             "Active execution:" "Queue length:" "Transport phase:"
                             "Retry countdown:" "Last error:"))
              (should (string-match-p (regexp-quote label) text))))
        (cancel-timer retry-timer)
        (remhash 1 emacs-jupyter-notebook--execution-ledger)
        (emacs-jupyter-notebook-helper-dispose helper "EI8 status cleanup")))))

(ert-deftest ejn-ei8-real-evaluation-record-has-visible-age ()
  "Normal evaluation reservation records a real status age."
  (with-temp-buffer
    (cl-letf (((symbol-function 'ejn-panel-ensure) (lambda (_source) 'panel))
              ((symbol-function 'ejn-panel-start-entry)
               (lambda (&rest _) '(:generation 1)))
              ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
              ((symbol-function 'ejn-panel-set-entry-status) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-fringe-set) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
      (let* ((id (emacs-jupyter-notebook--evaluate-code "print(1)" nil))
             (record (emacs-jupyter-notebook--execution-record id))
             (snapshot (progn
                         (setq emacs-jupyter-notebook--execution-active-id id)
                         (emacs-jupyter-notebook-status-snapshot))))
        (should (numberp (plist-get record :started-at)))
        (should (numberp (plist-get snapshot :active-execution-age)))
        (should (<= 0 (plist-get snapshot :active-execution-age) 1.0))))))

(ert-deftest ejn-ei8-status-error-is-redacted-and-byte-bounded ()
  "Status diagnostics redact connection secrets before byte truncation."
  (let* ((secret-values '("ei8-status-token" "ei8-status-key"
                          "ei8-status-hmac" "ei8-status-password"
                          "ei8-status-space" "ei8-status-flag"
                          "ei8-status-escaped-suffix"))
         (diagnostic
          (concat (make-string 600 ?é) "\n"
                  "token ei8-status-space with spaces\n"
                  "--token=ei8-status-flag\n"
                  "{\"token\":\"ei8-status-escaped\\\"ei8-status-escaped-suffix\"}\n"
                  "{\"token\":\"ei8-status-token\","
                  "\"key\":\"ei8-status-key\","
                  "\"hmac\":\"ei8-status-hmac\"} "
                  "ssh://user:ei8-status-password@example.test/\n"
                  (make-string 100000 ?X)))
         (bounded (emacs-jupyter-notebook--bounded-status-error diagnostic)))
    (should (<= (string-bytes bounded)
                emacs-jupyter-notebook--status-error-max-bytes))
    (dolist (secret secret-values)
      (should-not (string-match-p (regexp-quote secret) bounded)))))

(ert-deftest ejn-ei8-status-snapshot-covers-each-helper-lifecycle-state ()
  "Status reports no helper and every supervised helper lifecycle state."
  (with-temp-buffer
    (let ((source (current-buffer))
          (states '(nil starting ready failed))
          helpers)
      (unwind-protect
          (dolist (state states)
            (let ((helper (and state (ejn-ei8-test--fake-helper source state))))
              (when helper
                (push helper helpers))
              (setq-local emacs-jupyter-notebook--helper-session helper)
              (let ((snapshot (emacs-jupyter-notebook-status-snapshot)))
                (should (eq (plist-get snapshot :helper-state) state)))))
        (setq emacs-jupyter-notebook--helper-session nil)
        (dolist (helper helpers)
          (when (emacs-jupyter-notebook-helper-session-p helper)
            (emacs-jupyter-notebook-helper-dispose helper "EI8 state cleanup")))))))

(ert-deftest ejn-ei8-restart-helper-is-hidden-when-unavailable-or-recovering ()
  "Restart is never offered for absent, retired, or actively used helpers."
  (let ((base '(:durable-session t)))
    (dolist (snapshot
             (list (append base '(:helper (:backend-state none)
                                  :helper-state none))
                   (append base '(:helper (:id 8 :backend-state retired)
                                  :helper-id 8 :helper-state retired))
                   (append base '(:helper (:id 9 :state ready)
                                  :helper-id 9 :helper-state ready
                                  :async-live t))))
      (should-not
       (rassq 'emacs-jupyter-notebook--restart-helper
              (emacs-jupyter-notebook--status-suggestions-for snapshot)))))
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'ready))
           (entry '(:profile "p" :session-id "s" :remote-host "h"))
           (context (list :phase 'probe :started-at (float-time)
                          :status-token 'ei8-live-context))
           (disposals 0) (schedules 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook--helper-session helper
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                       (lambda (&rest _) (cl-incf disposals)))
                      ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                       (lambda (&rest _) (cl-incf schedules))))
              (should-error (emacs-jupyter-notebook--restart-helper)
                            :type 'user-error))
            (should (= disposals 0))
            (should (= schedules 0))
            (should (eq emacs-jupyter-notebook--helper-session helper))
            (should (eq emacs-jupyter-notebook--async-context context)))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 recovery cleanup"))))))

(ert-deftest ejn-ei8-current-status-cancel-action-cancels-one-retry-locally ()
  "The current retry button cancels exactly its retry, without remote work."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (entry '(:profile "p" :session-id "s" :remote-host "h"
                     :remote-pid 17 :remote-connection-file "/r/kernel.json"))
           (retry-token 'ei8-current-retry)
           (retry-timer (run-at-time 300 nil #'ignore))
           (status (generate-new-buffer " *ejn-ei8-current-cancel-status*"))
           (cancels 0) (remote-calls 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--reconnect-timer retry-timer
                        emacs-jupyter-notebook--reconnect-schedule-token retry-token
                        emacs-jupyter-notebook--reconnect-next-at (+ (float-time) 30)
                        emacs-jupyter-notebook--tunnel-dead t)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Cancel scheduled reconnect" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'call-interactively)
                           (lambda (command) (funcall command)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-auto-reconnect)
                           (lambda (&rest _)
                             (cl-incf cancels)
                             (when (timerp emacs-jupyter-notebook--reconnect-timer)
                               (cancel-timer emacs-jupyter-notebook--reconnect-timer))
                             (setq emacs-jupyter-notebook--reconnect-timer nil
                                   emacs-jupyter-notebook--reconnect-schedule-token nil)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-async-operation)
                           (lambda (&rest _) (ert-fail "retry action touched async operation")))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-management-operation)
                           (lambda (&rest _) (ert-fail "retry action touched management")))
                          ((symbol-function 'emacs-jupyter-notebook-ssh-start-management-operation)
                           (lambda (&rest _) (cl-incf remote-calls))))
                  (button-activate button))))
            (should (= cancels 1))
            (should (= remote-calls 0))
            (should-not emacs-jupyter-notebook--reconnect-timer)
            (should-not emacs-jupyter-notebook--reconnect-schedule-token))
        (when (timerp retry-timer) (cancel-timer retry-timer))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-current-status-restart-helper-is-local-and-schedules-once ()
  "Restart helper is local-only and admits one immediate reconnect retry."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'failed))
           (entry '(:profile "p" :session-id "s" :remote-host "h"
                     :remote-pid 17 :remote-connection-file "/r/kernel.json"))
           (status (generate-new-buffer " *ejn-ei8-current-restart-status*"))
           (reconnects 0) (disposals 0) (remote-calls 0)
           (registry-calls 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--helper-session helper
                        emacs-jupyter-notebook--tunnel-dead t)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Restart helper" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'call-interactively)
                           (lambda (command) (funcall command)))
                          ((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                           (lambda (&optional immediate)
                             ;; Explicit helper restart enters reconnect
                             ;; immediately, independent of auto-reconnect.
                             (should immediate)
                             (should emacs-jupyter-notebook--tunnel-dead)
                             (cl-incf reconnects)))
                          ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                           (lambda (&rest _) (cl-incf disposals)))
                          ((symbol-function 'emacs-jupyter-notebook-backend-control)
                           (lambda (&rest _) (cl-incf remote-calls)))
                          ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                           (lambda (&rest _) (cl-incf remote-calls)))
                          ((symbol-function 'emacs-jupyter-notebook-registry-create-async)
                           (lambda (&rest _) (cl-incf registry-calls)))
                          ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                           (lambda (&rest _) (cl-incf registry-calls)))
                          ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
                           (lambda (&rest _) (cl-incf registry-calls))))
                  (button-activate button))))
            (should (= reconnects 1))
            (should (= disposals 1))
            (should (= remote-calls 0))
            (should (= registry-calls 0)))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 restart cleanup"))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-stale-management-status-action-cannot-touch-replacement ()
  "A management cancel button captures the old management token exactly."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (entry '(:profile "p" :session-id "s" :remote-host "h"))
           (old (list :label "old management" :token 'old-management
                      :started-at (- (float-time) 2)))
           (new (list :label "new management" :token 'new-management
                      :started-at (float-time)))
           (status (generate-new-buffer " *ejn-ei8-stale-management-status*")))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--management-operation old)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Cancel the management operation" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (with-current-buffer source
                  (setq emacs-jupyter-notebook--management-operation new))
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'call-interactively)
                           (lambda (command) (funcall command)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-management-operation)
                           (lambda (&rest _) (ert-fail "stale button cancelled management replacement")))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-async-operation)
                           (lambda (&rest _) (ert-fail "management action touched async operation")))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-auto-reconnect)
                           (lambda (&rest _) (ert-fail "management action touched retry"))))
                  (button-activate button))))
            (should (eq (plist-get emacs-jupyter-notebook--management-operation :token)
                        'new-management)))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-current-active-execution-action-is-narrow ()
  "The advertised execution cancel affects only the captured active record."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (record (list :id 91 :state 'dispatched :started-at (float-time)
                         :status-token 'ei8-active-token))
           (status (generate-new-buffer " *ejn-ei8-current-execution-status*"))
           (cancels 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--execution-active-id 91
                        emacs-jupyter-notebook--execution-queue '(91))
            (emacs-jupyter-notebook--execution-put record)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Cancel active execution" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-evaluation)
                           (lambda () (cl-incf cancels)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-auto-reconnect)
                           (lambda (&rest _) (ert-fail "execution action touched retry")))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-management-operation)
                           (lambda (&rest _)
                             (ert-fail "execution action touched management"))))
                  (button-activate button))))
            (should (= cancels 1)))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-helper-backend-snapshot-is-bounded-across-lifecycle ()
  "Helper backend snapshots expose state, never payloads or artifacts."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'ready))
           (session (emacs-jupyter-notebook-backend-session-create nil source))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper helper
                   :request-map (make-hash-table :test #'equal)
                   :artifact-dir "/tmp/secret-artifact"
                   :retired-request-ids (make-hash-table :test #'equal)))
           snapshot)
      (unwind-protect
          (progn
            (setf (emacs-jupyter-notebook-backend-session-data session) state)
            (emacs-jupyter-notebook-backend-session-mark-attached session)
            (emacs-jupyter-notebook-backend-session-mark-installed session)
            (setq snapshot (emacs-jupyter-notebook-helper-backend-snapshot session))
            (should (eq (plist-get snapshot :backend-state) 'active))
            (dolist (forbidden '(:stderr :argv :artifact-dir :request-map
                                 :connection-file :payload :requests
                                 :client-object :context-object
                                 :active-execution-record :helper-session-object))
              (should-not (plist-member snapshot forbidden)))
            (setf (emacs-jupyter-notebook-helper-backend-state-retired state) t)
            (should (eq (plist-get (emacs-jupyter-notebook-helper-backend-snapshot session)
                                   :backend-state)
                        'retired))
            (setf (emacs-jupyter-notebook-helper-backend-state-retired state) nil)
            (setf (emacs-jupyter-notebook-backend-session-closed session) t)
            (should (eq (plist-get (emacs-jupyter-notebook-helper-backend-snapshot session)
                                   :backend-state)
                        'closed))
            (let ((empty (emacs-jupyter-notebook-backend-session-create nil source)))
              (should (eq (plist-get
                           (emacs-jupyter-notebook-helper-backend-snapshot empty)
                           :backend-state)
                          'none))))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 snapshot cleanup"))
        (when (emacs-jupyter-notebook-helper-backend-state-p state)
          (emacs-jupyter-notebook-helper-backend--dispose state "EI8 snapshot cleanup"))))))

(ert-deftest ejn-ei8-stale-status-cancel-button-cannot-touch-replacement ()
  "A status cancel action captures async/token identity, not current globals."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (entry '(:profile "p" :session-id "s" :remote-host "h"
                     :remote-pid 17 :remote-connection-file "/r/kernel.json"))
           (old-context (list :phase 'probe :started-at (- (float-time) 4)
                              :entry entry :session-id "s"
                              :status-token 'ei8-old-context
                              :reconnect-owner 'automatic))
           (new-context (list :phase 'retrieve :started-at (float-time)
                              :entry entry :session-id "s"
                              :status-token 'ei8-new-context
                              :reconnect-owner 'automatic))
           (old-client (ejn-ei7-test--session source))
           (new-client (ejn-ei7-test--session source))
           (status (generate-new-buffer " *ejn-ei8-stale-cancel-status*"))
           (old-token 'old-retry-token) (new-token 'new-retry-token)
           (new-timer (run-at-time 300 nil #'ignore)))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--tunnel-dead t
                        emacs-jupyter-notebook--client old-client
                        emacs-jupyter-notebook--async-context old-context
                        emacs-jupyter-notebook--reconnect-schedule-token old-token
                        emacs-jupyter-notebook--reconnect-timer nil)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Cancel reconnect" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                ;; Replace every identity-bearing local slot before the old
                ;; button is activated.
                (with-current-buffer source
                  (setq emacs-jupyter-notebook--async-context new-context
                        emacs-jupyter-notebook--client new-client
                        emacs-jupyter-notebook--reconnect-schedule-token new-token
                        emacs-jupyter-notebook--reconnect-timer new-timer))
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'call-interactively)
                           (lambda (command) (funcall command)))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-async-operation)
                           (lambda (&rest _) (ert-fail "stale button cancelled replacement")))
                          ((symbol-function 'emacs-jupyter-notebook--cancel-auto-reconnect)
                           (lambda (&rest _) (ert-fail "stale button cancelled retry"))))
                  (button-activate button))))
            (should (eq emacs-jupyter-notebook--async-context new-context))
            (should (eq emacs-jupyter-notebook--client new-client))
            (should (eq emacs-jupyter-notebook--reconnect-schedule-token new-token))
            (should (eq emacs-jupyter-notebook--reconnect-timer new-timer)))
        (when (timerp new-timer) (cancel-timer new-timer))
        (dolist (client (list old-client new-client))
          (when (emacs-jupyter-notebook-backend-session-p client)
            (when-let ((client-state
                        (emacs-jupyter-notebook-backend-session-data client)))
              (emacs-jupyter-notebook-helper-backend--dispose
               client-state "EI8 stale client cleanup"))))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-stale-restart-helper-action-cannot-touch-replacement ()
  "A stale restart-helper action cannot dispose or replace a new helper."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (old-helper (ejn-ei8-test--fake-helper source 'failed))
           (new-helper (ejn-ei8-test--fake-helper source 'ready))
           (entry '(:profile "p" :session-id "s" :remote-host "h"
                     :remote-pid 17 :remote-connection-file "/r/kernel.json"))
           (status (generate-new-buffer " *ejn-ei8-stale-restart-status*"))
           (disposals 0) (starts 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--session-entry entry
                        emacs-jupyter-notebook--helper-session old-helper)
            (emacs-jupyter-notebook--status-render status source)
            (with-current-buffer status
              (goto-char (point-min))
              (should (search-forward "Restart helper" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (with-current-buffer source
                  (setq emacs-jupyter-notebook--helper-session new-helper))
                (cl-letf (((symbol-function 'pop-to-buffer)
                           (lambda (buffer) (set-buffer buffer)))
                          ((symbol-function 'call-interactively)
                           (lambda (command) (funcall command)))
                          ((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                           (lambda (&rest _) (cl-incf disposals)))
                          ((symbol-function 'emacs-jupyter-notebook-helper-start)
                           (lambda (&rest _) (cl-incf starts)))
                          ((symbol-function 'emacs-jupyter-notebook--restart-helper)
                           (lambda () (ert-fail "stale button invoked replacement"))))
                  (button-activate button))))
            (should (= disposals 0))
            (should (= starts 0))
            (should (eq emacs-jupyter-notebook--helper-session new-helper)))
        (when (emacs-jupyter-notebook-helper-session-p old-helper)
          (emacs-jupyter-notebook-helper-dispose old-helper "EI8 stale cleanup"))
        (when (emacs-jupyter-notebook-helper-session-p new-helper)
          (emacs-jupyter-notebook-helper-dispose new-helper "EI8 stale cleanup"))
        (when (buffer-live-p status) (kill-buffer status))))))

(ert-deftest ejn-ei8-stderr-is-deferred-bounded-redacted-and-disposed ()
  "Hostile stderr is deferred, bounded, secret-free, and timer-cleaned."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'ready))
           (late-helper (ejn-ei8-test--fake-helper source 'ready))
           (stderr (emacs-jupyter-notebook-helper-session-stderr-buffer helper))
           (pipe (emacs-jupyter-notebook-helper-session-stderr-process helper))
           (late-pipe (emacs-jupyter-notebook-helper-session-stderr-process late-helper))
           (base64 (concat (make-string 440 ?A) "-_" (make-string 440 ?B)))
           (canaries (list "hunter2"
                           "ei8-secret-token"
                           "ei8-secret-key"
                           "ei8-secret-bearer"
                           "ei8-json-token"
                           "ei8-json-key"
                           "ei8-json-hmac"
                           "ei8-url-password"
                           "ei8-space-secret"
                           "ei8-flag-secret"
                           "ei8-escaped-suffix"
                           base64))
           (chunks (list "safe helper diagnostic\n" "pass" "word=hunter2 token=ei8-"
                         "secret-token private-key=ei8-"
                         "secret-key Authorization: Bearer ei8-"
                         "secret-bearer " (substring base64 0 450)
                         (substring base64 450)
                         " {\"tok" "en\":\"ei8-json-token\",\"key\":\"ei8-json-key\","
                         "\"hmac\":\"ei8-json-hmac\"} https://ei8-user:ei8-"
                         "url-password@example.test/path\n"
                         "token ei8-space-secret with spaces\n"
                         "--token=ei8-flag-secret\n"
                         "{\"token\":\"prefix\\\"ei8-escaped-suffix\"}\n"))
           (log-text nil) (messages nil)
           drain-timer oversize-timer late-timer)
      (unwind-protect
          (progn
            ;; Ownership is required: an orphaned session's stale pipe must
            ;; be ignored rather than becoming a hidden log sink.
            (setq-local emacs-jupyter-notebook--helper-session helper)
            (let ((emacs-jupyter-notebook-helper-stderr-log-function
                   (lambda (_session text) (push text log-text))))
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args) messages))))
                (dolist (chunk chunks)
                  (emacs-jupyter-notebook-helper--stderr-filter pipe chunk))
                ;; Process-filter work must not synchronously surface diagnostics.
                (should-not log-text)
                (should-not messages)
                (setq drain-timer
                      (emacs-jupyter-notebook-helper-session-stderr-drain-timer helper))
                (should (timerp drain-timer))
                (ejn-ei2-test--run-timers))
              (should (<= (buffer-size stderr)
                          (emacs-jupyter-notebook-helper--stderr-limit)))
              (should (cl-some (lambda (line)
                                 (string-match-p "safe helper diagnostic" line))
                               log-text))
              (let ((all (concat (with-current-buffer stderr (buffer-string))
                                 (mapconcat #'identity log-text "\n")
                                 (emacs-jupyter-notebook--status-snapshot-text
                                  (emacs-jupyter-notebook-status-snapshot)))))
                (dolist (canary canaries)
                  (should-not (string-match-p (regexp-quote canary) all))))
              ;; The retention ceiling is a byte ceiling even for multibyte
              ;; diagnostics, not merely a character-count approximation.
              (emacs-jupyter-notebook-helper--stderr-filter
               pipe (concat (make-string 40000 ?é) "\n"))
              (ejn-ei2-test--run-timers)
              (should (<= (with-current-buffer stderr
                            (string-bytes (buffer-string)))
                          (emacs-jupyter-notebook-helper--stderr-limit)))
              ;; An unterminated hostile line must be dropped in full, rather
              ;; than retaining a potentially meaningful suffix.
              (emacs-jupyter-notebook-helper--stderr-filter
               pipe (make-string
                     (1+ emacs-jupyter-notebook-helper--stderr-pending-max-bytes)
                     ?Z))
              (setq oversize-timer
                    (emacs-jupyter-notebook-helper-session-stderr-drain-timer helper))
              (should (timerp oversize-timer))
              (ejn-ei2-test--run-timers)
              (should (string-match-p
                       "line exceeded retention limit; dropped"
                       (mapconcat #'identity log-text "\n")))
              (should-not (emacs-jupyter-notebook-helper-session-stderr-pending helper))
              ;; A queued drain that loses ownership before its zero-delay turn
              ;; must become inert and must not surface a late diagnostic.
              (setq-local emacs-jupyter-notebook--helper-session late-helper)
              (emacs-jupyter-notebook-helper--stderr-filter late-pipe "late diagnostic\n")
              (setq late-timer
                    (emacs-jupyter-notebook-helper-session-stderr-drain-timer late-helper))
              (should (timerp late-timer))
              (setq-local emacs-jupyter-notebook--helper-session helper)
              (let ((before (length log-text)))
                (ejn-ei2-test--run-timers)
                (should (= before (length log-text)))
                (emacs-jupyter-notebook-helper-dispose late-helper "EI8 stderr cleanup")
                (should (= before (length log-text))))
              (should-not (memq drain-timer timer-list))
              (should-not (memq oversize-timer timer-list))
              (should-not (memq late-timer timer-list))
              (should-not (emacs-jupyter-notebook-helper-session-raw-chunks late-helper))
              (should (= (emacs-jupyter-notebook-helper-session-raw-bytes late-helper) 0))
              (emacs-jupyter-notebook-helper-dispose helper "EI8 stderr cleanup")))
        (when (timerp drain-timer) (cancel-timer drain-timer))
        (when (timerp oversize-timer) (cancel-timer oversize-timer))
        (when (timerp late-timer) (cancel-timer late-timer))
        (when (emacs-jupyter-notebook-helper-session-p late-helper)
          (emacs-jupyter-notebook-helper-dispose late-helper "EI8 final cleanup"))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 final cleanup"))))))

(ert-deftest ejn-ei8-stderr-filter-only-bounds-and-defers-sanitization ()
  "A huge stderr process callback only bounds bytes and arms the drain."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'ready))
           (pipe (emacs-jupyter-notebook-helper-session-stderr-process helper))
           (redactions 0) (decodes 0) (logs 0))
      (unwind-protect
          (progn
            (setq-local emacs-jupyter-notebook--helper-session helper)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper--redact-stderr)
                       (lambda (&rest _)
                         (cl-incf redactions)
                         "would be sanitized later"))
                      ((symbol-function 'emacs-jupyter-notebook-helper--stderr-text)
                       (lambda (&rest _)
                         (cl-incf decodes)
                         "would be decoded later"))
                      ((symbol-function 'emacs-jupyter-notebook-helper--stderr-log)
                       (lambda (&rest _) (cl-incf logs))))
              (emacs-jupyter-notebook-helper--stderr-filter
               pipe (make-string (* 4 emacs-jupyter-notebook-helper--stderr-pending-max-bytes)
                                 ?X))
              (should (= redactions 0))
              (should (= decodes 0))
              (should (= logs 0))
              (should (<= (emacs-jupyter-notebook-helper-session-stderr-pending-bytes helper)
                          emacs-jupyter-notebook-helper--stderr-pending-max-bytes))
              (should (timerp
                       (emacs-jupyter-notebook-helper-session-stderr-drain-timer helper))))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 filter-only cleanup")))))))

(ert-deftest ejn-ei8-stderr-reaches-real-ejn-log-only-after-deferred-drain ()
  "The production stderr callback writes a redacted, owner-gated EJN log line."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (helper (ejn-ei8-test--fake-helper source 'ready))
           (pipe (emacs-jupyter-notebook-helper-session-stderr-process helper))
           (log-buffer-name emacs-jupyter-notebook--log-buffer-name))
      (unwind-protect
          (progn
            (when-let ((old (get-buffer log-buffer-name))) (kill-buffer old))
            (setq-local emacs-jupyter-notebook--helper-session helper)
            (emacs-jupyter-notebook-helper--stderr-filter
             pipe "safe real logger token=ei8-real-log-secret\n")
            (should-not (get-buffer log-buffer-name))
            (ejn-ei2-test--run-timers)
            (should (buffer-live-p (get-buffer log-buffer-name)))
            (let ((logged (with-current-buffer log-buffer-name (buffer-string))))
              (should (string-match-p "safe real logger" logged))
              (should-not (string-match-p "ei8-real-log-secret" logged))))
        (when (emacs-jupyter-notebook-helper-session-p helper)
          (emacs-jupyter-notebook-helper-dispose helper "EI8 real log cleanup"))
        (when-let ((log (get-buffer log-buffer-name))) (kill-buffer log))))))

;;; EI10 — static no-hang architecture assertions

(defun ejn-ei10--production-files ()
  "Return production Elisp files in the package root."
  (let ((root (file-name-directory
               (directory-file-name ejn-ei2-test--directory))))
    (directory-files root t "\\`emacs-jupyter-notebook.*\\.el\\'")))

(defun ejn-ei10--jupyter-require-p (forms)
  "Return non-nil when FORMS requires an Emacs Jupyter feature."
  (cl-some
   (lambda (form)
     (when (and (consp form) (eq (car form) 'require))
       (let ((feature (cadr form)))
         (when (and (consp feature) (eq (car feature) 'quote))
           (setq feature (cadr feature)))
         (and (symbolp feature)
              (or (eq feature 'jupyter)
                  (string-prefix-p "jupyter-" (symbol-name feature)))))))
   forms))

(defun ejn-ei10--legacy-backend-selector-p (forms)
  "Return non-nil when FORMS contains the removed backend selector.
Module `require' and `provide' forms may mention the backend feature name;
those are not selector references."
  (let ((pending (list forms)) found)
    (while (and pending (not found))
      (let ((item (pop pending)))
        (cond
         ((symbolp item)
          (setq found (memq item '(emacs-jupyter-notebook-backend legacy))))
         ((consp item)
          (unless (memq (car item) '(require provide))
            (push (car item) pending)
            (push (cdr item) pending))))))
    found))

(defun ejn-ei10--package-header-requires-jupyter-p (source)
  "Return non-nil when SOURCE's package header requires Emacs Jupyter."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    (re-search-forward
     "^;;[[:space:]]*Package-Requires:.*\\_<jupyter\\(?:-[[:alnum:]_-]+\\)?\\_>"
     nil t)))

(defun ejn-ei10--read-forms (source)
  "Read top-level forms from SOURCE with the Emacs Lisp reader.
Comments are discarded by the reader and strings remain non-symbol atoms, so
static scans cannot mistake prose for executable code.  Malformed or
truncated source is an error rather than silently becoming a partial scan."
  (with-temp-buffer
    (insert source)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (let (forms)
      (while (< (point) (point-max))
        (let ((start (point)))
          (condition-case err
              (push (read (current-buffer)) forms)
            (end-of-file
             ;; A reader EOF is valid only when the remaining input consists
             ;; of whitespace/comments.  Unmatched delimiters must fail the
             ;; assertion instead of being silently truncated.
             (goto-char start)
             (forward-comment (buffer-size))
             (skip-chars-forward " \t\r\n")
             (if (= (point) (point-max))
                 (goto-char (point-max))
               (signal (car err) (cdr err)))))))
      (nreverse forms))))

(defun ejn-ei10--tree-contains-symbol-p (tree symbols)
  "Return non-nil when TREE contains one symbol in SYMBOLS."
  (let ((pending (list tree)) found)
    (while (and pending (not found))
      (let ((item (pop pending)))
        (cond
         ((symbolp item) (setq found (memq item symbols)))
         ((consp item)
          (unless (eq (car item) 'quote)
            (push (car item) pending)
            (push (cdr item) pending))))))
    found))

(defun ejn-ei10--direct-jupyter-call-p (forms)
  "Return non-nil when FORMS contains a direct or indirect `jupyter-*' call.
In addition to `(jupyter-foo ...)', recognize function designators passed to
`funcall' and `apply'."
  (let ((pending (list forms)) found)
    (while (and pending (not found))
      (let ((form (pop pending)))
        (when (consp form)
          (when (and (symbolp (car form))
                     (string-prefix-p "jupyter-" (symbol-name (car form))))
            (setq found t))
          (when (and (memq (car form) '(funcall apply))
                     (consp (cadr form))
                     (memq (caadr form) '(function quote))
                     (symbolp (cadadr form))
                     (string-prefix-p "jupyter-"
                                      (symbol-name (cadadr form))))
            (setq found t))
          (unless (eq (car form) 'quote)
            (push (car form) pending)
            (push (cdr form) pending)))))
    found))

(defun ejn-ei10--synchronous-process-form-p (forms)
  "Return non-nil when FORMS contains a blocking process/I/O primitive."
  (ejn-ei10--tree-contains-symbol-p
   forms '(sleep-for sit-for accept-process-output process-file call-process
           call-process-region shell-command shell-command-on-region)))

(defun ejn-ei10--defconst-values (forms)
  "Return an alist of numeric `defconst' values found in FORMS."
  (let (values)
    (dolist (form forms)
      (when (and (consp form) (eq (car form) 'defconst)
                 (symbolp (nth 1 form)))
        (push (cons (nth 1 form) (nth 2 form)) values)))
    values))

(defun ejn-ei10--positive-defconsts-p (forms names)
  "Return non-nil when every NAME has a positive numeric `defconst'."
  (let ((values (ejn-ei10--defconst-values forms)))
    (cl-every (lambda (name)
                (let ((value (cdr (assq name values))))
                  (and (numberp value) (> value 0))))
              names)))

(defun ejn-ei10--helper-wait-loop-p (forms)
  "Return non-nil when a helper loop waits for process I/O or liveness."
  (let ((pending (list forms)) found)
    (while (and pending (not found))
      (let ((form (pop pending)))
        (when (consp form)
          (when (and (eq (car form) 'while)
                     (ejn-ei10--tree-contains-symbol-p
                      (cdr form) '(accept-process-output sleep-for sit-for
                                      process-live-p process-status)))
            (setq found t))
          (unless (eq (car form) 'quote)
            (push (car form) pending)
            (push (cdr form) pending)))))
    found))

(ert-deftest ejn-ei10-production-has-no-direct-jupyter-calls ()
  "Production Elisp contains no direct `jupyter-*' calls."
  (let (offenders)
    (dolist (file (ejn-ei10--production-files))
      (let* ((raw (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
             (forms (ejn-ei10--read-forms raw)))
        (when (ejn-ei10--direct-jupyter-call-p forms)
          (push (file-name-nondirectory file) offenders))))
    (should-not offenders)))

(ert-deftest ejn-ei10-production-has-no-legacy-jupyter-transport ()
  "Production source and headers contain no removed Jupyter transport."
  (let (legacy-references feature-requires selector-references)
    (dolist (file (ejn-ei10--production-files))
      (let* ((raw (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
             (forms (ejn-ei10--read-forms raw))
             (name (file-name-nondirectory file)))
        (when (or (string-match-p "emacs-jupyter-notebook-jupyter" raw)
                  (ejn-ei10--package-header-requires-jupyter-p raw))
          (push name legacy-references))
        (when (ejn-ei10--jupyter-require-p forms)
          (push name feature-requires))
        (when (ejn-ei10--legacy-backend-selector-p forms)
          (push name selector-references))))
    (should-not legacy-references)
    (should-not feature-requires)
    (should-not selector-references)))

(ert-deftest ejn-ei10-jupyter-require-scanner-detects-code-but-ignores-prose ()
  "The feature gate catches a require form without prose false positives."
  (should-not
   (ejn-ei10--jupyter-require-p
    (ejn-ei10--read-forms
     "(defun prose () \"(require 'jupyter)\" nil)\n; (require 'jupyter)\n")))
  (should
   (ejn-ei10--jupyter-require-p
    (ejn-ei10--read-forms "(require 'jupyter-client)\n"))))

(ert-deftest ejn-ei10-legacy-selector-scanner-detects-code-but-ignores-prose ()
  "The legacy selector gate catches code without prose false positives."
  (should-not
   (ejn-ei10--legacy-backend-selector-p
    (ejn-ei10--read-forms
     "(defun prose () \"legacy emacs-jupyter-notebook-backend\" nil)\n")))
  (should
   (ejn-ei10--legacy-backend-selector-p
    (ejn-ei10--read-forms
     "(setq emacs-jupyter-notebook-backend 'legacy)\n"))))

(ert-deftest ejn-ei10-jupyter-scanner-detects-code-but-ignores-prose ()
  "The direct-call scanner catches a mutation without prose false positives."
  (let* ((prose (ejn-ei10--read-forms
                 "(defun prose () \"jupyter-eval\" nil)\n; (jupyter-eval x)\n"))
         (mutation (ejn-ei10--read-forms
                    "(defun prose () \"jupyter-eval\" nil)\n; (jupyter-eval x)\n(jupyter-eval x)\n"))
         (indirect (ejn-ei10--read-forms
                    "(funcall #'jupyter-eval x)\n(apply (function jupyter-inspect) args)\n")))
    (should-not (ejn-ei10--direct-jupyter-call-p prose))
    (should (ejn-ei10--direct-jupyter-call-p mutation))
    (should (ejn-ei10--direct-jupyter-call-p indirect))))

(ert-deftest ejn-ei10-reader-rejects-truncated-source ()
  "Static checks must fail closed when source cannot be completely read."
  (should-error (ejn-ei10--read-forms "(defun incomplete ()")))
  (should-not (ejn-ei10--read-forms "; comment-only tail\n  \n"))

(ert-deftest ejn-ei10-production-has-no-sleep-or-synchronous-processes ()
  "Interactive production Elisp has no blocking sleep or process primitive."
  (let (offenders)
    (dolist (file (ejn-ei10--production-files))
      (let* ((raw (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
             (forms (ejn-ei10--read-forms raw)))
        (when (ejn-ei10--synchronous-process-form-p forms)
          (push (file-name-nondirectory file) offenders))))
    (should-not offenders)))

(ert-deftest ejn-ei10-process-scanner-detects-blocking-mutation ()
  "The no-blocking scanner catches sleep and synchronous remote process forms."
  (let* ((prose (ejn-ei10--read-forms
                 "(defun prose () \"sleep-for call-process ssh\" nil)\n; (sleep-for 1)\n"))
         (mutation (ejn-ei10--read-forms
                    "(defun prose () \"sleep-for call-process ssh\" nil)\n; (sleep-for 1)\n(sleep-for 1)\n(call-process \"ssh\")\n")))
    (should-not (ejn-ei10--synchronous-process-form-p prose))
    (should (ejn-ei10--synchronous-process-form-p mutation))))

(ert-deftest ejn-ei10-frame-and-queue-constants-are-positive ()
  "All Elisp frame and queue ceilings are present and finite."
  (let* ((files (list (expand-file-name "emacs-jupyter-notebook-helper.el"
                                       (file-name-directory
                                        (directory-file-name ejn-ei2-test--directory)))
                      (expand-file-name "emacs-jupyter-notebook-helper-protocol.el"
                                       (file-name-directory
                                        (directory-file-name ejn-ei2-test--directory)))))
         (forms (cl-mapcan
                 (lambda (file)
                   (ejn-ei10--read-forms
                    (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
                 files))
         (names '(ejn-helper-protocol-max-to-emacs-frame
                  ejn-helper-protocol-max-to-helper-frame
                  ejn-helper-protocol-max-raw-accumulator
                  ejn-helper-protocol-max-code-bytes
                  emacs-jupyter-notebook-helper--initial-event-credit
                  emacs-jupyter-notebook-helper--max-event-queue
                  emacs-jupyter-notebook-helper--max-priority-queue
                  emacs-jupyter-notebook-helper--max-response-frame
                  emacs-jupyter-notebook-helper--filter-max-frames
                  emacs-jupyter-notebook-helper--filter-max-payload-bytes
                  emacs-jupyter-notebook-helper--max-late-responses)))
    (should (ejn-ei10--positive-defconsts-p forms names))))

(ert-deftest ejn-ei10-constant-scanner-rejects-nil-mutation ()
  "The bounded-constant check rejects nil and ignores prose mutations."
  (let ((names '(ejn-test-frame ejn-test-queue)))
    (should
     (ejn-ei10--positive-defconsts-p
      (ejn-ei10--read-forms
       "(defconst ejn-test-frame 16)\n(defconst ejn-test-queue 32)\n")
      names))
    (should-not
     (ejn-ei10--positive-defconsts-p
      (ejn-ei10--read-forms
       "(defun prose () \"(defconst ejn-test-frame nil)\" nil)\n; (defconst ejn-test-queue nil)\n(defconst ejn-test-frame nil)\n(defconst ejn-test-queue 32)\n")
      names))))

(ert-deftest ejn-ei10-helper-has-no-process-wait-loop ()
  "Helper I/O is callback/timer driven rather than a blocking wait loop."
  (let ((root (file-name-directory
               (directory-file-name ejn-ei2-test--directory))))
    (dolist (name '("emacs-jupyter-notebook-helper.el"
                    "emacs-jupyter-notebook-helper-backend.el"))
      (let ((forms (ejn-ei10--read-forms
                    (with-temp-buffer
                      (insert-file-contents (expand-file-name name root))
                      (buffer-string)))))
        (should-not (ejn-ei10--helper-wait-loop-p forms))))))

(ert-deftest ejn-ei10-wait-loop-scanner-detects-mutation ()
  "The wait-loop scanner catches process waits while ignoring prose."
  (let* ((prose (ejn-ei10--read-forms
                 "(defun prose () \"(while pending (accept-process-output nil 1))\" nil)\n; (while pending (sleep-for 1))\n"))
         (mutation (ejn-ei10--read-forms
                    "(defun prose () \"(while pending (accept-process-output nil 1))\" nil)\n; (while pending (sleep-for 1))\n(while pending (accept-process-output nil 1))\n")))
    (should-not (ejn-ei10--helper-wait-loop-p prose))
    (should (ejn-ei10--helper-wait-loop-p mutation))
    (should (ejn-ei10--helper-wait-loop-p
             (ejn-ei10--read-forms
              "(defun poll () (while (process-live-p process) (process-status process)))\n")))))

(provide 'emacs-jupyter-notebook-helper-backend-tests)

;;; emacs-jupyter-notebook-helper-backend-tests.el ends here
