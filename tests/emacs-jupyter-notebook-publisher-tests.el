;;; emacs-jupyter-notebook-publisher-tests.el --- Publisher setup -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook)

(ert-deftest ejn-publisher-setup-is-bounded-and-preserves-source ()
  (with-temp-buffer
    (insert "# %%\nreference = volume[120]\n")
    (set-buffer-modified-p nil)
    (let ((before (buffer-string))
          (code (emacs-jupyter-notebook--array-publisher-setup-code)))
      (should (string-match-p "<ejn-publisher>" code))
      (should (string-match-p "install.*globals" code))
      (should (< (string-bytes code) 65536))
      (should (equal before (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest ejn-publisher-setup-rejects-oversized-bundle ()
  (let ((file (make-temp-file "ejn-publisher-test-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert (make-string 32769 ?x)))
          (let ((emacs-jupyter-notebook--publisher-source-file file))
            (should-error (emacs-jupyter-notebook--array-publisher-setup-code))))
      (delete-file file))))

(provide 'emacs-jupyter-notebook-publisher-tests)
;;; emacs-jupyter-notebook-publisher-tests.el ends here
