;;; emacs-jupyter-notebook-registry-timing-tests.el --- Registry timing tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-registry)

(defconst ejn-registry-timing-test--now 1000000000.0)

(ert-deftest ejn-registry-timing-deadline-is-finite-and-hard-bounded ()
  "Every relative or non-finite deadline gets a finite hard upper bound."
  (dolist (value (list nil 0 -1 'invalid (sqrt -1.0) 1.0e+INF
                       most-positive-fixnum))
    (cl-letf (((symbol-function 'float-time)
               (lambda (&rest _) ejn-registry-timing-test--now)))
      (let ((deadline
             (emacs-jupyter-notebook-registry--deadline-at value)))
        (should (emacs-jupyter-notebook-registry--finite-number-p deadline))
        (should (<= deadline
                    (+ ejn-registry-timing-test--now
                       emacs-jupyter-notebook-registry--hard-deadline)))))))

(ert-deftest ejn-registry-timing-deadline-preserves-nearer-and-stale-absolute ()
  "A nearer absolute deadline is retained and a stale one stays stale."
  (cl-letf (((symbol-function 'float-time)
             (lambda (&rest _) ejn-registry-timing-test--now)))
    (should (= (emacs-jupyter-notebook-registry--deadline-at
                (+ ejn-registry-timing-test--now 5.0))
               (+ ejn-registry-timing-test--now 5.0)))
    (should (= (emacs-jupyter-notebook-registry--deadline-at
                (- ejn-registry-timing-test--now 100.0))
               (- ejn-registry-timing-test--now 100.0)))
    (should (= (emacs-jupyter-notebook-registry--deadline-at
                (+ ejn-registry-timing-test--now 10000.0))
               (+ ejn-registry-timing-test--now
                  emacs-jupyter-notebook-registry--hard-deadline)))
    (should (= (emacs-jupyter-notebook-registry--deadline-at 1.0e+INF)
               (+ ejn-registry-timing-test--now
                  emacs-jupyter-notebook-registry--hard-deadline)))))

(ert-deftest ejn-registry-timing-request-normalizes-logical-deadline ()
  "The operation handle receives the same finite hard-bounded deadline."
  (let (scheduled operation)
    (cl-letf (((symbol-function 'float-time)
               (lambda (&rest _) ejn-registry-timing-test--now))
              ((symbol-function 'run-at-time)
               (lambda (seconds _repeat function &rest args)
                 (push (list seconds function args) scheduled)
                 nil))
              ((symbol-function 'emacs-jupyter-notebook-registry--start-attempt)
               (lambda (_operation) nil)))
      (with-temp-buffer
        (setq operation
              (emacs-jupyter-notebook-registry-request-async
               '(("v" . 1)) #'ignore #'ignore
               :deadline most-positive-fixnum))
        (should (= (emacs-jupyter-notebook-registry-operation-deadline operation)
                   (+ ejn-registry-timing-test--now
                      emacs-jupyter-notebook-registry--hard-deadline)))
        (should (= (length scheduled) 1))
        (emacs-jupyter-notebook-registry-operation-cancel operation)))))

(ert-deftest ejn-registry-timing-retry-values-are-finite-positive-and-clamped ()
  "Invalid, non-finite, and huge retry settings cannot reach timers."
  (dolist (values (list (cons nil nil) (cons 0 -1) (cons -1 0)
                        (cons 'bad 'bad) (cons (sqrt -1.0) 1.0e+INF)
                        (cons 1.0e+INF most-positive-fixnum)))
    (let* ((emacs-jupyter-notebook-registry-worker-retry-initial-delay
            (car values))
           (emacs-jupyter-notebook-registry-worker-retry-max-delay
            (cdr values))
           (operation
            (emacs-jupyter-notebook-registry--make-operation :retry-count 100)))
      (let ((delay (emacs-jupyter-notebook-registry--retry-delay operation)))
        (should (emacs-jupyter-notebook-registry--finite-number-p delay))
        (should (> delay 0))
        (should (<= delay emacs-jupyter-notebook-registry--hard-deadline))))))

(ert-deftest ejn-registry-timing-retry-scheduling-never-exceeds-remaining ()
  "A retry timer is scheduled no later than the logical deadline."
  (let (scheduled)
    (cl-letf (((symbol-function 'float-time)
               (lambda (&rest _) ejn-registry-timing-test--now))
              ((symbol-function 'run-at-time)
               (lambda (seconds _repeat _function &rest _args)
                 (setq scheduled seconds)
                 nil)))
      (let ((emacs-jupyter-notebook-registry-worker-retry-initial-delay 1.0e+INF)
            (emacs-jupyter-notebook-registry-worker-retry-max-delay
             most-positive-fixnum)
            (operation
             (emacs-jupyter-notebook-registry--make-operation
              :deadline (+ ejn-registry-timing-test--now 0.2)
              :retry-count most-positive-fixnum)))
        (emacs-jupyter-notebook-registry--schedule-retry operation)
        (should (emacs-jupyter-notebook-registry--finite-number-p scheduled))
        (should (> scheduled 0))
        (should (<= scheduled
                    (- 0.2
                       emacs-jupyter-notebook-registry--retry-safety-margin
                       -1.0e-5)))))))

(ert-deftest ejn-registry-timing-worker-filters-never-concat-oversized-chunks ()
  "Worker filters slice to remaining capacity before allocating a concat."
  (let* ((operation
          (emacs-jupyter-notebook-registry--make-operation
           :stdout "ab" :stderr "e"))
         (huge (make-string (* 1024 1024) ?x))
         (real-concat (symbol-function 'concat))
         (largest-concat 0)
         (emacs-jupyter-notebook-registry-worker-output-max-bytes 8)
         (emacs-jupyter-notebook-registry-worker-stderr-max-bytes 5))
    (cl-letf (((symbol-function 'concat)
               (lambda (&rest strings)
                 (let ((bytes (apply #'+ (mapcar #'string-bytes strings))))
                   (setq largest-concat (max largest-concat bytes))
                   (when (> bytes 8)
                     (ert-fail "registry filter concatenated beyond its cap")))
                 (apply real-concat strings))))
      (should (emacs-jupyter-notebook-registry--append-stdout operation huge))
      (should (equal
               (emacs-jupyter-notebook-registry-operation-stdout operation)
               "abxxxxxx"))
      ;; A full buffer rejects a later hostile chunk without concatenating it.
      (should (emacs-jupyter-notebook-registry--append-stdout operation huge))
      (emacs-jupyter-notebook-registry--append-stderr operation huge)
      (should (equal
               (emacs-jupyter-notebook-registry-operation-stderr operation)
               "exxxx"))
      (should (= largest-concat 8)))))

(ert-deftest ejn-registry-timing-worker-filter-fails-closed-on-multibyte-chunk ()
  "A violated binary process invariant retains no multibyte worker output."
  (let ((operation
         (emacs-jupyter-notebook-registry--make-operation
          :stdout "kept" :stderr "diagnostic")))
    (should
     (emacs-jupyter-notebook-registry--append-stdout
      operation (string (decode-char 'ucs #x03c0))))
    (emacs-jupyter-notebook-registry--append-stderr
     operation (string (decode-char 'ucs #x03c0)))
    (should (equal
             (emacs-jupyter-notebook-registry-operation-stdout operation)
             "kept"))
    (should (equal
             (emacs-jupyter-notebook-registry-operation-stderr operation)
             "diagnostic"))))

(ert-deftest ejn-registry-timing-deadline-timer-allocation-cleans-owner ()
  "A timer allocation error delivers one failure and never starts a worker."
  (let (failures starts owner operation)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (error "timer allocation failed")))
              ((symbol-function 'emacs-jupyter-notebook-registry--start-attempt)
               (lambda (&rest _) (setq starts t))))
      (with-temp-buffer
        (setq owner (emacs-jupyter-notebook-registry-owner-create)
              operation
              (emacs-jupyter-notebook-registry-request-async
               '(("v" . 1) ("op" . "read")) #'ignore
               (lambda (failure _operation) (push failure failures))
               :owner owner))
        (should (emacs-jupyter-notebook-registry-operation-finished operation))
        (should-not starts)
        (should (null (emacs-jupyter-notebook-registry-owner-operations owner)))
        (should (= (length failures) 1))
        (should (equal (plist-get (car failures) :code) "deadline-timer"))))))

(ert-deftest ejn-registry-timing-framed-response-waits-for-final-chunk ()
  "Only the newline-terminated complete worker response settles an operation."
  (let* ((owner (emacs-jupyter-notebook-registry--make-owner
                 :buffer nil :operations nil))
         (process (make-pipe-process
                   :name "ejn-registry-chunk-test" :buffer nil :noquery t))
         (successes 0)
         (failures 0)
         (operation
          (emacs-jupyter-notebook-registry--make-operation
           :owner owner :request '(("op" . "read")) :process process
           :stdout "" :success (lambda (&rest _) (cl-incf successes))
           :failure (lambda (&rest _) (cl-incf failures)))))
    (setf (emacs-jupyter-notebook-registry-owner-operations owner)
          (list operation))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry--stdout-filter
           operation process "{\"v\":1,\"ok\":true,")
          (should-not
           (emacs-jupyter-notebook-registry-operation-finished operation))
          (should (= successes 0))
          (emacs-jupyter-notebook-registry--stdout-filter
           operation process "\"result\":{}}\n")
          (should
           (emacs-jupyter-notebook-registry-operation-finished operation))
          (should (= successes 1))
          (should (= failures 0)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest ejn-registry-timing-malformed-frame-is-uncertain-for-mutation ()
  "A complete malformed mutation frame fails once with uncertain durability."
  (let* ((owner (emacs-jupyter-notebook-registry--make-owner
                 :buffer nil :operations nil))
         (process (make-pipe-process
                   :name "ejn-registry-malformed-test" :buffer nil :noquery t))
         failure
         (operation
          (emacs-jupyter-notebook-registry--make-operation
           :owner owner :request '(("op" . "replace-if-revision"))
           :process process :stdout "" :success #'ignore
           :failure (lambda (value _operation) (setq failure value)))))
    (setf (emacs-jupyter-notebook-registry-owner-operations owner)
          (list operation))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry--stdout-filter
           operation process "{not-json}\n")
          (should
           (emacs-jupyter-notebook-registry-operation-finished operation))
          (should (eq (plist-get failure :kind) 'durability-uncertain))
          (should (plist-get failure :durability-uncertain)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest ejn-registry-timing-constructor-defers-terminal-until-publication ()
  "A child exit during construction is delivered after operation ownership."
  (let* ((child (start-process "ejn-registry-fast-exit" nil "true"))
         (owner (emacs-jupyter-notebook-registry--make-owner
                 :buffer nil :operations nil))
         failures
         (operation
          (emacs-jupyter-notebook-registry--make-operation
           :owner owner :request '(("op" . "replace-if-revision"))
           :deadline (+ (float-time) 5) :stdout "" :stderr ""
           :success #'ignore
           :failure (lambda (value _operation) (push value failures)))))
    (setf (emacs-jupyter-notebook-registry-owner-operations owner)
          (list operation))
    (while (process-live-p child)
      (accept-process-output child 0.01))
    (cl-letf (((symbol-function
                'emacs-jupyter-notebook-registry-worker-resolve-argv)
               (lambda (&rest _) '("ignored")))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (funcall (plist-get args :sentinel) child "finished\n")
                 child))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore))
      (emacs-jupyter-notebook-registry--start-attempt operation))
    (should
     (emacs-jupyter-notebook-registry-operation-finished operation))
    (should (= (length failures) 1))
    (should (eq (plist-get (car failures) :kind) 'durability-uncertain))
    (should-not
     (emacs-jupyter-notebook-registry-operation-attempt-timer operation))))

(provide 'emacs-jupyter-notebook-registry-timing-tests)

;;; emacs-jupyter-notebook-registry-timing-tests.el ends here
