;;; emacs-jupyter-notebook-docker-command-tests.el --- Resolver command tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Container-only Python paths must never become direct host kernel commands.
;; These tests construct argv only; no Docker, SSH, or remote host is needed.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-ssh)

(ert-deftest ejn-docker-command-rejected-before-kernelspec-resolution ()
  "Direct Docker commands fail with a useful diagnostic before SSH dispatch."
  (dolist (argv '(("docker" "run" "-it" "--rm" "my/image" "python")
                  ("/usr/bin/docker" "run" "--rm" "my/image" "python")
                  ("docker" "--context" "remote" "run" "my/image" "python")
                  ("docker" "exec" "running-container" "python")
                  ("/usr/local/bin/docker" "exec" "running-container" "python")))
    (let (ssh-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-command)
                 (lambda (&rest _)
                   (setq ssh-called t)
                   '("ssh" "example.test"))))
        (let* ((profile (list :profile "container" :host "example.test"
                              :python-command argv))
               (failure
                (should-error
                 (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
                  profile "docker-test"))))
          (should-not ssh-called)
          (should (string-match-p "Docker" (error-message-string failure)))
          (should (string-match-p ":python-command"
                                  (error-message-string failure)))
          (should (string-match-p "SSH host"
                                  (error-message-string failure))))))))

(ert-deftest ejn-docker-command-rejected-through-default-command ()
  "The global resolver command follows the same validation as a profile."
  (let ((emacs-jupyter-notebook-python-command
         '("docker" "run" "--rm" "my/image" "python")))
    (should-error
     (emacs-jupyter-notebook-ssh-profile
      '(:profile "container" :host "example.test")))))

(ert-deftest ejn-docker-command-preserves-host-python-prefixes ()
  "Normal host Python, Nix, and uv resolver commands remain structured argv."
  (dolist (argv '(("python3")
                  ("/opt/python/bin/python")
                  ("uv" "run" "--project" "/srv/work" "python")
                  ("nix" "shell" "nixpkgs#python3" "-c" "python")))
    (let* ((profile (list :profile "host" :host "example.test"
                          :python-command argv))
           (normalized (emacs-jupyter-notebook-ssh-profile profile))
           (resolution
            (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
             profile "host-test")))
      (should (equal argv (plist-get normalized :python-command)))
      (should (string-match-p
               (regexp-quote
                (mapconcat #'shell-quote-argument (append argv '("-c")) " "))
               (plist-get resolution :remote-command))))))

(provide 'emacs-jupyter-notebook-docker-command-tests)
;;; emacs-jupyter-notebook-docker-command-tests.el ends here
