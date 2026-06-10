;;; emacs-jupyter-notebook-tests.el --- Tests for emacs-jupyter-notebook  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Unit tests that do not require emacs-jupyter, Jupyter, SSH, or a remote host.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defmacro ejn-test-with-temp-buffer (content &rest body)
  "Create a temporary buffer containing CONTENT and evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     (python-mode)
     ,@body))

(defmacro ejn-test-with-temp-file (var &rest body)
  "Bind VAR to a temporary file path and evaluate BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ejn-test-")))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p ,var)
         (delete-file ,var)))))

(ert-deftest ejn-cell-no-marker-is-whole-buffer ()
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (should (equal (emacs-jupyter-notebook-cell-bounds)
                   (cons (point-min) (point-max))))
    (should (equal (emacs-jupyter-notebook-cell-code) "x = 1\ny = 2\n"))))

(ert-deftest ejn-cell-current-marker-with-title ()
  (ejn-test-with-temp-buffer "# %% setup\na = 1\n# %% work\nb = 2\n"
    (search-forward "b = 2")
    (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
      (should (equal (buffer-substring-no-properties beg end) "b = 2\n")))))

(ert-deftest ejn-cell-empty-cell-between-markers ()
  (ejn-test-with-temp-buffer "# %%\n# %%\nx = 1\n"
    (goto-char (point-min))
    (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
      (should (equal (buffer-substring-no-properties beg end) "")))))

(ert-deftest ejn-cell-inline-marker-is-not-boundary ()
  (ejn-test-with-temp-buffer "x = '# %%'\ny = 2\n"
    (search-forward "y = 2")
    (should (equal (emacs-jupyter-notebook-cell-bounds)
                   (cons (point-min) (point-max))))))

(ert-deftest ejn-registry-roundtrip-and-permissions ()
  (ejn-test-with-temp-file file
    (let ((entry '(:profile "default"
                   :remote-host "mother"
                   :remote-cwd "/tmp/project"
                   :kernelspec "python3"
                   :remote-connection-file "/tmp/kernel.json"
                   :remote-pid 123
                   :created-at "2026-06-10T00:00:00+0000"
                   :tunnel-ports (:shell_port 50001)
                   :display-name "mother:python3"
                   :session-id "abc")))
      (emacs-jupyter-notebook-registry-save (list entry) file)
      (should (equal (emacs-jupyter-notebook-registry-load file) (list entry)))
      (should (= (logand (file-modes file) #o777) #o600)))))

(ert-deftest ejn-registry-save-creates-parent-directory ()
  (let* ((dir (make-temp-file "ejn-registry-dir-" t))
         (file (expand-file-name "missing/registry.el" dir)))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save
           '((:profile "default" :session-id "abc")) file)
          (should (file-readable-p file))
          (should (equal (emacs-jupyter-notebook-registry-load file)
                         '((:profile "default" :session-id "abc")))))
      (delete-directory dir t))))

(ert-deftest ejn-registry-upsert-remove-find ()
  (let* ((a '(:profile "default" :session-id "a" :created-at "1"))
         (b '(:profile "default" :session-id "b" :created-at "2"))
         (a2 '(:profile "default" :session-id "a" :created-at "3"))
         (entries (emacs-jupyter-notebook-registry-upsert a nil)))
    (setq entries (emacs-jupyter-notebook-registry-upsert b entries))
    (setq entries (emacs-jupyter-notebook-registry-upsert a2 entries))
    (should (= (length entries) 2))
    (should (equal (emacs-jupyter-notebook-registry-find "a" entries) a2))
    (should (equal (emacs-jupyter-notebook-registry-latest-for-profile "default" entries) a2))
    (should-not (emacs-jupyter-notebook-registry-find
                 "a" (emacs-jupyter-notebook-registry-remove "a" entries)))))

(ert-deftest ejn-connection-rewrite-ports-preserves-keys ()
  (let* ((conn '(:ip "10.0.0.5"
                 :transport "tcp"
                 :shell_port 1
                 :iopub_port 2
                 :stdin_port 3
                 :hb_port 4
                 :control_port 5
                 :key "secret"
                 :signature_scheme "hmac-sha256"))
         (ports '(:shell_port 1001
                  :iopub_port 1002
                  :stdin_port 1003
                  :hb_port 1004
                  :control_port 1005))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports conn ports)))
    (should (equal (plist-get rewritten :ip) "127.0.0.1"))
    (should (equal (plist-get rewritten :shell_port) 1001))
    (should (equal (plist-get rewritten :control_port) 1005))
    (should (equal (plist-get rewritten :key) "secret"))
    (should (equal (plist-get rewritten :signature_scheme) "hmac-sha256"))
    (should (equal (plist-get conn :shell_port) 1))))

(ert-deftest ejn-connection-file-read-write ()
  (ejn-test-with-temp-file file
    (let ((conn '(:ip "127.0.0.1" :shell_port 123 :key "secret")))
      (emacs-jupyter-notebook-connection-write-file conn file)
      (should (equal (emacs-jupyter-notebook-connection-read-file file) conn)))))

(ert-deftest ejn-retrieve-connection-file-retries-until-parseable ()
  (ejn-test-with-temp-file local-file
    (let ((attempts 0)
          (sleeps 0)
          (emacs-jupyter-notebook-connection-retrieve-attempts 3)
          (emacs-jupyter-notebook-connection-retrieve-delay 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
                 (lambda (_argv)
                   (setq attempts (1+ attempts))
                   (with-temp-file local-file
                     (insert (if (= attempts 1)
                                 "{"
                               "{\"ip\":\"127.0.0.1\",\"shell_port\":123}")))
                   ""))
                ((symbol-function 'sleep-for)
                 (lambda (&rest _)
                   (setq sleeps (1+ sleeps)))))
        (should (equal (emacs-jupyter-notebook--retrieve-connection-file
                        '(:profile "p" :host "example.com")
                        "/tmp/kernel.json" local-file)
                       '(:ip "127.0.0.1" :shell_port 123)))
        (should (= attempts 2))
        (should (= sleeps 1))))))

(ert-deftest ejn-ssh-basic-command-with-user-port-and-options ()
  (let ((emacs-jupyter-notebook-ssh-command "ssh")
        (emacs-jupyter-notebook-ssh-options '("-o" "BatchMode=yes")))
    (should (equal (emacs-jupyter-notebook-ssh-command
                    '(:profile "p" :host "example.com" :user "alice" :port 2222))
                   '("ssh" "-o" "BatchMode=yes" "-p" "2222" "alice@example.com")))))

(ert-deftest ejn-ssh-tunnel-command-multiple-ports ()
  (let ((cmd (emacs-jupyter-notebook-ssh-tunnel-command
              '(:profile "p" :host "example.com")
              '(:shell_port 1 :iopub_port 2 :stdin_port 3 :hb_port 4 :control_port 5)
              '(:shell_port 1001 :iopub_port 1002 :stdin_port 1003 :hb_port 1004 :control_port 1005))))
    (should (equal (car cmd) emacs-jupyter-notebook-ssh-command))
    (should (member "1001:127.0.0.1:1" cmd))
    (should (member "1005:127.0.0.1:5" cmd))
    (should (equal (car (last cmd)) "example.com"))))

(ert-deftest ejn-ssh-remote-launch-command-is-detached ()
  (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                  '(:profile "p" :host "mother" :remote-cwd "/work" :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                  "session"))
         (remote-command (plist-get launch :remote-command)))
    (should (equal (plist-get launch :connection-file) "/tmp/ejn/kernel-session.json"))
    (should (string-match-p "nohup jupyter kernel" remote-command))
    (should (string-match-p "--kernel=python3" remote-command))
    (should (string-match-p "printf" remote-command))))

(ert-deftest ejn-result-overlay-create-and-clear-without-text-mutation ()
  (ejn-test-with-temp-buffer "# %%\n1 + 1\n"
    (let ((before (buffer-string)))
      (emacs-jupyter-notebook-result-create (point-min) (point-max) "2")
      (should (equal (buffer-string) before))
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 1))
      (emacs-jupyter-notebook-result-clear-all)
      (should (equal (buffer-string) before))
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0)))))

(ert-deftest ejn-result-overlay-replaces-existing-for-region ()
  (ejn-test-with-temp-buffer "x = 1\n"
    (emacs-jupyter-notebook-result-create (point-min) (point-max) "one")
    (emacs-jupyter-notebook-result-create (point-min) (point-max) "two")
    (let ((overlays (emacs-jupyter-notebook-result--all-overlays)))
      (should (= (length overlays) 1))
      (should (string-match-p "two" (overlay-get (car overlays) 'after-string))))))

(ert-deftest ejn-evaluate-cell-does-not-mutate-source ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n# %%\nb = 2\n"
    (search-forward "a = 1")
    (let ((before (buffer-string))
          (emacs-jupyter-notebook--client 'mock-client)
          captured-code)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code beg end)
               (setq captured-code code)
               (emacs-jupyter-notebook-result-create beg end "ok"))))
        (emacs-jupyter-notebook-evaluate-current-cell))
      (should (equal captured-code "a = 1\n"))
      (should (equal (buffer-string) before))
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 1)))))

(ert-deftest ejn-evaluate-region-and-buffer-do-not-mutate-source ()
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (let ((before (buffer-string))
          (modified (buffer-modified-p))
          (emacs-jupyter-notebook--client 'mock-client)
          calls)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code _beg _end)
               (push code calls))))
        (emacs-jupyter-notebook-evaluate-region (point-min) (line-end-position))
        (emacs-jupyter-notebook-evaluate-buffer))
      (should (equal (buffer-string) before))
      (should (equal (buffer-modified-p) modified))
      (should (equal (nreverse calls) '("x = 1" "x = 1\ny = 2\n"))))))

(provide 'emacs-jupyter-notebook-tests)

;;; emacs-jupyter-notebook-tests.el ends here
