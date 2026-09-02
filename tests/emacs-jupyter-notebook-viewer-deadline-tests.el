;;; emacs-jupyter-notebook-viewer-deadline-tests.el --- Viewer hand-off deadline tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Deterministic lifecycle tests for the local viewer's bounded artifact
;; hand-off.  They use only mock timers and pipe processes; no GUI, socket
;; server, Jupyter package, or remote host is involved.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-viewer)

(defun ejn-viewer-deadline--pickle ()
  "Return a syntactically valid confined pickle descriptor for mock sends."
  '(:root "/tmp/root"
    :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
    :root-identity (7 . 11)
    :identity (7 . 12)
    :size 3
    :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))

(defun ejn-viewer-deadline--timer-record (records seconds)
  "Return the first timer record in RECORDS scheduled after SECONDS."
  (cl-find-if (lambda (record) (= (plist-get record :seconds) seconds)) records))

(ert-deftest ejn-viewer-deadline-effective-options-are-finite-and-bounded ()
  "Malformed viewer retry settings must never create runaway timer schedules."
  (dolist (value (list nil "bad" -1 0 1.5 1.0e+INF 0.0e+NaN))
    (let ((emacs-jupyter-notebook-viewer-send-max-attempts value))
      (should (= (emacs-jupyter-notebook-viewer--effective-send-max-attempts) 25))))
  (let ((emacs-jupyter-notebook-viewer-send-max-attempts most-positive-fixnum))
    (should (= (emacs-jupyter-notebook-viewer--effective-send-max-attempts)
               emacs-jupyter-notebook-viewer--send-max-attempts-hard-limit)))
  (dolist (value (list nil "bad" -1 0 0.0e+NaN 1.0e+INF))
    (let ((emacs-jupyter-notebook-viewer-send-retry-delay value))
      (should (= (emacs-jupyter-notebook-viewer--effective-send-retry-delay) 0.15))))
  (let ((emacs-jupyter-notebook-viewer-send-retry-delay 1.0e-100))
    (should (= (emacs-jupyter-notebook-viewer--effective-send-retry-delay) 0.025)))
  (let ((emacs-jupyter-notebook-viewer-send-retry-delay most-positive-fixnum))
    (should (= (emacs-jupyter-notebook-viewer--effective-send-retry-delay)
               emacs-jupyter-notebook-viewer--send-retry-delay-hard-limit))))

(ert-deftest ejn-viewer-deadline-timer-construction-failure-releases-without-spawn ()
  "Failure to construct the transaction deadline must settle the hand-off once."
  (let ((emacs-jupyter-notebook-viewer--active-transaction nil)
        (completions nil)
        (spawns 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (error "timer construction failed")))
              ((symbol-function 'emacs-jupyter-notebook-viewer-ensure)
               (lambda () (cl-incf spawns))))
      (emacs-jupyter-notebook-viewer-open-pickle-file
       (ejn-viewer-deadline--pickle)
       (lambda (accepted) (push accepted completions))))
    (should (equal completions '(nil)))
    (should-not emacs-jupyter-notebook-viewer--active-transaction)
    (should (= spawns 0))))

(ert-deftest ejn-viewer-deadline-total-timeout-is-terminal-and-late-events-inert ()
  "Total timeout completes once; its old retry and ACK cannot revive state."
  (let ((real-delete-process (symbol-function 'delete-process))
        (schedules nil)
        (connections 0)
        (completions nil)
        connection
        (socket-path (make-temp-file "ejn-viewer-deadline-socket-")))
    (unwind-protect
        (let ((emacs-jupyter-notebook-viewer--active-transaction nil)
              (emacs-jupyter-notebook-viewer--socket-path socket-path)
              (emacs-jupyter-notebook-viewer--next-request-id 0)
              (emacs-jupyter-notebook-viewer-send-max-attempts 3)
              (emacs-jupyter-notebook-viewer-send-retry-delay 0.15))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-ensure)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-viewer-live-p)
                     (lambda () t))
                    ((symbol-function 'make-network-process)
                     (lambda (&rest _)
                       (cl-incf connections)
                       (if (= connections 1)
                           (error "socket is not ready")
                         (setq connection
                               (make-pipe-process :name "ejn-viewer-deadline"
                                                  :buffer nil :noquery t)))))
                    ((symbol-function 'process-send-string) (lambda (&rest _) nil))
                    ;; Retain the process filter after timeout to model an ACK
                    ;; that was already queued by the event loop.
                    ((symbol-function 'delete-process) (lambda (&rest _) nil))
                    ((symbol-function 'run-at-time)
                     (lambda (seconds _repeat function &rest args)
                       (let ((timer (timer-create)))
                         (push (list :seconds seconds :function function
                                     :args args :timer timer)
                               schedules)
                         timer))))
            (emacs-jupyter-notebook-viewer-open-pickle-file
             (ejn-viewer-deadline--pickle)
             (lambda (accepted) (push accepted completions)))
            (let* ((deadline
                    (ejn-viewer-deadline--timer-record
                     schedules emacs-jupyter-notebook-viewer--send-transaction-timeout))
                   (retry (ejn-viewer-deadline--timer-record schedules 0.15)))
              (should deadline)
              (should retry)
              (funcall (plist-get retry :function))
              (should (= connections 2))
              (let ((filter (process-filter connection)))
                (should filter)
                (funcall (plist-get deadline :function))
                (should (equal completions '(nil)))
                (should-not emacs-jupyter-notebook-viewer--active-transaction)
                ;; Both callbacks were captured while the transaction was
                ;; live.  The deadline must make them inert forever.
                (funcall (plist-get retry :function))
                (funcall filter connection "{\"id\":\"v1\",\"accepted\":true}\n")
                (should (= connections 2))
                (should (equal completions '(nil)))))))
      (when (process-live-p connection)
        (funcall real-delete-process connection))
      (ignore-errors (delete-file socket-path)))))

(ert-deftest ejn-viewer-deadline-reap-cancels-attempt-and-total-timers ()
  "Reaping a viewer releases the hand-off lease and cancels both timers once."
  (let* ((real-cancel-timer (symbol-function 'cancel-timer))
         (attempt-timer (timer-create))
         (deadline-timer (timer-create))
         (cancelled nil)
         (completed 0)
         (state (list :pickle (ejn-viewer-deadline--pickle)
                      :completion (lambda (_accepted) (cl-incf completed))
                      :attempt 0 :token 0 :timer attempt-timer
                      :deadline-timer deadline-timer :connection nil :done nil)))
    (let ((emacs-jupyter-notebook-viewer--active-transaction state)
          (emacs-jupyter-notebook-viewer--process nil)
          (emacs-jupyter-notebook-viewer--socket-path nil)
          (emacs-jupyter-notebook-viewer--socket-directory nil)
          (emacs-jupyter-notebook-viewer--socket-directory-identity nil)
          (emacs-jupyter-notebook-viewer--stdout-buffer nil)
          (emacs-jupyter-notebook-viewer--stderr-buffer nil)
          (emacs-jupyter-notebook-viewer--stderr-process nil)
          (kill-emacs-hook nil))
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (timer)
                   (push timer cancelled)
                   (funcall real-cancel-timer timer))))
        (emacs-jupyter-notebook-viewer-reap)
        (emacs-jupyter-notebook-viewer-reap))
      (should (= completed 1))
      (should-not emacs-jupyter-notebook-viewer--active-transaction)
      (should (= (length cancelled) 2))
      (should (memq attempt-timer cancelled))
      (should (memq deadline-timer cancelled)))))

(provide 'emacs-jupyter-notebook-viewer-deadline-tests)

;;; emacs-jupyter-notebook-viewer-deadline-tests.el ends here
