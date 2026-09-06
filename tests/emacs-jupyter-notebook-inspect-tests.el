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
       (ignore-errors (emacs-jupyter-notebook-inspect--stop state)))))

(defun ejn-inspect-test--feed (state object)
  "Dispatch OBJECT through the real framed response drain."
  (setf (ejn-inspection-raw state)
        (list (ejn-helper-protocol-encode object 65536)))
  (emacs-jupyter-notebook-inspect--drain state))

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
    (emacs-jupyter-notebook-inspect-publication (ejn-inspect-test--lease "new" counts))
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
              (emacs-jupyter-notebook-inspect-publication
               (ejn-inspect-test--lease "new" counts)))
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
                 (lambda () (setq spawned t) '("unexpected-viewer"))))
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
