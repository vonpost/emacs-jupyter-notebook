;;; emacs-jupyter-notebook-helper-process-tests.el --- ET2 tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-helper)

(defconst ejn-et2--root
  (file-name-directory (directory-file-name
                        (file-name-directory (file-truename load-file-name)))))
(defconst ejn-et2--fixture
  (expand-file-name "tests/fixtures/ejn_fake_helper.py" ejn-et2--root))

(defun ejn-et2--await (predicate &optional timeout)
  "Permit test subprocess notifications until PREDICATE succeeds or times out."
  (let ((deadline (+ (float-time) (or timeout 1))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(defun ejn-et2--clean ()
  (emacs-jupyter-notebook-helper--kill-emacs)
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer))
      (kill-buffer buffer))))

(cl-defmacro ejn-et2--with-session ((session scenario &rest options) &body body)
  "Run BODY with SESSION started against one TH1 SCENARIO."
  (declare (indent 1) (debug ((symbolp form &rest form) body)))
  `(let ((ready nil) (failure nil)
         (owner (generate-new-buffer " *ejn-et2-owner*"))
         (emacs-jupyter-notebook-helper-hello-timeout 0.12)
         (emacs-jupyter-notebook-helper-partial-frame-timeout 0.12)
         (emacs-jupyter-notebook-helper-command
          (append (list "python3" ejn-et2--fixture ,scenario) (list ,@options))))
     (ignore ready failure)
     (unwind-protect
         (let ((,session
                (emacs-jupyter-notebook-helper-start
                 :buffer owner
                 :ready-callback (lambda (_session _reason) (setq ready t))
                 :failure-callback (lambda (_session reason) (setq failure reason)))))
           ,@body)
       (when (buffer-live-p owner) (kill-buffer owner))
       (ejn-et2--clean))))

(defun ejn-et2--assert-no-local-leaks ()
  (should-not emacs-jupyter-notebook-helper--sessions)
  (should-not
   (cl-find-if (lambda (process)
                 (process-get process 'emacs-jupyter-notebook-helper-session))
               (process-list)))
  (should-not
   (cl-find-if (lambda (buffer)
                 (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer)))
               (buffer-list))))

(defun ejn-et2--assert-disposed-slots-cleared (session)
  (should (emacs-jupyter-notebook-helper-session-disposed session))
  (should-not (emacs-jupyter-notebook-helper-session-owner-buffer session))
  (should-not (emacs-jupyter-notebook-helper-session-process session))
  (should-not (emacs-jupyter-notebook-helper-session-stderr-process session))
  (should-not (emacs-jupyter-notebook-helper-session-stderr-buffer session))
  (should-not (emacs-jupyter-notebook-helper-session-decoder session))
  (should-not (emacs-jupyter-notebook-helper-session-hello-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-partial-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-decode-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-drain-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-ping-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-control-timer session))
  (should-not (emacs-jupyter-notebook-helper-session-ping-id session))
  (should-not (emacs-jupyter-notebook-helper-session-requests session))
  (should-not (emacs-jupyter-notebook-helper-session-raw-chunks session))
  (should-not (emacs-jupyter-notebook-helper-session-event-queue session))
  (should-not (emacs-jupyter-notebook-helper-session-priority-queue session))
  (should-not (emacs-jupyter-notebook-helper-session-ready-callback session))
  (should-not (emacs-jupyter-notebook-helper-session-failure-callback session))
  (should-not (emacs-jupyter-notebook-helper-session-closed-callback session)))

(defun ejn-et3--object (&rest pairs)
  "Build a JSON object from string/value PAIRS."
  (let ((object (make-hash-table :test 'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) object))
    object))

(defun ejn-et3--event (seq &optional text)
  "Build one ordinary protocol event with SEQ and TEXT."
  (ejn-et3--object
   "v" 1 "kind" "event" "seq" seq "event" "stream" "request_id" "test"
   "data" (ejn-et3--object "name" "stdout" "text" (or text "x"))))

(defun ejn-et3--feed (session object)
  "Inject one framed helper OBJECT through SESSION's real process filter."
  (emacs-jupyter-notebook-helper--filter
   (emacs-jupyter-notebook-helper-session-process session)
   (ejn-helper-protocol-encode object ejn-helper-protocol-max-to-emacs-frame)))

(cl-defmacro ejn-et3--with-ready ((session scenario &rest options) &body body)
  "Start SESSION against TH1 SCENARIO and wait for its hello drain."
  (declare (indent 1) (debug ((symbolp form &rest form) body)))
  `(let ((ready nil) (failure nil)
         (owner (generate-new-buffer " *ejn-et3-owner*"))
         (emacs-jupyter-notebook-helper-hello-timeout 0.5)
         (emacs-jupyter-notebook-helper--ping-interval 300)
         (emacs-jupyter-notebook-helper-command
          (append (list "python3" ejn-et2--fixture ,scenario) (list ,@options))))
     (unwind-protect
         (let ((,session
                (emacs-jupyter-notebook-helper-start
                 :buffer owner
                 :ready-callback (lambda (_session _reason) (setq ready t))
                 :failure-callback (lambda (_session reason) (setq failure reason)))))
           (should (ejn-et2--await (lambda () (or ready failure)) 1))
           (should ready)
           ,@body)
       (when (buffer-live-p owner) (kill-buffer owner))
       (ejn-et2--clean))))

(ert-deftest ejn-et2-normal-hello-is-binary-and-nonblocking ()
  (ejn-et2--with-session (session "normal")
    (should (processp (emacs-jupyter-notebook-helper-session-process session)))
    (should (equal (process-coding-system
                    (emacs-jupyter-notebook-helper-session-process session))
                   '(binary . binary)))
    (should (ejn-et2--await (lambda () ready)))
    (should (eq (emacs-jupyter-notebook-helper-session-state session) 'ready))
    (should-not failure)
    (emacs-jupyter-notebook-helper-dispose session "test done")
    (ejn-et2--assert-disposed-slots-cleared session)
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et2-resolves-a-configured-symlink-to-stable-argv ()
  (let* ((target (make-temp-file "ejn-et2-helper-target"))
         (link (concat target "-link")))
    (unwind-protect
        (progn
          (set-file-modes target #o700)
          (make-symbolic-link target link)
          (should (equal (emacs-jupyter-notebook-helper-resolve-argv
                          (list link "--flag"))
                         (list (file-truename target) "--flag"))))
      (when (file-exists-p link) (delete-file link))
      (when (file-exists-p target) (delete-file target)))))

(ert-deftest ejn-et2-hello-request-is-the-exact-v1-envelope ()
  (let ((request-log (make-temp-file "ejn-et2-requests")))
    (unwind-protect
        (ejn-et2--with-session (session "normal" "--requests" request-log)
          (should (ejn-et2--await (lambda () ready)))
          (let ((request (json-parse-string
                          (car (split-string (with-temp-buffer
                                               (insert-file-contents request-log)
                                               (buffer-string)) "\n" t))
                          :object-type 'hash-table)))
            (should (= (gethash "v" request) 1))
            (should (equal (gethash "kind" request) "request"))
            (should (equal (gethash "op" request) "hello"))
            (should (equal (gethash "versions" (gethash "params" request)) [1])))
          (emacs-jupyter-notebook-helper-dispose session "test done"))
      (when (file-exists-p request-log) (delete-file request-log)))))

(ert-deftest ejn-et2-version-mismatch-fails-the-th1-normal-handshake ()
  (let ((original (symbol-function 'ejn-helper-protocol-decoder-feed)))
    (cl-letf (((symbol-function 'ejn-helper-protocol-decoder-feed)
               (lambda (decoder bytes)
                 (let ((objects (funcall original decoder bytes)))
                   (dolist (object objects)
                     (when (hash-table-p object)
                       (let ((result (gethash "result" object)))
                         (when (hash-table-p result) (puthash "version" 2 result)))))
                   objects))))
      (ejn-et2--with-session (session "normal")
        (should (ejn-et2--await (lambda () failure)))
        (should-not ready)
        (should (string-match-p "hello" failure))
        (should (emacs-jupyter-notebook-helper-session-disposed session))
        (ejn-et2--assert-no-local-leaks)))))

(ert-deftest ejn-et2-th1-silence-hits-the-hello-deadline ()
  (ejn-et2--with-session (session "silent")
    (should (ejn-et2--await (lambda () failure)))
    (should-not ready)
    (should (string-match-p "timed out" failure))
    (should (emacs-jupyter-notebook-helper-session-disposed session))
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et2-failure-preserves-close-then-failure-callback-order ()
  (let ((emacs-jupyter-notebook-helper-command
         (list "python3" ejn-et2--fixture "silent"))
        (emacs-jupyter-notebook-helper-hello-timeout 0.12)
        (owner (generate-new-buffer " *ejn-et2-callback-owner*"))
        events session)
    (unwind-protect
        (progn
          (setq session
                (emacs-jupyter-notebook-helper-start
                 :buffer owner
                 :closed-callback (lambda (_session _reason) (push 'closed events))
                 :failure-callback (lambda (_session _reason) (push 'failure events))))
          (should (ejn-et2--await (lambda () (= (length events) 2))))
          (should (equal events '(failure closed)))
          (ejn-et2--assert-disposed-slots-cleared session)
          (emacs-jupyter-notebook-helper-dispose session "again")
          (should (equal events '(failure closed)))
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et2-th1-garbage-and-oversize-are-protocol-failures ()
  (dolist (scenario '("garbage" "oversize"))
    (ejn-et2--with-session (session scenario)
      (should (ejn-et2--await (lambda () failure)))
      (should-not ready)
      (should (emacs-jupyter-notebook-helper-session-disposed session))
      (ejn-et2--assert-no-local-leaks))))

(ert-deftest ejn-et2-th1-mid-frame-stop-and-early-exit-fail-locally ()
  (dolist (scenario '("mid-frame-stop" "exit-after-op"))
    (ejn-et2--with-session (session scenario)
      (should (ejn-et2--await (lambda () failure)))
      (should-not ready)
      (should (emacs-jupyter-notebook-helper-session-disposed session))
      (ejn-et2--assert-no-local-leaks))))

(ert-deftest ejn-et2-partial-frame-deadline-is-not-reset-by-silence ()
  (ejn-et2--with-session (session "silent")
    (let* ((response (make-hash-table :test 'equal))
           (result (make-hash-table :test 'equal)))
      (puthash "version" 1 result)
      (puthash "helper_version" "test" result)
      (puthash "capabilities" ["ping"] result)
      (puthash "v" 1 response)
      (puthash "kind" "response" response)
      (puthash "id" (emacs-jupyter-notebook-helper-session-hello-id session) response)
      (puthash "ok" t response)
      (puthash "result" result response)
      (let ((wire (ejn-helper-protocol-encode response 1024)))
        (emacs-jupyter-notebook-helper--filter
         (emacs-jupyter-notebook-helper-session-process session)
         (concat wire (substring wire 0 5)))))
    (should (ejn-et2--await (lambda () failure)))
    (should (string-match-p "partial frame timeout" failure))
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et2-stale-sentinel-cannot-mutate-a-replacement-session ()
  (let ((emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "silent"))
        (emacs-jupyter-notebook-helper-hello-timeout 1)
        (owner (generate-new-buffer " *ejn-et2-owner*")))
    (unwind-protect
        (let* ((first (emacs-jupyter-notebook-helper-start :buffer owner))
               (first-process (emacs-jupyter-notebook-helper-session-process first))
               (second (emacs-jupyter-notebook-helper-start :buffer owner)))
          (emacs-jupyter-notebook-helper--sentinel first-process "finished\n")
          (should (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner) second))
          (should-not (emacs-jupyter-notebook-helper-session-disposed second))
          (emacs-jupyter-notebook-helper-dispose second "test done")
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et2-reentrant-supersede-leaves-only-the-newest-session-live ()
  (let ((emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "silent"))
        (emacs-jupyter-notebook-helper-hello-timeout 1)
        (owner (generate-new-buffer " *ejn-et2-reentrant-owner*"))
        a b c)
    (unwind-protect
        (progn
          (setq a
                (emacs-jupyter-notebook-helper-start
                 :buffer owner
                 :closed-callback
                 (lambda (_session _reason)
                   (setq c (emacs-jupyter-notebook-helper-start :buffer owner)))))
          (setq b (emacs-jupyter-notebook-helper-start :buffer owner))
          (should (emacs-jupyter-notebook-helper-session-disposed a))
          (should (emacs-jupyter-notebook-helper-session-disposed b))
          (should (emacs-jupyter-notebook-helper-session-p c))
          (should-not (emacs-jupyter-notebook-helper-session-disposed c))
          (should (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner) c))
          (should (equal emacs-jupyter-notebook-helper--sessions (list c)))
          (ejn-et2--assert-disposed-slots-cleared a)
          (ejn-et2--assert-disposed-slots-cleared b)
          (should (process-live-p (emacs-jupyter-notebook-helper-session-process c)))
          (emacs-jupyter-notebook-helper-dispose c "test done")
          (ejn-et2--assert-disposed-slots-cleared c)
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et2-dead-owner-is-rejected-before-resource-allocation ()
  (let ((owner (generate-new-buffer " *ejn-et2-dead-owner*"))
        (sessions emacs-jupyter-notebook-helper--sessions)
        (buffers (cl-count-if (lambda (buffer)
                                (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer)))
                              (buffer-list))))
    (kill-buffer owner)
    (should-error (emacs-jupyter-notebook-helper-start :buffer owner))
    (should (equal emacs-jupyter-notebook-helper--sessions sessions))
    (should (= buffers
               (cl-count-if (lambda (buffer)
                              (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer)))
                            (buffer-list))))))

(ert-deftest ejn-et2-kill-buffer-mode-and-emacs-clean-only-local-resources ()
  (let ((emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "silent"))
        (emacs-jupyter-notebook-helper-hello-timeout 1))
    (unwind-protect
        (let ((owner (generate-new-buffer " *ejn-et2-owner*")))
          (let ((session (emacs-jupyter-notebook-helper-start :buffer owner)))
            (kill-buffer owner)
            (should (emacs-jupyter-notebook-helper-session-disposed session))
            (ejn-et2--assert-disposed-slots-cleared session)
            (ejn-et2--assert-no-local-leaks))
          (let ((owner (generate-new-buffer " *ejn-et2-mode-owner*")))
            (with-current-buffer owner (setq-local emacs-jupyter-notebook-mode nil))
            (let ((session (emacs-jupyter-notebook-helper-start :buffer owner)))
              (with-current-buffer owner (emacs-jupyter-notebook-helper--mode-hook))
              (should (emacs-jupyter-notebook-helper-session-disposed session))
              (ejn-et2--assert-disposed-slots-cleared session)
              (kill-buffer owner)
              (ejn-et2--assert-no-local-leaks)))
          (let ((session (emacs-jupyter-notebook-helper-start
                          :buffer (generate-new-buffer " *ejn-et2-exit-owner*"))))
            (emacs-jupyter-notebook-helper--kill-emacs)
            (should (emacs-jupyter-notebook-helper-session-disposed session))
            (ejn-et2--assert-disposed-slots-cleared session)
            (ejn-et2--assert-no-local-leaks)))
      (ejn-et2--clean))))

(ert-deftest ejn-et2-invalid-customization-keeps-hard-bounds ()
  (let ((emacs-jupyter-notebook-helper-hello-timeout nil)
        (emacs-jupyter-notebook-helper-partial-frame-timeout -1)
        (emacs-jupyter-notebook-helper-stderr-max-bytes most-positive-fixnum)
        (emacs-jupyter-notebook-helper-max-to-emacs-frame most-positive-fixnum)
        (emacs-jupyter-notebook-helper-raw-accumulator-max-bytes 1))
    (should (= (emacs-jupyter-notebook-helper--frame-limit) 262144))
    (should (= (emacs-jupyter-notebook-helper--accumulator-limit 262144) 1048576))
    (should (= (emacs-jupyter-notebook-helper--stderr-limit) 65536))
    (should (= (emacs-jupyter-notebook-helper--bounded-positive-number nil 5) 5))
    (should (= (emacs-jupyter-notebook-helper--bounded-positive-number -1 5) 5))))

(ert-deftest ejn-et2-main-process-construction-failure-disposes-stderr-pipe ()
  (let ((emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "silent"))
        (owner (generate-new-buffer " *ejn-et2-owner*")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _arguments) (error "injected main process failure"))))
          (let ((session (emacs-jupyter-notebook-helper-start :buffer owner)))
            (should (emacs-jupyter-notebook-helper-session-disposed session))
            (should-not (process-live-p
                         (emacs-jupyter-notebook-helper-session-stderr-process session)))
            (ejn-et2--assert-no-local-leaks)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et2-stderr-filter-never-inserts-an-oversized-chunk ()
  (let* ((emacs-jupyter-notebook-helper-stderr-max-bytes 32)
         (buffer (generate-new-buffer " *ejn-et2-stderr*"))
         (session (emacs-jupyter-notebook-helper--make-session :stderr-buffer buffer))
         (pipe (make-pipe-process :name "ejn-et2-stderr-pipe" :buffer nil
                                  :coding 'binary :noquery t)))
    (unwind-protect
        (progn
          (process-put pipe 'emacs-jupyter-notebook-helper-session session)
          (emacs-jupyter-notebook-helper--stderr-filter pipe (make-string 4096 ?x))
          (should (= (buffer-size buffer) 32))
          (emacs-jupyter-notebook-helper--stderr-filter pipe (make-string 4096 ?y))
          (should (= (buffer-size buffer) 32))
          (with-current-buffer buffer
            (should (string= (buffer-string) (make-string 32 ?y)))))
      (when (process-live-p pipe) (delete-process pipe))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ejn-et2-stderr-filter-bounds-hostile-multibyte-input-before-encoding ()
  (let* ((emacs-jupyter-notebook-helper-stderr-max-bytes 32)
         (buffer (generate-new-buffer " *ejn-et2-multibyte-stderr*"))
         (session (emacs-jupyter-notebook-helper--make-session :stderr-buffer buffer))
         (pipe (make-pipe-process :name "ejn-et2-multibyte-stderr-pipe" :buffer nil
                                  :coding 'binary :noquery t)))
    (unwind-protect
        (progn
          (process-put pipe 'emacs-jupyter-notebook-helper-session session)
          (emacs-jupyter-notebook-helper--stderr-filter pipe (make-string 100000 ?\u03c0))
          (should (= (buffer-size buffer) 32))
          (with-current-buffer buffer
            (should-not (multibyte-string-p (buffer-string)))))
      (when (process-live-p pipe) (delete-process pipe))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ejn-et3-filter-defers-event-callbacks-and-isolates-throws ()
  (let ((events nil)
        (owner (generate-new-buffer " *ejn-et3-callback-owner*"))
        (emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "normal"))
        (emacs-jupyter-notebook-helper--ping-interval 300))
    (unwind-protect
        (let* ((ready nil)
              (session (emacs-jupyter-notebook-helper-start
                        :buffer owner
                        :ready-callback (lambda (&rest _) (setq ready t))
                        :event-callback
                        (lambda (_session event)
                          (push (gethash "seq" event) events)
                          (when (= (gethash "seq" event) 1) (error "injected callback failure"))))))
          (should (ejn-et2--await (lambda () ready)))
          (ejn-et3--feed session (ejn-et3--event 1))
          (ejn-et3--feed session (ejn-et3--event 2))
          (should-not events)
          (should (ejn-et2--await (lambda () (= (length events) 2))))
          (should (equal (sort events #'<) '(1 2)))
          (emacs-jupyter-notebook-helper-dispose session "test done")
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et3-th1-flood-keeps-an-independent-timer-running ()
  (let ((ticks 0)
        (timer nil)
        (events 0)
        (owner (generate-new-buffer " *ejn-et3-flood-owner*"))
        (emacs-jupyter-notebook-helper-command
         (list "python3" ejn-et2--fixture "flood" "--count" "128"))
        (emacs-jupyter-notebook-helper--ping-interval 300))
    (unwind-protect
        (let ((session (emacs-jupyter-notebook-helper-start
                        :buffer owner :event-callback (lambda (&rest _) (cl-incf events)))))
          (setq timer (run-at-time 0.005 0.005 (lambda () (cl-incf ticks))))
          (should (ejn-et2--await
                   (lambda () (and (= events 128)
                                    (= (emacs-jupyter-notebook-helper-session-control-acked session) 129))) 2))
          (should (> ticks 0))
          (should (eq (emacs-jupyter-notebook-helper-session-state session) 'ready))
          (emacs-jupyter-notebook-helper-dispose session "test done")
          (ejn-et2--assert-no-local-leaks))
      (when (timerp timer) (cancel-timer timer))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et3-request-timeout-late-and-duplicate-responses-are-bounded ()
  (let ((callback-count 0)
        (late-count 0))
    (ejn-et3--with-ready (session "normal")
      (let ((id nil))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper--send-envelope)
                   (lambda (&rest _) nil)))
          (setq id (emacs-jupyter-notebook-helper-request
                    session "ping" (make-hash-table :test 'equal)
                    (lambda (_session _response error)
                      (when error (cl-incf callback-count)))
                    :timeout 0.02)))
        (should (ejn-et2--await (lambda () (= callback-count 1))))
        (ejn-et3--feed session
                        (ejn-et3--object "v" 1 "kind" "response" "id" id "ok" t
                                         "result" (make-hash-table :test 'equal)))
        (should (ejn-et2--await
                 (lambda () (emacs-jupyter-notebook-helper-session-late-responses session)) 1))
        (setq late-count (length (emacs-jupyter-notebook-helper-session-late-responses session)))
        (should (= callback-count 1))
        (dotimes (_ 100)
          (ejn-et3--feed session
                          (ejn-et3--object "v" 1 "kind" "response" "id" "duplicate"
                                           "ok" t "result" (make-hash-table :test 'equal))))
        (should (ejn-et2--await
                 (lambda () (> (length (emacs-jupyter-notebook-helper-session-late-responses session)) late-count))))
        (should (<= (length (emacs-jupyter-notebook-helper-session-late-responses session)) 64))
        (should (= callback-count 1))))))

(ert-deftest ejn-et3-credit-is-exact-and-responses-run-at-zero-credit ()
  (let ((request-log (make-temp-file "ejn-et3-credit"))
        (events 0) (response-count 0))
    (unwind-protect
        (let ((owner (generate-new-buffer " *ejn-et3-credit-owner*"))
              (ready nil)
              (emacs-jupyter-notebook-helper-command
               (list "python3" ejn-et2--fixture "normal" "--requests" request-log))
              (emacs-jupyter-notebook-helper--ping-interval 300))
          (unwind-protect
              (let ((session (emacs-jupyter-notebook-helper-start
                              :buffer owner
                              :ready-callback (lambda (&rest _) (setq ready t))
                              :event-callback (lambda (&rest _) (cl-incf events)))))
                (should (ejn-et2--await (lambda () ready)))
                (setf (emacs-jupyter-notebook-helper-session-event-credit session) 0)
                (let ((id (emacs-jupyter-notebook-helper-request
                           session "ping" (make-hash-table :test 'equal)
                           (lambda (_session response error)
                             (should response) (should-not error) (cl-incf response-count))
                           :timeout 0.5)))
                  (ignore id)
                  (should (ejn-et2--await (lambda () (= response-count 1)))))
                (setf (emacs-jupyter-notebook-helper-session-event-credit session) 262144)
                (let* ((event (ejn-et3--event 1 "credited"))
                       (bytes (length (ejn-helper-protocol-encode event 262144))))
                  (ejn-et3--feed session event)
                  (should (ejn-et2--await (lambda () (= events 1))))
                  (should (= (emacs-jupyter-notebook-helper-session-event-credit session) 262144))
                  (should (ejn-et2--await
                           (lambda ()
                             (with-temp-buffer
                               (insert-file-contents request-log)
                               (string-match-p (format "\\\"bytes\\\":%d" bytes) (buffer-string)))))))
                (emacs-jupyter-notebook-helper-dispose session "test done")
                (ejn-et2--assert-no-local-leaks))
            (when (buffer-live-p owner) (kill-buffer owner))
            (ejn-et2--clean)))
      (when (file-exists-p request-log) (delete-file request-log)))))

(ert-deftest ejn-et3-rejects-pregrant-and-aggregate-over-credit-arrivals ()
  (let ((owner (generate-new-buffer " *ejn-et3-pregrant-owner*"))
        (emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "silent")))
    (unwind-protect
        (let ((session (emacs-jupyter-notebook-helper-start :buffer owner)))
          (ejn-et3--feed session (ejn-et3--event 1))
          (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean)))
  (ejn-et3--with-ready (session "normal")
    (let* ((event (ejn-et3--event 1))
           (bytes (length (ejn-helper-protocol-encode event 262144))))
      (setf (emacs-jupyter-notebook-helper-session-event-credit session) bytes)
      (ejn-et3--feed session event)
      (ejn-et3--feed session (ejn-et3--event 2))
      (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
      (ejn-et2--assert-no-local-leaks))))

(ert-deftest ejn-et3-control-acks-are-ordered-and-never-late-logged ()
  (ejn-et3--with-ready (session "normal")
    (should (ejn-et2--await
             (lambda () (= (emacs-jupyter-notebook-helper-session-control-acked session) 1))))
    (should-not (emacs-jupyter-notebook-helper-session-late-responses session))
    (ejn-et3--feed session
                    (ejn-et3--object "v" 1 "kind" "response"
                                     "id" (format "ejn-control-%d-1"
                                                  (emacs-jupyter-notebook-helper-session-id session))
                                     "ok" t "result" (make-hash-table :test 'equal)))
    (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
    (ejn-et2--assert-no-local-leaks))
  (ejn-et3--with-ready (session "normal")
    (setf (emacs-jupyter-notebook-helper-session-control-sent session) 2)
    (ejn-et3--feed session
                    (ejn-et3--object "v" 1 "kind" "response"
                                     "id" (format "ejn-control-%d-2"
                                                  (emacs-jupyter-notebook-helper-session-id session))
                                     "ok" :false "error" (make-hash-table :test 'equal)))
    (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))))

(ert-deftest ejn-et3-credit-ack-deadline-survives-successful-ping ()
  (let ((owner (generate-new-buffer " *ejn-et3-credit-deadline-owner*"))
        (ready nil) (ping-replied nil)
        (emacs-jupyter-notebook-helper-command
         (list "python3" ejn-et2--fixture "normal" "--omit-credit-ack"))
        (emacs-jupyter-notebook-helper--control-ack-timeout 0.12)
        (emacs-jupyter-notebook-helper--ping-interval 300))
    (unwind-protect
        (let ((session (emacs-jupyter-notebook-helper-start
                        :buffer owner :ready-callback (lambda (&rest _) (setq ready t)))))
          (should (ejn-et2--await (lambda () ready)))
          (emacs-jupyter-notebook-helper-request
           session "ping" (make-hash-table :test 'equal)
           (lambda (_ response error) (setq ping-replied (and response (not error))))
           :timeout 0.5)
          (should (ejn-et2--await (lambda () ping-replied)))
          (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session)) 1))
          (ejn-et2--assert-disposed-slots-cleared session)
          (ejn-et2--assert-no-local-leaks))
      (when (buffer-live-p owner) (kill-buffer owner))
      (ejn-et2--clean))))

(ert-deftest ejn-et3-malformed-arrivals-and-priority-reordering-are-safe ()
  (dolist (object (list (ejn-et3--object "v" 2 "kind" "response" "id" "x" "ok" t "result" (make-hash-table :test 'equal))
                        (ejn-et3--object "v" 1 "kind" "bogus")
                        (ejn-et3--object "v" 1 "kind" "response" "id" 1 "ok" t "result" (make-hash-table :test 'equal))
                        (ejn-et3--object "v" 1 "kind" "response" "id" (make-string 129 #x00e9)
                                         "ok" t "result" (make-hash-table :test 'equal))
                        (ejn-et3--object "v" 1 "kind" "event" "seq" 1 "event" "stream"
                                         "request_id" "" "data" (make-hash-table :test 'equal))
                        (ejn-et3--object "v" 1 "kind" "event" "seq" 1 "event" "stream"
                                         "request_id" (make-string 129 #x00e9)
                                         "data" (make-hash-table :test 'equal))
                        (ejn-et3--object "v" 1 "kind" "event" "seq" 1 "event" "stream" "data" (make-hash-table :test 'equal))))
    (ejn-et3--with-ready (session "normal")
      (ejn-et3--feed session object)
      (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))))
  (let ((seen nil) (owner (generate-new-buffer " *ejn-et3-order-owner*"))
        (emacs-jupyter-notebook-helper-command (list "python3" ejn-et2--fixture "normal"))
        (emacs-jupyter-notebook-helper--ping-interval 300))
    (unwind-protect
        (let* ((ready nil)
               (session (emacs-jupyter-notebook-helper-start
                         :buffer owner :ready-callback (lambda (&rest _) (setq ready t))
                         :event-callback (lambda (_ event) (push (gethash "seq" event) seen)))))
          (should (ejn-et2--await (lambda () ready)))
          (ejn-et3--feed session (ejn-et3--event 1))
          (ejn-et3--feed session (ejn-et3--object "v" 1 "kind" "event" "seq" 2 "event" "status"
                                                   "request_id" "test" "data" (make-hash-table :test 'equal)))
          (ejn-et3--feed session (ejn-et3--object "v" 1 "kind" "event" "seq" 3
                                                   "event" "transport_error"
                                                   "data" (make-hash-table :test 'equal)))
          (should (ejn-et2--await (lambda () (= (length seen) 3))))
          (should (equal seen '(1 3 2)))
          (emacs-jupyter-notebook-helper-dispose session "test done"))
      (when (buffer-live-p owner) (kill-buffer owner)) (ejn-et2--clean))))

(ert-deftest ejn-et3-rejects-duplicate-and-out-of-order-event-sequences ()
  (dolist (sequence '(2 1))
    (ejn-et3--with-ready (session "normal")
      (setf (emacs-jupyter-notebook-helper-session-last-event-seq session) 2)
      (ejn-et3--feed session (ejn-et3--event sequence))
      (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session)))))))

(ert-deftest ejn-et3-queue-and-raw-overflow-fail-through-the-drain ()
  (ejn-et3--with-ready (session "normal")
    (setf (emacs-jupyter-notebook-helper-session-event-queue-bytes session)
          emacs-jupyter-notebook-helper--max-event-queue)
    (ejn-et3--feed session (ejn-et3--event 1))
    (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
    (ejn-et2--assert-no-local-leaks))
  (ejn-et3--with-ready (session "normal")
    (emacs-jupyter-notebook-helper--filter
     (emacs-jupyter-notebook-helper-session-process session)
     (make-string (1+ ejn-helper-protocol-max-raw-accumulator) ?x))
    (should-not (emacs-jupyter-notebook-helper-session-disposed session))
    (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et3-death-fails-pending-ping-and-stale-ticks-cannot-revive ()
  (let ((callbacks 0))
    (ejn-et3--with-ready (session "normal")
      (let* ((id "pending")
             (request (emacs-jupyter-notebook-helper--make-request
                       :id id :callback (lambda (&rest _) (cl-incf callbacks))))
             (requests (emacs-jupyter-notebook-helper-session-requests session))
             (process (emacs-jupyter-notebook-helper-session-process session)))
        (puthash id request requests)
        (emacs-jupyter-notebook-helper--sentinel process "killed\n")
        (should (= callbacks 1))
        (should (emacs-jupyter-notebook-helper-session-disposed session))
        (emacs-jupyter-notebook-helper--ping-tick session)
        (should-not (emacs-jupyter-notebook-helper-session-ping-id session))
        (ejn-et2--assert-no-local-leaks)))))

(ert-deftest ejn-et3-ping-timeout-disposes-a-live-but-silent-loop ()
  (ejn-et3--with-ready (session "normal")
    (let ((emacs-jupyter-notebook-helper--ping-timeout 0.02))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper--send-envelope)
                 (lambda (&rest _) nil)))
        (emacs-jupyter-notebook-helper--ping-tick session)
        (should (ejn-et2--await
                 (lambda () (emacs-jupyter-notebook-helper-session-disposed session)) 1))))
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et3-ping-reserves-capacity-after-seven-ordinary-requests ()
  (ejn-et3--with-ready (session "normal")
    (let ((ordinary 0)
          (emacs-jupyter-notebook-helper--ping-timeout 0.02))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper--send-envelope)
                 (lambda (&rest _) nil)))
        (dotimes (_ 7)
          (emacs-jupyter-notebook-helper-request
           session "ping" (make-hash-table :test 'equal)
           (lambda (&rest _) (cl-incf ordinary)) :timeout 1))
        (should-error (emacs-jupyter-notebook-helper-request
                       session "ping" (make-hash-table :test 'equal) (lambda (&rest _))))
        (emacs-jupyter-notebook-helper--ping-tick session)
        (should (ejn-et2--await (lambda () (emacs-jupyter-notebook-helper-session-disposed session))))
        (should (= ordinary 7))))
    (ejn-et2--assert-no-local-leaks)))

(ert-deftest ejn-et2-supervisor-has-no-durable-state-or-wait-loop ()
  (let ((source (with-temp-buffer
                  (insert-file-contents (expand-file-name "emacs-jupyter-notebook-helper.el" ejn-et2--root))
                  (buffer-string))))
    (should-not (string-match-p "accept-process-output\\|sleep-for\\|registry-\\|jupyter-shutdown\\|cleanup-remote" source))))

(provide 'emacs-jupyter-notebook-helper-process-tests)
;;; emacs-jupyter-notebook-helper-process-tests.el ends here
