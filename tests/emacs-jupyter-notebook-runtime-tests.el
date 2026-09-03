;;; emacs-jupyter-notebook-runtime-tests.el --- Lazy Nix runtime tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook)

(defmacro ejn-runtime-test--clean (&rest body)
  "Run BODY with the shared runtime state restored afterwards."
  (declare (indent 0) (debug body))
  `(let ((saved-build emacs-jupyter-notebook-runtime--build)
         (saved-directory emacs-jupyter-notebook--runtime-directory))
     (setq emacs-jupyter-notebook-runtime--build nil
           emacs-jupyter-notebook--runtime-directory nil)
     (unwind-protect
         (progn ,@body)
       (when emacs-jupyter-notebook-runtime--build
         (emacs-jupyter-notebook-runtime--fail
          emacs-jupyter-notebook-runtime--build "test cleanup"))
       (setq emacs-jupyter-notebook-runtime--build saved-build
             emacs-jupyter-notebook--runtime-directory saved-directory)
       (dolist (buffer (buffer-list))
         (when (string-match-p "\\*ejn-runtime-build" (buffer-name buffer))
           (kill-buffer buffer))))))

(defun ejn-runtime-test--fixture (&optional output)
  "Create a complete runtime fixture and return its directory."
  (let ((root (make-temp-file "ejn-runtime-output-" t)))
    (make-directory (expand-file-name "bin" root) t)
    (dolist (name '("ejn-helper" "ejn-registry-worker"))
      (let ((file (expand-file-name (concat "bin/" name) root)))
        (with-temp-file file (insert "#!/bin/sh\nexit 0\n"))
        (set-file-modes file #o700)))
    (when output
      (with-temp-file output (insert (file-name-as-directory root) "\n")))
    root))

(ert-deftest ejn-runtime-package-root-is-physical-and-default-directory-independent ()
  (let* ((physical (make-temp-file "ejn-runtime-package-" t))
         (linked (concat physical "-link"))
         (old-module emacs-jupyter-notebook-runtime--module-directory))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "flake.nix" physical) (insert "{}"))
          (with-temp-file (expand-file-name "flake.lock" physical) (insert "{}"))
          (make-symbolic-link physical linked)
          (let ((emacs-jupyter-notebook-runtime--module-directory linked)
                (default-directory "/"))
            (should (equal (emacs-jupyter-notebook-runtime--package-root)
                           (file-name-as-directory (file-truename physical))))))
      (setq emacs-jupyter-notebook-runtime--module-directory old-module)
      (if (file-symlink-p linked)
          (delete-file linked)
        (delete-directory linked t))
      (delete-directory physical t))))

(ert-deftest ejn-runtime-package-root-follows-straight-flake-symlink ()
  (let ((repository (make-temp-file "ejn-runtime-repository-" t))
        (build (make-temp-file "ejn-runtime-straight-build-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "flake.nix" repository) (insert "{}"))
          (with-temp-file (expand-file-name "flake.lock" repository) (insert "{}"))
          ;; A regular byte-code file models Straight's build directory; the
          ;; recipe-provided flake remains a symlink into the Git checkout.
          (with-temp-file (expand-file-name "emacs-jupyter-notebook-runtime.elc" build)
            (insert "compiled"))
          (make-symbolic-link (expand-file-name "flake.nix" repository)
                              (expand-file-name "flake.nix" build))
          (let ((emacs-jupyter-notebook-runtime--module-directory build))
            (should
             (equal (emacs-jupyter-notebook-runtime--package-root)
                    (file-name-as-directory (file-truename repository))))))
      (delete-directory build t)
      (delete-directory repository t))))

(ert-deftest ejn-runtime-package-root-recovers-from-native-cache-load ()
  (let ((repository (make-temp-file "ejn-runtime-native-repository-" t))
        (build (make-temp-file "ejn-runtime-native-build-" t))
        (eln-cache (make-temp-file "ejn-runtime-eln-cache-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "flake.nix" repository) (insert "{}"))
          (with-temp-file (expand-file-name "flake.lock" repository) (insert "{}"))
          (with-temp-file
              (expand-file-name "emacs-jupyter-notebook-runtime.el" repository)
            (insert ";;; native source anchor\n"))
          (make-symbolic-link
           (expand-file-name "emacs-jupyter-notebook-runtime.el" repository)
           (expand-file-name "emacs-jupyter-notebook-runtime.el" build))
          (make-symbolic-link (expand-file-name "flake.nix" repository)
                              (expand-file-name "flake.nix" build))
          (let ((emacs-jupyter-notebook-runtime--module-directory eln-cache)
                (load-path (list build)))
            (should
             (equal (emacs-jupyter-notebook-runtime--package-root)
                    (file-name-as-directory (file-truename repository))))))
      (delete-directory eln-cache t)
      (delete-directory build t)
      (delete-directory repository t))))

(ert-deftest ejn-runtime-ready-probe-does-not-start-a-process ()
  (ejn-runtime-test--clean
    (let ((started 0) (ready 0))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (cl-incf started))))
        (should-not
         (emacs-jupyter-notebook-runtime-ensure
          (lambda () (list :ready t :buildable t))
          (lambda () (cl-incf ready)) #'ignore)))
      (should (= ready 1))
      (should (= started 0)))))

(ert-deftest ejn-runtime-disabled-or-missing-nix-fails-without-a-build ()
  (ejn-runtime-test--clean
    (dolist (case '((disabled . "disabled") (missing-nix . "Nix is not available")))
      (let ((emacs-jupyter-notebook-auto-build-runtime
             (not (eq (car case) 'disabled)))
            failure)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                   (lambda () "/tmp/"))
                  ((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
                   (lambda () nil)))
          (emacs-jupyter-notebook-runtime-ensure
           (lambda () (list :ready nil :buildable t)) #'ignore
           (lambda (reason) (setq failure reason)))
          (should (string-match-p (cdr case) failure))
          (should-not emacs-jupyter-notebook-runtime--build))))))

(ert-deftest ejn-runtime-custom-missing-command-is-not-buildable ()
  (let ((emacs-jupyter-notebook-helper-command '("missing-custom-helper"))
        (emacs-jupyter-notebook-registry-worker-command
         '("ejn-registry-worker"))
        (emacs-jupyter-notebook--runtime-directory nil)
        (emacs-jupyter-notebook-helper--module-directory "/tmp/ejn-no-runtime/")
        (emacs-jupyter-notebook-registry--module-directory "/tmp/ejn-no-runtime/")
        (exec-path nil))
    (let ((status (emacs-jupyter-notebook--runtime-probe)))
      (should-not (plist-get status :ready))
      (should-not (plist-get status :buildable)))))

(ert-deftest ejn-runtime-published-directory-resolves-both-tools ()
  (let ((root (ejn-runtime-test--fixture)))
    (unwind-protect
        (let ((emacs-jupyter-notebook--runtime-directory root)
              (exec-path nil))
          (should
           (equal (car (emacs-jupyter-notebook-helper-resolve-argv))
                  (file-truename (expand-file-name "bin/ejn-helper" root))))
          (should
           (equal (car (emacs-jupyter-notebook-registry-worker-resolve-argv))
                  (expand-file-name "bin/ejn-registry-worker" root))))
      (delete-directory root t))))

(defun ejn-runtime-test--start-build (probe _output &optional callback failure buffer)
  "Start a mocked pending build with CALLBACK and FAILURE waiters."
  (let ((real (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
               (lambda () temporary-file-directory))
              ((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
               (lambda () "/bin/sh"))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq args (plist-put args :command
                                       (list "/bin/sh" "-c" "sleep 30")))
                 (apply real args))))
      (emacs-jupyter-notebook-runtime-ensure
       probe (or callback #'ignore) (or failure #'ignore)
       (or buffer (current-buffer))))))

(ert-deftest ejn-runtime-discovery-error-settles-and-allows-retry ()
  (ejn-runtime-test--clean
    (let ((failures 0))
      (with-temp-buffer
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                   (lambda () (error "injected discovery failure"))))
          (should-not
           (emacs-jupyter-notebook-runtime-ensure
            (lambda () (list :ready nil :buildable t)) #'ignore
            (lambda (reason)
              (should (string-match-p "injected discovery failure" reason))
              (cl-incf failures))
            (current-buffer))))
        (should (= failures 1))
        (should-not emacs-jupyter-notebook-runtime--build)
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil
         #'ignore #'ignore (current-buffer))
        (should emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-core-discovery-error-is-terminal-not-wedged ()
  (ejn-runtime-test--clean
    (let ((emacs-jupyter-notebook-helper-command '("ejn-helper" "--protocol"))
          (emacs-jupyter-notebook-registry-worker-command
           '("ejn-registry-worker"))
          (emacs-jupyter-notebook-helper--module-directory "/tmp/ejn-missing/")
          (emacs-jupyter-notebook-registry--module-directory "/tmp/ejn-missing/")
          (exec-path nil)
          failure)
      (with-temp-buffer
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--runtime-ready-p)
                   (lambda () nil))
                  ((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                   (lambda () (error "injected discovery failure"))))
          (emacs-jupyter-notebook--with-runtime-ready
           #'ignore (lambda (_context reason) (setq failure reason))))
        (should (string-match-p "injected discovery failure" failure))
        (should (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                    'error))
        (should-not (emacs-jupyter-notebook--async-in-progress-p))
        (should-not emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-build-command-and-cwd-are-platform-neutral ()
  (ejn-runtime-test--clean
    (let ((real (symbol-function 'make-process)) captured-command captured-cwd)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                 (lambda () temporary-file-directory))
                ((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
                 (lambda () "/bin/sh"))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq captured-command (plist-get args :command)
                         captured-cwd default-directory
                         args (plist-put args :command
                                         (list "/bin/sh" "-c" "sleep 30")))
                   (apply real args))))
        (with-temp-buffer
          (emacs-jupyter-notebook-runtime-ensure
           (lambda () (list :ready nil :buildable t)) #'ignore #'ignore)
          (should
           (equal (cdr captured-command)
                  '("--extra-experimental-features" "nix-command flakes"
                    "build" "--no-link" "--print-out-paths"
                    "--print-build-logs" "--show-trace" ".#default")))
          (should (equal (car captured-command) "/bin/sh"))
          (should (equal captured-cwd temporary-file-directory)))))))

(ert-deftest ejn-runtime-single-flight-cancel-one-resumes-other ()
  (ejn-runtime-test--clean
    (let* ((output (ejn-runtime-test--fixture))
           (probe (lambda ()
                    (if emacs-jupyter-notebook--runtime-directory
                        (list :ready t :buildable t)
                      (list :ready nil :buildable t))))
           (calls 0) (first nil) (second nil) token-a build-a)
      (unwind-protect
          (let ((buffer-a (generate-new-buffer " *ejn-runtime-a*"))
                (buffer-b (generate-new-buffer " *ejn-runtime-b*")))
            (unwind-protect
                (progn
                  (with-current-buffer buffer-a
                    (setq token-a (ejn-runtime-test--start-build probe output))
                    (setq build-a emacs-jupyter-notebook-runtime--build))
                  (with-current-buffer buffer-b
                    (emacs-jupyter-notebook-runtime-ensure
                     probe (lambda () (cl-incf calls))
                     (lambda (_reason) (setq second :failed)) (current-buffer)))
                  (should (eq build-a emacs-jupyter-notebook-runtime--build))
                  (with-current-buffer buffer-a
                    (should (emacs-jupyter-notebook-runtime-cancel-waiter token-a)))
                  ;; The first cancellation leaves the shared build alive.
                  (should emacs-jupyter-notebook-runtime--build)
                  (should (= calls 0))
                  (let ((build emacs-jupyter-notebook-runtime--build))
                    (with-current-buffer
                        (emacs-jupyter-notebook-runtime--build-stdout-buffer build)
                      (insert (file-name-as-directory output)))
                    (setf (emacs-jupyter-notebook-runtime--build-stdout-bytes build)
                          (string-bytes (file-name-as-directory output)))
                    (emacs-jupyter-notebook-runtime--succeed build))
                  (should (= calls 1))
                  (should-not second))
              (kill-buffer buffer-a)
              (kill-buffer buffer-b)))
        (delete-directory output t)))))

(ert-deftest ejn-runtime-single-flight-resumes-all-live-waiters-on-success ()
  (ejn-runtime-test--clean
    (let* ((output (ejn-runtime-test--fixture))
           (probe (lambda ()
                    (if emacs-jupyter-notebook--runtime-directory
                        (list :ready t :buildable t)
                      (list :ready nil :buildable t))))
           (first 0)
           (second 0)
           (buffer-a (generate-new-buffer " *ejn-runtime-all-a*"))
           (buffer-b (generate-new-buffer " *ejn-runtime-all-b*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer-a
              (ejn-runtime-test--start-build
               probe output (lambda () (cl-incf first)) #'ignore
               (current-buffer)))
            (with-current-buffer buffer-b
              (emacs-jupyter-notebook-runtime-ensure
               probe (lambda () (cl-incf second)) #'ignore (current-buffer)))
            (let ((build emacs-jupyter-notebook-runtime--build))
              (with-current-buffer
                  (emacs-jupyter-notebook-runtime--build-stdout-buffer build)
                (insert (file-name-as-directory output)))
              (setf (emacs-jupyter-notebook-runtime--build-stdout-bytes build)
                    (string-bytes (file-name-as-directory output)))
              (emacs-jupyter-notebook-runtime--succeed build))
            (should (= first 1))
            (should (= second 1))
            (should-not emacs-jupyter-notebook-runtime--build))
        (kill-buffer buffer-a)
        (kill-buffer buffer-b)
        (delete-directory output t)))))

(ert-deftest ejn-runtime-failure-resets-slot-and-allows-retry ()
  (ejn-runtime-test--clean
    (let ((failures 0) (build nil))
      (with-temp-buffer
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil
         #'ignore (lambda (_reason) (cl-incf failures)) (current-buffer))
        (setq build emacs-jupyter-notebook-runtime--build)
        (emacs-jupyter-notebook-runtime--fail build "status 1")
        (should-not emacs-jupyter-notebook-runtime--build)
        (should (= failures 1))
        (emacs-jupyter-notebook-runtime-ensure
         (lambda () (list :ready nil :buildable t)) #'ignore
         #'ignore (current-buffer))
        (should emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-failure-delivers-waiter-when-dispose-raises ()
  (ejn-runtime-test--clean
    (let ((failures 0)
          build
          (real-dispose
           (symbol-function 'emacs-jupyter-notebook-runtime--dispose)))
      (with-temp-buffer
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil #'ignore
         (lambda (_reason) (cl-incf failures)) (current-buffer))
        (setq build emacs-jupyter-notebook-runtime--build)
        (unwind-protect
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--dispose)
                       (lambda (_build) (error "injected dispose failure"))))
              (emacs-jupyter-notebook-runtime--fail build "status 1"))
          (funcall real-dispose build))
        (should (= failures 1))
        (should-not emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-success-delivers-waiter-when-dispose-raises ()
  (ejn-runtime-test--clean
    (let* ((output (ejn-runtime-test--fixture))
           (probe (lambda ()
                    (if emacs-jupyter-notebook--runtime-directory
                        (list :ready t :buildable t)
                      (list :ready nil :buildable t))))
           (successes 0)
           build
           (real-dispose
            (symbol-function 'emacs-jupyter-notebook-runtime--dispose)))
      (unwind-protect
          (with-temp-buffer
            (ejn-runtime-test--start-build
             probe output (lambda () (cl-incf successes)) #'ignore
             (current-buffer))
            (setq build emacs-jupyter-notebook-runtime--build)
            (with-current-buffer
                (emacs-jupyter-notebook-runtime--build-stdout-buffer build)
              (insert (file-name-as-directory output)))
            (unwind-protect
                (cl-letf
                    (((symbol-function 'emacs-jupyter-notebook-runtime--dispose)
                      (lambda (_build) (error "injected dispose failure"))))
                  (emacs-jupyter-notebook-runtime--succeed build))
              (funcall real-dispose build))
            (should (= successes 1))
            (should-not emacs-jupyter-notebook-runtime--build))
        (delete-directory output t)))))

(ert-deftest ejn-runtime-diagnostic-error-still-settles-failed-process ()
  (ejn-runtime-test--clean
    (let ((failures 0))
      (with-temp-buffer
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil #'ignore
         (lambda (reason)
           (should (string-match-p "process exited" reason))
           (cl-incf failures))
         (current-buffer))
        (let* ((build emacs-jupyter-notebook-runtime--build)
               (process (emacs-jupyter-notebook-runtime--build-process build)))
          (setf (emacs-jupyter-notebook-runtime--build-stderr-closed build) t)
          (set-process-sentinel process #'ignore)
          (delete-process process)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--diagnostic)
                     (lambda (&rest _) (error "injected diagnostic failure"))))
            (emacs-jupyter-notebook-runtime--sentinel build process "failed")))
        (should (= failures 1))
        (should-not emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-timeout-fails-and-clears-build ()
  (ejn-runtime-test--clean
    (let ((failure nil) (build nil))
      (with-temp-buffer
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil #'ignore
         (lambda (reason) (setq failure reason)) (current-buffer))
        (setq build emacs-jupyter-notebook-runtime--build)
        (emacs-jupyter-notebook-runtime--timeout-fired build)
        (should-not emacs-jupyter-notebook-runtime--build)
        (should (string-match-p "timed out" failure))))))

(ert-deftest ejn-runtime-cancelling-last-waiter-stops-build ()
  (ejn-runtime-test--clean
    (with-temp-buffer
      (let ((token (ejn-runtime-test--start-build
                    (lambda () (list :ready nil :buildable t)) nil
                    #'ignore #'ignore (current-buffer))))
        (should emacs-jupyter-notebook-runtime--build)
        (should (emacs-jupyter-notebook-runtime-cancel-waiter token))
        (should-not emacs-jupyter-notebook-runtime--build)))))

(ert-deftest ejn-runtime-output-limit-fails-without-reading-unbounded-data ()
  (ejn-runtime-test--clean
    (let ((emacs-jupyter-notebook-runtime-build-output-max-bytes 8)
          (failure nil))
      (with-temp-buffer
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil #'ignore
         (lambda (reason) (setq failure reason)) (current-buffer))
        (let ((build emacs-jupyter-notebook-runtime--build)
              (process (get-buffer-process
                        (emacs-jupyter-notebook-runtime--build-stdout-buffer
                         emacs-jupyter-notebook-runtime--build))))
          (emacs-jupyter-notebook-runtime--filter
           build 'stdout process (make-string 9 ?x)))
        (should (string-match-p "output limit" failure))))))

(ert-deftest ejn-runtime-progress-is-short-and-sampled ()
  "Nix progress reports only the latest bounded stderr sample."
  (ejn-runtime-test--clean
    (with-temp-buffer
      (let (report)
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil
         #'ignore #'ignore (current-buffer))
        (let* ((build emacs-jupyter-notebook-runtime--build)
               (stderr-process
                (emacs-jupyter-notebook-runtime--build-stderr-process build)))
          (let ((emacs-jupyter-notebook-runtime-progress-function
                 (lambda (_buffer line) (setq report line))))
            (emacs-jupyter-notebook-runtime--filter
             build 'stderr stderr-process "copying one\ncopying two\n")
            (should (equal report "copying two"))))))))

(ert-deftest ejn-runtime-failure-waits-for-full-stderr ()
  "Failure settlement preserves stderr beyond the old arbitrary tail cut."
  (ejn-runtime-test--clean
    (with-temp-buffer
      (let ((long-line (concat "first: " (make-string 9000 ?x))) failure)
        (ejn-runtime-test--start-build
         (lambda () (list :ready nil :buildable t)) nil #'ignore
         (lambda (reason) (setq failure reason))
         (current-buffer))
        (let* ((build emacs-jupyter-notebook-runtime--build)
               (stderr-process
                (emacs-jupyter-notebook-runtime--build-stderr-process build))
               (process (emacs-jupyter-notebook-runtime--build-process build)))
          (set-process-sentinel process #'ignore)
          (set-process-sentinel stderr-process #'ignore)
          (delete-process process)
          (emacs-jupyter-notebook-runtime--sentinel build process "killed")
          (should-not failure)
          (emacs-jupyter-notebook-runtime--filter
           build 'stderr stderr-process
           (concat long-line "\nhttps://cache.nixos.org failed\n"))
          (setf (emacs-jupyter-notebook-runtime--build-stderr-closed build) t)
          (emacs-jupyter-notebook-runtime--settle build)
          (should (string-match-p (regexp-quote long-line) failure))
          (should (string-match-p "https://cache.nixos.org failed" failure)))))))

(ert-deftest ejn-runtime-argv-and-paths-are-darwin-portable ()
  (let ((system-type 'darwin)
        (system-configuration "aarch64-apple-darwin")
        (root (make-temp-file "ejn-runtime-darwin-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "flake.nix" root) (insert "{}"))
          (with-temp-file (expand-file-name "flake.lock" root) (insert "{}"))
          (let ((emacs-jupyter-notebook-runtime--module-directory root))
            (should (file-name-absolute-p
                     (emacs-jupyter-notebook-runtime--package-root)))
            (should-not (file-remote-p
                         (emacs-jupyter-notebook-runtime--package-root)))))
      (delete-directory root t))))

(ert-deftest ejn-runtime-finds-standard-darwin-nix-without-gui-exec-path ()
  (let ((system-type 'darwin)
        (system-configuration "aarch64-apple-darwin")
        (exec-path nil))
    (cl-letf (((symbol-function 'file-executable-p)
               (lambda (path)
                 (equal path "/nix/var/nix/profiles/default/bin/nix"))))
      (should
       (equal (emacs-jupyter-notebook-runtime--nix-program)
              "/nix/var/nix/profiles/default/bin/nix")))))

(ert-deftest ejn-runtime-finds-homebrew-nix-without-gui-exec-path ()
  (let ((system-type 'darwin)
        (system-configuration "aarch64-apple-darwin")
        (exec-path nil))
    (dolist (expected '("/opt/homebrew/bin/nix" "/usr/local/bin/nix"))
      (cl-letf (((symbol-function 'file-executable-p)
                 (lambda (path) (equal path expected))))
        (should (equal (emacs-jupyter-notebook-runtime--nix-program)
                       expected))))))

(provide 'emacs-jupyter-notebook-runtime-tests)

;;; emacs-jupyter-notebook-runtime-tests.el ends here
