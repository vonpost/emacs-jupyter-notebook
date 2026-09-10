;;; emacs-jupyter-notebook-ssh-isolation-tests.el --- CC22 tunnel isolation -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-ssh)

(ert-deftest ejn-cc22-tunnel-isolation-follows-all-user-options ()
  "The final control socket selection overrides both long and short user flags."
  (dolist (enabled '(nil t))
    (let* ((emacs-jupyter-notebook-ssh-control-master enabled)
           (emacs-jupyter-notebook-ssh-options
            '("-o" "ControlPath=/tmp/ejn-global-control"))
           (profile '(:host "ejn-isolation.invalid"
                      :ssh-options ("-S" "/tmp/ejn-profile-control")))
           (argv (emacs-jupyter-notebook-ssh-tunnel-command
                  profile '(:shell_port 41001) '(:shell_port 42001)))
           (last-short (cl-position "-S" argv :test #'equal :from-end t)))
      (should last-short)
      (should (equal (nth (1+ last-short) argv) "none"))
      (should (> last-short (cl-position "/tmp/ejn-profile-control" argv :test #'equal)))
      (should (member "42001:127.0.0.1:41001" argv)))))

(ert-deftest ejn-cc22-tunnel-isolation-effective-openssh-config ()
  "Local ssh -G proves inherited and explicit control sockets cannot capture a tunnel."
  (skip-unless (executable-find "ssh"))
  (let ((config (make-temp-file "ejn-cc22-ssh-config-")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "Host ejn-isolation.invalid\n"
                    "  HostName 127.0.0.1\n"
                    "  CanonicalizeHostname no\n"
                    "  ControlMaster auto\n"
                    "  ControlPath /tmp/ejn-inherited-control-%C\n"
                    "  ControlPersist 60\n"))
          (dolist (enabled '(nil t))
            (dolist (scope '(global profile))
              (dolist (options '(nil
                                 ("-o" "ControlPath=/tmp/ejn-explicit-control")
                                 ("-oControlPath=/tmp/ejn-explicit-control")
                                 ("-S" "/tmp/ejn-explicit-control")
                                 ("-S/tmp/ejn-explicit-control")))
                (let* ((emacs-jupyter-notebook-ssh-control-master enabled)
                       (emacs-jupyter-notebook-ssh-options (and (eq scope 'global) options))
                       (profile (list :host "ejn-isolation.invalid"
                                      :ssh-options (and (eq scope 'profile) options)))
                       (argv (emacs-jupyter-notebook-ssh-tunnel-command
                              profile '(:shell_port 41001) '(:shell_port 42001))))
                  (with-temp-buffer
                    ;; -G exits after configuration evaluation; this never
                    ;; opens an SSH connection or binds a forwarded port.
                    (should (zerop (apply #'call-process (executable-find "ssh")
                                         nil '(t nil) nil "-G" "-F" config (cdr argv))))
                    (should-not (string-match-p "^controlpath " (buffer-string)))
                    (should (string-match-p "^hostname 127\\.0\\.0\\.1$" (buffer-string)))
                    (should (string-match-p "^localforward .*42001 .*41001$" (buffer-string)))))))))
      (delete-file config))
    (should-not (file-exists-p config))))

(ert-deftest ejn-cc22-one-shot-commands-retain-multiplexing-policy ()
  "Tunnel isolation does not override the user's one-shot SSH/SCP control sockets."
  (let* ((emacs-jupyter-notebook-ssh-control-master nil)
         (emacs-jupyter-notebook-ssh-options '("-o" "ControlPath=/tmp/ejn-selected-control"))
         (profile '(:host "ejn-isolation.invalid")))
    (dolist (argv (list (emacs-jupyter-notebook-ssh-command profile "true")
                       (emacs-jupyter-notebook-ssh-scp-from-command
                        profile "/remote/connection.json" "/tmp/local-connection.json")))
      (should (member "ControlPath=/tmp/ejn-selected-control" argv))
      (should-not (member "none" argv)))))

(provide 'emacs-jupyter-notebook-ssh-isolation-tests)
;;; emacs-jupyter-notebook-ssh-isolation-tests.el ends here
