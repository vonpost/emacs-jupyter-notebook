;;; emacs-jupyter-notebook-runtime-cache-tests.el --- Durable runtime cache tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Real local files model Nix outputs and output links.  No test invokes Nix,
;; Docker, SSH, Jupyter, or an executable from a cached output.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-inspect)

(defun ejn-runtime-cache-test--write (root relative content)
  "Write CONTENT into RELATIVE below ROOT and return its path."
  (let ((path (expand-file-name relative root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content))
    path))

(defun ejn-runtime-cache-test--output (root names)
  "Create inert executable NAMES under ROOT and return ROOT."
  (dolist (name names)
    (set-file-modes
     (ejn-runtime-cache-test--write root (concat "bin/" name)
                                    "#!/bin/sh\nexit 0\n")
     #o700))
  (file-name-as-directory (file-truename root)))

(defmacro ejn-runtime-cache-test--with-fixture (&rest body)
  "Run BODY with isolated source trees and both runtime outputs."
  (declare (indent 0) (debug body))
  `(let* ((fixture (make-temp-file "ejn-runtime-cache-" t))
          (root (expand-file-name "package/" fixture))
          (headless (expand-file-name "headless/" fixture))
          (viewer-output (expand-file-name "viewer-output/" fixture))
          (user-emacs-directory (expand-file-name "emacs/" fixture))
          (exec-path nil)
          (emacs-jupyter-notebook-helper-command '("ejn-helper" "--protocol"))
          (emacs-jupyter-notebook-registry-worker-command '("ejn-registry-worker"))
          (emacs-jupyter-notebook-inspector-command nil)
          (emacs-jupyter-notebook-helper--module-directory root)
          (emacs-jupyter-notebook-registry--module-directory root)
          (emacs-jupyter-notebook-runtime--module-directory root)
          (emacs-jupyter-notebook-runtime--build nil)
          (emacs-jupyter-notebook-runtime--viewer-build nil)
          (emacs-jupyter-notebook--runtime-directory nil)
          (emacs-jupyter-notebook-runtime-viewer-directory nil))
     (unwind-protect
         (progn
           (dolist (name '("flake.nix" "flake.lock"
                           "helper/pyproject.toml" "helper/ejn_helper/main.py"
                           "registry_worker/pyproject.toml"
                           "registry_worker/ejn_registry_worker/main.py"
                           "array_protocol/pyproject.toml"
                           "array_protocol/ejn_array/main.py"
                           "viewer/pyproject.toml" "viewer/ejn_viewer/main.py"))
             (ejn-runtime-cache-test--write root name "fixture-source\n"))
           (setq headless (ejn-runtime-cache-test--output
                           headless '("ejn-helper" "ejn-registry-worker"))
                 viewer-output (ejn-runtime-cache-test--output
                                viewer-output '("ejn-viewer")))
           (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                      (lambda () root)))
             ,@body))
       (when emacs-jupyter-notebook-runtime--build
         (emacs-jupyter-notebook-runtime--fail
          emacs-jupyter-notebook-runtime--build "cache test cleanup"))
       (when emacs-jupyter-notebook-runtime--viewer-build
         (emacs-jupyter-notebook-runtime--fail
          emacs-jupyter-notebook-runtime--viewer-build "cache test cleanup"))
       (delete-directory fixture t))))

(defun ejn-runtime-cache-test--link (root output viewer &optional ready)
  "Create the target-specific cache link for ROOT to OUTPUT.
VIEWER selects the GUI output; READY adds the successful-build record."
  (let ((link (emacs-jupyter-notebook-runtime--cache-link root viewer)))
    (should (and (stringp link) (file-name-absolute-p link)))
    (make-directory (file-name-directory link) t)
    (make-symbolic-link output link)
    (when ready
      (with-temp-file (concat link ".ready") (insert output)))
    link))

(defun ejn-runtime-cache-test--complete-build (root output viewer)
  "Complete a fake Nix build of OUTPUT for ROOT and VIEWER."
  (let* ((link (ejn-runtime-cache-test--link root output viewer))
         (stdout (generate-new-buffer " *ejn-cache-completed-build*"))
         (build (emacs-jupyter-notebook-runtime--make-build
                 :token (gensym "ejn-cache-build-") :root root :viewer viewer
                 :cache-link link :stdout-buffer stdout)))
    (with-current-buffer stdout (insert output "\n"))
    (set (emacs-jupyter-notebook-runtime--build-slot viewer) build)
    (emacs-jupyter-notebook-runtime--succeed build)
    (should-not (buffer-live-p stdout))
    link))

(ert-deftest ejn-runtime-cache-restart-reuses-completed-build-without-nix ()
  (ejn-runtime-cache-test--with-fixture
    (let* ((link (ejn-runtime-cache-test--complete-build root headless nil))
           (emacs-jupyter-notebook-auto-build-runtime nil)
           (ready 0) failure)
      (should (file-regular-p (concat link ".ready")))
      ;; A fresh Emacs has none of the previous process-local discovery state.
      (setq emacs-jupyter-notebook--runtime-directory nil
            emacs-jupyter-notebook-runtime-viewer-directory nil)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Cache hit started a process")))
                ((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
                 (lambda () (ert-fail "Cache hit consulted Nix"))))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook--runtime-probe (lambda () (cl-incf ready))
         (lambda (reason) (setq failure reason))))
      (should (= ready 1))
      (should-not failure)
      (should (equal emacs-jupyter-notebook--runtime-directory headless))
      (should (equal (car (emacs-jupyter-notebook-helper-resolve-argv))
                     (expand-file-name "bin/ejn-helper" headless)))
      (should (equal (car (emacs-jupyter-notebook-registry-worker-resolve-argv))
                     (expand-file-name "bin/ejn-registry-worker" headless))))))

(ert-deftest ejn-runtime-cache-viewer-and-headless-restore-independently ()
  (ejn-runtime-cache-test--with-fixture
    (ejn-runtime-cache-test--complete-build root headless nil)
    (ejn-runtime-cache-test--complete-build root viewer-output t)
    (setq emacs-jupyter-notebook--runtime-directory nil
          emacs-jupyter-notebook-runtime-viewer-directory nil)
    (let ((emacs-jupyter-notebook-auto-build-runtime nil) (ready 0) failure)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Cache hit started a process"))))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook-inspect--probe (lambda () (cl-incf ready))
         (lambda (reason) (setq failure reason)) nil t)
        (should (= ready 1))
        (should-not failure)
        (should-not emacs-jupyter-notebook--runtime-directory)
        (should (equal emacs-jupyter-notebook-runtime-viewer-directory viewer-output))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook--runtime-probe (lambda () (cl-incf ready))
         (lambda (reason) (setq failure reason)))
        (should (= ready 2))
        (should-not failure)
        (should (equal emacs-jupyter-notebook--runtime-directory headless))
        (should (equal (emacs-jupyter-notebook-inspect--command)
                       (list (expand-file-name "bin/ejn-viewer" viewer-output))))))))

(ert-deftest ejn-runtime-cache-source-content-change-invalidates-same-size-and-time ()
  (ejn-runtime-cache-test--with-fixture
    (let* ((source (expand-file-name "helper/ejn_helper/main.py" root))
           (mtime (file-attribute-modification-time (file-attributes source)))
           (old (emacs-jupyter-notebook-runtime--cache-link root nil))
           (old-viewer (emacs-jupyter-notebook-runtime--cache-link root t)))
      (ejn-runtime-cache-test--write root "helper/ejn_helper/main.py" "fixture-CHANGE\n")
      (set-file-times source mtime)
      (should-not (equal old (emacs-jupyter-notebook-runtime--cache-link root nil)))
      (should (equal old-viewer (emacs-jupyter-notebook-runtime--cache-link root t))))))

(ert-deftest ejn-runtime-cache-shared-protocol-and-lock-invalidate-both-targets ()
  (ejn-runtime-cache-test--with-fixture
    (dolist (relative '("array_protocol/ejn_array/main.py" "flake.lock" "flake.nix"))
      (let ((old (emacs-jupyter-notebook-runtime--cache-link root nil))
            (old-viewer (emacs-jupyter-notebook-runtime--cache-link root t)))
        (ejn-runtime-cache-test--write root relative "changed source contents\n")
        (should-not (equal old (emacs-jupyter-notebook-runtime--cache-link root nil)))
        (should-not (equal old-viewer (emacs-jupyter-notebook-runtime--cache-link root t)))))))

(ert-deftest ejn-runtime-cache-viewer-source-keeps-headless-cache-valid ()
  (ejn-runtime-cache-test--with-fixture
    (let ((old (emacs-jupyter-notebook-runtime--cache-link root nil))
          (old-viewer (emacs-jupyter-notebook-runtime--cache-link root t)))
      (ejn-runtime-cache-test--write root "viewer/ejn_viewer/main.py" "viewer changed\n")
      (should (equal old (emacs-jupyter-notebook-runtime--cache-link root nil)))
      (should-not (equal old-viewer (emacs-jupyter-notebook-runtime--cache-link root t))))))

(ert-deftest ejn-runtime-cache-unrelated-and-generated-files-do-not-invalidate ()
  (ejn-runtime-cache-test--with-fixture
    (let ((old (emacs-jupyter-notebook-runtime--cache-link root nil))
          (old-viewer (emacs-jupyter-notebook-runtime--cache-link root t)))
      (dolist (name '("README.md" "emacs-jupyter-notebook.el" "tests/new-tests.el"
                      "helper/tests/test_runtime.py" "helper/integration_tests/test_a.py"
                      "registry_worker/tests/test_worker.py"
                      "helper/ejn_helper/__pycache__/main.cpython-314.pyc"
                      "helper/ejn_helper/main.pyc" "viewer/ejn_viewer/main.pyo"
                      "viewer/ejn_viewer.egg-info/PKG-INFO" "helper/.git/index"))
        (ejn-runtime-cache-test--write root name "irrelevant change\n"))
      (should (equal old (emacs-jupyter-notebook-runtime--cache-link root nil)))
      (should (equal old-viewer (emacs-jupyter-notebook-runtime--cache-link root t))))))

(ert-deftest ejn-runtime-cache-record-required-and-output-must-match ()
  (ejn-runtime-cache-test--with-fixture
    (let* ((link (ejn-runtime-cache-test--link root headless nil))
           (record (concat link ".ready")))
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil))
      (with-temp-file record (insert viewer-output))
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil))
      (with-temp-file record (insert headless))
      (should (equal headless (emacs-jupyter-notebook-runtime--cache-output link nil)))
      ;; Corrupt or multiple records cannot be interpreted as a usable output.
      (with-temp-file record (insert headless "\n" viewer-output))
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil))
      (with-temp-file record (insert (make-string 65536 ?x)))
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil)))))

(ert-deftest ejn-runtime-cache-missing-executable-and-collected-output-are-misses ()
  (ejn-runtime-cache-test--with-fixture
    (let ((link (ejn-runtime-cache-test--link root headless nil t)))
      (delete-file (expand-file-name "bin/ejn-registry-worker" headless))
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil))
      (delete-directory headless t)
      (should-not (emacs-jupyter-notebook-runtime--cache-output link nil))
      (emacs-jupyter-notebook-runtime--restore nil)
      (should-not emacs-jupyter-notebook--runtime-directory))))

(ert-deftest ejn-runtime-cache-custom-missing-commands-are-never-replaced ()
  (ejn-runtime-cache-test--with-fixture
    (ejn-runtime-cache-test--link root headless nil t)
    (ejn-runtime-cache-test--link root viewer-output t t)
    (let ((emacs-jupyter-notebook-helper-command '("my-missing-helper"))
          (emacs-jupyter-notebook-inspector-command '("my-missing-viewer"))
          (ready 0) failures)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Custom missing command started a build")))
                ((symbol-function 'emacs-jupyter-notebook-runtime--restore)
                 (lambda (&rest _) (ert-fail "Custom missing command used cache"))))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook--runtime-probe (lambda () (cl-incf ready))
         (lambda (reason) (push reason failures)))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook-inspect--probe (lambda () (cl-incf ready))
         (lambda (reason) (push reason failures)) nil t))
      (should (= ready 0))
      (should (= (length failures) 2))
      (should-not emacs-jupyter-notebook--runtime-directory)
      (should-not emacs-jupyter-notebook-runtime-viewer-directory))))

(ert-deftest ejn-runtime-cache-exec-path-command-wins-over-cached-executable ()
  (ejn-runtime-cache-test--with-fixture
    (ejn-runtime-cache-test--link root headless nil t)
    (let* ((preferred (ejn-runtime-cache-test--output
                       (expand-file-name "preferred/" fixture) '("ejn-helper")))
           (exec-path (list (expand-file-name "bin" preferred))))
      (emacs-jupyter-notebook-runtime--restore nil)
      (should (equal (car (emacs-jupyter-notebook-helper-resolve-argv))
                     (expand-file-name "bin/ejn-helper" preferred)))
      (should (equal (car (emacs-jupyter-notebook-registry-worker-resolve-argv))
                     (expand-file-name "bin/ejn-registry-worker" headless))))))

(ert-deftest ejn-runtime-cache-source-change-during-build-is-not-published ()
  (ejn-runtime-cache-test--with-fixture
    (let* ((link (ejn-runtime-cache-test--link root headless nil))
           (build (emacs-jupyter-notebook-runtime--make-build
                   :root root :viewer nil :cache-link link)))
      (ejn-runtime-cache-test--write root "helper/ejn_helper/main.py" "new source\n")
      (emacs-jupyter-notebook-runtime--publish-cache build headless)
      (should-not (file-exists-p (concat link ".ready")))
      (should-not (file-exists-p
                   (concat (emacs-jupyter-notebook-runtime--cache-link root nil)
                           ".ready"))))))

(ert-deftest ejn-runtime-cache-roots-and-architectures-do-not-share-links ()
  (ejn-runtime-cache-test--with-fixture
    (let ((other (expand-file-name "other-package/" fixture))
          (old (emacs-jupyter-notebook-runtime--cache-link root nil)))
      (copy-directory root other nil t t)
      (should-not (equal old (emacs-jupyter-notebook-runtime--cache-link other nil)))
      (let ((system-configuration "different-test-architecture"))
        (should-not (equal old (emacs-jupyter-notebook-runtime--cache-link root nil)))))))

(ert-deftest ejn-runtime-cache-build-requests-nix-managed-output-link ()
  (ejn-runtime-cache-test--with-fixture
    (let ((emacs-jupyter-notebook-auto-build-runtime t) command failure snapshot)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
                 (lambda () "/fixture/nix"))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq command (plist-get args :command)
                         snapshot (emacs-jupyter-notebook-runtime--build-source-directory
                                   emacs-jupyter-notebook-runtime--build))
                   (should (file-directory-p snapshot))
                   (should (equal (car (last command))
                                  (concat "path:" snapshot "#default")))
                   (error "Test stops at the process boundary"))))
        (emacs-jupyter-notebook-runtime-ensure
         #'emacs-jupyter-notebook--runtime-probe #'ignore
         (lambda (reason) (setq failure reason))))
      (should (equal (cadr (member "--out-link" command))
                     (emacs-jupyter-notebook-runtime--cache-link root nil)))
      (should-not (member "--no-link" command))
      (should failure)
      (should-not emacs-jupyter-notebook-runtime--build)
      (should-not (file-exists-p snapshot)))))

(ert-deftest ejn-runtime-cache-publication-error-or-quit-still-resumes-ready-waiter ()
  (dolist (problem '(error quit))
    (ejn-runtime-cache-test--with-fixture
     (let* ((link (ejn-runtime-cache-test--link root headless nil))
           (stdout (generate-new-buffer " *ejn-cache-write-failure*"))
           (ready 0) failure
           (waiter (emacs-jupyter-notebook-runtime--make-waiter
                    :buffer (current-buffer)
                    :probe #'emacs-jupyter-notebook--runtime-probe
                    :callback (lambda () (cl-incf ready))
                    :failure (lambda (reason) (setq failure reason))))
           (build (emacs-jupyter-notebook-runtime--make-build
                   :root root :cache-link link :stdout-buffer stdout
                   :waiters (list waiter))))
      (with-current-buffer stdout (insert headless "\n"))
      (setq emacs-jupyter-notebook-runtime--build build)
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (&rest _)
                   (signal problem (and (eq problem 'error)
                                        '("Fixture cannot save the cache"))))))
        (emacs-jupyter-notebook-runtime--succeed build))
      (should (= ready 1))
      (should-not failure)
      (should-not (buffer-live-p stdout))
      (should-not emacs-jupyter-notebook-runtime--build)
      (should (equal emacs-jupyter-notebook--runtime-directory headless))
      (should-not (file-exists-p (concat link ".ready")))
      (should-not (directory-files (file-name-directory link) nil "\\.ready-"))))))

(ert-deftest ejn-runtime-cache-failed-build-does-not-admit-uncompleted-output ()
  (ejn-runtime-cache-test--with-fixture
    (let* ((link (ejn-runtime-cache-test--link root headless nil))
           (snapshot (car (emacs-jupyter-notebook-runtime--snapshot root nil)))
           (build (emacs-jupyter-notebook-runtime--make-build
                   :root root :cache-link link :source-directory snapshot)))
      (setq emacs-jupyter-notebook-runtime--build build)
      (emacs-jupyter-notebook-runtime--fail build "Fixture build was cancelled")
      (emacs-jupyter-notebook-runtime--restore nil)
      (should-not emacs-jupyter-notebook-runtime--build)
      (should-not emacs-jupyter-notebook--runtime-directory)
      (should-not (file-exists-p (concat link ".ready")))
      (should-not (file-exists-p snapshot)))))

(ert-deftest ejn-runtime-cache-source-discovery-rejects-symlinks-and-missing-inputs ()
  (ejn-runtime-cache-test--with-fixture
    (let ((source (expand-file-name "helper/ejn_helper/main.py" root))
          (outside (ejn-runtime-cache-test--write fixture "outside.py" "outside\n")))
      (delete-file source)
      (make-symbolic-link outside source)
      (should-not (emacs-jupyter-notebook-runtime--cache-link root nil))
      (should (emacs-jupyter-notebook-runtime--cache-link root t))
      (delete-file (expand-file-name "flake.lock" root))
      (should-not (emacs-jupyter-notebook-runtime--cache-link root t)))))

(ert-deftest ejn-runtime-cache-source-discovery-bounds-total-bytes ()
  (ejn-runtime-cache-test--with-fixture
    (ejn-runtime-cache-test--write root "helper/ejn_helper/oversized.py"
                                   (make-string (* 8 1024 1024) ?x))
    (should-not (emacs-jupyter-notebook-runtime--cache-link root nil))
    (should (emacs-jupyter-notebook-runtime--cache-link root t))))

(ert-deftest ejn-runtime-cache-snapshot-hashes-exact-copied-inputs-without-git ()
  (ejn-runtime-cache-test--with-fixture
    ;; These files have never been added to a Git index.  A path flake must
    ;; nevertheless contain the same bytes whose digest chooses the cache.
    (dolist (name '("helper/ejn_helper/new_untracked.py"
                    "viewer/ejn_viewer/new_untracked.py"))
      (set-file-modes (ejn-runtime-cache-test--write root name "new contents\n") #o755))
    (dolist (name '("helper/ejn_helper/__pycache__/new_untracked.pyc"
                    "viewer/ejn_viewer/__pycache__/new_untracked.pyc"
                    "helper/tests/test_new.py" "helper/integration_tests/test_new.py"
                    "registry_worker/tests/test_new.py" "README.md" ".git/index"))
      (ejn-runtime-cache-test--write root name "excluded contents\n"))
    (dolist (viewer '(nil t))
      (let* ((snapshot (emacs-jupyter-notebook-runtime--snapshot root viewer))
             (directory (car snapshot))
             (relative (if viewer "viewer/ejn_viewer/new_untracked.py"
                         "helper/ejn_helper/new_untracked.py")))
        (unwind-protect
            (progn
              (should (and (stringp directory) (file-directory-p directory)))
              (should (equal (cdr snapshot)
                             (emacs-jupyter-notebook-runtime--source-key root viewer)))
              (should (equal (cdr snapshot)
                             (emacs-jupyter-notebook-runtime--source-key directory viewer)))
              (should (equal (with-temp-buffer
                               (insert-file-contents-literally
                                (expand-file-name relative directory))
                               (buffer-string))
                             "new contents\n"))
              (should (= (logand (file-modes (expand-file-name relative directory)) #o777)
                         #o755))
              (dolist (relative '("README.md" ".git"
                                  "helper/ejn_helper/__pycache__"
                                  "viewer/ejn_viewer/__pycache__"
                                  "helper/tests/test_new.py"
                                  "helper/integration_tests/test_new.py"
                                  "registry_worker/tests/test_new.py"))
                (should-not (file-exists-p (expand-file-name relative directory)))))
          (when directory (delete-directory directory t)))))))

(ert-deftest ejn-runtime-cache-relative-cache-under-remote-default-is-rejected ()
  (ejn-runtime-cache-test--with-fixture
    (let ((default-directory "/ssh:unreachable.invalid:/tmp/")
          (user-emacs-directory "relative-emacs/") (handlers 0))
      ;; Even metadata handlers must not be invoked for a relative cache
      ;; path resolved against a remote default directory.
      (let ((file-name-handler-alist
             (cons (cons "\\`/ssh:"
                         (lambda (&rest _)
                           (cl-incf handlers)
                           (error "Remote filesystem handler invoked")))
                   file-name-handler-alist)))
        (should-not (emacs-jupyter-notebook-runtime--cache-link root nil))
        (should-not (emacs-jupyter-notebook-runtime--prepare-cache-link root nil))
        (should (= handlers 0))))))

(provide 'emacs-jupyter-notebook-runtime-cache-tests)

;;; emacs-jupyter-notebook-runtime-cache-tests.el ends here
