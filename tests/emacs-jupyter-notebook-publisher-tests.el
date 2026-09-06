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

(defun ejn-publisher-test--client (&optional capabilities disposed)
    (let ((helper (emacs-jupyter-notebook-helper--make-session
                 :state (if disposed 'disposed 'ready)
                 :disposed disposed
                 :capabilities (vconcat capabilities)))
        (state (emacs-jupyter-notebook-helper-backend--make-state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-helper state) helper)
    (emacs-jupyter-notebook-backend--make-session
     :backend 'helper :data state :attached t)))

(ert-deftest ejn-publisher-setup-for-client-requires-exact-capability-session ()
  (let ((code "publisher-setup"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--array-publisher-setup-code)
               (lambda () code)))
      (should (equal (emacs-jupyter-notebook--array-publisher-setup-for-client
                      (ejn-publisher-test--client '("array-group-v1")))
                     (list code)))
      (should-not (emacs-jupyter-notebook--array-publisher-setup-for-client
                   (ejn-publisher-test--client '("other"))))
      (should-not (emacs-jupyter-notebook--array-publisher-setup-for-client
                   (ejn-publisher-test--client '("array-group-v1") t)))
      (should-not (emacs-jupyter-notebook--array-publisher-setup-for-client 'wrong-client)))))

(ert-deftest ejn-publisher-is-first-in-initial-and-restart-setup ()
  (let* ((client (ejn-publisher-test--client '("array-group-v1")))
         (emacs-jupyter-notebook--client client)
         (emacs-jupyter-notebook--execution-setup-pending nil)
         (emacs-jupyter-notebook--execution-setup-epoch 0)
         captured)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-setup-send-next)
               (lambda (_client _epoch snippets) (setq captured snippets)))
              ((symbol-function 'emacs-jupyter-notebook--array-publisher-setup-code)
               (lambda () "publisher")))
      (emacs-jupyter-notebook--execution-start-setup client)
      (should (equal (car captured) "publisher"))
      (setq captured nil)
      (emacs-jupyter-notebook--execution-restart-start-setup
       client emacs-jupyter-notebook--execution-setup-epoch)
      (should (equal (car captured) "publisher")))))

(ert-deftest ejn-publisher-missing-bundle-does-not-strand-setup-gate ()
  (let* ((client (ejn-publisher-test--client '("array-group-v1")))
         (emacs-jupyter-notebook--client client)
         (emacs-jupyter-notebook--execution-setup-pending nil)
         (emacs-jupyter-notebook--execution-setup-epoch 0)
         captured)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-setup-send-next)
               (lambda (_client _epoch snippets) (setq captured snippets)))
              ((symbol-function 'emacs-jupyter-notebook--array-publisher-setup-code)
               (lambda () (error "missing bundle"))))
      (emacs-jupyter-notebook--execution-start-setup client)
      (should captured)
      (should-not (member nil captured))
      (should emacs-jupyter-notebook--execution-setup-pending))))

(provide 'emacs-jupyter-notebook-publisher-tests)
;;; emacs-jupyter-notebook-publisher-tests.el ends here
