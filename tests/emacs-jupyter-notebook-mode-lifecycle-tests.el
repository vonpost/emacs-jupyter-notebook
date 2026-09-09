;;; emacs-jupyter-notebook-mode-lifecycle-tests.el --- Idempotent setup regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'python)
(require 'emacs-jupyter-notebook)

(defmacro ejn-mode-lifecycle--with-python (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (python-mode)
     (insert "# %%\ndef f():\n    pass\n")
     (goto-char (point-min))
     (forward-line 1)
     (let ((text (buffer-string))
           (modified (buffer-modified-p))
           (max-lisp-eval-depth 100))
       (unwind-protect
           (progn ,@body)
         (emacs-jupyter-notebook-mode -1))
       (should (equal text (buffer-string)))
       (should (eq modified (buffer-modified-p))))))

(ert-deftest ejn-mode-lifecycle-repeated-enable-keeps-python-outline-finite ()
  "Double activation must not install code-cells' outline function over itself."
  (ejn-mode-lifecycle--with-python
    (let ((original-outline outline-level)
          (original-imenu imenu-create-index-function))
      (emacs-jupyter-notebook-mode 1)
      (let ((timer emacs-jupyter-notebook--completion-idle-timer))
        (emacs-jupyter-notebook-mode 1)
        (should (= (funcall outline-level) 2))
        (should (eq (cadr code-cells--saved-vars) original-outline))
        (should (eq emacs-jupyter-notebook--completion-idle-timer timer))
        (emacs-jupyter-notebook-mode -1)
        (should-not code-cells-mode)
        (should (eq outline-level original-outline))
        (should (eq imenu-create-index-function original-imenu))
        (should (local-variable-p 'imenu-create-index-function))
        (should-not (memq timer timer-list))
        (should-not (memq timer timer-idle-list))))))

(ert-deftest ejn-mode-lifecycle-preserves-preexisting-code-cells ()
  "A Python hook may have enabled code-cells before EJN is first enabled."
  (ejn-mode-lifecycle--with-python
    (code-cells-mode 1)
    (let ((saved code-cells--saved-vars))
      (emacs-jupyter-notebook-mode 1)
      (should (= (funcall outline-level) 2))
      (should (eq code-cells--saved-vars saved))
      (emacs-jupyter-notebook-mode -1)
      (should code-cells-mode)
      (should (= (funcall outline-level) 2))
      (should (eq code-cells--saved-vars saved))
      (emacs-jupyter-notebook-mode -1)
      (should code-cells-mode)
      (should (= (funcall outline-level) 2)))))

(ert-deftest ejn-mode-lifecycle-fontification-keeps-python-outline-finite ()
  "Outline highlighting must remain finite with independently enabled cells."
  (ejn-mode-lifecycle--with-python
    (setq-local outline-minor-mode-highlight 'override)
    (let ((global-font-lock-mode t))
      (outline-minor-mode 1))
    (code-cells-mode 1)
    (emacs-jupyter-notebook-mode 1)
    (emacs-jupyter-notebook-mode 1)
    (font-lock-ensure)
    (should (= (funcall outline-level) 2))))

(ert-deftest ejn-mode-lifecycle-repeated-disable-preserves-restored-state ()
  (ejn-mode-lifecycle--with-python
    (let ((original-outline outline-level)
          (original-imenu imenu-create-index-function))
      (emacs-jupyter-notebook-mode 1)
      (emacs-jupyter-notebook-mode -1)
      (emacs-jupyter-notebook-mode -1)
      (should (eq outline-level original-outline))
      (should (= (funcall outline-level) 1))
      (should (eq imenu-create-index-function original-imenu))
      (should (local-variable-p 'imenu-create-index-function))
      (should-not code-cells-mode)
      (should-not emacs-jupyter-notebook--completion-idle-timer)
      (should-not (memq #'emacs-jupyter-notebook-completion-at-point
                        completion-at-point-functions))
      (should-not (memq #'emacs-jupyter-notebook-panel--source-post-command
                        post-command-hook)))))

(ert-deftest ejn-mode-lifecycle-reenable-restores-original-state-again ()
  (ejn-mode-lifecycle--with-python
    (let ((original-outline outline-level)
          (original-imenu imenu-create-index-function))
      (dotimes (_ 2)
        (emacs-jupyter-notebook-mode 1)
        (should (= (funcall outline-level) 2))
        (should (eq imenu-create-index-function
                    #'emacs-jupyter-notebook--imenu-index))
        (emacs-jupyter-notebook-mode -1)
        (should (eq outline-level original-outline))
        (should (eq imenu-create-index-function original-imenu))
        (should-not emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-mode-lifecycle-disable-without-enable-preserves-code-cells ()
  (ejn-mode-lifecycle--with-python
    (code-cells-mode 1)
    (let ((saved code-cells--saved-vars)
          (original-imenu imenu-create-index-function))
      (emacs-jupyter-notebook-mode -1)
      (should code-cells-mode)
      (should (eq saved code-cells--saved-vars))
      (should (= (funcall outline-level) 2))
      (should (eq imenu-create-index-function original-imenu)))))

(ert-deftest ejn-mode-lifecycle-imenu-helpers-preserve-inherited-default ()
  (with-temp-buffer
    (let ((original imenu-create-index-function))
      (should-not (local-variable-p 'imenu-create-index-function))
      (unwind-protect
          (progn
            (emacs-jupyter-notebook--enable-imenu)
            (emacs-jupyter-notebook--enable-imenu)
            (emacs-jupyter-notebook--disable-imenu)
            (should (eq imenu-create-index-function original))
            (should-not (local-variable-p 'imenu-create-index-function))
            (emacs-jupyter-notebook--disable-imenu)
            (should (eq imenu-create-index-function original))
            (should-not (local-variable-p 'imenu-create-index-function)))
        (emacs-jupyter-notebook--disable-imenu)))))

(provide 'emacs-jupyter-notebook-mode-lifecycle-tests)
;;; emacs-jupyter-notebook-mode-lifecycle-tests.el ends here
