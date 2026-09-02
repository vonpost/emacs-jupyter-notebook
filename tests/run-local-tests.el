;;; run-local-tests.el --- Canonical source-only local ERT runner -*- lexical-binding: t; -*-

;;; Commentary:
;; Load every local ERT module while keeping optional remote and Doom tests
;; out of the normal, deterministic test command.  This file is intentionally
;; loaded by `emacs -Q'; it must not depend on a user's init file.

;;; Code:

(require 'cl-lib)

(defconst ejn-test-runner--root
  (file-name-directory (directory-file-name
                        (file-name-directory (file-truename load-file-name))))
  "Repository root containing this test runner.")

(defun ejn-test-runner--project-elc-files ()
  "Return project byte-code files that can hide source changes."
  (let ((ignored (rx "/" (or ".git" ".opencode" ".agent-shell") "/")))
    (cl-remove-if
     (lambda (file) (string-match-p ignored file))
     (directory-files-recursively ejn-test-runner--root "\\.elc\\'"))))

(defun ejn-test-runner--assert-no-project-elc ()
  "Signal a clear error when project byte-code could shadow source."
  (let ((files (ejn-test-runner--project-elc-files)))
    (when files
      (error "Refusing source-only tests: remove stale project .elc files: %s"
             (mapconcat (lambda (file)
                          (file-relative-name file ejn-test-runner--root))
                        files ", ")))))

(defun ejn-test-runner--code-cells-directory ()
  "Resolve and return the directory containing `code-cells.el'."
  (let* ((configured (getenv "CODE_CELLS_DIR"))
         (candidates
          (delete-dups
           (delq nil
                 (list configured
                       (expand-file-name ".local/straight/repos/code-cells.el"
                                         user-emacs-directory)
                       (expand-file-name "straight/repos/code-cells.el"
                                         user-emacs-directory))))))
    (or (cl-find-if (lambda (dir)
                      (and (file-directory-p dir)
                           (file-readable-p (expand-file-name "code-cells.el"
                                                              dir))))
                    candidates)
        (error "Cannot resolve CODE_CELLS_DIR; set it to the code-cells.el directory"))))

(defun ejn-test-runner--local-test-files ()
  "Return deterministic local ERT modules, excluding optional suites."
  (sort
   (directory-files (expand-file-name "tests" ejn-test-runner--root) t
                    "\\`emacs-jupyter-notebook.*tests\\.el\\'")
   #'string<))

(defun ejn-test-runner--make-runtime-fixture ()
  "Create a no-op complete runtime so unrelated ERTs never invoke real Nix."
  (let* ((root (make-temp-file "ejn-test-runtime-" t))
         (bin (expand-file-name "bin" root)))
    (make-directory bin t)
    (dolist (name '("ejn-helper" "ejn-registry-worker"))
      (let ((file (expand-file-name name bin)))
        (with-temp-file file
          (insert "#!/bin/sh\nexit 0\n"))
        (set-file-modes file #o700)))
    root))

(defvar ejn-test-runner--runtime-fixture nil
  "Temporary complete runtime used by unrelated local ERTs.")

(defun ejn-test-runner--delete-runtime-fixture ()
  "Delete the local ERT runtime fixture without masking Emacs exit."
  (when (and (stringp ejn-test-runner--runtime-fixture)
             (file-directory-p ejn-test-runner--runtime-fixture))
    (ignore-errors
      (delete-directory ejn-test-runner--runtime-fixture t)))
  (setq ejn-test-runner--runtime-fixture nil))

(ejn-test-runner--assert-no-project-elc)
(let ((code-cells-dir (ejn-test-runner--code-cells-directory)))
  (add-to-list 'load-path ejn-test-runner--root)
  (add-to-list 'load-path (expand-file-name "tests" ejn-test-runner--root))
  (add-to-list 'load-path code-cells-dir)
  (dolist (file (ejn-test-runner--local-test-files))
    (unless (string-match-p "-\\(?:remote\\|doom\\)-tests\\.el\\'" file)
      (load file nil nil t)))
  ;; Existing orchestration tests mock the registry/helper layers below the
  ;; new first-use gate.  Give them a complete inert runtime; the dedicated
  ;; runtime tests dynamically clear this variable and own all process mocks.
  (setq ejn-test-runner--runtime-fixture
        (ejn-test-runner--make-runtime-fixture)
        emacs-jupyter-notebook--runtime-directory
        ejn-test-runner--runtime-fixture)
  (add-hook 'kill-emacs-hook #'ejn-test-runner--delete-runtime-fixture))

(provide 'run-local-tests)
;;; run-local-tests.el ends here
