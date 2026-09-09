;;; emacs-jupyter-notebook-transport-hang-tests.el --- UI blocking regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-registry)

(ert-deftest ejn-transport-reentrant-write-never-interleaves-bytes ()
  "A callback during a blocked write cannot append another protocol frame."
  (let ((process (make-pipe-process :name "ejn-reentrant-write" :noquery t))
        sent rejected)
    (unwind-protect
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (process string)
                     (push string sent)
                     (unless rejected
                       (setq rejected t)
                       (should-error (emacs-jupyter-notebook-process-send
                                      process "nested frame"))))))
          (emacs-jupyter-notebook-process-send process "outer frame")
          (should (equal sent '("outer frame")))
          (should-not (process-get process 'ejn-write-owner)))
      (delete-process process))))

(ert-deftest ejn-transport-quit-retires-partial-write ()
  "C-g must not leave a partial frame available to the next request."
  (let ((process (make-pipe-process :name "ejn-interrupted-write" :noquery t))
        quit-seen)
    (unwind-protect
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (&rest _) (signal 'quit nil))))
          (condition-case nil
              (emacs-jupyter-notebook-process-send process "partial frame")
            (quit (setq quit-seen t)))
          (should quit-seen)
          (should-not (process-live-p process))
          (should-not (process-get process 'ejn-write-owner)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest ejn-transport-write-deadline-failure-sends-no-bytes ()
  (let ((process (make-pipe-process :name "ejn-write-no-deadline" :noquery t))
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (&rest _) (error "no timer")))
                  ((symbol-function 'process-send-string)
                   (lambda (&rest _) (setq sent t))))
          (should-error (emacs-jupyter-notebook-process-send process "frame"))
          (should-not sent)
          (should (process-live-p process))
          (should-not (process-get process 'ejn-write-owner)))
      (delete-process process))))

(ert-deftest ejn-transport-stale-write-deadline-cannot-kill-process ()
  (let ((process (make-pipe-process :name "ejn-write-stale-deadline" :noquery t))
        (real-timer (symbol-function 'run-at-time)) deadline)
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (delay repeat function &rest args)
                     (setq deadline (lambda () (apply function args)))
                     (apply real-timer delay repeat function args)))
                  ((symbol-function 'process-send-string) #'ignore))
          (emacs-jupyter-notebook-process-send process "frame")
          (funcall deadline)
          (should (process-live-p process)))
      (delete-process process))))

(ert-deftest ejn-transport-eager-write-deadline-sends-no-bytes ()
  (let ((process (make-pipe-process :name "ejn-write-eager-deadline" :noquery t))
        (real-timer (symbol-function 'run-at-time)) sent)
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (delay repeat function &rest args)
                     (apply function args)
                     (apply real-timer delay repeat function args)))
                  ((symbol-function 'process-send-string)
                   (lambda (&rest _) (setq sent t))))
          (should-error (emacs-jupyter-notebook-process-send process "frame"))
          (should-not sent)
          (should-not (process-live-p process)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest ejn-transport-helper-continuations-yield-to-keyboard ()
  (let ((session (emacs-jupyter-notebook-helper--make-session)) delays)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (delay &rest _) (push delay delays) nil)))
      (emacs-jupyter-notebook-helper--schedule-decode session)
      (emacs-jupyter-notebook-helper--schedule-drain session)
      (emacs-jupyter-notebook-helper--stderr-schedule-drain session))
    (should (= (length delays) 3))
    (should (cl-every (lambda (delay) (> delay 0)) delays))))

(ert-deftest ejn-transport-registry-attempt-deadline-precedes-send ()
  (let* ((owner (emacs-jupyter-notebook-registry--make-owner :buffer nil))
         (operation (emacs-jupyter-notebook-registry--make-operation
                     :owner owner :request '(("op" . "list"))
                     :deadline (+ (float-time) 5) :stdout "" :stderr ""))
         attempted)
    (setf (emacs-jupyter-notebook-registry-owner-operations owner) (list operation))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-worker-resolve-argv)
               (lambda () '("python3" "-c" "import time; time.sleep(30)")))
              ((symbol-function 'emacs-jupyter-notebook-process-send)
               (lambda (&rest _)
                 (setq attempted t)
                 (should (timerp (emacs-jupyter-notebook-registry-operation-attempt-timer
                                  operation)))
                 (error "test stops delivery"))))
      (emacs-jupyter-notebook-registry--start-attempt operation))
    (should attempted)
    (should (emacs-jupyter-notebook-registry-operation-finished operation))
    (should-not (memq (emacs-jupyter-notebook-registry-operation-attempt-timer operation)
                      timer-list))))

(ert-deftest ejn-transport-stalled-registry-write-is-short-and-uncertain ()
  "A non-reading mutation worker cannot delay delivery for its full timeout."
  (let* ((owner (emacs-jupyter-notebook-registry--make-owner :buffer nil))
         (operation (emacs-jupyter-notebook-registry--make-operation
                     :owner owner :request `(("op" . "create-if-absent")
                                             ("padding" . ,(make-string 60000 ?x)))
                     :deadline (+ (float-time) 5) :stdout "" :stderr ""))
         (fallback (run-at-time 0.8 nil
                                (lambda ()
                                  (when-let ((process (emacs-jupyter-notebook-registry-operation-process
                                                      operation)))
                                    (delete-process process)))))
         (start (float-time)))
    (setf (emacs-jupyter-notebook-registry-owner-operations owner) (list operation))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-worker-resolve-argv)
                   (lambda () '("python3" "-c" "import time; time.sleep(30)"))))
          (emacs-jupyter-notebook-registry--start-attempt operation)
          (should (< (- (float-time) start) 0.3))
          ;; Linux may buffer this whole bounded request; smaller pipe buffers
          ;; on other platforms hit the short write watchdog.  Both must return
          ;; promptly and retain uncertainty if any mutation bytes were sent.
          (unless (emacs-jupyter-notebook-registry-operation-finished operation)
            (emacs-jupyter-notebook-registry--attempt-timeout
             operation (emacs-jupyter-notebook-registry-operation-process operation)))
          (should (eq (plist-get (emacs-jupyter-notebook-registry-operation-result operation)
                                 :kind) 'durability-uncertain))
          (should-not (emacs-jupyter-notebook-registry-operation-process operation))
          (should-not (emacs-jupyter-notebook-registry-operation-retry-timer operation)))
      (cancel-timer fallback)
      (emacs-jupyter-notebook-registry-operation-cancel operation))))

(ert-deftest ejn-transport-stalled-helper-write-returns-promptly ()
  "A stopped local reader cannot trap keyboard dispatch in a pipe write."
  (let* ((process (make-process :name "ejn-stalled-reader" :buffer nil
                                :command '("python3" "-c" "import time; time.sleep(30)")
                                :connection-type 'pipe :coding 'binary :noquery t))
         (session (emacs-jupyter-notebook-helper--make-session :process process))
         (params (make-hash-table :test 'equal))
         ;; The fallback makes this regression finite even without the fix.
         (fallback (run-at-time 0.8 nil (lambda () (delete-process process))))
         (start (float-time)))
    (process-put process 'emacs-jupyter-notebook-helper-session session)
    (puthash "code" (make-string 524288 ?x) params)
    (unwind-protect
        (progn
          (should-error (emacs-jupyter-notebook-helper--send-envelope
                         session "stalled-write" "execute" params))
          (should (< (- (float-time) start) 0.3))
          (should-not (process-live-p process)))
      (cancel-timer fallback)
      (when (process-live-p process) (delete-process process)))))

(ert-deftest ejn-transport-decoder-budget-yields-inside-a-frame ()
  "Two legal frames crossing the work budget resume without failing."
  (let* ((object (make-hash-table :test 'equal))
         (session (emacs-jupyter-notebook-helper--make-session
                   :decoder (ejn-helper-protocol-make-decoder
                             ejn-helper-protocol-max-to-emacs-frame
                             ejn-helper-protocol-max-raw-accumulator)
                   :raw-bytes 0))
         received failures)
    (puthash "text" (make-string 170000 ?x) object)
    (let ((wire (ejn-helper-protocol-encode object ejn-helper-protocol-max-to-emacs-frame)))
      (emacs-jupyter-notebook-helper--raw-append session (concat wire wire)))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper--enqueue-object)
               (lambda (_session object _bytes) (push object received)))
              ((symbol-function 'emacs-jupyter-notebook-helper--queue-failure)
               (lambda (_session failure) (push failure failures)))
              ((symbol-function 'emacs-jupyter-notebook-helper--update-partial-deadline) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-helper--schedule-decode) #'ignore))
      (emacs-jupyter-notebook-helper--decode-raw session)
      (should-not failures)
      (should (= (length received) 1))
      (should (emacs-jupyter-notebook-helper-session-raw-chunks session))
      (emacs-jupyter-notebook-helper--decode-raw session)
      (should (= (length received) 2))
      (should-not failures)
      (should-not (emacs-jupyter-notebook-helper-session-raw-chunks session)))))

(provide 'emacs-jupyter-notebook-transport-hang-tests)
