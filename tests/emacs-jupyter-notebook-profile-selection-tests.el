;;; emacs-jupyter-notebook-profile-selection-tests.el --- Failed-start choices -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise public starts and evaluation through real local acquisition state.
;; Only external registry/runtime/resolver boundaries are replaced.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defmacro ejn-cc27--with-profiles (&rest body)
  "Run BODY in a clean source with controlled external launch boundaries."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name "/tmp/ejn-cc27.py"
           emacs-jupyter-notebook-mode t)
     (insert "# %%\nvalue = 42\n")
     (set-buffer-modified-p nil)
     (let ((emacs-jupyter-notebook-default-profile "default")
           (emacs-jupyter-notebook-remote-profiles
            '(("default" :host "default.invalid")
              ("chosen" :host "chosen.invalid")
              ("second" :host "second.invalid")))
           (emacs-jupyter-notebook-auto-reconnect nil)
           (original-timers (copy-sequence timer-list))
           (original-processes (process-list))
           attempts registry-entry)
       (cl-letf (((symbol-function 'emacs-jupyter-notebook--runtime-ready-p)
                  (lambda () t))
                 ((symbol-function 'emacs-jupyter-notebook--ensure-selected-backend)
                  #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-registry-read-async)
                  (lambda (success _failure &rest _)
                    (funcall success (and registry-entry (list registry-entry)) nil)
                    nil))
                 ((symbol-function 'emacs-jupyter-notebook--async-resolve-kernelspec)
                  (lambda (context) (push context attempts)))
                 ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-invalidate) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-variables-execution-finished)
                  #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore)
                 ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                  (lambda (&rest _) (ert-fail "Executed without a connected kernel")))
                 ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                  (lambda (&rest _) (ert-fail "Terminated a remote kernel"))))
         (unwind-protect
             (progn ,@body
                    (should (equal (buffer-string) "# %%\nvalue = 42\n"))
                    (should-not (buffer-modified-p))
                    (should (equal emacs-jupyter-notebook-default-profile "default")))
           (emacs-jupyter-notebook--release-local-resources)
           (emacs-jupyter-notebook--kill-panel)
           (should-not (cl-set-difference (process-list) original-processes))
           (should-not
            (cl-remove-if
             (lambda (timer) (eq (timer--function timer) #'undo-auto--boundary-timer))
             (cl-set-difference timer-list original-timers))))))))

(defun ejn-cc27--fail-start (context)
  "Fail the exact pending resolver CONTEXT without a remote launch."
  (emacs-jupyter-notebook--async-fail context "Resolver command failed"))

(ert-deftest ejn-cc27-failed-start-keeps-profile-for-all-evaluation-commands ()
  (ejn-cc27--with-profiles
    (emacs-jupyter-notebook-start-remote-kernel "chosen")
    (ejn-cc27--fail-start (car attempts))
    (dolist (evaluate (list #'emacs-jupyter-notebook-send-cell
                           (lambda () (emacs-jupyter-notebook-send-region
                                       (point-min) (point-max)))
                           #'emacs-jupyter-notebook-send-buffer))
      (funcall evaluate)
      (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                     "chosen"))
      (should (equal (plist-get (plist-get (car attempts) :profile) :host)
                     "chosen.invalid"))
      (ejn-cc27--fail-start (car attempts)))
    (should (= (length attempts) 4))))

(ert-deftest ejn-cc27-prefix-evaluation-remembers-choice-after-failure ()
  (ejn-cc27--with-profiles
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-profile-name)
               (lambda () "chosen")))
      (emacs-jupyter-notebook-send-cell '(4)))
    (ejn-cc27--fail-start (car attempts))
    (emacs-jupyter-notebook-send-cell)
    (should (= (length attempts) 2))
    (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                   "chosen"))))

(ert-deftest ejn-cc27-runtime-failure-keeps-profile-before-context-exists ()
  (ejn-cc27--with-profiles
    (let (failure)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--with-runtime-ready)
                 (lambda (_success error-callback)
                   (funcall error-callback nil "Runtime build failed"))))
        (emacs-jupyter-notebook-start-remote-kernel
         "chosen" nil (lambda (_context reason) (setq failure reason))))
      (should failure)
      (should-not attempts)
      (emacs-jupyter-notebook-send-cell)
      (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                     "chosen")))))

(ert-deftest ejn-cc27-invalid-profile-retries-same-choice-after-config-fix ()
  (ejn-cc27--with-profiles
    (let (failure)
      (let ((emacs-jupyter-notebook-remote-profiles
             '(("chosen" :host "chosen.invalid" :python-command "python"))))
        (emacs-jupyter-notebook-start-remote-kernel
         "chosen" nil (lambda (_context reason) (setq failure reason))))
      (should failure)
      (should-not attempts)
      (emacs-jupyter-notebook-send-cell)
      (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                     "chosen")))))

(ert-deftest ejn-cc27-new-choice-survives-late-failure-and-local-cleanup ()
  (ejn-cc27--with-profiles
    (emacs-jupyter-notebook-start-remote-kernel "chosen")
    (let ((old (car attempts)))
      (ejn-cc27--fail-start old)
      (emacs-jupyter-notebook-start-remote-kernel "second")
      (ejn-cc27--fail-start (car attempts))
      (ejn-cc27--fail-start old)
      (emacs-jupyter-notebook--release-local-resources)
      (emacs-jupyter-notebook-send-cell)
      (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                     "second")))))

(ert-deftest ejn-cc27-retry-fresh-keeps-choice-after-early-validation-failure ()
  (ejn-cc27--with-profiles
    (let ((emacs-jupyter-notebook-remote-profiles
           '(("chosen" :host "chosen.invalid" :python-command "python"))))
      (emacs-jupyter-notebook-start-remote-kernel "chosen" nil #'ignore))
    (should-not attempts)
    (emacs-jupyter-notebook-retry-fresh-kernel)
    (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                   "chosen"))))

(ert-deftest ejn-cc27-choice-does-not-leak-to-another-source ()
  (ejn-cc27--with-profiles
    (emacs-jupyter-notebook-start-remote-kernel "chosen")
    (ejn-cc27--fail-start (car attempts))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/ejn-cc27-other.py")
      (unwind-protect
          (progn
            (emacs-jupyter-notebook--ensure-client-async #'ignore #'ignore)
            (should (equal (plist-get (plist-get (car attempts) :profile) :profile)
                           "default")))
        (emacs-jupyter-notebook--release-local-resources)))))

(ert-deftest ejn-cc27-durable-session-still-reconnects-without-launching ()
  (ejn-cc27--with-profiles
    (emacs-jupyter-notebook-start-remote-kernel "chosen")
    (ejn-cc27--fail-start (car attempts))
    (setq registry-entry '(:profile "chosen" :session-id "durable"
                           :local-file "/tmp/ejn-cc27.py"))
    (let (reconnected)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                 (lambda (entry _success failure &rest _)
                   (setq reconnected entry)
                   (funcall failure nil "Reconnect failed"))))
        (emacs-jupyter-notebook-send-cell))
      (should (equal reconnected registry-entry))
      (should (= (length attempts) 1)))))

(provide 'emacs-jupyter-notebook-profile-selection-tests)
;;; emacs-jupyter-notebook-profile-selection-tests.el ends here
