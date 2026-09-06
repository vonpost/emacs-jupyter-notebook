;;; emacs-jupyter-notebook-inspect-tests.el --- Inspector lifetime guards -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook-inspect)

(defun ejn-inspect-test--lease (id counts)
  "Return metadata with a deliberately non-idempotent release for ID."
  (list :workspace "test/workspace" :generation 1 :execution "test/exec"
        :kind 'array-group :root "/tmp/ejn-test-root"
        :file "/tmp/ejn-test-root/ejn-artifact-0123456789abcdef0123456789abcdef"
        :root-identity '(1 . 2) :identity '(3 . 2)
        :size 20 :sha256 (make-string 64 ?a)
        :source-buffer (current-buffer)
        :release (lambda () (puthash id (1+ (gethash id counts 0)) counts))))

(defmacro ejn-inspect-test--with-state (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((counts (make-hash-table :test #'equal))
          (state (ejn-inspection-create
                  :decoder (ejn-helper-protocol-make-decoder 65536 65540)
                  :raw-bytes 0 :counter 0 :owner (current-buffer)))
          (emacs-jupyter-notebook-inspect--state state)
          (emacs-jupyter-notebook-inspect--watches nil))
     (unwind-protect (progn ,@body)
       (when emacs-jupyter-notebook-inspect--state
         (ignore-errors (emacs-jupyter-notebook-inspect--stop emacs-jupyter-notebook-inspect--state)))
       (ignore-errors (emacs-jupyter-notebook-inspect--stop state)))))

(defun ejn-inspect-test--feed (state object)
  "Dispatch OBJECT through the real framed response drain."
  (setf (ejn-inspection-raw state)
        (list (ejn-helper-protocol-encode object 65536)))
  (emacs-jupyter-notebook-inspect--drain state))

(ert-deftest ejn-inspect-cold-start-announces-build-to-message-and-log ()
  (ejn-inspect-test--with-state
    (let (messages logs)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--command) (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook-runtime-ensure)
                 (lambda (&rest _) 'test-build-token))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)))
                ((symbol-function 'emacs-jupyter-notebook--log-append)
                 (lambda (phase format-string &rest args)
                   (push (cons phase (apply #'format format-string args)) logs))))
        (emacs-jupyter-notebook-inspect-publication (ejn-inspect-test--lease "cold" counts))
        (should (cl-some (lambda (line) (string-match-p "Building.*viewer" line)) messages))
        (should (cl-some (lambda (line) (and (eq (car line) 'viewer)
                                            (string-match-p "Building.*viewer" (cdr line)))) logs))))))

(ert-deftest ejn-inspect-orphaned-waiter-recovers-without-dropping-new-lease ()
  (ejn-inspect-test--with-state
    (let ((emacs-jupyter-notebook-runtime--viewer-build nil)
          (starts 0))
      (setf (ejn-inspection-waiter state) 'orphaned-token
            (ejn-inspection-pending state) (list :lease (ejn-inspect-test--lease "old" counts)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--command) (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook-runtime-ensure)
                 (lambda (&rest _) (cl-incf starts) 'new-token)))
        (emacs-jupyter-notebook-inspect-publication (ejn-inspect-test--lease "new" counts))
        (should (= starts 1))
        (should (= (gethash "old" counts 0) 1))
        (should (= (gethash "new" counts 0) 0))
        (should-not (eq state emacs-jupyter-notebook-inspect--state))
        (emacs-jupyter-notebook-inspect--stop emacs-jupyter-notebook-inspect--state)
        (should (= (gethash "new" counts 0) 1))))))

(ert-deftest ejn-inspect-feedback-is-bounded-redacted-and-status-needs-no-kernel ()
  (ejn-inspect-test--with-state
    (let (messages logs)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)))
                ((symbol-function 'emacs-jupyter-notebook--log-append)
                 (lambda (_phase format-string &rest args)
                   (push (apply #'format format-string args) logs)))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (&rest _) (ert-fail "Status must not contact a kernel"))))
        (setf (ejn-inspection-phase state) 'building)
        (emacs-jupyter-notebook-inspect--report
         state "Nix — token=synthetic-secret\n%s" (make-string 2000 ?界))
        (should (<= (string-bytes emacs-jupyter-notebook-inspect--last-message) 512))
        (should-not (string-match-p "synthetic-secret" (car logs)))
        (should-not (string-match-p "[[:cntrl:]]" (car logs)))
        (emacs-jupyter-notebook-inspector-status)
        (should (string-match-p "\\[building\\]" (car messages)))))))

(ert-deftest ejn-inspect-live-build-token-checks-slot-and-owner ()
  (let* ((owner (generate-new-buffer " *ejn-inspect-waiter-owner*"))
         (token (make-symbol "viewer-token"))
         (waiter (emacs-jupyter-notebook-runtime--make-waiter :token token :buffer owner))
         (build (emacs-jupyter-notebook-runtime--make-build :waiters (list waiter)))
         (emacs-jupyter-notebook-runtime--viewer-build build)
         (emacs-jupyter-notebook-runtime--build nil))
    (unwind-protect
        (progn
          (should (emacs-jupyter-notebook-runtime-waiter-active-p token t))
          (should-not (emacs-jupyter-notebook-runtime-waiter-active-p token))
          (should-not (emacs-jupyter-notebook-runtime-waiter-active-p 'unknown t))
          (setf (emacs-jupyter-notebook-runtime--build-terminal build) t)
          (should-not (emacs-jupyter-notebook-runtime-waiter-active-p token t))
          (setf (emacs-jupyter-notebook-runtime--build-terminal build) nil)
          (kill-buffer owner)
          (should-not (emacs-jupyter-notebook-runtime-waiter-active-p token t)))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest ejn-inspect-stderr-tail-omits-cut-credential-line ()
  (ejn-inspect-test--with-state
    (let* ((suffix "synthetic-secret\nQt plugin unavailable\n")
           (emacs-jupyter-notebook-inspect--last-message nil))
      (setf (ejn-inspection-stderr-tail state)
            (concat (make-string (- 8192 (length suffix)) ?\s) suffix))
      (emacs-jupyter-notebook-inspect--stop state "Local viewer exited")
      (should (string-match-p "Qt plugin unavailable" emacs-jupyter-notebook-inspect--last-message))
      (should-not (string-match-p "synthetic-secret" emacs-jupyter-notebook-inspect--last-message)))))

(ert-deftest ejn-inspect-stop-releases-active-and-pending-exactly-once ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-active state) (list :lease (ejn-inspect-test--lease "active" counts))
          (ejn-inspection-pending state) (list :lease (ejn-inspect-test--lease "pending" counts)))
    (emacs-jupyter-notebook-inspect--stop state)
    (emacs-jupyter-notebook-inspect--stop state)
    (should (= (gethash "active" counts 0) 1))
    (should (= (gethash "pending" counts 0) 1))
    (should-not emacs-jupyter-notebook-inspect--state)))

(ert-deftest ejn-inspect-runtime-cancellation-error-cannot-strand-handoffs ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-active state) (list :lease (ejn-inspect-test--lease "active" counts))
          (ejn-inspection-pending state) (list :lease (ejn-inspect-test--lease "pending" counts))
          (ejn-inspection-waiter state) 'test-waiter)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-cancel-waiter)
               (lambda (_) (error "test cancellation failure"))))
      (ignore-errors (emacs-jupyter-notebook-inspect--stop state)))
    (should (= (gethash "active" counts 0) 1))
    (should (= (gethash "pending" counts 0) 1))))

(ert-deftest ejn-inspect-unexpected-runtime-start-error-releases-accepted-lease ()
  (ejn-inspect-test--with-state
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-ensure)
               (lambda (&rest _) (error "test runtime failure"))))
      (ignore-errors
        (emacs-jupyter-notebook-inspect-publication
         (ejn-inspect-test--lease "new" counts))))
    (should (= (gethash "new" counts 0) 1))
    (should-not emacs-jupyter-notebook-inspect--state)))

(ert-deftest ejn-inspect-missing-command-does-not-leak-stderr-process ()
  (ejn-inspect-test--with-state
    (let ((make-pipe (symbol-function 'make-pipe-process)) created)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--command)
                       (lambda () nil))
                      ((symbol-function 'make-pipe-process)
                       (lambda (&rest args)
                         (let ((process (apply make-pipe args)))
                           (push process created) process))))
              (emacs-jupyter-notebook-inspect--spawn state))
            (should (cl-every (lambda (process) (not (process-live-p process))) created)))
        (dolist (process created)
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest ejn-inspect-pending-selections-coalesce-without-releasing-active ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-active state) (list :lease (ejn-inspect-test--lease "active" counts))
          (ejn-inspection-pending state) (list :lease (ejn-inspect-test--lease "old" counts))
          (ejn-inspection-waiter state) 'already-building)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-waiter-active-p)
               (lambda (&rest _) t)))
      (emacs-jupyter-notebook-inspect-publication (ejn-inspect-test--lease "new" counts)))
    (should (= (gethash "old" counts 0) 1))
    (should (= (gethash "active" counts 0) 0))
    (should (= (gethash "new" counts 0) 0))
    (emacs-jupyter-notebook-inspect--stop state)
    (should (= (gethash "active" counts 0) 1))
    (should (= (gethash "new" counts 0) 1))))

(ert-deftest ejn-inspect-valid-ownership-ack-releases-source-lease-but-keeps-viewer ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-ready state) t
          (ejn-inspection-active state)
          (list :id "open-1" :lease (ejn-inspect-test--lease "active" counts)))
    (ejn-inspect-test--feed
     state (emacs-jupyter-notebook-inspect--object
            "v" 1 "id" "open-1" "ok" t
            "result" (emacs-jupyter-notebook-inspect--object "state" "visible")))
    (should (= (gethash "active" counts 0) 1))
    (should-not (ejn-inspection-active state))
    (should (emacs-jupyter-notebook-inspect--live-p state))))

(ert-deftest ejn-inspect-malformed-ownership-ack-stops-before-releasing-lease ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-ready state) t
          (ejn-inspection-active state)
          (list :id "open-1" :lease (ejn-inspect-test--lease "active" counts)))
    (ejn-inspect-test--feed
     state (emacs-jupyter-notebook-inspect--object
            "v" 1 "id" "open-1" "ok" t
            "result" (emacs-jupyter-notebook-inspect--object "state" "received")))
    (should (ejn-inspection-closed state))
    (should (= (gethash "active" counts 0) 1))))

(ert-deftest ejn-inspect-negative-ack-requires-structured-bounded-error ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-ready state) t
          (ejn-inspection-active state)
          (list :id "open-1" :lease (ejn-inspect-test--lease "active" counts)))
    (ejn-inspect-test--feed
     state (emacs-jupyter-notebook-inspect--object "v" 1 "id" "open-1" "ok" :false))
    (should (ejn-inspection-closed state))
    (should (= (gethash "active" counts 0) 1))))

(ert-deftest ejn-inspect-stable-installed-viewer-survives-source-buffer-kill ()
  (ejn-inspect-test--with-state
    (setf (ejn-inspection-ready state) t
          (ejn-inspection-process state)
          (make-pipe-process :name "ejn-test-installed-viewer" :noquery t))
    (emacs-jupyter-notebook-inspect--owner-killed)
    (should (emacs-jupyter-notebook-inspect--live-p state))))

(ert-deftest ejn-inspect-superseded-build-owner-cannot-cancel-other-buffer-selection ()
  (ejn-inspect-test--with-state
    (let ((other (generate-new-buffer " *ejn-inspector-other-owner*")))
      (unwind-protect
          (progn
            (setf (ejn-inspection-waiter state) 'already-building
                  (ejn-inspection-pending state)
                  (list :owner (current-buffer) :lease (ejn-inspect-test--lease "old" counts)))
            (with-current-buffer other
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-waiter-active-p)
                         (lambda (&rest _) t)))
                (emacs-jupyter-notebook-inspect-publication
                 (ejn-inspect-test--lease "new" counts))))
            (emacs-jupyter-notebook-inspect--owner-killed)
            (should (emacs-jupyter-notebook-inspect--live-p state))
            (should (= (gethash "old" counts 0) 1))
            (should (= (gethash "new" counts 0) 0)))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest ejn-inspect-source-kill-cancels-only-active-handoff-until-terminal-ack ()
  (ejn-inspect-test--with-state
    (let (requests)
      (setf (ejn-inspection-ready state) t
            (ejn-inspection-process state)
            (make-pipe-process :name "ejn-test-cancel-viewer" :noquery t)
            (ejn-inspection-active state)
            (list :id "open-1" :owner (current-buffer)
                  :lease (ejn-inspect-test--lease "active" counts)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--send)
                 (lambda (_state id operation params)
                   (push (list id operation (gethash "id" params)) requests))))
        (emacs-jupyter-notebook-inspect--owner-killed)
        (emacs-jupyter-notebook-inspect--owner-killed))
      (should (equal requests '(("cancel-open-1" "cancel" "open-1"))))
      (should (= (gethash "active" counts 0) 0))
      (ejn-inspect-test--feed
       state (emacs-jupyter-notebook-inspect--object
              "v" 1 "id" "open-1" "ok" :false
              "error" (emacs-jupyter-notebook-inspect--object
                       "code" "cancelled" "message" "cancelled")))
      (should (= (gethash "active" counts 0) 1))
      (should (emacs-jupyter-notebook-inspect--live-p state)))))

(ert-deftest ejn-inspect-late-runtime-ready-callback-cannot-spawn-revoked-state ()
  (ejn-inspect-test--with-state
    (let (ready spawned)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-ensure)
                 (lambda (_probe callback _failure &rest _)
                   (setq ready callback) 'test-waiter))
                ((symbol-function 'emacs-jupyter-notebook-inspect--command)
                 (lambda () '("unexpected-viewer")))
                ((symbol-function 'make-process)
                 (lambda (&rest _) (setq spawned t))))
        (emacs-jupyter-notebook-inspect-publication (ejn-inspect-test--lease "new" counts))
        (emacs-jupyter-notebook-inspect--stop state)
        (funcall ready)
        (should-not spawned)
        (should (= (gethash "new" counts 0) 1))))))

(ert-deftest ejn-inspect-filter-overflow-revokes-before-releasing-handoff ()
  (ejn-inspect-test--with-state
    (let ((process (make-pipe-process :name "ejn-test-overflow-viewer" :noquery t)))
      (setf (ejn-inspection-process state) process
            (ejn-inspection-active state)
            (list :lease (ejn-inspect-test--lease "active" counts)))
      (emacs-jupyter-notebook-inspect--filter state process (make-string 65537 ?x))
      (should-not (process-live-p process))
      (should (ejn-inspection-closed state))
      (should (= (gethash "active" counts 0) 1)))))

(ert-deftest ejn-inspect-hello-negotiates-required-capability-before-pumping ()
  (ejn-inspect-test--with-state
    (let (sent)
      (setf (ejn-inspection-pending state)
            (list :lease (ejn-inspect-test--lease "new" counts) :focus t))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--send)
                 (lambda (_state id operation params)
                   (setq sent (list id operation params)))))
        (ejn-inspect-test--feed
         state (emacs-jupyter-notebook-inspect--object
                "v" 1 "id" "hello" "ok" t
                "result" (emacs-jupyter-notebook-inspect--object
                          "version" 1 "capabilities" ["array-group-v1" "raster-v1"]))))
      (should (ejn-inspection-ready state))
      (should (equal (seq-take sent 2) '("open-1" "open")))
      (should (equal (gethash "kind" (nth 2 sent)) "array-group"))
      (let ((artifact (gethash "artifact" (nth 2 sent))))
        (should (= (gethash "root_device" artifact) 2))
        (should (= (gethash "root_inode" artifact) 1))
        (should-not (gethash "manifest" artifact))
        (should-not (gethash "data" artifact)))
      (should (= (gethash "new" counts 0) 0)))))

(ert-deftest ejn-inspect-hello-without-numerical-capability-is-rejected ()
  (ejn-inspect-test--with-state
    (ejn-inspect-test--feed
     state (emacs-jupyter-notebook-inspect--object
            "v" 1 "id" "hello" "ok" t
            "result" (emacs-jupyter-notebook-inspect--object
                      "version" 1 "capabilities" ["raster-v1"])))
    (should (ejn-inspection-closed state))))

(ert-deftest ejn-inspect-reentrant-spawn-exit-cannot-send-hello-or-strand-lease ()
  (ejn-inspect-test--with-state
    (let (sent)
      (setf (ejn-inspection-pending state)
            (list :lease (ejn-inspect-test--lease "new" counts)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--command)
                 (lambda () '("test-viewer")))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (let ((process (make-pipe-process :name "ejn-test-early-exit" :noquery t)))
                     (delete-process process)
                     (funcall (plist-get args :sentinel) process "finished\n")
                     process)))
                ((symbol-function 'emacs-jupyter-notebook-inspect--send)
                 (lambda (&rest _) (setq sent t))))
        (emacs-jupyter-notebook-inspect--spawn state))
      (should (ejn-inspection-closed state))
      (should-not sent)
      (should-not (process-live-p (ejn-inspection-stderr state)))
      (should (= (gethash "new" counts 0) 1)))))

(provide 'emacs-jupyter-notebook-inspect-tests)
;;; emacs-jupyter-notebook-inspect-tests.el ends here
