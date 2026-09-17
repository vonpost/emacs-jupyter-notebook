;;; emacs-jupyter-notebook-docker-shell-tests.el --- Docker shell integration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execute the actual remote shell snippets against a deterministic Docker CLI.
;; No Docker daemon, SSH server, Jupyter runtime, or remote host is required.

;;; Code:

(require 'ert)
(require 'json)
(require 'emacs-jupyter-notebook)

(defconst ejn-docker-shell--fixture
  (expand-file-name "fixtures/ejn_fake_docker.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defvar ejn-docker-shell--state-file)

(defun ejn-docker-shell--state ()
  "Read the CLI fixture state."
  (with-temp-buffer
    (insert-file-contents ejn-docker-shell--state-file)
    (json-parse-buffer :object-type 'hash-table :array-type 'array
                       :false-object :false :null-object nil)))

(defun ejn-docker-shell--save (state)
  "Write fixture STATE."
  (with-temp-file ejn-docker-shell--state-file
    (insert (json-serialize state :false-object :false :null-object nil))))

(defmacro ejn-docker-shell--with-fixture (&rest body)
  "Run BODY with an isolated shell, fake Docker, and profile."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "ejn-docker-shell-" t))
          (process-environment (copy-sequence process-environment))
          (ejn-docker-shell--state-file (expand-file-name "state.json" directory))
          (profile (list :profile "docker-test" :host "unused.invalid"
                         :launcher 'docker :docker-image "example/image:gpu"
                         :docker-options '("--gpus" "all" "--ipc=host"
                                           "-v" "local2:/local2"
                                           "--env" "LITERAL=$(false); space ' quote")
                         :remote-cache-dir (expand-file-name "cache with spaces" directory)
                         :remote-cwd "/pluto" :python-command '("python")
                         :kernelspec "python3")))
     (unwind-protect
         (progn
           (copy-file ejn-docker-shell--fixture (expand-file-name "docker" directory))
           (set-file-modes (expand-file-name "docker" directory) #o700)
           ;; Exercise the production bounded retry loop without spending
           ;; five seconds on its remote sleep budget in each unit run.
           (with-temp-file (expand-file-name "sleep" directory)
             (insert "#!/bin/sh\nexit 0\n"))
           (set-file-modes (expand-file-name "sleep" directory) #o700)
           (setenv "PATH" (concat directory path-separator (getenv "PATH")))
           (setenv "EJN_FAKE_DOCKER_STATE" ejn-docker-shell--state-file)
           (with-temp-file ejn-docker-shell--state-file (insert "{}"))
           ,@body)
       (delete-directory directory t))))

(defun ejn-docker-shell--run (command &optional failure)
  "Execute actual shell COMMAND; require success unless FAILURE is non-nil."
  (with-temp-buffer
    (let ((status (call-process shell-file-name nil t nil "-c" command)))
      (if failure (should-not (equal status 0)) (should (equal status 0))))
    (buffer-string)))

(defun ejn-docker-shell--argv (argv &optional failure)
  "Execute the remote command from SSH ARGV, optionally expecting FAILURE."
  (ejn-docker-shell--run (car (last argv)) failure))

(defun ejn-docker-shell--launch (profile)
  "Resolve and launch PROFILE; return (PROVISIONAL PROMOTED RESOLVED)."
  (let* ((session "shell-test")
         (resolution (emacs-jupyter-notebook-launcher-build-resolution profile session))
         (output (ejn-docker-shell--run (plist-get resolution :remote-command)))
         (resolved (emacs-jupyter-notebook-launcher-parse-resolved
                    profile output session "python3"
                    (plist-get resolution :connection-file) resolution))
         (launch (emacs-jupyter-notebook-launcher-build-launch profile session resolved))
         (entry (append (list :session-id session :profile "docker-test"
                              :remote-host "unused.invalid" :remote-cwd "/pluto"
                              :kernelspec "python3" :provisional t
                              :remote-connection-file (plist-get launch :connection-file)
                              :remote-pid-sidecar (plist-get launch :sidecar-file)
                              :connection-file-tokens (plist-get launch :connection-tokens))
                        (plist-get launch :entry-fields))))
    (should (emacs-jupyter-notebook-launcher-entry-valid-p entry))
    (should (equal (ejn-docker-shell--run (plist-get launch :remote-command))
                   "EJN_LAUNCH_ADMITTED\n"))
    (let* ((identity (ejn-docker-shell--argv
                      (emacs-jupyter-notebook-launcher-build-read-identity profile entry)))
           (promoted (emacs-jupyter-notebook-launcher-parse-identity entry identity)))
      (should (plist-get promoted :docker-container-id))
      (list entry promoted resolved))))

(ert-deftest ejn-docker-shell-resolve-launch-recover-and-clean ()
  "Real shell quoting preserves container argv; exact saved identity recovers."
  (ejn-docker-shell--with-fixture
    (pcase-let* ((`(,entry ,promoted ,resolved) (ejn-docker-shell--launch profile))
                 (state (ejn-docker-shell--state))
                 (calls (mapcar (lambda (argv) (append argv nil))
                                (gethash "calls" state)))
                 (runs (cl-remove-if-not (lambda (argv) (equal (nth 2 argv) "run")) calls))
                 (connection (plist-get promoted :remote-connection-file)))
      (should (= (length runs) 2))
      (should (equal (car (plist-get resolved :argv)) "/opt/image/bin/python"))
      (dolist (argv runs)
        (should (member "LITERAL=$(false); space ' quote" argv))
        (should (member "local2:/local2" argv))
        (should (member "all" argv)))
      (should (= (file-modes connection) #o600))
      (should (= (file-modes (file-name-directory connection)) #o700))
      ;; Reading identity from the original provisional entry models a lost
      ;; launch reply. It must recover the same ID without another run call.
      (should (equal (plist-get promoted :docker-container-id)
                     (plist-get
                      (emacs-jupyter-notebook-launcher-parse-identity
                       entry (ejn-docker-shell--argv
                              (emacs-jupyter-notebook-launcher-build-read-identity profile entry)))
                      :docker-container-id)))
      (should (equal (ejn-docker-shell--argv
                      (emacs-jupyter-notebook-launcher-build-probe profile promoted))
                     "__EJN_ALIVE_MATCH__\n__EJN_DONE__\n"))
      (should (equal (ejn-docker-shell--argv
                      (emacs-jupyter-notebook-launcher-build-cleanup profile promoted))
                     "__EJN_CLEANUP_DONE__\n"))
      (should-not (file-exists-p connection))
      (should (= (hash-table-count (gethash "containers" (ejn-docker-shell--state))) 0))
      (should (equal (ejn-docker-shell--argv
                      (emacs-jupyter-notebook-launcher-build-probe profile promoted))
                     "__EJN_DEAD__\n__EJN_DONE__\n")))))

(ert-deftest ejn-docker-shell-daemon-failure-retains-files-and-identity ()
  "An unreachable daemon cannot prove death or authorize destructive cleanup."
  (ejn-docker-shell--with-fixture
    (let* ((entry (cadr (ejn-docker-shell--launch profile)))
           (state (ejn-docker-shell--state)))
      (puthash "unavailable" t state)
      (ejn-docker-shell--save state)
      (should (string-match-p "__EJN_EXISTENCE_UNAVAILABLE__"
                              (ejn-docker-shell--argv
                               (emacs-jupyter-notebook-launcher-build-probe profile entry))))
      (ejn-docker-shell--argv (emacs-jupyter-notebook-launcher-build-cleanup profile entry) t)
      (should (file-exists-p (plist-get entry :remote-connection-file)))
      (should (= (hash-table-count (gethash "containers" (ejn-docker-shell--state))) 1)))))

(ert-deftest ejn-docker-shell-reused-name-does-not-authorize-cleanup ()
  "An exact container ID mismatch preserves the replacement and connection file."
  (ejn-docker-shell--with-fixture
    (let* ((entry (cadr (ejn-docker-shell--launch profile)))
           (state (ejn-docker-shell--state))
           (containers (gethash "containers" state))
           (container (gethash (plist-get entry :docker-container-id) containers)))
      (puthash "Id" (make-string 64 ?f) container)
      (ejn-docker-shell--save state)
      (should (string-match-p "__EJN_ALIVE_MISMATCH__"
                              (ejn-docker-shell--argv
                               (emacs-jupyter-notebook-launcher-build-probe profile entry))))
      (ejn-docker-shell--argv (emacs-jupyter-notebook-launcher-build-cleanup profile entry) t)
      (should (file-exists-p (plist-get entry :remote-connection-file)))
      (should (= (hash-table-count (gethash "containers" (ejn-docker-shell--state))) 1)))))

(ert-deftest ejn-docker-shell-restart-retirement-requires-stopped-container ()
  "Restart retirement never kills a running kernel or removes its connection file."
  (ejn-docker-shell--with-fixture
    (let* ((entry (cadr (ejn-docker-shell--launch profile)))
           (command (emacs-jupyter-notebook-launcher-build-restart-cleanup profile entry)))
      (ejn-docker-shell--argv command t)
      (let* ((state (ejn-docker-shell--state))
             (container (gethash (plist-get entry :docker-container-id)
                                 (gethash "containers" state))))
        (puthash "Running" :false (gethash "State" container))
        (puthash "Pid" 0 (gethash "State" container))
        (ejn-docker-shell--save state))
      (ejn-docker-shell--argv command)
      (should (file-exists-p (plist-get entry :remote-connection-file)))
      (should (= (hash-table-count (gethash "containers" (ejn-docker-shell--state))) 0)))))

(provide 'emacs-jupyter-notebook-docker-shell-tests)
;;; emacs-jupyter-notebook-docker-shell-tests.el ends here
