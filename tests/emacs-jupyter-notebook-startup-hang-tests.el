;;; emacs-jupyter-notebook-startup-hang-tests.el --- Deferred startup prompts -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defmacro ejn-hang-startup--with-missing-host (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (setq buffer-file-name "/tmp/ejn-hang-startup.py")
     (let ((emacs-jupyter-notebook-remote-profiles '(("missing" . (:kernelspec "python3"))))
           prompted deferred resolved cleaned failure)
       (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-selected-backend) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook--ensure-clean-before-start)
                  (lambda () (setq cleaned t)))
                 ((symbol-function 'emacs-jupyter-notebook-ui-defer)
                  (lambda (&rest args) (setq deferred args)))
                 ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
                  (lambda (&rest _)
                    (setq prompted t)
                    '(:profile "missing" :host "example.invalid" :remote-cwd "~"
                      :remote-cache-dir "~/.cache/ejn" :kernelspec "python3")))
                 ((symbol-function 'emacs-jupyter-notebook--async-resolve-kernelspec)
                  (lambda (context) (setq resolved context)))
                 ((symbol-function 'run-at-time)
                  (lambda (&rest _) (timer-create))))
         (unwind-protect
             (progn ,@body)
           (when emacs-jupyter-notebook--async-context
             (emacs-jupyter-notebook--async-cancel-overall-timer
              emacs-jupyter-notebook--async-context))
           (emacs-jupyter-notebook-ui-cancel))))))

(ert-deftest ejn-hang-startup-missing-host-yields-before-prompt-or-transport ()
  (ejn-hang-startup--with-missing-host
    (let ((context (emacs-jupyter-notebook--start-remote-kernel-admitted "missing")))
      (should-not prompted)
      (should-not cleaned)
      (should-not resolved)
      (should (eq context emacs-jupyter-notebook--async-context))
      (should (eq (plist-get context :phase) 'host-input))
      (should (timerp (plist-get context :overall-timer)))
      (should (eq (car deferred) (current-buffer)))
      (should (funcall (nth 1 deferred)))
      (funcall (nth 2 deferred))
      (should prompted)
      (should cleaned)
      (should (eq resolved context))
      (should (equal (plist-get (plist-get context :profile) :host) "example.invalid")))))

(ert-deftest ejn-hang-startup-missing-host-retains-preflight-identity-and-deadline ()
  (ejn-hang-startup--with-missing-host
    (let* ((deadline (+ (float-time) 120))
           (timer (timer-create))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'registry-start-preflight
                     :overall-timer timer :overall-deadline deadline :callback #'ignore)))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--start-remote-kernel-admitted "missing" nil nil context)
      (should-not prompted)
      (should (eq context emacs-jupyter-notebook--async-context))
      (should (eq timer (plist-get context :overall-timer)))
      (should (= deadline (plist-get context :overall-deadline)))
      (should (eq #'ignore (plist-get context :callback)))
      (funcall (nth 2 deferred))
      (should (eq resolved context))
      (should (eq timer (plist-get context :overall-timer))))))

(ert-deftest ejn-hang-startup-missing-host-rechecks-after-user-input ()
  (ejn-hang-startup--with-missing-host
    (emacs-jupyter-notebook--start-remote-kernel-admitted "missing")
    (should deferred)
    (let ((old-context emacs-jupyter-notebook--async-context)
          (new-context '(:phase resolve)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
                 (lambda (&rest _)
                   (setq emacs-jupyter-notebook--async-context new-context)
                   '(:profile "missing" :host "example.invalid"))))
        (funcall (nth 2 deferred)))
      (should-not resolved)
      (should-not cleaned)
      (should (eq new-context emacs-jupyter-notebook--async-context))
      (should-not (funcall (nth 1 deferred)))
      (when (timerp (plist-get old-context :overall-timer))
        (cancel-timer (plist-get old-context :overall-timer))))))

(ert-deftest ejn-hang-startup-quitting-host-input-retires-local-attempt ()
  (ejn-hang-startup--with-missing-host
    (let ((context
           (emacs-jupyter-notebook--start-remote-kernel-admitted
            "missing" nil (lambda (_context reason) (setq failure reason)))))
      (should deferred)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
                 (lambda (&rest _) (signal 'quit nil))))
        (funcall (nth 2 deferred)))
      (should failure)
      (should (plist-get context :cancelled))
      (should-not emacs-jupyter-notebook--async-context)
      (should-not (plist-get context :overall-timer))
      (should-not resolved)
      (should-not cleaned))))

(provide 'emacs-jupyter-notebook-startup-hang-tests)
;;; emacs-jupyter-notebook-startup-hang-tests.el ends here
