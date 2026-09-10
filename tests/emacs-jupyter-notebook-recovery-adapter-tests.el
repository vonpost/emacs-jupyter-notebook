;;; emacs-jupyter-notebook-recovery-adapter-tests.el --- CC21 recovery adapter -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook-events)

(ert-deftest ejn-cc21-adapter-recoverable-loss-preserves-execution-mapping ()
  "A proven recoverable outage reaches the core without retiring its helper."
  (with-temp-buffer
    (let* (events failures
           (session (emacs-jupyter-notebook-backend-session-create
                     (lambda (_session event) (push event events))))
           (mapping (make-hash-table :test #'equal))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'live-helper :request-map mapping
                   :emit (lambda (event)
                           (emacs-jupyter-notebook-backend--emit session event))
                   :transport-failure (lambda (reason) (push reason failures)))))
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (puthash "execute-1" '(:ledger-id 1 :backend-request-id 2) mapping)
      (emacs-jupyter-notebook-helper-backend--event
       session state
       (emacs-jupyter-notebook-helper-backend--make-object
        "event" "transport_error" "data"
        (emacs-jupyter-notebook-helper-backend--make-object
         "message" "heartbeat unavailable" "recoverable" t)))
      (should (equal events '((:type tunnel-lost :message "heartbeat unavailable"))))
      (should-not failures)
      (should (eq (emacs-jupyter-notebook-helper-backend-state-helper state) 'live-helper))
      (should (= (hash-table-count mapping) 1))
      (should (emacs-jupyter-notebook-backend-session-live-p session)))))

(ert-deftest ejn-cc21-adapter-recoverability-requires-exact-true ()
  "Missing, false and malformed recovery claims retain fatal failure behavior."
  (dolist (recoverable '(nil :false :null "true" 1))
    (with-temp-buffer
      (let* (events failures
             (session (emacs-jupyter-notebook-backend-session-create))
             (state (emacs-jupyter-notebook-helper-backend--make-state
                     :emit (lambda (event) (push event events))
                     :transport-failure (lambda (reason) (push reason failures))))
             (data (emacs-jupyter-notebook-helper-backend--make-object
                    "message" "channel failed")))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (when recoverable (puthash "recoverable" recoverable data))
        (emacs-jupyter-notebook-helper-backend--event
         session state
         (emacs-jupyter-notebook-helper-backend--make-object
          "event" "transport_error" "data" data))
        (should-not events)
        (should (= (length failures) 1))))))

(ert-deftest ejn-cc21-adapter-suspend-resume-retain-helper-and-request ()
  "Recovery operations are asynchronous and do not replace execution ownership."
  (with-temp-buffer
    (let* (wire-calls callbacks successes failures
           (session (emacs-jupyter-notebook-backend-session-create))
           (mapping (make-hash-table :test #'equal))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :helper 'live-helper :request-map mapping)))
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (puthash "execute-1" '(:ledger-id 1) mapping)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                     (lambda (helper op params callback &rest keys)
                       (should (eq helper 'live-helper))
                       (should (= (hash-table-count params) 0))
                       (should (<= 1 (plist-get keys :timeout) 30))
                       (push op wire-calls)
                       (push callback callbacks)
                       (format "wire-%s" op))))
            (dolist (operation '(suspend resume))
              (let ((id (funcall
                         (if (eq operation 'suspend)
                             #'emacs-jupyter-notebook-backend-suspend
                           #'emacs-jupyter-notebook-backend-resume)
                         session
                         (lambda (request-id value) (push (list request-id value) successes))
                         (lambda (_id reason) (push reason failures)))))
                (should (integerp id))
                (should callbacks)
                (funcall (pop callbacks) 'live-helper
                         (emacs-jupyter-notebook-helper-backend--make-object
                          "ok" t "result"
                          (emacs-jupyter-notebook-helper-backend--make-object
                           (if (eq operation 'suspend) "suspended" "attached") t))
                         nil)))
            (should (equal wire-calls '("resume" "suspend")))
            (accept-process-output nil 0.02)
            (should (= (length successes) 2))
            (should-not failures)
            (should (= (hash-table-count mapping) 1))
            (should (eq (emacs-jupyter-notebook-helper-backend-state-helper state) 'live-helper))
            (should (emacs-jupyter-notebook-backend-session-live-p session)))
        (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
          (when (timerp timer) (cancel-timer timer)))))))

(ert-deftest ejn-cc21-adapter-completed-reply-retains-neutral-outcome ()
  "A shell barrier permits completed, even without a recoverable execution count."
  (dolist (count '(nil :null 4))
    (let* ((result (emacs-jupyter-notebook-helper-backend--make-object
                    "status" "completed" "execution_count" count))
           (reply (emacs-jupyter-notebook-helper-backend--normalize-event
                   nil (emacs-jupyter-notebook-helper-backend--make-object
                        "event" "execute_reply" "data" result))))
      (should (equal (plist-get reply :status) "completed"))
      (should (equal (plist-get reply :execution-count) (and (integerp count) count)))
      (should (equal (emacs-jupyter-notebook-helper-backend--execute-result result)
                     (list :status "completed" :execution-count (and (integerp count) count))))
      (should (eq (emacs-jupyter-notebook-events--reply-status reply) 'completed)))))

(ert-deftest ejn-cc21-adapter-stale-resume-never-rearms-new-suspension ()
  "A late success or error from superseded resume cannot revive its deadlines."
  (dolist (error-data '(nil "old resume timeout"))
    (with-temp-buffer
      (let* (callbacks successes failures rearmed
             (session (emacs-jupyter-notebook-backend-session-create))
             (helper (emacs-jupyter-notebook-helper--make-session))
             (state (emacs-jupyter-notebook-helper-backend--make-state :helper helper)))
        (setf (emacs-jupyter-notebook-backend-session-data session) state)
        (unwind-protect
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                       (lambda (_helper op _params callback &rest _keys)
                         (push callback callbacks) (format "wire-%s" op)))
                      ((symbol-function 'emacs-jupyter-notebook-helper-resume-execution-deadlines)
                       (lambda (_helper) (setq rearmed t))))
              (let* ((resume-id
                      (emacs-jupyter-notebook-backend-resume
                       session (lambda (&rest _args) (push t successes))
                       (lambda (&rest _args) (push t failures))))
                     (old-resume (pop callbacks)))
                (emacs-jupyter-notebook-backend-suspend session #'ignore #'ignore)
                (funcall old-resume helper
                         (emacs-jupyter-notebook-helper-backend--make-object
                          "ok" t "result"
                          (emacs-jupyter-notebook-helper-backend--make-object "attached" t))
                         error-data)
                (accept-process-output nil 0.01)
                (should-not rearmed)
                (should-not successes)
                (should-not failures)
                (should-not (gethash resume-id
                                     (emacs-jupyter-notebook-backend-session-requests session)))))
          (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
            (when (timerp timer) (cancel-timer timer))))))))

(ert-deftest ejn-cc21-adapter-recovery-acknowledgements-require-exact-true ()
  "An unproven attachment cannot resume queued work or fabricate success."
  (dolist (operation '(suspend resume))
    (dolist (value '(:false :null "true" 1))
      (with-temp-buffer
        (let* (failures successes
               (session (emacs-jupyter-notebook-backend-session-create))
               (state (emacs-jupyter-notebook-helper-backend--make-state
                       :helper 'live-helper
                       :transport-failure (lambda (reason) (push reason failures)))))
          (setf (emacs-jupyter-notebook-backend-session-data session) state)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                     (lambda (_helper _op _params callback &rest _keys)
                       (funcall callback nil
                                (emacs-jupyter-notebook-helper-backend--make-object
                                 "ok" t "result"
                                 (emacs-jupyter-notebook-helper-backend--make-object
                                  (if (eq operation 'suspend) "suspended" "attached") value)) nil)
                       "wire-recovery")))
            (emacs-jupyter-notebook-helper-backend-dispatch
             session nil operation nil (lambda (_result) (push t successes))
             (lambda (reason) (push reason failures)) #'ignore)
            (should-not successes)
            (should (= (length failures) 1))))))))

(ert-deftest ejn-cc21-adapter-completed-does-not-accept-malformed-count ()
  (dolist (count '(-1 "4" :false t))
    (let ((result (emacs-jupyter-notebook-helper-backend--make-object
                   "status" "completed" "execution_count" count)))
      (should-error (emacs-jupyter-notebook-helper-backend--execute-result result))
      (should-error (emacs-jupyter-notebook-helper-backend--normalize-event
                     nil (emacs-jupyter-notebook-helper-backend--make-object
                          "event" "execute_reply" "data" result))))))

(ert-deftest ejn-cc21-adapter-completed-renders-with-clean-source ()
  "Completion without a known outcome has a neutral, visible source indicator."
  (with-temp-buffer
    (insert "# %% recovered\nprint(1)\n")
    (set-buffer-modified-p nil)
    (let* ((before (buffer-string))
           (key (cons "source.py" 1))
           (overlay (emacs-jupyter-notebook-fringe-set key 'completed))
           (display (get-text-property 0 'display (overlay-get overlay 'before-string)))
           (glyph (cadr display)))
      (should (equal (car display) '(margin left-margin)))
      (should (equal (substring-no-properties glyph) "✓"))
      (should (eq (get-text-property 0 'face glyph)
                  'emacs-jupyter-notebook-fringe-completed-face))
      (should (string-match-p "\\[completed\\]"
                              (emacs-jupyter-notebook-panel--format-header
                               '(:status completed :code "print(1)"))))
      (should (equal before (buffer-string)))
      (should-not (buffer-modified-p))
      (delete-overlay overlay))))

(ert-deftest ejn-cc21-adapter-pauses-only-execute-deadline-and-fences-stale-timer ()
  "An offline execute retains its remaining budget while helper ping stays bounded."
  (let* ((requests (make-hash-table :test #'equal))
         (helper (emacs-jupyter-notebook-helper--make-session
                  :id 1 :state 'ready :requests requests :request-sequence 0))
         (now 100.0) callbacks execute ping original-token)
    (unwind-protect
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _time) now))
                  ((symbol-function 'emacs-jupyter-notebook-helper--send-envelope) #'ignore))
          (setq execute
                (gethash (emacs-jupyter-notebook-helper-request
                          helper "execute" (make-hash-table)
                          (lambda (&rest args) (push args callbacks)) :timeout 60)
                         requests)
                ping
                (gethash (emacs-jupyter-notebook-helper-request
                          helper "ping" (make-hash-table) #'ignore :timeout 2)
                         requests)
                original-token (emacs-jupyter-notebook-helper-request-deadline-token execute)
                now 110.0)
          (emacs-jupyter-notebook-helper-pause-execution-deadlines helper)
          (should (= (emacs-jupyter-notebook-helper-request-paused-remaining execute) 50))
          (should-not (emacs-jupyter-notebook-helper-request-timer execute))
          (should (timerp (emacs-jupyter-notebook-helper-request-timer ping)))
          (setq now 1000.0)
          (emacs-jupyter-notebook-helper-pause-execution-deadlines helper)
          (should (= (emacs-jupyter-notebook-helper-request-paused-remaining execute) 50))
          (emacs-jupyter-notebook-helper-resume-execution-deadlines helper)
          (should (= (emacs-jupyter-notebook-helper-request-deadline execute) 1050))
          (should (timerp (emacs-jupyter-notebook-helper-request-timer execute)))
          (emacs-jupyter-notebook-helper--request-deadline
           helper (emacs-jupyter-notebook-helper-request-id execute) execute original-token)
          (should-not callbacks)
          (should (= (hash-table-count requests) 2)))
      (maphash (lambda (_id request)
                 (when (timerp (emacs-jupyter-notebook-helper-request-timer request))
                   (cancel-timer (emacs-jupyter-notebook-helper-request-timer request))))
               requests))))

(provide 'emacs-jupyter-notebook-recovery-adapter-tests)
;;; emacs-jupyter-notebook-recovery-adapter-tests.el ends here
