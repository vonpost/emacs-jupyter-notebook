;;; emacs-jupyter-notebook-variables-hang-tests.el --- UI responsiveness tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'python)
(require 'emacs-jupyter-notebook-variables)

(ert-deftest ejn-hang-variables-oversized-name-never-parses-or-copies-source ()
  (with-temp-buffer
    (python-mode)
    (insert (make-string 4096 ?a))
    (goto-char 2048)
    (cl-letf (((symbol-function 'syntax-ppss)
               (lambda (&rest _) (ert-fail "Oversized name reached syntax parser")))
              ((symbol-function 'buffer-substring-no-properties)
               (lambda (&rest _) (ert-fail "Oversized name was copied"))))
      (should-not (emacs-jupyter-notebook-variables--name-at-point)))))

(ert-deftest ejn-hang-variables-large-source-skips-cold-syntax-parse ()
  (with-temp-buffer
    (python-mode)
    (insert (make-string (1+ (* 1024 1024)) ?\s) "image")
    (goto-char (point-max))
    (cl-letf (((symbol-function 'syntax-ppss)
               (lambda (&rest _) (ert-fail "Large source reached syntax parser"))))
      (should-not (emacs-jupyter-notebook-variables--name-at-point)))))

(ert-deftest ejn-hang-variables-name-detection-keeps-bounded-identifiers ()
  (with-temp-buffer
    (python-mode)
    (dolist (name '("image" "_private" "élève"))
      (erase-buffer)
      (insert name "[0]")
      (goto-char (1+ (/ (length name) 2)))
      (should (equal name (emacs-jupyter-notebook-variables--name-at-point))))))

(ert-deftest ejn-hang-variables-plane-prompt-yields-and-fences-stale-source ()
  (with-temp-buffer
    (python-mode)
    (insert "image")
    (goto-char (point-min))
    (setq-local emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--client 'client)
    (let (reply deferred prompted)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-variables--ensure-ready) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-variables--request)
                 (lambda (_names callback &rest _) (setq reply callback)))
                ((symbol-function 'emacs-jupyter-notebook-ui-defer)
                 (lambda (&rest args) (setq deferred args)))
                ((symbol-function 'emacs-jupyter-notebook-variables--view-metadata)
                 (lambda (&rest _) (setq prompted t))))
        (emacs-jupyter-notebook-view-variable "image")
        (funcall reply '(:variables ((:name "image" :type "numpy.ndarray"
                                     :shape [8 32 64] :dtype "float32"))))
        (should-not prompted)
        (should (eq (car deferred) (current-buffer)))
        (should (eq (nth 3 deferred) (current-buffer)))
        (should (eq (nth 4 deferred) 'variable-view))
        (should (funcall (nth 1 deferred)))
        (funcall (nth 2 deferred))
        (should prompted)
        (cl-incf emacs-jupyter-notebook-variables--generation)
        (should-not (funcall (nth 1 deferred)))))))

(ert-deftest ejn-hang-variables-table-view-keeps-origin-and-supersedes-old-prompt ()
  (let ((source (generate-new-buffer " *ejn-hang-variable-source*"))
        (table (generate-new-buffer " *ejn-hang-variable-table*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer table)
          (with-current-buffer source
            (python-mode)
            (setq-local emacs-jupyter-notebook-mode t
                        emacs-jupyter-notebook--client 'client
                        emacs-jupyter-notebook-variables--table table)
            (let (reply deferred)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-variables--ensure-ready) #'ignore)
                        ((symbol-function 'emacs-jupyter-notebook-variables--request)
                         (lambda (_names callback &rest _) (setq reply callback)))
                        ((symbol-function 'emacs-jupyter-notebook-ui-defer)
                         (lambda (&rest args) (setq deferred args)))
                        ((symbol-function 'emacs-jupyter-notebook-variables--view-metadata)
                         (lambda (&rest _) (ert-fail "Prompt entered helper callback"))))
                (emacs-jupyter-notebook-view-variable "image")
                (funcall reply '(:variables ((:name "image" :type "numpy.ndarray"
                                             :shape [8 32 64] :dtype "float32"))))
                (should (eq (nth 3 deferred) table))
                (should (funcall (nth 1 deferred)))
                (emacs-jupyter-notebook-view-variable "other")
                (should-not (funcall (nth 1 deferred)))))))
      (kill-buffer source)
      (kill-buffer table))))

(ert-deftest ejn-hang-variables-plane-selection-waits-for-the-minibuffer ()
  (save-window-excursion
    (with-temp-buffer
      (python-mode)
      (switch-to-buffer (current-buffer))
      (setq-local emacs-jupyter-notebook-mode t
                  emacs-jupyter-notebook--client 'client)
      (let ((minibuffer-active t) timers cancelled reply prompted)
        (cl-letf (((symbol-function 'active-minibuffer-window)
                   (lambda () minibuffer-active))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay _repeat _function &rest _args)
                     (let ((timer (timer-create))) (push timer timers) timer)))
                  ((symbol-function 'cancel-timer)
                   (lambda (timer) (push timer cancelled)))
                  ((symbol-function 'emacs-jupyter-notebook-variables--ensure-ready) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-variables--request)
                   (lambda (_names callback &rest _) (setq reply callback)))
                  ((symbol-function 'emacs-jupyter-notebook-variables--view-metadata)
                   (lambda (&rest _) (setq prompted t))))
          (unwind-protect
              (progn
                (emacs-jupyter-notebook-view-variable "image")
                (funcall reply '(:variables ((:name "image" :type "numpy.ndarray"
                                             :shape [8 32 64] :dtype "float32"))))
                (should-not prompted)
                (let ((record (car emacs-jupyter-notebook-ui--pending)))
                  (should record)
                  (emacs-jupyter-notebook-ui--run (current-buffer) record)
                  (should-not prompted)
                  (should (= (length timers) 2))
                  (setq minibuffer-active nil)
                  (emacs-jupyter-notebook-ui--run (current-buffer) record)
                  (should prompted)
                  (should-not emacs-jupyter-notebook-ui--pending)
                  (should (memq (car timers) cancelled))
                  (setq prompted nil)
                  (emacs-jupyter-notebook-ui--run (current-buffer) record)
                  (should-not prompted)))
            (emacs-jupyter-notebook-ui-cancel)
            (dolist (timer timers) (cancel-timer timer))))))))

(provide 'emacs-jupyter-notebook-variables-hang-tests)
;;; emacs-jupyter-notebook-variables-hang-tests.el ends here
