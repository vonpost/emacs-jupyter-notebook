;;; emacs-jupyter-notebook-scratch-tests.el --- Scratch ownership tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-scratch)
(defvar doom-localleader-key)
(defvar doom-localleader-alt-key)

(defmacro ejn-scratch-test--with-owner (&rest body)
  (declare (indent 0) (debug t))
  `(let ((owner (generate-new-buffer " *ejn-scratch-test-source*")) scratch)
     (unwind-protect
         (with-current-buffer owner
           (setq-local emacs-jupyter-notebook-mode t)
           (insert "# %%\nsource = 7\n")
           (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
             (setq scratch (emacs-jupyter-notebook-scratch)))
           (set-buffer owner)
           (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                      (lambda (&rest _) (ert-fail "Scratch test attempted a real connection"))))
             ,@body))
       (when (buffer-live-p owner) (kill-buffer owner))
       (when (buffer-live-p scratch) (kill-buffer scratch)))))

(ert-deftest ejn-scratch-submits-through-owner-and-never-edits-source ()
  (ejn-scratch-test--with-owner
    (let ((original (buffer-string)) submitted)
      (with-current-buffer scratch
        (insert "temporary = inspect_volume()")
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                   (lambda (code key &optional _profile _announce options)
                     (setq submitted (list (current-buffer) code key options)) 42)))
          (should (= (emacs-jupyter-notebook-scratch-send) 42)))
        (should (string-empty-p (buffer-string)))
        (should-not emacs-jupyter-notebook-mode)
        (should-not emacs-jupyter-notebook--client))
      (should (eq (car submitted) owner))
      (should (equal (nth 1 submitted) "temporary = inspect_volume()"))
      (should-not (nth 2 submitted))
      (should (eq (plist-get (nth 3 submitted) :origin) 'scratch))
      (should (equal (buffer-string) original)))))

(ert-deftest ejn-scratch-rejected-reservation-preserves-draft ()
  (ejn-scratch-test--with-owner
    (with-current-buffer scratch
      (insert "run_this()")
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) (user-error "queue full"))))
        (should-error (emacs-jupyter-notebook-scratch-send) :type 'user-error))
      (should (equal (buffer-string) "run_this()")))))

(ert-deftest ejn-scratch-disables-parent-auto-notebook-hooks-and-reuses-input ()
  (let ((python-mode-hook (list (lambda () (ert-fail "Must not run source auto-enable hooks")))))
    (ejn-scratch-test--with-owner
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
        (should (eq (emacs-jupyter-notebook-scratch "draft = 1") scratch))
        (with-current-buffer owner
          (should (eq (emacs-jupyter-notebook-scratch "recalled = 2") scratch))))
      (with-current-buffer scratch
        (should (derived-mode-p 'python-mode))
        (should (equal (buffer-string) "draft = 1\n\nrecalled = 2"))))))

(ert-deftest ejn-scratch-owner-kill-reclaims-modified-input-without-kernel-action ()
  (ejn-scratch-test--with-owner
    (with-current-buffer scratch (insert "unsaved = True"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-close-local)
               (lambda (&rest _) (ert-fail "Scratch must not own a backend")))
              ((symbol-function 'emacs-jupyter-notebook-shutdown-kernel)
               (lambda (&rest _) (ert-fail "Scratch must not stop a kernel"))))
      (kill-buffer owner))
    (should-not (buffer-live-p scratch))))

(ert-deftest ejn-scratch-disabled-owner-rejects-send-with-draft-intact ()
  (ejn-scratch-test--with-owner
    (setq emacs-jupyter-notebook-mode nil)
    (with-current-buffer scratch
      (insert "wait()")
      (should-error (emacs-jupyter-notebook-scratch-send) :type 'user-error)
      (should (equal (buffer-string) "wait()")))))

(ert-deftest ejn-scratch-doom-local-leader-binds-subordinate-input-only ()
  (let ((doom-localleader-key ",")
        (doom-localleader-alt-key "C-c m")
        (real-featurep (symbol-function 'featurep)) calls)
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional subfeature)
                 (or (eq feature 'evil) (funcall real-featurep feature subfeature))))
              ((symbol-function 'evil-define-minor-mode-key)
               (lambda (states mode key map &rest _) (push (list states mode key map) calls))))
      (emacs-jupyter-notebook-scratch--setup-doom-keybindings))
    (should (= (length calls) 2))
    (dolist (state '(normal visual motion insert emacs))
      (let ((call (cl-find-if (lambda (row) (memq state (car row))) calls)))
        (should (eq (nth 1 call) 'emacs-jupyter-notebook-scratch-input-mode))
        (should (equal (nth 2 call) (kbd (if (memq state '(insert emacs)) "C-c m" ","))))
        (should (eq (lookup-key (nth 3 call) (kbd "c")) #'emacs-jupyter-notebook-scratch-send))
        (should (eq (lookup-key (nth 3 call) (kbd "H")) #'emacs-jupyter-notebook-history))
        (should (eq (lookup-key (nth 3 call) (kbd "~")) #'emacs-jupyter-notebook-scratch-source))))))

(ert-deftest ejn-scratch-cannot-acquire-a-notebook-session-of-its-own ()
  (ejn-scratch-test--with-owner
    (with-current-buffer scratch
      (should-error (emacs-jupyter-notebook-mode 1) :type 'user-error)
      (should-not emacs-jupyter-notebook-mode)
      (should-not emacs-jupyter-notebook--client))))

(ert-deftest ejn-scratch-region-keeps-unsubmitted-draft ()
  (ejn-scratch-test--with-owner
    (with-current-buffer scratch
      (insert "first()\nsecond()\n")
      (let (submitted)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                   (lambda (code &rest _) (setq submitted code) 1)))
          (emacs-jupyter-notebook-scratch-send-region 1 9))
        (should (equal submitted "first()\n"))
        (should (equal (buffer-string) "second()\n"))))))

(provide 'emacs-jupyter-notebook-scratch-tests)
