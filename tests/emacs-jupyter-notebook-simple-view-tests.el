;;; emacs-jupyter-notebook-simple-view-tests.el --- Lightweight viewing -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'python)
(require 'emacs-jupyter-notebook-variables)
(require 'emacs-jupyter-notebook-inspect)

(ert-deftest ejn-simple-view-reuses-valid-selectors-and-reprompts-after-shrink ()
  (with-temp-buffer
    (let ((metadata '(:shape [8 16 32] :dtype "float32")) (prompts 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-variables--select-plane)
                 (lambda (_) (cl-incf prompts) '([1 2] [7 nil nil]))))
        (should (equal (emacs-jupyter-notebook-variables--selection "volume" metadata)
                       '([1 2] [7 nil nil])))
        (emacs-jupyter-notebook-variables--selection "volume" metadata)
        (should (= prompts 1))
        (emacs-jupyter-notebook-variables--selection "volume" '(:shape [4 16 32] :dtype "float32"))
        (should (= prompts 2))))))

(ert-deftest ejn-simple-view-crop-validity-tracks-fresh-bounds ()
  (should (emacs-jupyter-notebook-variables--valid-selection-p
           '([0 1 2] [nil nil nil] [[3 7] [0 8] [2 9]]) [10 10 10]))
  (should-not (emacs-jupyter-notebook-variables--valid-selection-p
               '([0 1 2] [nil nil nil] [[3 7] [0 8] [2 9]]) [10 10 8])))

(ert-deftest ejn-simple-view-group-uses-one-inspection-and-keeps-source-clean ()
  (with-temp-buffer
    (insert "# %%\ninput = load()\nprediction = model(input)\n")
    (let ((before (buffer-string)) code title
          (metadata '((:name "input" :shape [5 8] :dtype "float32")
                      (:name "prediction" :shape [5 8] :dtype "float32"))))
      (setq-local emacs-jupyter-notebook--client 'client)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-evaluate)
                 (lambda (text label) (setq code text title label))))
        (emacs-jupyter-notebook-variables--view-group '("input" "prediction") metadata))
      (should (equal code (concat "ejn.view_variables(["
                                 "{\"name\":\"input\",\"axes\":[0,1],\"indices\":[None,None]},"
                                 "{\"name\":\"prediction\",\"axes\":[0,1],\"indices\":[None,None]}])\n")))
      (should (equal title "View input + prediction"))
      (should (equal emacs-jupyter-notebook-variables--view-recent '("input" "prediction")))
      (should (equal before (buffer-string))))))

(ert-deftest ejn-simple-view-single-group-keeps-plane-publisher ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook--client 'client)
    (let (code)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-evaluate)
                 (lambda (text _) (setq code text))))
        (emacs-jupyter-notebook-variables--view-group
         '("x") '((:name "x" :shape [8 9] :dtype "float32"))))
      (should (equal code "ejn.view_variable(\"x\", axes=[0,1], indices=[None,None])\n")))))

(ert-deftest ejn-simple-view-chooser-defers-input-and-rejects-stale-generation ()
  (with-temp-buffer
    (python-mode)
    (setq-local emacs-jupyter-notebook-mode t emacs-jupyter-notebook--client 'client)
    (let (reply deferred generated)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-variables--ensure-ready) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-variables--request)
                 (lambda (names callback &rest _) (should-not names) (setq reply callback)))
                ((symbol-function 'emacs-jupyter-notebook-ui-defer)
                 (lambda (&rest args) (setq deferred args)))
                ((symbol-function 'completing-read-multiple)
                 (lambda (_prompt names &rest _)
                   (should (equal names '("image"))) '("image")))
                ((symbol-function 'emacs-jupyter-notebook-inspect-evaluate)
                 (lambda (code _) (setq generated code))))
        (emacs-jupyter-notebook-view-variables)
        (funcall reply '(:variables ((:name "scalar" :type "int")
                                     (:name "image" :shape [8 9] :dtype "float32"))))
        (should-not generated)
        (should (funcall (nth 1 deferred)))
        (funcall (nth 2 deferred))
        (should generated)
        (cl-incf emacs-jupyter-notebook-variables--generation)
        (should-not (funcall (nth 1 deferred)))))))

(ert-deftest ejn-simple-view-opens-exact-output-without-kernel-evaluation ()
  (with-temp-buffer
    (let (opened)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-variables--name-at-point) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--current-cell-key) (lambda () 7))
                ((symbol-function 'emacs-jupyter-notebook-panel-acquire-array-for-cell)
                 (lambda (source key) (should (eq source (current-buffer)))
                   (should (= key 7)) 'exact-lease))
                ((symbol-function 'emacs-jupyter-notebook-inspect-publication)
                 (lambda (lease) (setq opened lease)))
                ((symbol-function 'emacs-jupyter-notebook-send-cell)
                 (lambda () (ert-fail "View evaluated source")))
                ((symbol-function 'emacs-jupyter-notebook-view-variables)
                 (lambda (&rest _) (ert-fail "View queried current kernel"))))
        (emacs-jupyter-notebook-view)
        (should (eq opened 'exact-lease))))))

(ert-deftest ejn-simple-view-prefix-chooses-and-double-prefix-reconfigures ()
  (with-temp-buffer
    (let (calls)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-view-variables)
                 (lambda (&rest args) (push args calls)))
                ((symbol-function 'emacs-jupyter-notebook-panel-acquire-array-for-cell)
                 (lambda (&rest _) (ert-fail "Prefix acquired existing output"))))
        (emacs-jupyter-notebook-view '(4))
        (emacs-jupyter-notebook-view '(16))
        (should (equal calls '((t nil) (nil nil))))))))

(ert-deftest ejn-simple-view-review-starts-without-a-kernel-or-artifact ()
  (let ((emacs-jupyter-notebook-inspect--state nil) startup sent)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--ensure-running)
                   (lambda (state) (setq startup state)))
                  ((symbol-function 'emacs-jupyter-notebook-inspect--send)
                   (lambda (_state id operation params) (setq sent (list id operation params)))))
          (emacs-jupyter-notebook-inspect-control "findings" (make-hash-table :test #'equal))
          (should startup)
          (should-not (ejn-inspection-pending startup))
          (should-not sent)
          (emacs-jupyter-notebook-inspect--response
           startup (emacs-jupyter-notebook-inspect--object
                    "v" 1 "id" "hello" "ok" t
                    "result" (emacs-jupyter-notebook-inspect--object
                              "version" 1 "capabilities" ["array-group-v1" "findings-v1"])))
          (should (equal (cadr sent) "findings"))
          (should (timerp (ejn-inspection-control-timer startup))))
      (when startup (emacs-jupyter-notebook-inspect--stop startup)))))

(ert-deftest ejn-simple-view-capture-never-starts-an-absent-viewer ()
  (let ((emacs-jupyter-notebook-inspect--state nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--ensure-state)
               (lambda () (ert-fail "Capture started a viewer"))))
      (should-error
       (emacs-jupyter-notebook-inspect-control "capture" (make-hash-table :test #'equal) t)
       :type 'user-error))))

(ert-deftest ejn-simple-view-control-ack-cannot-release-an-active-image ()
  (let* ((state (ejn-inspection-create :ready t :counter 0 :process 'test-process
                                      :capabilities '("findings-v1")))
         (emacs-jupyter-notebook-inspect--state state)
         (active (list :id "open-1" :lease (list :release (lambda () (ert-fail "Released image")))))
         sent)
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'emacs-jupyter-notebook-inspect--send)
                   (lambda (_state id _operation _params) (setq sent id))))
          (setf (ejn-inspection-active state) active)
          (emacs-jupyter-notebook-inspect-control "capture" (make-hash-table :test #'equal) t)
          (let ((timer (ejn-inspection-control-timer state)))
            (should (timerp timer))
            (should-error
             (emacs-jupyter-notebook-inspect-control "capture" (make-hash-table :test #'equal) t)
             :type 'user-error)
            (emacs-jupyter-notebook-inspect--response
             state (emacs-jupyter-notebook-inspect--object
                    "v" 1 "id" sent "ok" t "result"
                    (emacs-jupyter-notebook-inspect--object "state" "saving")))
            (should-not (memq timer timer-list)))
          (should-not (ejn-inspection-control state))
          (should (eq (ejn-inspection-active state) active)))
      (setf (ejn-inspection-active state) nil (ejn-inspection-process state) nil)
      (emacs-jupyter-notebook-inspect--stop state))))

(ert-deftest ejn-simple-view-generated-output-workspace-survives-lease-release ()
  (let* ((state (ejn-inspection-create :ready t :counter 0))
         (emacs-jupyter-notebook-inspect--state state)
         released)
    (unwind-protect
        (progn
          (setf (ejn-inspection-active state)
                (list :id "open-1" :lease
                      (list :source-buffer (current-buffer) :workspace "variables-test" :cell-key nil
                            :release (lambda () (setq released t)))))
          (emacs-jupyter-notebook-inspect--response
           state (emacs-jupyter-notebook-inspect--object
                  "v" 1 "id" "open-1" "ok" t
                  "result" (emacs-jupyter-notebook-inspect--object "state" "visible")))
          (should released)
          (should (equal (plist-get (car (emacs-jupyter-notebook-inspect-workspaces)) :workspace)
                         "variables-test"))
          (should-not (plist-get (car (emacs-jupyter-notebook-inspect-workspaces)) :cell-key)))
      (emacs-jupyter-notebook-inspect--stop state))))

(ert-deftest ejn-simple-view-context-freezes-producing-execution-before-startup ()
  (let ((emacs-jupyter-notebook-inspect--state nil)
        (context (make-hash-table :test #'equal))
        resolved released)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-history-provenance)
                   (lambda (handle) (setq resolved handle) context))
                  ((symbol-function 'emacs-jupyter-notebook-inspect--ensure-running) #'ignore))
          (emacs-jupyter-notebook-inspect-publication
           (list :execution-handle '(:id 2 :generation 3) :entry-handle '(:id 1 :generation 3)
                 :source-buffer (current-buffer) :release (lambda () (setq released t))))
          (should (equal resolved '(:id 2 :generation 3)))
          (let ((lease (plist-get (ejn-inspection-pending emacs-jupyter-notebook-inspect--state) :lease)))
            (setq resolved nil context (make-hash-table :test #'equal))
            (should-not (eq context (emacs-jupyter-notebook-inspect--context lease)))
            (should-not resolved)))
      (when emacs-jupyter-notebook-inspect--state
        (emacs-jupyter-notebook-inspect--stop emacs-jupyter-notebook-inspect--state)))
    (should released)))

(ert-deftest ejn-simple-view-source-kill-preserves-independent-review-during-build ()
  (let* ((source (generate-new-buffer " *ejn-review-source*"))
         (build-owner (generate-new-buffer " *ejn-review-build*"))
         (state (ejn-inspection-create :counter 0 :owner source :build-owner build-owner
                                      :waiter 'review-build :phase 'building))
         (emacs-jupyter-notebook-inspect--state state)
         (control (list :id "review-control" :operation "findings"
                        :params (make-hash-table :test #'equal)))
         (released 0) cancelled sent timer)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime-cancel-waiter)
                   (lambda (_) (setq cancelled t)))
                  ((symbol-function 'emacs-jupyter-notebook-inspect--send)
                   (lambda (_state _id operation _params) (setq sent operation))))
          (setf (ejn-inspection-pending state)
                (list :owner source :lease
                      (list :source-buffer source :release (lambda () (cl-incf released))))
                (ejn-inspection-control state) control)
          (with-current-buffer source
            (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-inspect--owner-killed nil t))
          (kill-buffer source)
          (should (= released 1))
          (should-not (ejn-inspection-pending state))
          (should (eq state emacs-jupyter-notebook-inspect--state))
          (should (eq control (ejn-inspection-control state)))
          (should (buffer-live-p build-owner))
          (should-not cancelled)
          ;; The shared build can still finish and deliver the independent
          ;; review request without reacquiring the dead source's artifact.
          (emacs-jupyter-notebook-inspect--response
           state (emacs-jupyter-notebook-inspect--object
                  "v" 1 "id" "hello" "ok" t "result"
                  (emacs-jupyter-notebook-inspect--object
                   "version" 1 "capabilities" ["array-group-v1" "findings-v1"])))
          (setq timer (ejn-inspection-control-timer state))
          (should (equal sent "findings"))
          (should (timerp timer)))
      (emacs-jupyter-notebook-inspect--stop state)
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p build-owner) (kill-buffer build-owner)))
    (should (= released 1))
    (should-not (buffer-live-p build-owner))
    (should-not (memq timer timer-list))))

(defmacro ejn-simple-view-test--with-control (&rest body)
  "Run BODY with a ready mocked viewer and captured one-shot timers."
  (declare (indent 0))
  `(let* ((state (ejn-inspection-create :ready t :counter 0 :process 'test-process
                                       :capabilities '("findings-v1")))
          (emacs-jupyter-notebook-inspect--state state)
          scheduled cancelled)
     (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
               ((symbol-function 'emacs-jupyter-notebook-inspect--send) #'ignore)
               ((symbol-function 'run-at-time)
                (lambda (delay repeat function &rest args)
                  (let ((timer (timer-create)))
                    (push (list timer delay repeat function args) scheduled)
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (push timer cancelled))))
       (unwind-protect (progn ,@body)
         (setf (ejn-inspection-active state) nil (ejn-inspection-process state) nil)
         (emacs-jupyter-notebook-inspect--stop state)))))

(ert-deftest ejn-simple-view-org-callback-is-deferred-once-and-independent-of-viewer ()
  (ejn-simple-view-test--with-control
    (let ((result (emacs-jupyter-notebook-inspect--object "path" "/tmp/findings.org" "count" 1))
          (calls 0) value)
      (emacs-jupyter-notebook-inspect-control
       "findings_org" (make-hash-table :test #'equal) t
       (lambda (reply) (cl-incf calls) (setq value reply)))
      (let* ((id (plist-get (ejn-inspection-control state) :id))
             (ack (emacs-jupyter-notebook-inspect--object "v" 1 "id" id "ok" t "result" result)))
        (emacs-jupyter-notebook-inspect--response state ack)
        (should (= calls 0))
        (should-not (ejn-inspection-control state))
        (should-not (ejn-inspection-control-timer state))
        (should (= (length cancelled) 1))
        ;; Duplicate/stale replies cannot schedule another open operation.
        (should-error (emacs-jupyter-notebook-inspect--response state ack))
        (let ((completion (cl-find 0 scheduled :key #'cadr)))
          (should completion)
          (should-not (nth 2 completion))
          (should (= (length scheduled) 2))
          ;; Generated local findings survive the viewer that created them.
          (setf (ejn-inspection-process state) nil)
          (emacs-jupyter-notebook-inspect--stop state)
          (dotimes (_ 2) (apply (nth 3 completion) (nth 4 completion)))
          (should (= calls 1))
          (should (eq value result)))))))

(ert-deftest ejn-simple-view-org-error-never-invokes-callback-or-releases-image ()
  (ejn-simple-view-test--with-control
    (let ((active (list :id "open-independent" :lease (list :release
                                                           (lambda () (ert-fail "Released image"))))))
      (setf (ejn-inspection-active state) active)
      (emacs-jupyter-notebook-inspect-control
       "findings_org" (make-hash-table :test #'equal) t
       (lambda (_) (ert-fail "Failure delivered success callback")))
      (emacs-jupyter-notebook-inspect--response
       state (emacs-jupyter-notebook-inspect--object
              "v" 1 "id" (plist-get (ejn-inspection-control state) :id) "ok" :false
              "error" (emacs-jupyter-notebook-inspect--object "code" "failed" "message" "Could not write index")))
      (should (= (length scheduled) 1))
      (should (eq active (ejn-inspection-active state)))
      (should-not (ejn-inspection-control state))
      (should-not (ejn-inspection-closed state)))))

(ert-deftest ejn-simple-view-org-callback-error-does-not-stop-image-viewer ()
  (ejn-simple-view-test--with-control
    (let ((active (list :id "open-independent")) reported)
      (setf (ejn-inspection-active state) active)
      (emacs-jupyter-notebook-inspect-control
       "findings_org" (make-hash-table :test #'equal) t
       (lambda (_) (error "Rejected generated index")))
      (emacs-jupyter-notebook-inspect--response
       state (emacs-jupyter-notebook-inspect--object
              "v" 1 "id" (plist-get (ejn-inspection-control state) :id) "ok" t
              "result" (emacs-jupyter-notebook-inspect--object "path" "/tmp/findings.org")))
      (let ((completion (cl-find 0 scheduled :key #'cadr)))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect--report)
                   (lambda (&rest args) (setq reported args))))
          (apply (nth 3 completion) (nth 4 completion))))
      (should reported)
      (should (eq active (ejn-inspection-active state)))
      (should-not (ejn-inspection-closed state)))))

(provide 'emacs-jupyter-notebook-simple-view-tests)
;;; emacs-jupyter-notebook-simple-view-tests.el ends here
