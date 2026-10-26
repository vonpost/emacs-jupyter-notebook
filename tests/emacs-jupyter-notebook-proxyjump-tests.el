;;; emacs-jupyter-notebook-proxyjump-tests.el --- ProxyJump isolation -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-ssh)

(defmacro ejn-proxyjump-test--with-fixture (&rest body)
  "Run BODY with private SSH configuration and disposable EJN launchers."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (and (executable-find "ssh") (executable-find "bash")))
     (let* ((fixture (make-temp-file "/tmp/ejn-proxyjump-test-" t))
            (config (expand-file-name "ssh_config" fixture))
            (identity (expand-file-name "identity with spaces" fixture))
            (emacs-jupyter-notebook-ssh-command (executable-find "ssh"))
            (emacs-jupyter-notebook-ssh-options nil)
            (emacs-jupyter-notebook-ssh-control-master t)
            (emacs-jupyter-notebook-ssh-control-path
             "/tmp/ejn-proxyjump-test-target-master")
            (emacs-jupyter-notebook-ssh--ssh-wrapper-directory nil)
            (emacs-jupyter-notebook-ssh--ssh-wrapper-programs nil))
       (unwind-protect
           (progn
             (with-temp-file identity)
             (with-temp-file config
               (insert
                "Host ejn-target.invalid\n"
                "  HostName 127.0.0.21\n"
                "  User target-user\n"
                "  Port 2221\n"
                "  ProxyJump ejn-jump-last.invalid\n"
                "Host ejn-jump-last.invalid\n"
                "  HostName 127.0.0.22\n"
                "  User jump-last-user\n"
                "  Port 2222\n"
                "  ProxyJump ejn-jump-first.invalid\n"
                "Host ejn-jump-first.invalid\n"
                "  HostName 127.0.0.23\n"
                "  User jump-first-user\n"
                "  Port 2223\n"
                "Host *\n"
                "  CanonicalizeHostname no\n"
                "  IdentityFile \"" identity "\"\n"
                "  ControlMaster auto\n"
                "  ControlPath /tmp/ejn-proxyjump-test-user-master\n"
                "  ControlPersist 60\n"))
             ,@body)
         (when (fboundp 'emacs-jupyter-notebook-ssh--ssh-wrapper-cleanup)
           (emacs-jupyter-notebook-ssh--ssh-wrapper-cleanup))
         (delete-directory fixture t)))))

(defun ejn-proxyjump-test--config-value (name result)
  "Read the first NAME from RESULT's local `ssh -G' output."
  (let ((output (plist-get result :stdout)))
    (when (string-match (concat "^" (regexp-quote name) " \\(.*\\)$") output)
      (match-string 1 output))))

(defun ejn-proxyjump-test--dump (argv)
  "Evaluate ARGV with `-G -vv', without connecting or binding forwards."
  (let ((stderr-file (make-temp-file "/tmp/ejn-proxyjump-stderr-")))
    (unwind-protect
        (with-temp-buffer
          (let* ((status (apply #'call-process (car argv) nil
                                (list t stderr-file) nil
                                "-G" "-vv" (cdr argv)))
                 (stdout (buffer-string))
                 (stderr (with-temp-buffer
                           (insert-file-contents stderr-file)
                           (buffer-string))))
            (ert-info ((format "Local SSH configuration failed: %S\n%s"
                               argv stderr))
              (should (equal status 0)))
            (list :argv argv :stdout stdout :stderr stderr)))
      (delete-file stderr-file))))

(defun ejn-proxyjump-test--child-command (result)
  "Read OpenSSH's actual implicit ProxyJump command from RESULT.
Expand only the destination tokens in this controlled fixture, then split
the shell quoting produced by OpenSSH.  The returned argv is inspected
with `-G' before any command can establish a connection."
  (let ((stderr (plist-get result :stderr)))
    (when (string-match
           "Setting implicit ProxyCommand from ProxyJump: \\([^\r\n]+\\)"
           stderr)
      (let ((command (match-string 1 stderr)))
        (dolist (item `(("%h" . ,(ejn-proxyjump-test--config-value "hostname" result))
                        ("%p" . ,(ejn-proxyjump-test--config-value "port" result))))
          (setq command (replace-regexp-in-string
                         (regexp-quote (car item)) (cdr item) command t t)))
        ;; These fixture paths/hosts contain no shell metacharacters; only
        ;; OpenSSH's -W argument is single-quoted.  No general shell parser
        ;; (or newer Emacs shell-mode API) is needed to inspect that argv.
        (mapcar (lambda (word) (string-trim word "'" "'"))
                (split-string command))))))

(defun ejn-proxyjump-test--chain (argv)
  "Return effective configurations for ARGV and each implicit jump."
  (let (results)
    (while argv
      (should (< (length results) 4))
      (let ((result (ejn-proxyjump-test--dump argv)))
        (push result results)
        (setq argv (ejn-proxyjump-test--child-command result))))
    (nreverse results)))

(defun ejn-proxyjump-test--assert-route (chain identity)
  "Check that CHAIN preserves the native fixture's route and IDENTITY."
  (should (= (length chain) 3))
  (cl-loop for result in chain
           for host in '("127.0.0.21" "127.0.0.22" "127.0.0.23")
           for user in '("target-user" "jump-last-user" "jump-first-user")
           for port in '("2221" "2222" "2223")
           do (should (equal (ejn-proxyjump-test--config-value "hostname" result) host))
           do (should (equal (ejn-proxyjump-test--config-value "user" result) user))
           do (should (equal (ejn-proxyjump-test--config-value "port" result) port))
           do (should (equal (ejn-proxyjump-test--config-value "identityfile" result)
                             identity))))

(ert-deftest ejn-proxyjump-configured-jumps-cannot-share-user-master ()
  "Tunnel and probe lifetimes cannot own either configured jump's shared socket."
  (ejn-proxyjump-test--with-fixture
    (dolist (enabled '(nil t))
      (let* ((emacs-jupyter-notebook-ssh-control-master enabled)
             (profile (list :host "ejn-target.invalid"
                            :ssh-options (list "-F" config)))
             (tunnel (ejn-proxyjump-test--chain
                      (emacs-jupyter-notebook-ssh-tunnel-command
                       profile '(:shell_port 41001) '(:shell_port 42001))))
             (probe (ejn-proxyjump-test--chain
                     (emacs-jupyter-notebook-ssh-command profile "true"))))
        (ejn-proxyjump-test--assert-route tunnel identity)
        (ejn-proxyjump-test--assert-route probe identity)
        (dolist (result tunnel)
          (should-not (ejn-proxyjump-test--config-value "controlpath" result)))
        (should (equal (ejn-proxyjump-test--config-value "controlpath" (car probe))
                       (if enabled emacs-jupyter-notebook-ssh-control-path
                         "/tmp/ejn-proxyjump-test-user-master")))
        (dolist (result (cdr probe))
          (should-not (ejn-proxyjump-test--config-value "controlpath" result)))
        (should (string-match-p "^localforward .*42001 .*41001$"
                                (plist-get (car tunnel) :stdout)))))))

(ert-deftest ejn-proxyjump-explicit-chain-preserves-options-and-isolates-every-hop ()
  "Both config-file spellings and explicit multi-hop forms retain native routing."
  (ejn-proxyjump-test--with-fixture
    (dolist (config-options (list (list "-F" config) (list (concat "-F" config))))
      (dolist (jump-options '(("-J" "ejn-jump-first.invalid,ejn-jump-last.invalid")
                              ("-oProxyJump=ejn-jump-first.invalid,ejn-jump-last.invalid")))
        (let* ((emacs-jupyter-notebook-ssh-options
                '("-o" "ControlPath=/tmp/ejn-proxyjump-explicit-target-master"))
               (profile (list :host "ejn-target.invalid"
                              :ssh-options (append config-options jump-options)))
               (chain (ejn-proxyjump-test--chain
                       (emacs-jupyter-notebook-ssh-command profile "true"))))
          (ejn-proxyjump-test--assert-route chain identity)
          (should (equal (ejn-proxyjump-test--config-value "controlpath" (car chain))
                         "/tmp/ejn-proxyjump-explicit-target-master"))
          (dolist (result (cdr chain))
            (should-not (ejn-proxyjump-test--config-value "controlpath" result))))))))

(ert-deftest ejn-proxyjump-none-config-and-custom-ssh-path-are-preserved ()
  "The launcher accepts an SSH path with spaces and passes -F none unchanged."
  (ejn-proxyjump-test--with-fixture
    (let ((custom-ssh (expand-file-name "custom ssh executable" fixture)))
      (make-symbolic-link emacs-jupyter-notebook-ssh-command custom-ssh)
      (let* ((emacs-jupyter-notebook-ssh-command custom-ssh)
             (profile (list :host "ejn-target.invalid"
                            :ssh-options (list "-F" config)))
             (chain (ejn-proxyjump-test--chain
                     (emacs-jupyter-notebook-ssh-tunnel-command
                      profile '(:shell_port 41001) '(:shell_port 42001)))))
        (ejn-proxyjump-test--assert-route chain identity)
        (dolist (result chain)
          (should-not (ejn-proxyjump-test--config-value "controlpath" result)))
        (dolist (options '(("-F" "none") ("-Fnone")))
          (let* ((profile (list :host "ejn-no-config.invalid"
                                :ssh-options options))
                 (argv (emacs-jupyter-notebook-ssh-command profile "true"))
                 (result (ejn-proxyjump-test--dump argv)))
            (dolist (option options) (should (member option argv)))
            (should (equal (ejn-proxyjump-test--config-value "hostname" result)
                           "ejn-no-config.invalid"))
            (should-not (ejn-proxyjump-test--child-command result))))))))

(ert-deftest ejn-proxyjump-scp-both-directions-use-top-level-launcher ()
  "Real SCP selects EJN's transport after user -S options, preserving target args."
  (skip-unless (executable-find "scp"))
  (ejn-proxyjump-test--with-fixture
    (let* ((capture (expand-file-name "captured-ssh-argv" fixture))
           (fake-ssh (expand-file-name "capture ssh" fixture))
           (local-file (expand-file-name "source.txt" fixture))
           (emacs-jupyter-notebook-scp-command (executable-find "scp")))
      (with-temp-file local-file (insert "fixture\n"))
      (with-temp-file fake-ssh
        (insert "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" > " (shell-quote-argument capture) "\n"
                "exit 1\n"))
      (set-file-modes fake-ssh #o700)
      (let* ((emacs-jupyter-notebook-ssh-command fake-ssh)
             (profile (list :host "ejn-target.invalid"
                            :ssh-options
                            (list "-S" "/never/execute-this-scp-transport"
                                  "-F" config)))
             (program (emacs-jupyter-notebook-ssh--ssh-program)))
        (dolist (argv (list
                      (emacs-jupyter-notebook-ssh-scp-from-command
                       profile "/remote/data" (expand-file-name "download" fixture))
                      (emacs-jupyter-notebook-ssh-scp-to-command
                       profile local-file "/remote/data")))
          (let ((last-selection (cl-position "-S" argv :test #'equal :from-end t)))
            ;; Check transport selection before running SCP: the selected
            ;; executable only records argv and exits; it cannot connect.
            (should last-selection)
            (should (equal (nth (1+ last-selection) argv) program)))
          (when (file-exists-p capture) (delete-file capture))
          (with-temp-buffer
            (should-not (equal 0 (apply #'call-process (car argv) nil t nil (cdr argv)))))
          (should (file-exists-p capture))
          (let ((transport-argv (with-temp-buffer
                                  (insert-file-contents capture)
                                  (split-string (buffer-string) "\n" t))))
            (should (member config transport-argv))
            (should (member "ejn-target.invalid" transport-argv))
            (should (member (concat "ControlPath=" emacs-jupyter-notebook-ssh-control-path)
                            transport-argv))
            ;; The target still owns its one-shot multiplexing choice; only
            ;; implicit ProxyJump children receive the disabling short flag.
            (should-not (member "-S" transport-argv))))))))

(ert-deftest ejn-proxyjump-launchers-are-private-cached-and-cleaned ()
  "Launcher cleanup removes only EJN's private local scripts and resets its cache."
  (ejn-proxyjump-test--with-fixture
    (let* ((program (emacs-jupyter-notebook-ssh--ssh-program))
           (directory emacs-jupyter-notebook-ssh--ssh-wrapper-directory))
      (should (equal program (emacs-jupyter-notebook-ssh--ssh-program)))
      (should (file-executable-p program))
      (should (file-name-absolute-p program))
      (should (file-in-directory-p program directory))
      (should (equal (logand (file-modes directory) #o777) #o700))
      (should-not (string-match-p "[^/[:alnum:]_.-]" program))
      (emacs-jupyter-notebook-ssh--ssh-wrapper-cleanup)
      (should-not emacs-jupyter-notebook-ssh--ssh-wrapper-directory)
      (should-not emacs-jupyter-notebook-ssh--ssh-wrapper-programs)
      (should-not (file-exists-p directory))
      (should (file-exists-p config)))))

(provide 'emacs-jupyter-notebook-proxyjump-tests)
;;; emacs-jupyter-notebook-proxyjump-tests.el ends here
