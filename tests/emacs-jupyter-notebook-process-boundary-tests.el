;;; emacs-jupyter-notebook-process-boundary-tests.el --- Process boundary tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'emacs-jupyter-notebook-ssh)
(require 'emacs-jupyter-notebook-helper)

(defun ejn-process-boundary-test--dispose-ssh (process)
  "Dispose PROCESS and both output buffers used by the SSH constructor."
  (when (processp process)
    (when (process-live-p process)
      (set-process-sentinel process #'ignore)
      (delete-process process))
    (dolist (buffer (list (process-buffer process)
                          (process-get
                           process
                           'emacs-jupyter-notebook-stderr-buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ejn-process-boundary-ssh-start-process-bounds-at-creation ()
  "The generic SSH constructor installs its bounded filter immediately."
  (let (process)
    (unwind-protect
        (progn
          (setq process
                (emacs-jupyter-notebook-ssh-start-process
                 "ejn-boundary-ssh"
                 '("sh" "-c" "head -c 50000 /dev/zero")
                 #'ignore 32))
          (should (functionp (process-filter process)))
          (while (process-live-p process)
            (accept-process-output process 0.05))
          (should (process-get process 'ejn-output-overflow))
          (should (<= (with-current-buffer (process-buffer process)
                        (buffer-size))
                      32))
          (should (<= (with-current-buffer
                          (process-get process
                                       'emacs-jupyter-notebook-stderr-buffer)
                        (buffer-size))
                      32)))
      (ejn-process-boundary-test--dispose-ssh process))))

(ert-deftest ejn-process-boundary-helper-rejects-oversized-multibyte-before-encoding ()
  "An oversized unexpected multibyte chunk never reaches conversion."
  (let ((emacs-jupyter-notebook-helper-max-to-emacs-frame 1024)
        (emacs-jupyter-notebook-helper-raw-accumulator-max-bytes 1024)
        (owner nil)
        process session
        encoded)
    (unwind-protect
        (progn
          (setq process
                (make-pipe-process :name "ejn-boundary-helper"
                                   :buffer nil :coding 'binary :noquery t))
          (setq session
                (emacs-jupyter-notebook-helper--make-session
                 :process process
                 :owner-buffer owner
                 :decoder (ejn-helper-protocol-make-decoder 1024 1024)
                 :state 'ready
                 :raw-bytes 0))
          (process-put process
                       'emacs-jupyter-notebook-helper-session session)
          (cl-letf (((symbol-function 'encode-coding-string)
                     (lambda (&rest _args)
                       (setq encoded t)
                       (error "unexpected conversion"))))
            (emacs-jupyter-notebook-helper--filter
             process (make-string 1025 ?\u03c0)))
          (should-not encoded)
          (should (equal
                   (emacs-jupyter-notebook-helper-session-pending-failure session)
                   "helper raw accumulator exceeded"))
          (should (= (emacs-jupyter-notebook-helper-session-raw-bytes session)
                     0)))
      (when session
        (emacs-jupyter-notebook-helper-dispose
         session "process boundary test cleanup"))
      (when (and process (process-live-p process))
        (delete-process process)))))

(ert-deftest ejn-process-boundary-management-defers-terminal-during-setup ()
  "A child exit inside its constructor is delivered after callbacks exist."
  (let* ((buffer (generate-new-buffer " *ejn-management-fast-exit*"))
         (process (make-process
                   :name "ejn-management-fast-exit"
                   :buffer buffer :command '("sh" "-c" "exit 0")
                   :connection-type 'pipe :noquery t :sentinel #'ignore))
         (successes 0)
         (failures 0))
    (unwind-protect
        (progn
          (while (process-live-p process)
            (accept-process-output process 0.01))
          (cl-letf (((symbol-function
                      'emacs-jupyter-notebook-ssh-start-process)
                     (lambda (_name _argv sentinel &optional _limit)
                       (funcall sentinel process "finished\n")
                       process)))
            (should
             (eq process
                 (emacs-jupyter-notebook-ssh-start-management-operation
                  "ignored" '("ignored")
                  (lambda (_output) (cl-incf successes))
                  (lambda (&rest _) (cl-incf failures))
                  1))))
          (should (= successes 1))
          (should (= failures 0))
          (should (process-get process 'ejn-management-finished))
          (should-not (process-get process 'ejn-management-timeout))
          (should-not (buffer-live-p buffer)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ejn-process-boundary-management-watchdog-failure-reaps-child ()
  "A watchdog setup failure cannot leave a management child running."
  (let (process returned stdout stderr (failures 0) reason)
    (unwind-protect
        (let ((real-start
               (symbol-function 'emacs-jupyter-notebook-ssh-start-process)))
          (cl-letf (((symbol-function
                     'emacs-jupyter-notebook-ssh-start-process)
                     (lambda (&rest args)
                       (setq process (apply real-start args)
                             stdout (process-buffer process)
                             stderr
                             (process-get
                              process
                              'emacs-jupyter-notebook-stderr-buffer))
                       process))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _)
                       (error "injected management watchdog setup failure"))))
            (setq returned
                  (emacs-jupyter-notebook-ssh-start-management-operation
                   "ejn-management-watchdog-failure"
                   '("sh" "-c" "sleep 2")
                   (lambda (&rest _) (ert-fail "setup failure cannot succeed"))
                   (lambda (why _stderr)
                     (setq reason why)
                     (cl-incf failures))
                   1)))
          (should (eq process returned))
          (should (= failures 1))
          (should (eq reason 'failed))
          (should-not (process-live-p process))
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr))
          (should-not (process-get process 'ejn-management-timeout)))
      (ejn-process-boundary-test--dispose-ssh process))))

(provide 'emacs-jupyter-notebook-process-boundary-tests)

;;; emacs-jupyter-notebook-process-boundary-tests.el ends here
