;;; emacs-jupyter-notebook-tests.el --- Tests for emacs-jupyter-notebook  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Unit tests that do not require emacs-jupyter, Jupyter, SSH, or a remote host.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark)
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

(defun ejn-test-overlay-display-string (ov)
  "Return the rendered display string for result overlay OV."
  (or (overlay-get ov 'after-string)
      (overlay-get ov 'before-string)))

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

(ert-deftest ejn-cell-navigation-lands-in-cell-body ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (emacs-jupyter-notebook-forward-cell)
    (should (looking-at-p "b = 2"))
    (emacs-jupyter-notebook-backward-cell)
    (should (looking-at-p "a = 1"))))

(ert-deftest ejn-cell-insert-below-creates-empty-cell-and-enters-it ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (emacs-jupyter-notebook-insert-cell-below)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %%\n# %% B\nb = 2\n"))
    (should (looking-at-p "# %% B"))))

(ert-deftest ejn-cell-insert-above-creates-empty-cell-and-enters-it ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-insert-cell-above)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %%\n# %% B\nb = 2\n"))
    (should (looking-at-p "# %% B"))))

(ert-deftest ejn-cell-delete-removes-whole-cell-and-enters-next ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-delete-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% C\nc = 3\n"))
    (should (looking-at-p "c = 3"))))

(ert-deftest ejn-cell-clear-keeps-marker-and-deletes-body ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-clear-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% B\n# %% C\nc = 3\n"))
    (should (looking-at-p "# %% C"))))

(ert-deftest ejn-cell-duplicate-copies-current-cell-and-enters-copy ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-duplicate-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% B\nb = 2\n# %% B\nb = 2\n# %% C\nc = 3\n"))
    (should (looking-at-p "b = 2"))))

(ert-deftest ejn-cell-evaluate-and-advance-moves-to-next-cell ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-evaluate-current-cell)
                 (lambda () (setq called t))))
        (emacs-jupyter-notebook-evaluate-current-cell-and-advance))
      (should called)
      (should (looking-at-p "b = 2")))))

(ert-deftest ejn-imenu-no-cells ()
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (should-not (emacs-jupyter-notebook--imenu-index))))

(ert-deftest ejn-imenu-single-cell-with-title ()
  (ejn-test-with-temp-buffer "# %% The Title\na = 1\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (= (length index) 1))
      (should (equal (caar index) "The Title"))
      (should (markerp (cdar index)))
      (should (= (cdar index) (point-min))))))

(ert-deftest ejn-imenu-multiple-cells-mixed-titles ()
  (ejn-test-with-temp-buffer
      "# %% First Cell\na = 1\n# %% \nb = 2\n# %% Third Cell\nc = 3\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (mapcar #'car index)
                     '("First Cell" "Cell 2" "Third Cell"))))))

(ert-deftest ejn-imenu-all-untitled-cells-numbered-sequentially ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n# %%\nb = 2\n# %%\nc = 3\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (mapcar #'car index)
                     '("Cell 1" "Cell 2" "Cell 3"))))))

(ert-deftest ejn-imenu-markers-point-to-marker-line-start ()
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n# %% B\ny = 2\n"
    (dolist (entry (emacs-jupyter-notebook--imenu-index))
      (save-excursion
        (goto-char (cdr entry))
        (should (bolp))
        (should (looking-at-p "# %%"))))))

(ert-deftest ejn-imenu-title-trimming ()
  (ejn-test-with-temp-buffer "# %%   Spaces Galore   \nx = 1\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (caar index) "Spaces Galore")))))

(ert-deftest ejn-imenu-mode-sets-function-and-restores-python-imenu ()
  (with-temp-buffer
    (python-mode)
    (let ((python-imenu imenu-create-index-function))
      (should (local-variable-p 'imenu-create-index-function))
      (emacs-jupyter-notebook-mode 1)
      (should (eq imenu-create-index-function
                  #'emacs-jupyter-notebook--imenu-index))
      (emacs-jupyter-notebook-mode -1)
      (should (eq imenu-create-index-function python-imenu))
      (should (local-variable-p 'imenu-create-index-function)))))

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

(ert-deftest ejn-registry-latest-for-file ()
  (let* ((file (expand-file-name "notebook.py" temporary-file-directory))
         (other (expand-file-name "other.py" temporary-file-directory))
         (a `(:profile "default" :session-id "a" :local-file ,file :created-at "1"))
         (b `(:profile "default" :session-id "b" :local-file ,file :created-at "2"))
         (c `(:profile "default" :session-id "c" :local-file ,other :created-at "3")))
    (should (equal (emacs-jupyter-notebook-registry-latest-for-file
                    file (list a b c))
                   b))))

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

(ert-deftest ejn-wait-for-tunnel-retries-until-all-ports-open ()
  (let ((attempts 0)
        (sleeps 0)
        (emacs-jupyter-notebook-tunnel-wait-timeout 1)
        (emacs-jupyter-notebook-tunnel-wait-delay 0))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--local-port-open-p)
               (lambda (_port)
                 (>= (cl-incf attempts) 6)))
              ((symbol-function 'process-live-p)
               (lambda (_process) t))
              ((symbol-function 'sleep-for)
               (lambda (&rest _)
                 (setq sleeps (1+ sleeps)))))
      (should (emacs-jupyter-notebook--wait-for-tunnel
               'mock-process
               '(:shell_port 1001
                 :iopub_port 1002
                 :stdin_port 1003
                 :hb_port 1004
                 :control_port 1005)))
      (should (= sleeps 1)))))

(ert-deftest ejn-connect-entry-waits-for-tunnel-before-jupyter-connect ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-connection-file "/tmp/kernel.json"
                 :session-id "session"))
        (profile '(:profile "p" :host "example.com"))
        (connection '(:ip "127.0.0.1"
                      :transport "tcp"
                      :shell_port 1
                      :iopub_port 2
                      :stdin_port 3
                      :hb_port 4
                      :control_port 5
                      :key "secret"))
        (local-ports '(:shell_port 1001
                       :iopub_port 1002
                       :stdin_port 1003
                       :hb_port 1004
                       :control_port 1005))
        waited)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--retrieve-connection-file)
               (lambda (&rest _) connection))
              ((symbol-function 'emacs-jupyter-notebook-connection-allocate-local-ports)
               (lambda () local-ports))
              ((symbol-function 'emacs-jupyter-notebook--start-tunnel)
               (lambda (&rest _) 'mock-process))
              ((symbol-function 'emacs-jupyter-notebook--wait-for-tunnel)
               (lambda (_process ports)
                 (should (equal ports local-ports))
                 (setq waited t)))
              ((symbol-function 'emacs-jupyter-notebook-jupyter-connect)
               (lambda (_connection-file)
                 (should waited)
                 'mock-client))
              ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
               #'ignore))
      (with-temp-buffer
        (should (equal (plist-get (emacs-jupyter-notebook--connect-entry entry profile)
                                  :tunnel-ports)
                       local-ports))
        (should (eq emacs-jupyter-notebook--client 'mock-client))))))

(ert-deftest ejn-start-remote-kernel-uses-async-launch ()
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "start command used synchronous SSH")))
               ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                (lambda (_name _argv _sentinel)
                  (setq started t)
                  'mock-launch-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (let ((context (emacs-jupyter-notebook-start-remote-kernel "p")))
          (should started)
          (should (eq context emacs-jupyter-notebook--async-context))
          (should (eq (plist-get context :phase) 'launch))
          (should (eq (plist-get context :launch-process) 'mock-launch-process))
          (should (equal (plist-get (plist-get context :entry) :local-file)
                         "/tmp/example-notebook.py"))
          (should (string-match-p "example-notebook" (plist-get context :session-id))))))))

(ert-deftest ejn-start-remote-kernel-requires-file-buffer ()
  (let ((emacs-jupyter-notebook-remote-profiles
           '(("p" . (:host "example.com")))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore))
      (with-temp-buffer
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)))))

(ert-deftest ejn-start-remote-kernel-refuses-duplicate-operation ()
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _)
                 (setq started t)
                 'mock-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'retrieve
               :origin-buffer (current-buffer)))
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)
        (should-not started)))))

(ert-deftest ejn-start-remote-kernel-refuses-existing-client-noninteractive ()
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _)
                 (setq started t)
                 'mock-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (setq emacs-jupyter-notebook--client 'mock-client)
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)
        (should-not started)))))

(ert-deftest ejn-reconnect-remote-kernel-uses-async-retrieve ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "reconnect command used synchronous SSH")))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieved t)
                 context)))
      (with-temp-buffer
        (let ((context (emacs-jupyter-notebook-reconnect-remote-kernel entry)))
          (should retrieved)
          (should (eq context emacs-jupyter-notebook--async-context))
          (should (eq (plist-get context :phase) 'retrieve))
          (should-not (plist-get context :owns-kernel)))))))

(ert-deftest ejn-reconnect-remote-kernel-refuses-duplicate-operation ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (&rest _)
                 (setq retrieved t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'connect
               :origin-buffer (current-buffer)))
        (should-error (emacs-jupyter-notebook-reconnect-remote-kernel entry)
                      :type 'user-error)
        (should-not retrieved)))))

(ert-deftest ejn-reconnect-remote-kernel-refuses-existing-session-noninteractive ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (&rest _)
                 (setq retrieved t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry '(:profile "p" :session-id "old"))
        (should-error (emacs-jupyter-notebook-reconnect-remote-kernel entry)
                      :type 'user-error)
        (should-not retrieved)))))

(ert-deftest ejn-read-registry-entry-prefers-current-file ()
  (let* ((file (expand-file-name "current.py" temporary-file-directory))
         (entry `(:profile "p"
                  :session-id "current"
                  :local-file ,file
                  :created-at "2"))
         (other '(:profile "p" :session-id "other" :created-at "3")))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list other entry)))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (ert-fail "reconnect prompted despite current file entry"))))
      (with-temp-buffer
        (setq buffer-file-name file)
        (should (equal (emacs-jupyter-notebook--read-registry-entry) entry))))))

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

(ert-deftest ejn-ssh-scp-preserves-home-expansion ()
  (should (equal (emacs-jupyter-notebook-ssh-scp-from-command
                  '(:profile "p" :host "example.com")
                  "~/.cache/ejn/kernel.json" "/tmp/kernel.json")
                 (list emacs-jupyter-notebook-scp-command
                       "example.com:~/.cache/ejn/kernel.json"
                       "/tmp/kernel.json"))))

(ert-deftest ejn-ssh-remote-cleanup-targets-connection-file ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cleanup
                '(:profile "p" :host "example.com")
                "~/.cache/ejn/kernel-session.json"))
         (remote-command (car (last cmd))))
    (should (string-match-p "pkill -f \\\$HOME/.cache/ejn/kernel-session.json"
                            remote-command))
    (should (string-match-p "rm -f \\\$HOME/.cache/ejn/kernel-session.json"
                            remote-command))
    (should (string-match-p "\\$HOME/.cache/ejn/kernel-session.log"
                            remote-command))))

(ert-deftest ejn-ssh-remote-cat-log-targets-connection-log ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cat-log
               '(:profile "p" :host "example.com")
               "~/.cache/ejn/kernel-session.json"))
         (remote-command (car (last cmd))))
    (should (string-match-p "cat \\$HOME/.cache/ejn/kernel-session.log"
                            remote-command))))

(ert-deftest ejn-ssh-remote-ps-command-targets-cache-dir ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-ps-command
               '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
         (remote-command (car (last cmd))))
    (should (string-match-p "ps -eo pid,ppid,stat,etime,args" remote-command))
    (should (string-match-p "KernelManager.connection_file\\\\=/tmp/ejn/kernel-"
                            remote-command))))

(ert-deftest ejn-ssh-remote-cleanup-all-targets-cache-dir ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cleanup-all
               '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
         (remote-command (car (last cmd))))
    (should (string-match-p "pkill -f" remote-command))
    (should (string-match-p "KernelManager.connection_file\\\\=/tmp/ejn/kernel-"
                            remote-command))
    (should (string-match-p "rm -f /tmp/ejn/kernel-\\*.json /tmp/ejn/kernel-\\*.log"
                            remote-command))))

(ert-deftest ejn-ssh-remote-launch-command-is-detached ()
  (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                  '(:profile "p" :host "mother" :remote-cwd "/work" :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                  "session"))
         (remote-command (plist-get launch :remote-command)))
    (should (equal (plist-get launch :connection-file) "/tmp/ejn/kernel-session.json"))
    (should (string-match-p "&& { nohup jupyter kernel" remote-command))
    (should (string-match-p "--kernel=python3" remote-command))
    (should (string-match-p "& printf '%s\\\\n' \"\\$!\"; }" remote-command))))

(ert-deftest ejn-ssh-remote-launch-preserves-home-expansion ()
  (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                  '(:profile "p" :host "mother" :remote-cwd "~" :remote-cache-dir "~/.cache/ejn" :kernelspec "python3")
                  "session"))
         (remote-command (plist-get launch :remote-command)))
    (should (string-match-p "mkdir -p \\\$HOME/.cache/ejn" remote-command))
    (should (string-match-p "cd \\\$HOME" remote-command))
    (should-not (string-match-p "\\\\~" remote-command))
    (should-not (string-match-p "'~" remote-command))))

(ert-deftest ejn-ssh-remote-launch-uses-default-jupyter-command ()
  (let ((emacs-jupyter-notebook-jupyter-command "jupyter"))
    (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                    '(:profile "p" :host "mother" :remote-cwd "/work"
                      :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                    "session"))
           (remote-command (plist-get launch :remote-command)))
      (should (string-match-p "nohup jupyter kernel" remote-command)))))

(ert-deftest ejn-ssh-remote-launch-profile-override-takes-precedence ()
  (let ((emacs-jupyter-notebook-jupyter-command "jupyter"))
    (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                    '(:profile "p" :host "mother" :remote-cwd "/work"
                      :remote-cache-dir "/tmp/ejn" :kernelspec "python3"
                      :jupyter-command "uv run jupyter")
                    "session"))
           (remote-command (plist-get launch :remote-command)))
      (should (string-match-p "nohup uv run jupyter kernel" remote-command))
      (should-not (string-match-p "nohup jupyter kernel" remote-command)))))

(ert-deftest ejn-ssh-remote-launch-complex-jupyter-command ()
  (let ((emacs-jupyter-notebook-jupyter-command
         "uv run --project ~/myproject jupyter"))
    (let* ((launch (emacs-jupyter-notebook-ssh-build-remote-launch
                    '(:profile "p" :host "mother" :remote-cwd "/work"
                      :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                    "session"))
           (remote-command (plist-get launch :remote-command)))
      (should (string-match-p
               "nohup uv run --project ~/myproject jupyter kernel"
               remote-command)))))

(ert-deftest ejn-evaluate-cell-does-not-mutate-source ()
  "W2: evaluating a cell does not mutate source-buffer text.
Output goes to the panel; the source buffer is untouched."
  (ejn-test-with-temp-buffer "# %%\na = 1\n# %%\nb = 2\n"
    (search-forward "a = 1")
    (let ((before (buffer-string))
          (emacs-jupyter-notebook--client 'mock-client)
          captured-code)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code _entry)
               (setq captured-code code))))
        (emacs-jupyter-notebook-evaluate-current-cell))
      (should (equal captured-code "a = 1\n"))
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-evaluate-code-error-routes-to-panel ()
  "W2: an evaluate failure creates a panel entry annotated with the error and
leaves source-buffer text untouched."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (_callback error-callback)
                   (funcall error-callback nil "connect failed"))))
        (emacs-jupyter-notebook--evaluate-code "x = 1\n" nil))
      (should (equal (buffer-string) before))
      (let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
        (should (buffer-live-p panel))
        (with-current-buffer panel
          (should (cl-find-if
                   (lambda (cell)
                     (let* ((e (cdr cell))
                            (c (or (plist-get e :content) "")))
                       (string-match-p "Evaluation failed: connect failed" c)))
                   emacs-jupyter-notebook-panel--entries)))))))

(ert-deftest ejn-evaluate-region-and-buffer-do-not-mutate-source ()
  "W2: region/buffer eval does not mutate source-buffer text and has cell-key nil."
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (let ((before (buffer-string))
          (modified (buffer-modified-p))
          (emacs-jupyter-notebook--client 'mock-client)
          calls)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code entry-handle)
               (push (list code (plist-get entry-handle :cell-key)) calls))))
        (emacs-jupyter-notebook-evaluate-region (point-min) (line-end-position))
        (emacs-jupyter-notebook-evaluate-buffer))
      (should (equal (buffer-string) before))
      (should (equal (buffer-modified-p) modified))
      (let ((codes (mapcar #'car (nreverse calls)))
            (keys (mapcar #'cadr (nreverse calls))))
        (should (equal codes '("x = 1" "x = 1\ny = 2\n")))
        (should (cl-every #'null keys))))))

(ert-deftest ejn-mode-enable-does-not-start-remote-work ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "mode enable ran synchronous SSH command")))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _)
                 (ert-fail "mode enable started SSH process")))
              ((symbol-function 'emacs-jupyter-notebook--wait-for-tunnel)
               (lambda (&rest _)
                 (ert-fail "mode enable waited for tunnel")))
              ((symbol-function 'emacs-jupyter-notebook-jupyter-connect)
               (lambda (&rest _)
                 (ert-fail "mode enable connected to Jupyter"))))
      (emacs-jupyter-notebook-mode 1)
      (should emacs-jupyter-notebook-mode))))

(ert-deftest ejn-result-last-bytes-truncates-to-tail ()
  "W2: byte truncation helper trims to the trailing window."
  (let ((text "abcdefghij"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 100) text))
    (should (equal (emacs-jupyter-notebook--last-bytes text 5) "fghij"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 1) "j"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 10) text))))

(ert-deftest ejn-read-registry-entry-empty-registry-raises-user-error ()
  (let ((completing-read-called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (setq completing-read-called t)
                 "choice")))
      (with-temp-buffer
        (should-error (emacs-jupyter-notebook--read-registry-entry)
                      :type 'user-error)
        (should-not completing-read-called)))))

(ert-deftest ejn-shutdown-deletes-local-connection-file-and-removes-registry-by-session-id ()
  (let* ((dir (make-temp-file "ejn-shutdown-" t))
         (local-conn (expand-file-name "kernel.json" dir))
         (registry-file (expand-file-name "registry.el" dir))
         (target-entry `(:profile "p"
                         :session-id "target-session"
                         :local-connection-file ,local-conn))
         (other-entry '(:profile "p" :session-id "other-session"))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (progn
          (with-temp-file local-conn (insert "{}"))
          (emacs-jupyter-notebook-registry-save
           (list target-entry other-entry) registry-file)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown) #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry) #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-ssh-start-process) #'ignore))
            (with-temp-buffer
              (setq emacs-jupyter-notebook--client 'mock)
              (setq emacs-jupyter-notebook--session-entry target-entry)
              (setq emacs-jupyter-notebook--tunnel-process nil)
              (emacs-jupyter-notebook-shutdown-kernel)
              (should-not (file-exists-p local-conn))
              (should-not emacs-jupyter-notebook--client)
              (should-not emacs-jupyter-notebook--session-entry)
              (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
                (should (= (length remaining) 1))
                (should (equal (plist-get (car remaining) :session-id) "other-session"))))))
      (delete-directory dir t))))

(ert-deftest ejn-status-snapshot-reports-engine-state ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--session-entry
           '(:profile "p"
             :session-id "session"
             :remote-host "example.com"
             :remote-pid 123
             :remote-connection-file "/tmp/kernel.json"
             :local-connection-file "/tmp/local.json"
             :tunnel-ports (:shell_port 1001)))
          (emacs-jupyter-notebook--async-context
           (emacs-jupyter-notebook--async-new-context
            :phase 'error
            :error "boom"
            :origin-buffer (current-buffer))))
      (let ((snapshot (emacs-jupyter-notebook-status-snapshot)))
        (should (plist-get snapshot :client))
        (should (eq (plist-get snapshot :kernel-status) 'idle))
        (should (eq (plist-get snapshot :tunnel-state) 'dead))
        (should (eq (plist-get snapshot :async-phase) 'error))
        (should (equal (plist-get snapshot :async-error) "boom"))
        (should (equal (plist-get snapshot :profile) "p"))
        (should (equal (plist-get snapshot :session-id) "session"))
        (should (string-match-p "Session: session"
                                (emacs-jupyter-notebook-status)))))))

(ert-deftest ejn-status-suggestions-report-no-client ()
  (let ((text (emacs-jupyter-notebook--status-suggestions
               '(:client nil :tunnel-state none))))
    (should (string-match-p "No client connected" text))
    (should (string-match-p "start-remote-kernel" text))
    (should (string-match-p "reconnect-remote-kernel" text))))

(ert-deftest ejn-status-suggestions-report-dead-tunnel-and-async-error ()
  (let ((text (emacs-jupyter-notebook--status-suggestions
               '(:client t :tunnel-state dead :async-error "boom"))))
    (should (string-match-p "Tunnel is not alive" text))
    (should (string-match-p "retry-fresh-kernel" text))
    (should (string-match-p "Last async failure: boom" text))))

(ert-deftest ejn-status-suggestions-report-healthy-state ()
  (let ((text (emacs-jupyter-notebook--status-suggestions
               '(:client t :tunnel-state alive))))
    (should (string-match-p "Engine looks healthy" text))
    (should (string-match-p "C-c C-c" text))))

(ert-deftest ejn-cleanup-current-state-resets-buffer-state ()
  (let* ((dir (make-temp-file "ejn-cleanup-" t))
         (local-file (expand-file-name "kernel.json" dir))
         (entry `(:profile "p"
                  :session-id "session"
                  :remote-connection-file "/tmp/kernel.json"
                  :local-connection-file ,local-file))
         shutdown-called cleanup-entry removed-key)
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                     (lambda (client)
                       (setq shutdown-called client)))
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                     (lambda (captured-entry)
                       (setq cleanup-entry captured-entry)))
                    ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                     (lambda (key &optional _file)
                       (setq removed-key key))))
            (with-temp-buffer
              (setq emacs-jupyter-notebook--client 'mock-client)
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-dead t)
              (emacs-jupyter-notebook--cleanup-current-state "cleanup")
              (should (eq shutdown-called 'mock-client))
              (should (equal cleanup-entry entry))
              (should (equal removed-key "session"))
              (should-not (file-exists-p local-file))
              (should-not emacs-jupyter-notebook--client)
              (should-not emacs-jupyter-notebook--session-entry)
              (should-not emacs-jupyter-notebook--tunnel-dead))))
      (delete-directory dir t))))

(ert-deftest ejn-cancel-operation-does-not-tear-down-session-entry ()
  (let ((entry '(:profile "p" :session-id "existing"))
        cleanup-called)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'retrieve
               :origin-buffer (current-buffer)
               :error-callback (lambda (_ctx _err) nil)))
        (emacs-jupyter-notebook-cancel-operation)
        (should-not emacs-jupyter-notebook--async-context)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should-not cleanup-called)))))

(ert-deftest ejn-retry-fresh-kernel-cleans-state-and-starts-profile ()
  (let ((entry '(:profile "p" :session-id "old"))
        cleanup-called started-profile)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (reason skip-shutdown)
                 (setq cleanup-called (list reason skip-shutdown))))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &optional _callback _error-callback)
                 (setq started-profile profile))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook-retry-fresh-kernel)
        (should (equal cleanup-called '("Retrying with fresh kernel" t)))
        (should (equal started-profile "p"))))))

(ert-deftest ejn-retry-fresh-kernel-uses-async-context-profile ()
  (let (started-profile)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &optional _callback _error-callback)
                 (setq started-profile profile))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'launch
               :profile '(:profile "context-profile")
               :origin-buffer (current-buffer)))
        (emacs-jupyter-notebook-retry-fresh-kernel)
        (should (equal started-profile "context-profile"))))))

(ert-deftest ejn-fetch-remote-log-displays-command-output ()
  (let (argv displayed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (captured-argv)
                 (setq argv captured-argv)
                 "log text"))
              ((symbol-function 'emacs-jupyter-notebook--display-command-output)
               (lambda (buffer-name output)
                 (setq displayed (list buffer-name output)))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry
              '(:profile "p"
                :remote-host "example.com"
                :remote-cwd "~"
                :kernelspec "python3"
                :remote-connection-file "~/.cache/ejn/kernel-session.json"))
        (emacs-jupyter-notebook-fetch-remote-log)
        (should (equal displayed '("*ejn-log*" "log text")))
        (should (string-match-p "kernel-session.log" (car (last argv))))))))

(ert-deftest ejn-list-remote-processes-runs-ps-command ()
  (let (argv displayed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_profile)
                 '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (captured-argv)
                 (setq argv captured-argv)
                 "ps output"))
              ((symbol-function 'emacs-jupyter-notebook--display-command-output)
               (lambda (buffer-name output)
                 (setq displayed (list buffer-name output)))))
      (emacs-jupyter-notebook-list-remote-processes "p")
      (should (equal displayed '("*ejn-remote-processes*" "ps output")))
      (should (string-match-p "ps -eo" (car (last argv)))))))

(ert-deftest ejn-clean-orphaned-kernels-runs-cleanup-all-command ()
  (let (argv message-text)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_profile)
                 '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (captured-argv)
                 (setq argv captured-argv)
                 ""))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacs-jupyter-notebook-clean-orphaned-kernels "p")
      (should (string-match-p "pkill -f" (car (last argv))))
      (should (string-match-p "requested remote orphan cleanup" message-text)))))

(ert-deftest ejn-registry-latest-for-file-normalizes-with-file-truename ()
  (let* ((dir (make-temp-file "ejn-truename-" t))
         (real-file (expand-file-name "notebook.py" dir))
         (link (expand-file-name "link.py" dir)))
    (unwind-protect
        (progn
          (with-temp-file real-file (insert "x = 1\n"))
          (make-symbolic-link real-file link)
          (let* ((true-path (file-truename real-file))
                 (a `(:profile "p" :session-id "a" :local-file ,true-path :created-at "1"))
                 (b `(:profile "p" :session-id "b" :local-file ,true-path :created-at "2")))
            (should (equal (emacs-jupyter-notebook-registry-latest-for-file
                            link (list a b))
                           b))))
      (delete-directory dir t))))

(ert-deftest ejn-evaluate-cell-with-existing-client-evaluates-immediately ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let ((emacs-jupyter-notebook--client 'mock-client)
          captured)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code _entry-handle)
               (push code captured))))
        (emacs-jupyter-notebook-evaluate-current-cell))
      (should (equal captured '("a = 1\n"))))))

(ert-deftest ejn-evaluate-cell-no-client-with-file-entry-calls-reconnect ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (entry '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-captured nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () entry))
                 ((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                  (lambda (captured-entry callback &optional _error-callback)
                    (setq reconnect-captured (cons captured-entry callback))
                    (setq emacs-jupyter-notebook--client 'mock-client)
                    (funcall callback nil))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should (equal (car reconnect-captured) entry))
        (should (functionp (cdr reconnect-captured)))
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-no-client-no-entry-calls-start-default ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook-default-profile "mydefault")
           (start-captured nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                 ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                  (lambda (profile callback &optional _error-callback)
                    (setq start-captured (cons profile callback))
                    (setq emacs-jupyter-notebook--client 'mock-client)
                    (funcall callback nil))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should (equal (car start-captured) "mydefault"))
        (should (functionp (cdr start-captured)))
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-stale-file-entry-falls-back-to-start-default ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook-default-profile "mydefault")
           (entry '(:profile "p" :session-id "stale" :local-file "/tmp/x.py"))
           start-captured
           removed-key
           eval-called
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () entry))
                ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                 (lambda (key &optional _file)
                   (setq removed-key key)))
                ((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                 (lambda (captured-entry _callback &optional error-callback)
                   (should (equal captured-entry entry))
                   (funcall error-callback nil "missing connection file")))
                ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                 (lambda (profile callback &optional _error-callback)
                   (setq start-captured profile)
                   (setq emacs-jupyter-notebook--client 'mock-client)
                   (funcall callback nil))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should (equal removed-key "stale"))
        (should (equal start-captured "mydefault"))
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-async-in-progress-chains-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client code _entry-handle)
              (setq eval-called t)))
           (emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context
             :phase 'launch
             :origin-buffer (current-buffer))))
      (emacs-jupyter-notebook-evaluate-current-cell)
      (should-not eval-called)
      (let ((cb (plist-get emacs-jupyter-notebook--async-context :callback)))
        (should (functionp cb))
        (setq emacs-jupyter-notebook--client 'mock-client)
        (funcall cb emacs-jupyter-notebook--async-context)
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-async-in-progress-chains-error-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           messages
           (emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context
             :phase 'launch
             :origin-buffer (current-buffer))))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (let ((cb (plist-get emacs-jupyter-notebook--async-context
                             :error-callback)))
          (should (functionp cb))
          (funcall cb emacs-jupyter-notebook--async-context "boom")
          (should (equal (car messages)
                         "emacs-jupyter-notebook: evaluation failed: boom")))))))

(ert-deftest ejn-jupyter-runtime-adapter-dispatches ()
  (let ((emacs-jupyter-notebook-jupyter-complete-function
         (lambda (client code pos callback)
           (funcall callback (list :client client :code code :pos pos) nil)))
        (emacs-jupyter-notebook-jupyter-inspect-function
         (lambda (client code pos detail callback)
           (funcall callback
                    (list :client client :code code :pos pos :detail detail)
                    nil)))
        (emacs-jupyter-notebook-jupyter-is-complete-function
         (lambda (client code callback)
           (funcall callback (list :client client :code code :status "complete") nil)))
        complete-result inspect-result is-complete-result)
    (emacs-jupyter-notebook-jupyter-complete
     'client "abc" 2 (lambda (reply _error) (setq complete-result reply)))
    (emacs-jupyter-notebook-jupyter-inspect
     'client "abc" 2 0 (lambda (reply _error) (setq inspect-result reply)))
    (emacs-jupyter-notebook-jupyter-is-complete
     'client "abc" (lambda (reply _error) (setq is-complete-result reply)))
    (should (equal complete-result '(:client client :code "abc" :pos 2)))
    (should (equal inspect-result '(:client client :code "abc" :pos 2 :detail 0)))
    (should (equal is-complete-result '(:client client :code "abc" :status "complete")))))

(ert-deftest ejn-completion-at-point-does-not-request-on-cursor-motion ()
  ;; Cursor motion: capf returns nil without scheduling an idle timer.
  ;; The existing assertion that the adapter is never called still holds —
  ;; W3 strengthens it: even the idle timer must not be installed.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'next-line)
          called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not called)
        (should-not (timerp emacs-jupyter-notebook--completion-idle-timer))))))

(ert-deftest ejn-completion-at-point-requests-after-self-insert ()
  ;; W3.2: capf schedules an idle timer after self-insert.  The adapter is
  ;; NOT called synchronously by the capf — the timer is the proxy for the
  ;; pending request.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'self-insert-command)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq adapter-called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not adapter-called)
        (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-completion-at-point-returns-cached-data ()
  ;; W3.1: cache is a hash-table keyed by (point . line-up-to-point).
  (ejn-test-with-temp-buffer "# %% setup\nx = 1\n# %% work\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (should (equal (emacs-jupyter-notebook-completion-at-point)
                     (list (- (point) 10) (point) '("my_obj.method")
                           :exclusive 'no))))))

(ert-deftest ejn-completion-at-point-returns-nil-when-kernel-busy ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--kernel-status 'busy)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (should-not (emacs-jupyter-notebook-completion-at-point)))))

(ert-deftest ejn-completion-callback-triggers-completion-in-region ()
  ;; Forces the fallback UI branch (no corfu/company) so the reply lands
  ;; via `completion-in-region'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-pending-key nil)
           (emacs-jupyter-notebook--completion-pending-id nil)
           (emacs-jupyter-notebook--completion-request-counter 0)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           triggered)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos callback)
               (funcall callback
                        '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                        nil))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq triggered t))))
          (emacs-jupyter-notebook--request-completion t)
          (should triggered))))))

(ert-deftest ejn-completion-no-duplicate-request ()
  ;; Dedup: when the pending key matches the current key and an id is
  ;; already set, the adapter must not be called twice.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (key (emacs-jupyter-notebook--completion-key))
           (emacs-jupyter-notebook--completion-pending-key key)
           (emacs-jupyter-notebook--completion-pending-id 42)
           (emacs-jupyter-notebook--completion-request-counter 42)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           call-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq call-count (1+ (or call-count 0))))))
        (emacs-jupyter-notebook--request-completion)
        (should-not call-count)))))

(ert-deftest ejn-completion-explicit-command-schedules-request-when-empty ()
  ;; Explicit `complete-at-point' with no cached candidates schedules the
  ;; idle async request rather than calling the adapter synchronously.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq adapter-called t))))
        (emacs-jupyter-notebook-complete-at-point)
        (should-not adapter-called)
        (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-completion-idle-timer-set-up-on-mode-enable ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (timerp emacs-jupyter-notebook--completion-idle-timer))
    (let ((timer emacs-jupyter-notebook--completion-idle-timer))
      (emacs-jupyter-notebook-mode -1)
      (should-not (timerp emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-completion-at-point-no-client-returns-nil ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (goto-char (point-max))
    (should-not (emacs-jupyter-notebook-completion-at-point))))

(ert-deftest ejn-w3.1-completion-key-shape ()
  ;; Key shape contract: (point . line-up-to-point).
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((key (emacs-jupyter-notebook--completion-key)))
      (should (consp key))
      (should (integerp (car key)))
      (should (stringp (cdr key)))
      (should (string-suffix-p "my_obj.met" (cdr key))))))

(ert-deftest ejn-w3.1-completion-cache-hit-miss ()
  ;; Cache hit returns the put value; miss returns nil.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil))
      (should-not (emacs-jupyter-notebook--completion-cache-get '(1 . "a")))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") '(:matches ("a")))
      (should (equal (emacs-jupyter-notebook--completion-cache-get '(1 . "a"))
                     '(:matches ("a"))))
      (should-not (emacs-jupyter-notebook--completion-cache-get '(2 . "b"))))))

(ert-deftest ejn-w3.1-completion-cache-lru-eviction ()
  ;; When the LRU exceeds the bound, the least-recently-used key is evicted.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook-completion-cache-size 3))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      (emacs-jupyter-notebook--completion-cache-put '(3 . "c") 'r3)
      (should (equal (emacs-jupyter-notebook--completion-cache-get '(1 . "a")) 'r1))
      ;; (1 . "a") now MRU; (2 . "b") becomes LRU.
      (emacs-jupyter-notebook--completion-cache-put '(4 . "d") 'r4)
      (should-not (gethash '(2 . "b") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(1 . "a") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(3 . "c") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(4 . "d") emacs-jupyter-notebook--completion-cache))
      (should (= (hash-table-count emacs-jupyter-notebook--completion-cache) 3)))))

(ert-deftest ejn-w3.1-completion-cache-promotes-on-hit ()
  ;; A cache hit promotes the entry to most-recently-used.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook-completion-cache-size 2))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      ;; Touch (1 . "a") so it becomes MRU.
      (emacs-jupyter-notebook--completion-cache-get '(1 . "a"))
      ;; Insert (3 . "c"): now (2 . "b") is LRU and gets evicted.
      (emacs-jupyter-notebook--completion-cache-put '(3 . "c") 'r3)
      (should (gethash '(1 . "a") emacs-jupyter-notebook--completion-cache))
      (should-not (gethash '(2 . "b") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(3 . "c") emacs-jupyter-notebook--completion-cache)))))

(ert-deftest ejn-w3.2-schedule-installs-idle-timer ()
  ;; A schedule call installs exactly one idle timer.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10))
      (emacs-jupyter-notebook--completion-schedule-request)
      (unwind-protect
          (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (emacs-jupyter-notebook--completion-cancel-idle-timer)))))

(ert-deftest ejn-w3.2-schedule-cancels-prior-timer ()
  ;; A second schedule cancels the first; the old timer object is dead.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10))
      (emacs-jupyter-notebook--completion-schedule-request)
      (let ((first emacs-jupyter-notebook--completion-idle-timer))
        (should (timerp first))
        (emacs-jupyter-notebook--completion-schedule-request)
        (let ((second emacs-jupyter-notebook--completion-idle-timer))
          (should (timerp second))
          (should-not (eq first second))
          (should-not (memq first timer-list))
          (emacs-jupyter-notebook--completion-cancel-idle-timer))))))

(ert-deftest ejn-w3.2-cancel-idle-timer-clears-state ()
  ;; Explicit cancel drops the timer and the pending key/id.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil))
      (emacs-jupyter-notebook--completion-schedule-request)
      (emacs-jupyter-notebook--completion-cancel-idle-timer)
      (should-not (timerp emacs-jupyter-notebook--completion-idle-timer))
      (should-not emacs-jupyter-notebook--completion-pending-key)
      (should-not emacs-jupyter-notebook--completion-pending-id))))

(ert-deftest ejn-w3.2-schedule-fires-adapter-after-delay ()
  ;; When the scheduled timer fires, the adapter is called exactly once
  ;; with the expected (code, cursor-pos).  The test invokes the timer's
  ;; function directly rather than relying on the batch-mode scheduler.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (emacs-jupyter-notebook-mode 1)
    (unwind-protect
        (progn
          (search-forward "my_obj.met")
          (let ((emacs-jupyter-notebook--client 'mock-client)
                (emacs-jupyter-notebook--completion-cache nil)
                (emacs-jupyter-notebook--completion-cache-order nil)
                (emacs-jupyter-notebook--completion-idle-timer nil)
                (emacs-jupyter-notebook--completion-pending-key nil)
                (emacs-jupyter-notebook--completion-pending-id nil)
                (emacs-jupyter-notebook-completion-idle 0.01)
                calls captured-code captured-pos)
            (let ((emacs-jupyter-notebook-jupyter-complete-function
                   (lambda (_client code pos _callback)
                     (setq calls (1+ (or calls 0))
                           captured-code code
                           captured-pos pos))))
              (emacs-jupyter-notebook--completion-schedule-request)
              (let ((timer emacs-jupyter-notebook--completion-idle-timer))
                (should (timerp timer))
                (apply (timer--function timer) (timer--args timer)))
              (should (equal calls 1))
              (should (stringp captured-code))
              (should (numberp captured-pos)))))
      (emacs-jupyter-notebook-mode -1))))

(ert-deftest ejn-w3.2-typing-after-schedule-invalidates-pending ()
  ;; A schedule that follows another schedule (the user typed) clears any
  ;; pending key/id so a stale reply will be dropped on arrival.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key "stale-key")
          (emacs-jupyter-notebook--completion-pending-id 42)
          (emacs-jupyter-notebook--completion-idle-timer nil))
      (emacs-jupyter-notebook--completion-schedule-request)
      (unwind-protect
          (progn
            (should-not emacs-jupyter-notebook--completion-pending-key)
            (should-not emacs-jupyter-notebook--completion-pending-id))
        (emacs-jupyter-notebook--completion-cancel-idle-timer)))))

(ert-deftest ejn-w3.3-stale-reply-dropped-by-superseded-id ()
  ;; Two requests fire; the first one's reply arrives AFTER the second has
  ;; superseded it.  The first reply must not populate the cache and must
  ;; not refresh the UI.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          first-callback second-callback ui-refresh-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb)
               (cond ((null first-callback) (setq first-callback cb))
                     (t (setq second-callback cb))))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args)
                     (setq ui-refresh-count (1+ (or ui-refresh-count 0))))))
          ;; First request fires.
          (emacs-jupyter-notebook--request-completion t)
          (should first-callback)
          ;; Simulate user keystroke: bump key by moving point, then a new
          ;; schedule sends a second request.
          (forward-char -1)
          (emacs-jupyter-notebook--request-completion t)
          (should second-callback)
          ;; First reply arrives AFTER the second request superseded it.
          (funcall first-callback
                   '(:matches ("stale_match") :cursor_start 0 :cursor_end 5)
                   nil)
          ;; The stale reply must NOT have populated the cache.
          (should (or (null emacs-jupyter-notebook--completion-cache)
                      (= 0 (hash-table-count
                            emacs-jupyter-notebook--completion-cache))))
          (should-not ui-refresh-count))))))

(ert-deftest ejn-w3.3-fresh-reply-populates-cache ()
  ;; Counterpoint: when the reply matches the live pending id and key,
  ;; it lands in the cache and the UI refresh runs.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-callback ui-refresh-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb)
               (setq captured-callback cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args)
                     (setq ui-refresh-count (1+ (or ui-refresh-count 0))))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-callback)
          (funcall captured-callback
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (let ((key (emacs-jupyter-notebook--completion-key)))
            (should (gethash key emacs-jupyter-notebook--completion-cache)))
          (should (equal ui-refresh-count 1)))))))

(ert-deftest ejn-w3.3-reply-after-buffer-killed-is-safe ()
  ;; If the buffer that owns the request is killed before the reply
  ;; arrives, the callback must not raise.
  (let (buffer captured-cb)
    (with-current-buffer (setq buffer (generate-new-buffer "ejn-w3.3"))
      (python-mode)
      (insert "# %%\nmy_obj.met\n")
      (goto-char (point-max))
      (setq-local emacs-jupyter-notebook--client 'mock-client)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (emacs-jupyter-notebook--request-completion t)))
    (should captured-cb)
    (kill-buffer buffer)
    ;; Should not raise.
    (should
     (eq nil
         (progn
           (funcall captured-cb
                    '(:matches ("x") :cursor_start 0 :cursor_end 1) nil)
           nil)))))

(ert-deftest ejn-w3.4-capf-returns-fast-even-when-adapter-stalls ()
  ;; Load-bearing W3 test: the adapter is mocked to delay 10 seconds.
  ;; The capf must still return well under the budget — the adapter is
  ;; only ever called from the deferred timer, never from the capf
  ;; itself.  This is the binding-rule guarantee in machine-checkable
  ;; form.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10)
          (this-command 'self-insert-command))
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (sleep-for 10))))
        (unwind-protect
            (let ((elapsed (benchmark-elapse
                             (emacs-jupyter-notebook-completion-at-point))))
              ;; Budget: 5 ms.  Even on a slow VM the capf body is a few
              ;; hash-table ops and a timer install — well under that.
              (should (< elapsed 0.005)))
          (when (timerp emacs-jupyter-notebook--completion-idle-timer)
            (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))))

(ert-deftest ejn-w3.4-capf-returns-fast-on-cache-hit ()
  ;; The cache-hit path must also stay in the few-ms budget.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (let ((elapsed (benchmark-elapse
                       (emacs-jupyter-notebook-completion-at-point))))
        (should (< elapsed 0.005))))))

(ert-deftest ejn-w3.1-completion-cache-reset-clears-everything ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      (emacs-jupyter-notebook--completion-cache-reset)
      (should (= (hash-table-count emacs-jupyter-notebook--completion-cache) 0))
      (should-not emacs-jupyter-notebook--completion-cache-order))))

(ert-deftest ejn-inspect-at-point-callback-displays-text-plain ()
  (ejn-test-with-temp-buffer "# %%\nrange(5)\n"
    (goto-char (point-min))
    (search-forward "range")
    (let ((emacs-jupyter-notebook--client 'mock-client)
           captured-code
           captured-pos
           captured-detail
           displayed
           inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (message &optional _buffer-name _action _frame)
                   (setq displayed message))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_client code pos detail callback)
                 (setq captured-code code
                       captured-pos pos
                       captured-detail detail)
                 (setq inspect-callback callback))))
          (emacs-jupyter-notebook-inspect-at-point)
          (should-not displayed)
          (funcall inspect-callback
                   '(:found t :data (:text/plain "range docs")) nil)))
      (should (equal displayed "range docs"))
      (should (equal captured-code "range(5)\n"))
      (should (= captured-pos 5))
      (should (= captured-detail 0)))))

(ert-deftest ejn-evaluate-cell-completeness-check-skips-incomplete-code-async ()
  (ejn-test-with-temp-buffer "# %%\nif True:\n"
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook-check-code-completeness t)
          eval-called
          callback)
      (let ((emacs-jupyter-notebook-jupyter-is-complete-function
             (lambda (_client _code captured-callback)
               (setq callback captured-callback)))
            (emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (&rest _)
               (setq eval-called t))))
        (emacs-jupyter-notebook-evaluate-current-cell))
      (should callback)
      (should-not eval-called)
      (funcall callback '(:status "incomplete" :indent "    ") nil)
      (should-not eval-called))))

(ert-deftest ejn-panel-append-replace-clear-pending ()
  "W2.1: panel API supports append, replace, clear and pending-clear semantics."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
      (ejn-panel-append-text handle "hello\n")
      (ejn-panel-append-text handle "world")
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) "hello\nworld")))
      (ejn-panel-clear-entry handle)
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content) ""))
      (ejn-panel-append-text handle "existing")
      (ejn-panel-clear-entry handle t)
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) "existing"))
        (should (plist-get e :pending-clear)))
      (ejn-panel-append-text handle "fresh")
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) "fresh"))
        (should-not (plist-get e :pending-clear)))
      (ejn-panel-replace-text handle "swapped")
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content)
                     "swapped")))))

(ert-deftest ejn-callback-clear-output-immediate ()
  "W2.7: clear_output without :wait clears the panel entry immediately."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (ejn-panel-append-text handle "some output")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait nil))))
        (funcall clear-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) ""))
        (should-not (plist-get e :pending-clear))))))

(ert-deftest ejn-callback-clear-output-wait-defers-clear ()
  "W2.7: clear_output with :wait defers the clear until next text arrives."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (ejn-panel-append-text handle "some output")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait t))))
        (funcall clear-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) "some output"))
        (should (plist-get e :pending-clear))))))

(ert-deftest ejn-callback-update-display-data-replaces-content ()
  "W2.7: update_display_data replaces the panel entry's content."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (update-fn (cadr (assoc "update_display_data" callbacks))))
      (ejn-panel-append-text handle "old display")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "updated output")
                                        :transient (:display_id "abc"))))
                ((symbol-function 'jupyter-message-data)
                 (lambda (_msg mimetype)
                   (when (eq mimetype :text/plain) "updated output"))))
        (funcall update-fn 'mock-update-msg))
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content)
                     "updated output")))))

(ert-deftest ejn-evaluate-cell-completeness-check-allows-complete-code-async ()
  (ejn-test-with-temp-buffer "# %%\nx = 1\n"
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook-check-code-completeness t)
          eval-called
          callback)
      (let ((emacs-jupyter-notebook-jupyter-is-complete-function
             (lambda (_client _code captured-callback)
               (setq callback captured-callback)))
            (emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (&rest _)
               (setq eval-called t))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should callback)
        (should-not eval-called)
        (funcall callback '(:status "complete") nil))
      (should eval-called))))

(ert-deftest ejn-status-message-sets-kernel-status ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (let* ((callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
             (status-handler (cadr (assoc "status" callbacks)))
             (mock-msg 'mock-status-msg))
        (should status-handler)
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:execution_state "busy"))))
          (funcall status-handler mock-msg))
        (should (eq emacs-jupyter-notebook--kernel-status 'busy))
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:execution_state "idle"))))
          (funcall status-handler mock-msg))
        (should (eq emacs-jupyter-notebook--kernel-status 'idle))))))

(ert-deftest ejn-mode-lighter-changes-based-on-kernel-status ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))
    (setq emacs-jupyter-notebook--kernel-status 'busy)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN*"))
    (setq emacs-jupyter-notebook--kernel-status 'idle)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))
    (setq emacs-jupyter-notebook--kernel-status nil)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))))

(ert-deftest ejn-tunnel-sentinel-sets-tunnel-dead-on-exit ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (proc (start-process "ejn-test-tunnel" nil "true")))
      (emacs-jupyter-notebook-mode 1)
      (setq emacs-jupyter-notebook--tunnel-process proc)
      (setq emacs-jupyter-notebook--tunnel-dead nil)
      (emacs-jupyter-notebook--install-tunnel-sentinel proc buffer)
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc)
                    (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (should emacs-jupyter-notebook--tunnel-dead)
      (should-not emacs-jupyter-notebook--kernel-status))))

(ert-deftest ejn-mode-lighter-shows-exclamation-when-tunnel-dead ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN!"))
    (setq emacs-jupyter-notebook--tunnel-dead nil)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))))

(ert-deftest ejn-tunnel-dead-reset-on-new-connection ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-connection-file "/tmp/kernel.json"
                 :session-id "session"))
        (profile '(:profile "p" :host "example.com"))
        (connection '(:ip "127.0.0.1"
                      :transport "tcp"
                      :shell_port 1
                      :iopub_port 2
                      :stdin_port 3
                      :hb_port 4
                      :control_port 5
                      :key "secret"))
        (local-ports '(:shell_port 1001
                       :iopub_port 1002
                       :stdin_port 1003
                       :hb_port 1004
                       :control_port 1005))
        (sentinel-installed nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--retrieve-connection-file)
               (lambda (&rest _) connection))
              ((symbol-function 'emacs-jupyter-notebook-connection-allocate-local-ports)
               (lambda () local-ports))
              ((symbol-function 'emacs-jupyter-notebook--start-tunnel)
               (lambda (&rest _) 'mock-process))
              ((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
               (lambda (_process _buffer)
                 (setq sentinel-installed t)))
              ((symbol-function 'emacs-jupyter-notebook--wait-for-tunnel)
               (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-jupyter-connect)
               (lambda (_connection-file) 'mock-client))
              ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
               #'ignore))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--tunnel-dead t)
        (emacs-jupyter-notebook--connect-entry entry profile)
        (should-not emacs-jupyter-notebook--tunnel-dead)
        (should sentinel-installed)))))

(ert-deftest ejn-mime-select-png-over-jpeg-and-text ()
  (let ((data '(:text/plain "hello" :image/png "pngdata" :image/jpeg "jpgdata")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :image/png))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "pngdata"))))

(ert-deftest ejn-mime-select-jpeg-over-text ()
  (let ((data '(:text/plain "hello" :image/jpeg "jpgdata")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :image/jpeg))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "jpgdata"))))

(ert-deftest ejn-mime-select-text-when-no-image ()
  (let ((data '(:text/plain "hello")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :text/plain))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "hello"))))

(ert-deftest ejn-mime-select-nil-when-only-unsupported-types ()
  (should-not (emacs-jupyter-notebook--select-mime-type '(:text/html "<p>hi</p>"))))

(ert-deftest ejn-mime-select-nil-for-empty-data ()
  (should-not (emacs-jupyter-notebook--select-mime-type nil)))

(ert-deftest ejn-mime-render-text-returns-plain-string ()
  (let ((result (emacs-jupyter-notebook--render-mime-result '(:text/plain "42"))))
    (should (equal result "42"))
    (should-not (get-text-property 0 'display result))))

(ert-deftest ejn-mime-render-image-decodes-base64 ()
  (let* ((raw "fake-image-data")
         (encoded (base64-encode-string raw t))
         (captured-data nil)
         (captured-props nil))
    (cl-letf (((symbol-function 'create-image)
               (lambda (data &optional _type _data-p &rest props)
                 (setq captured-data data)
                 (setq captured-props props)
                 (list 'image :type 'png :data data))))
      (let ((result (emacs-jupyter-notebook--render-mime-result
                     `(:image/png ,encoded))))
        (should result)
        (should (equal captured-data raw))
        (should (get-text-property 0 'display result))
        (should (equal (plist-get captured-props :max-width)
                       emacs-jupyter-notebook-image-max-width))
        (should (equal (plist-get captured-props :max-height)
                       emacs-jupyter-notebook-image-max-height))))))

(ert-deftest ejn-mime-render-image-falls-back-to-text-on-error ()
  (let* ((encoded (base64-encode-string "bad" t))
         (data `(:text/plain "fallback" :image/png ,encoded)))
    (cl-letf (((symbol-function 'create-image)
               (lambda (&rest _) (error "no image support"))))
      (let ((result (emacs-jupyter-notebook--render-mime-result data)))
        (should (equal result "fallback"))))))

(ert-deftest ejn-mime-render-image-nil-return-falls-back-to-text ()
  (let* ((encoded (base64-encode-string "bad" t))
         (data `(:text/plain "fallback" :image/png ,encoded)))
    (cl-letf (((symbol-function 'create-image)
               (lambda (&rest _) nil)))
      (let ((result (emacs-jupyter-notebook--render-mime-result data)))
        (should (equal result "fallback"))))))

(ert-deftest ejn-panel-set-image-clears-text-content ()
  "W2.5: setting an image clears the panel entry's text content."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "some text")
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content)
                     "some text"))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) ""))
        (should (equal (plist-get e :image)
                       '(image :type png :data "fake")))))))

(ert-deftest ejn-panel-append-clears-image ()
  "W2.5: text appended after an image clears the image."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (should (plist-get (ejn-panel-entry-snapshot handle) :image))
      (ejn-panel-append-text handle "text after image")
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should-not (plist-get e :image))
        (should (equal (plist-get e :content) "text after image"))))))

(ert-deftest ejn-panel-clear-removes-image ()
  "W2.5: clearing an entry also removes its image."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (should (plist-get (ejn-panel-entry-snapshot handle) :image))
      (ejn-panel-clear-entry handle)
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should-not (plist-get e :image))
        (should (equal (plist-get e :content) ""))))))

(ert-deftest ejn-callback-execute-result-renders-text-via-mime ()
  "W2.7: execute_result with text MIME goes through replace-text."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (exec-fn (cadr (assoc "execute_result" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "42")))))
        (funcall exec-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :content) "42"))
        (should-not (plist-get e :image))))))

(ert-deftest ejn-callback-execute-result-renders-image-via-mime ()
  "W2.7: display_data with PNG MIME goes through set-image."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (encoded (base64-encode-string "imgdata" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/png ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :image)
                     '(image :type png :data "imgdata"))))))

(ert-deftest ejn-callback-update-display-data-replaces-image ()
  "W2.7: update_display_data with image MIME swaps the entry's image."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (update-fn (cadr (assoc "update_display_data" callbacks)))
           (encoded (base64-encode-string "newimg" t)))
      (ejn-panel-append-text handle "old text")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/jpeg ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'jpeg :data data))))
        (funcall update-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :image)
                       '(image :type jpeg :data "newimg")))
        (should (equal (plist-get e :content) ""))))))

(ert-deftest ejn-mime-render-image-jpeg-decodes-base64 ()
  (let* ((raw "jpeg-data")
         (encoded (base64-encode-string raw t))
         (captured-data nil))
    (cl-letf (((symbol-function 'create-image)
               (lambda (data &optional _type _data-p &rest _props)
                 (setq captured-data data)
                 (list 'image :type 'jpeg :data data))))
      (let ((result (emacs-jupyter-notebook--render-mime-result
                     `(:image/jpeg ,encoded))))
        (should result)
        (should (equal captured-data raw))
        (should (get-text-property 0 'display result))))))

(ert-deftest ejn-tunnel-reconnect-is-async-and-uses-reconnect-context ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        (retrieve-called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieve-called t)
                 context))
              ((symbol-function 'emacs-jupyter-notebook--async-reconnect-context)
               (lambda (profile entry &optional callback error-callback)
                 (should callback)
                 (should error-callback)
                 (list :profile profile :entry entry
                       :callback callback :error-callback error-callback))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook--tunnel-reconnect
         (current-buffer) (lambda (_c) nil) (lambda (_c _e) nil))
        (should retrieve-called)))))

(ert-deftest ejn-tunnel-reconnect-with-no-entry-does-nothing ()
  (let ((called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (&rest _)
                 (setq called t)
                 nil)))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry nil)
        (emacs-jupyter-notebook--tunnel-reconnect (current-buffer))
        (should-not called)))))

(ert-deftest ejn-tunnel-dead-branch-wires-callback-and-error-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead t)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (buffer callback error-callback)
                   (setq reconnect-called t)
                   (should (functionp callback))
                   (should (functionp error-callback))
                   (setq emacs-jupyter-notebook--tunnel-dead nil)
                   (setq emacs-jupyter-notebook--client 'mock-client)
                   (funcall callback nil))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should reconnect-called)
        (should eval-called)))))

(ert-deftest ejn-tunnel-dead-branch-error-callback-fires-on-failure ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead t)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (error-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (&rest _)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (_buffer _callback error-callback)
                   (funcall error-callback nil "tunnel reconnect failed"))))
        (emacs-jupyter-notebook-evaluate-current-cell)
        (should-not eval-called)))))

(ert-deftest ejn-install-tunnel-sentinel-detects-already-dead-process ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (proc (start-process "ejn-test-dead-tunnel" nil "true")))
      (emacs-jupyter-notebook-mode 1)
      (setq emacs-jupyter-notebook--tunnel-dead nil)
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc)
                    (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (emacs-jupyter-notebook--install-tunnel-sentinel proc buffer)
      (should emacs-jupyter-notebook--tunnel-dead))))

(ert-deftest ejn-panel-source-text-not-mutated-by-image-result ()
  "W2: setting an image on a panel entry does not touch source-buffer text."
  (ejn-test-with-temp-buffer "# %%\nimport matplotlib\n"
    (let* ((before (buffer-string))
           (source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-clear-results-empties-panel ()
  "W2: clear-results empties the output panel and clears fringe indicators."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "stuff")
      (emacs-jupyter-notebook-fringe-set '("x.py" . 1) 'ok 3)
      (should emacs-jupyter-notebook--fringe-overlays)
      (emacs-jupyter-notebook-clear-results)
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--entries))
      (should-not emacs-jupyter-notebook--fringe-overlays))))

(ert-deftest ejn-callback-input-request-appends-prompt-to-panel ()
  "W2.7: input_request appends the prompt to the panel entry."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Enter value: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt) (should (equal prompt "Enter value: ")) "42"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (_client _value) nil)))
        (funcall input-fn 'mock-input-msg))
      (should (string-match-p "Enter value: "
                              (plist-get (ejn-panel-entry-snapshot handle) :content))))))

(ert-deftest ejn-callback-input-request-sends-reply-with-user-input ()
  "W2.7: input_request relays the user's response back to the kernel."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           reply-sent)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Name: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (_prompt) "alice"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (client value)
                   (setq reply-sent (list client value)))))
        (funcall input-fn 'mock-input-msg))
      (should (equal reply-sent '(mock-client "alice"))))))

(ert-deftest ejn-callback-input-request-uses-read-passwd-for-password ()
  "W2.7: password prompts route through `read-passwd'."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           passwd-called reply-value)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Password: " :password t)))
                ((symbol-function 'read-passwd)
                 (lambda (prompt)
                   (setq passwd-called t)
                   (should (equal prompt "Password: "))
                   "secret"))
                 ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                  (lambda (_client value)
                    (setq reply-value (copy-sequence value)))))
        (funcall input-fn 'mock-input-msg))
      (should passwd-called)
      (should (equal reply-value "secret")))))

(ert-deftest ejn-callback-input-request-without-client-does-not-send-reply ()
  "W2.7: without a client, the input_request callback still shows the prompt."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (reply-called nil))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Input: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (_prompt) "test"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (&rest _)
                   (setq reply-called t))))
        (funcall input-fn 'mock-input-msg))
      (should-not reply-called)
      (should (string-match-p "Input: "
                              (plist-get (ejn-panel-entry-snapshot handle) :content))))))

(ert-deftest ejn-callback-input-request-extracts-prompt-and-password-fields ()
  "W2.7: input_request reads :prompt and :password fields correctly."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           captured-prompt)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Your name: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt) (setq captured-prompt prompt) "bob"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 #'ignore))
        (funcall input-fn 'mock-input-msg))
      (should (equal captured-prompt "Your name: ")))))

(ert-deftest ejn-send-input-reply-delegates-to-jupyter-run-with-state ()
  (let ((called-with nil))
    (cl-letf (((symbol-function 'jupyter-run-with-state)
               (lambda (client body)
                 (setq called-with (list client body))
                 nil))
              ((symbol-function 'jupyter-sent)
               (lambda (req) (list 'sent req)))
              ((symbol-function 'jupyter-input-reply)
               (lambda (&rest args) (cons 'input-reply args))))
      (emacs-jupyter-notebook-jupyter--send-input-reply 'my-client "hello")
      (should (equal (car called-with) 'my-client))
      (should (equal (cadr called-with) '(sent (input-reply :value "hello")))))))

(ert-deftest ejn-watch-expressions-plist-converts-to-json-plist ()
  (let ((emacs-jupyter-notebook-watch-expressions
         '(("x" . "x")
           ("mean value" . "sum(xs) / len(xs)")
           ("" . "ignored")
           ("missing" . ""))))
    (should (equal (emacs-jupyter-notebook-jupyter--watch-expressions-plist)
                   (list :x "x"
                         (intern ":mean value") "sum(xs) / len(xs)")))))

(ert-deftest ejn-evaluate-sends-user-expressions ()
  "W2.7: user_expressions are forwarded to jupyter-execute-request."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-evaluation-timeout 120)
          (emacs-jupyter-notebook-watch-expressions
           '(("x" . "x") ("total" . "sum(xs)")))
          captured-args)
      (cl-letf* ((orig-require (symbol-function 'require))
                 ((symbol-function 'require)
                  (lambda (feature &optional filename noerror)
                    (if (memq feature '(jupyter-client jupyter-messages jupyter-monads))
                        feature
                      (funcall orig-require feature filename noerror))))
                 ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore)
                 ((symbol-function 'jupyter-run-with-state) (lambda (&rest _) nil))
                 ((symbol-function 'jupyter-sent) (lambda (x) x))
                 ((symbol-function 'jupyter-message-subscribed) (lambda (req _cbs) req))
                 ((symbol-function 'jupyter-execute-request)
                  (lambda (&rest args)
                    (setq captured-args args)
                    'mock-request)))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
          (unwind-protect
              (emacs-jupyter-notebook-jupyter--evaluate
               'mock-client "x = 1" handle)
            (when (timerp emacs-jupyter-notebook--evaluation-timer)
              (cancel-timer emacs-jupyter-notebook--evaluation-timer))))
        (should (equal (plist-get captured-args :user-expressions)
                       '(:x "x" :total "sum(xs)")))))))

(ert-deftest ejn-execute-reply-appends-watch-results ()
  "W2.7: execute_reply watch results are appended to the panel entry."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (reply-fn (cadr (assoc "execute_reply" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   '(:status "ok"
                     :execution_count 9
                     :user_expressions
                     (:x (:status "ok" :data (:text/plain "10"))
                      :bad (:status "error" :ename "NameError" :evalue "name 'bad' is not defined"))))))
        (funcall reply-fn 'mock-reply-msg))
      (let ((content (plist-get (ejn-panel-entry-snapshot handle) :content)))
        (should (string-match-p "\\[watch\\]" content))
        (should (string-match-p "x: 10" content))
        (should (string-match-p "bad: NameError: name 'bad' is not defined" content))))))

(ert-deftest ejn-evaluation-timer-started-on-evaluate ()
  "W2.7: jupyter--evaluate arms the evaluation timer."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-evaluation-timeout 120))
      (cl-letf* ((orig-require (symbol-function 'require))
                 ((symbol-function 'require)
                  (lambda (feature &optional filename noerror)
                    (if (memq feature '(jupyter-client jupyter-messages jupyter-monads))
                        feature
                      (funcall orig-require feature filename noerror))))
                 ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore)
                 ((symbol-function 'jupyter-run-with-state) (lambda (&rest _) nil))
                 ((symbol-function 'jupyter-sent) (lambda (x) x))
                 ((symbol-function 'jupyter-message-subscribed) (lambda (req _cbs) req))
                 ((symbol-function 'jupyter-execute-request) (lambda (&rest _) 'mock-request)))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
          (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 1" handle))
        (should (timerp emacs-jupyter-notebook--evaluation-timer))
        (cancel-timer emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-cancelled-on-execute-reply ()
  "W2.7: execute_reply cancels the buffer-local evaluation timer."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (reply-fn (cadr (assoc "execute_reply" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:status "ok" :execution_count 1))))
        (funcall reply-fn 'mock-msg))
      (should-not (timerp emacs-jupyter-notebook--evaluation-timer))
      (should (null emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-cancelled-on-status-idle ()
  "W2.7: status=idle cancels the buffer-local evaluation timer."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (status-fn (cadr (assoc "status" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:execution_state "idle"))))
        (funcall status-fn 'mock-msg))
      (should-not (timerp emacs-jupyter-notebook--evaluation-timer))
      (should (null emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-not-cancelled-on-status-busy ()
  "W2.7: status=busy leaves the evaluation timer running."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (status-fn (cadr (assoc "status" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:execution_state "busy"))))
        (funcall status-fn 'mock-msg))
      (should (timerp emacs-jupyter-notebook--evaluation-timer))
      (cancel-timer dummy-timer))))

(ert-deftest ejn-evaluation-timer-fires-warning-message ()
  "W2.7: evaluation timer expiry fires a non-blocking warning message."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-evaluation-timeout 0.01)
          messages)
      (cl-letf* ((orig-require (symbol-function 'require))
                 ((symbol-function 'require)
                  (lambda (feature &optional filename noerror)
                    (if (memq feature '(jupyter-client jupyter-messages jupyter-monads))
                        feature
                      (funcall orig-require feature filename noerror))))
                 ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore)
                 ((symbol-function 'jupyter-run-with-state) (lambda (&rest _) nil))
                 ((symbol-function 'jupyter-sent) (lambda (x) x))
                 ((symbol-function 'jupyter-message-subscribed) (lambda (req _cbs) req))
                 ((symbol-function 'jupyter-execute-request) (lambda (&rest _) 'mock-request))
                 ((symbol-function 'message)
                  (lambda (&rest args)
                    (push (apply #'format args) messages))))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
          (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 1" handle))
        (should (timerp emacs-jupyter-notebook--evaluation-timer))
        (sit-for 2)
        (should (cl-some (lambda (m) (string-match-p "[Ee]valuation timed out" m)) messages))))))

(ert-deftest ejn-async-connect-calls-connect-async-function ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-connection-file "/tmp/kernel.json"
                 :session-id "session"))
        (profile '(:profile "p" :host "example.com"))
        (local-ports '(:shell_port 1001
                       :iopub_port 1002
                       :stdin_port 1003
                       :hb_port 1004
                       :control_port 1005))
        (local-file (make-temp-file "ejn-test-" nil ".json"))
        connect-async-called
        captured-callback)
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--start-tunnel)
                     (lambda (&rest _) 'mock-process))
                    ((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-jupyter-connect-async)
                     (lambda (file callback)
                       (setq connect-async-called t)
                       (setq captured-callback callback)
                       'mock-client))
                    ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                     #'ignore))
            (with-temp-buffer
              (let* ((context (emacs-jupyter-notebook--async-new-context
                               :phase 'tunnel
                               :entry entry
                               :session-id "session"
                               :local-ports local-ports
                               :local-file local-file
                               :tunnel-process 'mock-process
                               :origin-buffer (current-buffer))))
                (setq emacs-jupyter-notebook--async-context context)
                (setq context (emacs-jupyter-notebook--async-connect context))
                (should connect-async-called)
                (should (functionp captured-callback))
                (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect))))))
      (when (file-exists-p local-file)
        (delete-file local-file)))))

(ert-deftest ejn-async-connect-finalize-sets-client-on-success ()
  (let ((entry '(:profile "p" :session-id "session"))
        (local-ports '(:shell_port 1001))
        (local-file "/tmp/test.json")
        (emacs-jupyter-notebook--client nil)
        (emacs-jupyter-notebook--session-entry nil)
        saved-entry)
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'connect
                      :entry entry
                      :origin-buffer (current-buffer))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                   (lambda (entry &optional _file)
                     (setq saved-entry entry))))
          (emacs-jupyter-notebook--async-connect-finalize
           buffer entry local-ports local-file 'mock-client))
        (should (eq emacs-jupyter-notebook--client 'mock-client))
        (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done))
        (should (equal (plist-get saved-entry :session-id) "session"))
        (should (equal (plist-get emacs-jupyter-notebook--session-entry :tunnel-ports)
                       local-ports))))))

(ert-deftest ejn-async-connect-finalize-fails-on-nil-client ()
  (let ((entry '(:profile "p" :session-id "session"))
        (local-ports '(:shell_port 1001))
        (local-file "/tmp/test.json")
        (emacs-jupyter-notebook--client nil))
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'connect
                      :entry entry
                      :origin-buffer (current-buffer)
                      :error-callback (lambda (_ctx _err) nil))))
        (setq emacs-jupyter-notebook--async-context context)
        (emacs-jupyter-notebook--async-connect-finalize
         buffer entry local-ports local-file nil)
        (should-not emacs-jupyter-notebook--client)
        (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error))))))

(ert-deftest ejn-async-connect-timeout-fails-context ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (context (emacs-jupyter-notebook--async-new-context
                    :phase 'connect
                    :entry '(:profile "p" :session-id "session")
                    :origin-buffer (current-buffer)
                    :error-callback (lambda (_ctx _err) nil))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--async-connect-timeout buffer)
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error)))))

(ert-deftest ejn-async-connect-timeout-noop-when-not-connecting ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (context (emacs-jupyter-notebook--async-new-context
                    :phase 'done
                    :entry '(:profile "p" :session-id "session")
                    :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--async-connect-timeout buffer)
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)))))

(ert-deftest ejn-mode-disable-does-not-install-source-change-hooks ()
  "W2: with the panel design the source buffer needs no before/after-change
hooks, so mode enable does not install them."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should-not (memq 'emacs-jupyter-notebook--after-change-cleanup
                      after-change-functions))
    (should-not (memq 'emacs-jupyter-notebook--before-change
                      before-change-functions))))

(ert-deftest ejn-mode-enable-installs-buffer-local-kill-buffer-hook ()
  "W1.1: enabling the minor mode installs the buffer-local kill-buffer-hook."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (memq 'emacs-jupyter-notebook--kill-buffer-hook
                  kill-buffer-hook))
    (should (local-variable-p 'kill-buffer-hook))))

(ert-deftest ejn-mode-disable-removes-kill-buffer-hook ()
  "W1.1: disabling the minor mode removes the buffer-local kill-buffer-hook."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (memq 'emacs-jupyter-notebook--kill-buffer-hook
                  kill-buffer-hook))
    (emacs-jupyter-notebook-mode -1)
    (should-not (memq 'emacs-jupyter-notebook--kill-buffer-hook
                      kill-buffer-hook))))

(ert-deftest ejn-release-local-resources-drops-client-without-shutdown ()
  "W1.1: the disposer drops the client without calling jupyter-shutdown."
  (let (shutdown-called)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
               (lambda (&rest _)
                 (setq shutdown-called t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--client 'mock-client)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not shutdown-called)
        (should-not emacs-jupyter-notebook--client)))))

(ert-deftest ejn-release-local-resources-preserves-session-entry ()
  "W1.1: the disposer leaves the registry-bearing session entry untouched."
  (let ((entry '(:profile "p"
                 :session-id "session"
                 :remote-connection-file "/tmp/kernel.json"
                 :local-connection-file "/tmp/local.json"))
        cleanup-called registry-removed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
               (lambda (&rest _)
                 (setq registry-removed t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not cleanup-called)
        (should-not registry-removed)
        (should (equal emacs-jupyter-notebook--session-entry entry))))))

(ert-deftest ejn-release-local-resources-preserves-local-connection-file ()
  "W1.1: the disposer does not delete the local connection file."
  (let* ((dir (make-temp-file "ejn-release-" t))
         (local-file (expand-file-name "kernel.json" dir))
         (entry `(:profile "p"
                  :session-id "session"
                  :remote-connection-file "/tmp/kernel.json"
                  :local-connection-file ,local-file)))
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry entry)
            (emacs-jupyter-notebook--release-local-resources)
            (should (file-exists-p local-file))))
      (delete-directory dir t))))

(ert-deftest ejn-release-local-resources-kills-tunnel-process ()
  "W1.1: the disposer kills the SSH tunnel process and its buffer."
  (with-temp-buffer
    (let ((proc (start-process "ejn-test-tunnel-release" nil "sleep" "60")))
      (setq emacs-jupyter-notebook--tunnel-process proc)
      (let ((proc-buffer (process-buffer proc)))
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not (and proc-buffer (buffer-live-p proc-buffer)))
        (should-not emacs-jupyter-notebook--tunnel-process)))))

(ert-deftest ejn-release-local-resources-cancels-evaluation-timer ()
  "W1.1: the disposer cancels the buffer-local evaluation timer."
  (with-temp-buffer
    (let ((timer (run-at-time 600 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer timer)
      (emacs-jupyter-notebook--release-local-resources)
      (should-not (memq timer timer-list))
      (should-not emacs-jupyter-notebook--evaluation-timer))))

(ert-deftest ejn-release-local-resources-cancels-async-context-processes ()
  "W1.1: the disposer kills in-flight async launch/scp/tunnel processes."
  (with-temp-buffer
    (let* ((launch (start-process "ejn-test-launch" nil "sleep" "60"))
           (scp (start-process "ejn-test-scp" nil "sleep" "60"))
           (tunnel (start-process "ejn-test-tunnel-ctx" nil "sleep" "60"))
           (remote-copy (make-temp-file "ejn-remote-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :remote-copy remote-copy
                     :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--release-local-resources)
      (should-not (process-live-p launch))
      (should-not (process-live-p scp))
      (should-not (process-live-p tunnel))
      (should-not (file-exists-p remote-copy))
      (should-not emacs-jupyter-notebook--async-context))))

(ert-deftest ejn-release-local-resources-does-not-delete-async-local-file ()
  "W1.1: the disposer does not delete the in-flight context's local-file path."
  (with-temp-buffer
    (let* ((local-file (make-temp-file "ejn-local-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'retrieve
                     :local-file local-file
                     :origin-buffer (current-buffer))))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--async-context context)
            (emacs-jupyter-notebook--release-local-resources)
            (should (file-exists-p local-file)))
        (when (file-exists-p local-file)
          (delete-file local-file))))))

(ert-deftest ejn-mode-disable-cancels-async-context-locally ()
  "W1.2: disabling the mode cancels any in-flight async context locally."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((launch (start-process "ejn-test-disable-launch" nil "sleep" "60"))
           (scp (start-process "ejn-test-disable-scp" nil "sleep" "60"))
           (tunnel (start-process "ejn-test-disable-tunnel" nil "sleep" "60"))
           (remote-copy (make-temp-file "ejn-disable-remote-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :remote-copy remote-copy
                     :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook-mode -1)
      (should-not (process-live-p launch))
      (should-not (process-live-p scp))
      (should-not (process-live-p tunnel))
      (should-not (file-exists-p remote-copy))
      (should-not emacs-jupyter-notebook--async-context))))

(ert-deftest ejn-mode-disable-cancels-buffer-local-timers ()
  "W1.2: disabling the mode cancels evaluation and completion idle timers."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let ((eval-timer (run-at-time 600 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer eval-timer)
      (emacs-jupyter-notebook-mode -1)
      (should-not emacs-jupyter-notebook--evaluation-timer)
      (should-not (memq eval-timer timer-list))
      (should-not emacs-jupyter-notebook--completion-idle-timer))))

(ert-deftest ejn-mode-disable-preserves-session-entry-and-registry ()
  "W1.2 + W1.9: mode disable does not call jupyter-shutdown, does not touch the
registry, and preserves the buffer's `--session-entry'.  It DOES drop the
buffer-local client handle: that handle is a local resource and the W1 GOAL
explicitly lists it among the things released on mode disable."
  (let (shutdown-called cleanup-called registry-removed
        (entry '(:profile "p" :session-id "session")))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
               (lambda (&rest _)
                 (setq shutdown-called t)))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
               (lambda (&rest _)
                 (setq registry-removed t))))
      (with-temp-buffer
        (emacs-jupyter-notebook-mode 1)
        (setq emacs-jupyter-notebook--client 'mock-client)
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook-mode -1)
        (should-not shutdown-called)
        (should-not cleanup-called)
        (should-not registry-removed)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should-not emacs-jupyter-notebook--client)))))

(ert-deftest ejn-release-local-resources-survives-one-disposer-raising ()
  "W1.10: when one disposer in `--release-local-resources' raises, the remaining
disposers still run and the final state-clearing setq still executes.  This
test poisons `--clear-buffer-timers' to throw and asserts that the tunnel
process is still disposed and the buffer-local state is still cleared."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-w110-tunnel" '("sleep" "60"))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--clear-buffer-timers)
                 (lambda (&rest _) (error "simulated disposer failure"))))
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (setq emacs-jupyter-notebook--client 'mock-client)
        (setq emacs-jupyter-notebook--kernel-status 'busy)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not emacs-jupyter-notebook--tunnel-process)
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--kernel-status)))))

(ert-deftest ejn-mode-disable-disposes-tunnel-process-and-stderr-buffer ()
  "W1.9: mode disable disposes the buffer-local tunnel process and its stderr
buffer.  The remote kernel and registry stay alive; only the local SSH tunnel
goes away."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-w19-tunnel" '("sleep" "60"))))
      (let ((stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
        (should (buffer-live-p stderr))
        (emacs-jupyter-notebook-mode 1)
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook-mode -1)
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))
        (should-not emacs-jupyter-notebook--tunnel-process)))))

(ert-deftest ejn-mode-disable-cleanup-swallows-errors ()
  "W1.2: mode-disable cleanup swallows disposer errors without raising."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook--cancel-async-context-locally)
             (lambda (&rest _) (error "boom"))))
    (with-temp-buffer
      (should
       (progn
         (emacs-jupyter-notebook--mode-disable-cleanup)
         t)))))

(ert-deftest ejn-async-delete-process-kills-stderr-buffer ()
  "W1.3: the disposer kills the stderr buffer carried as a process property."
  (let ((proc (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-stderr-leak" '("sleep" "60"))))
    (let ((stdout (process-buffer proc))
          (stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
      (should (buffer-live-p stderr))
      (emacs-jupyter-notebook--async-delete-process proc)
      (should-not (process-live-p proc))
      (should-not (and stdout (buffer-live-p stdout)))
      (should-not (buffer-live-p stderr)))))

(ert-deftest ejn-async-delete-process-tolerates-missing-stderr-buffer ()
  "W1.3: the disposer handles processes that have no stderr property."
  (let ((proc (start-process "ejn-test-plain" nil "sleep" "60")))
    (let ((stdout (process-buffer proc)))
      (emacs-jupyter-notebook--async-delete-process proc)
      (should-not (process-live-p proc))
      (should-not (and stdout (buffer-live-p stdout))))))

(ert-deftest ejn-async-fail-disposes-stderr-buffers ()
  "W1.3: `--async-fail' disposes launch/scp/tunnel stderr buffers."
  (let* ((launch (emacs-jupyter-notebook-ssh-start-process
                  "ejn-test-fail-launch" '("sleep" "60")))
         (scp (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-fail-scp" '("sleep" "60")))
         (tunnel (emacs-jupyter-notebook-ssh-start-process
                  "ejn-test-fail-tunnel" '("sleep" "60")))
         (stderrs (mapcar (lambda (p)
                            (process-get p 'emacs-jupyter-notebook-stderr-buffer))
                          (list launch scp tunnel)))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'launch
                   :launch-process launch
                   :scp-process scp
                   :tunnel-process tunnel)))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (with-temp-buffer
        (emacs-jupyter-notebook--async-fail context "boom")
        (dolist (b stderrs)
          (should-not (buffer-live-p b)))))))

(ert-deftest ejn-cleanup-current-state-disposes-tunnel-stderr-buffer ()
  "W1.3: `--cleanup-current-state' disposes the tunnel stderr buffer."
  (let ((proc (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-cleanup-tunnel" '("sleep" "60")))
        stderr)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               #'ignore))
      (setq stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer))
      (should (buffer-live-p stderr))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook--cleanup-current-state "cleanup")
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))))))

(ert-deftest ejn-release-local-resources-disposes-tunnel-stderr-buffer ()
  "W1.3: the kill-buffer disposer kills the tunnel stderr buffer."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-release-tunnel" '("sleep" "60"))))
      (let ((stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
        (should (buffer-live-p stderr))
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))))))

(ert-deftest ejn-kill-buffer-with-async-context-cleans-locally-and-preserves-registry ()
  "W1.4: killing a buffer with an in-flight async context kills the local
launch/scp/tunnel processes and their stderr buffers, yet leaves the registry
entry and the local connection file on disk untouched (they are the offline
reconnect key)."
  (let* ((registry-dir (make-temp-file "ejn-w14-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (local-dir (make-temp-file "ejn-w14-local-" t))
         (local-file (expand-file-name "kernel.json" local-dir))
         (entry `(:profile "p"
                  :session-id "w14-session"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"
                  :local-connection-file ,local-file))
         shutdown-called cleanup-called
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (setq cleanup-called t))))
          (with-temp-file local-file (insert "{}"))
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (let* ((buffer (generate-new-buffer "ejn-w14"))
                 (launch (emacs-jupyter-notebook-ssh-start-process
                          "ejn-test-w14-launch" '("sleep" "60")))
                 (scp (emacs-jupyter-notebook-ssh-start-process
                       "ejn-test-w14-scp" '("sleep" "60")))
                 (tunnel (emacs-jupyter-notebook-ssh-start-process
                          "ejn-test-w14-tunnel" '("sleep" "60")))
                 (stderrs (mapcar (lambda (p)
                                    (process-get
                                     p 'emacs-jupyter-notebook-stderr-buffer))
                                  (list launch scp tunnel))))
            (with-current-buffer buffer
              (emacs-jupyter-notebook-mode 1)
              (setq emacs-jupyter-notebook--client 'mock-client)
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :origin-buffer buffer)))
            (kill-buffer buffer)
            (should-not (process-live-p launch))
            (should-not (process-live-p scp))
            (should-not (process-live-p tunnel))
            (dolist (b stderrs)
              (should-not (buffer-live-p b)))
            (should-not shutdown-called)
            (should-not cleanup-called)
            (should (file-exists-p local-file))
            (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
              (should (= (length remaining) 1))
              (should (equal (plist-get (car remaining) :session-id)
                             "w14-session")))))
      (delete-directory registry-dir t)
      (delete-directory local-dir t))))

(defun ejn-test--mode-disable-during-phase (phase)
  "Helper for W1.5: disable the mode while async context is in PHASE.
Returns a plist describing post-disable state of the in-flight processes."
  (let* ((registry-dir (make-temp-file "ejn-w15-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry `(:profile "p"
                  :session-id ,(format "w15-%s" phase)
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"))
         (emacs-jupyter-notebook-registry-file registry-file)
         result)
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (with-temp-buffer
            (emacs-jupyter-notebook-mode 1)
            (let* ((launch (emacs-jupyter-notebook-ssh-start-process
                            (format "ejn-test-w15-%s-launch" phase)
                            '("sleep" "60")))
                   (scp (emacs-jupyter-notebook-ssh-start-process
                         (format "ejn-test-w15-%s-scp" phase)
                         '("sleep" "60")))
                   (tunnel (emacs-jupyter-notebook-ssh-start-process
                            (format "ejn-test-w15-%s-tunnel" phase)
                            '("sleep" "60")))
                   (timer (run-at-time 600 nil #'ignore))
                   (stderrs (mapcar (lambda (p)
                                      (process-get
                                       p 'emacs-jupyter-notebook-stderr-buffer))
                                    (list launch scp tunnel))))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase phase
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :timer timer
                     :origin-buffer (current-buffer)))
              (emacs-jupyter-notebook-mode -1)
              (setq result
                    (list :phase-cleared (null emacs-jupyter-notebook--async-context)
                          :launch-dead (not (process-live-p launch))
                          :scp-dead (not (process-live-p scp))
                          :tunnel-dead (not (process-live-p tunnel))
                          :timer-cancelled (not (memq timer timer-list))
                          :stderrs-dead (cl-every (lambda (b)
                                                    (not (buffer-live-p b)))
                                                  stderrs)
                          :session-entry emacs-jupyter-notebook--session-entry
                          :registry-entries
                          (emacs-jupyter-notebook-registry-load registry-file))))))
      (delete-directory registry-dir t))
    result))

(ert-deftest ejn-mode-disable-during-launch-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=launch kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'launch)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (plist-get result :session-entry))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-retrieve-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=retrieve kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'retrieve)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-tunnel-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=tunnel kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'tunnel)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-connect-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=connect kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'connect)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(defun ejn-test--ejn-process-buffers ()
  "Return live buffers whose names start with the EJN process buffer prefix."
  (cl-remove-if-not
   (lambda (b)
     (string-prefix-p " *emacs-jupyter-notebook-" (buffer-name b)))
   (buffer-list)))

(ert-deftest ejn-failed-launch-leaves-no-ejn-process-buffers ()
  "W1.6: a failed remote launch leaks no `*emacs-jupyter-notebook-*' buffers.
Spawn real launch/scp/tunnel processes through the SSH starter so each carries
both a stdout and a stderr buffer.  After `--async-fail' runs there must be
zero EJN-prefixed buffers above the baseline.  The remote-kernel-cleanup
branch is NOT stubbed: post-W1.8, `--async-fail' must not call
`--async-kill-remote-kernel' at all, so the kill helper would not run even
with `:owns-kernel' set."
  (let* ((baseline (ejn-test--ejn-process-buffers))
         (launch (emacs-jupyter-notebook-ssh-start-process
                  "emacs-jupyter-notebook-launch-w16" '("sleep" "60")))
         (scp (emacs-jupyter-notebook-ssh-start-process
               "emacs-jupyter-notebook-scp-w16" '("sleep" "60")))
         (tunnel (emacs-jupyter-notebook-ssh-start-process
                  "emacs-jupyter-notebook-tunnel-w16" '("sleep" "60")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'launch
                   :launch-process launch
                   :scp-process scp
                   :tunnel-process tunnel
                   :owns-kernel t)))
    (should (>= (length (cl-set-difference
                         (ejn-test--ejn-process-buffers) baseline))
                6))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (with-temp-buffer
        (emacs-jupyter-notebook--async-fail context "simulated launch failure")))
    (should-not (process-live-p launch))
    (should-not (process-live-p scp))
    (should-not (process-live-p tunnel))
    (let ((leaked (cl-set-difference (ejn-test--ejn-process-buffers) baseline)))
      (should-not leaked))))

(ert-deftest ejn-async-fail-does-not-kill-remote-kernel-or-delete-local-file ()
  "W1.8: `--async-fail' must not terminate the remote kernel or delete the
context's `:local-file'.  Binding-rule compliance: no automatic remote-kernel
cleanup from async failure paths.  The `:local-file' is the future
`:local-connection-file' reconnect key once `--async-connect-finalize'
promotes it."
  (let ((kill-called nil)
        (local-file (make-temp-file "ejn-w18-local-")))
    (unwind-protect
        (let ((context (emacs-jupyter-notebook--async-new-context
                        :phase 'launch
                        :owns-kernel t
                        :local-file local-file
                        :entry '(:profile "p"
                                 :session-id "w18"
                                 :remote-connection-file "/remote/k.json"))))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
                     (lambda (&rest _) (setq kill-called t)))
                    ((symbol-function 'display-warning) #'ignore))
            (with-temp-buffer
              (emacs-jupyter-notebook--async-fail context "boom")))
          (should-not kill-called)
          (should (file-exists-p local-file)))
      (when (file-exists-p local-file)
        (delete-file local-file)))))

(ert-deftest ejn-kill-buffer-with-live-client-does-not-shutdown-or-deregister ()
  "W1.7: killing a buffer that owns a live client does not call the configured
`emacs-jupyter-notebook-jupyter-shutdown-function' and does not remove the
session's registry entry.  The remote kernel and its registry entry are the
durable reconnect surface and must survive buffer kill."
  (let* ((registry-dir (make-temp-file "ejn-w17-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry '(:profile "p"
                  :session-id "w17-session"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"
                  :local-connection-file "/tmp/w17-local.json"))
         (emacs-jupyter-notebook-registry-file registry-file)
         shutdown-called registry-removed remote-cleanup-called)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (setq remote-cleanup-called t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq registry-removed t)))
                  ;; The kernel-info adapter would otherwise touch the network
                  ;; when the buffer's local hooks run.
                  ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
                   #'ignore))
          (let ((emacs-jupyter-notebook-jupyter-shutdown-function
                 (lambda (&rest _) (setq shutdown-called t))))
            (emacs-jupyter-notebook-registry-save (list entry) registry-file)
            (let ((buffer (generate-new-buffer "ejn-w17")))
              (with-current-buffer buffer
                (emacs-jupyter-notebook-mode 1)
                (setq emacs-jupyter-notebook--client 'mock-client)
                (setq emacs-jupyter-notebook--session-entry entry))
              (kill-buffer buffer))
            (should-not shutdown-called)
            (should-not registry-removed)
            (should-not remote-cleanup-called)
            (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
              (should (= (length remaining) 1))
              (should (equal (plist-get (car remaining) :session-id)
                             "w17-session")))))
      (delete-directory registry-dir t))))

;;; W2 — Output panel & fringe indicator

(defun ejn-test--make-source-buffer (&optional content)
  "Create a buffer-file-visited source buffer for panel tests."
  (let* ((file (make-temp-file "ejn-source-" nil ".py"))
         (buf (find-file-noselect file)))
    (with-current-buffer buf
      (erase-buffer)
      (insert (or content "# %%\nx = 1\n")))
    buf))

(defun ejn-test--kill-source-buffer (buf)
  "Kill BUF (and its visited file)."
  (let ((file (buffer-file-name buf)))
    (kill-buffer buf)
    (when (and file (file-exists-p file))
      (delete-file file))))

;; W2.1: panel mode + API in isolation
(ert-deftest ejn-w2.1-panel-mode-is-special-mode-derived ()
  "W2.1: panel mode is derived from `special-mode' and has buffer-read-only."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (with-current-buffer panel
            (should (derived-mode-p 'emacs-jupyter-notebook-panel-mode))
            (should (derived-mode-p 'special-mode))
            (should buffer-read-only)))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-panel-name-uses-source-basename ()
  "W2.1: the panel buffer name is `*ejn: <basename>*'."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (should (string-match-p (format "\\*ejn: %s\\*"
                                          (regexp-quote
                                           (file-name-nondirectory
                                            (buffer-file-name buf))))
                                  (buffer-name panel))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-ensure-is-idempotent ()
  "W2.1: ejn-panel-ensure returns the same buffer on repeated calls."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((p1 (ejn-panel-ensure buf))
              (p2 (ejn-panel-ensure buf)))
          (should (eq p1 p2)))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-api-start-append-finish-clear-image ()
  "W2.1: the entire panel API works without a kernel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("a" . 1) "x = 1")))
          (should handle)
          (should (plist-get handle :id))
          (should (plist-get handle :cell-key))
          (ejn-panel-append-text handle "hello ")
          (ejn-panel-append-text handle "world")
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (equal (plist-get e :content) "hello world"))
            (should (eq (plist-get e :status) 'running))
            (should (equal (plist-get e :exec-count) "*")))
          (ejn-panel-replace-text handle "swapped")
          (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content)
                         "swapped"))
          (ejn-panel-set-image handle '(image :type png :data "fake"))
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (equal (plist-get e :image)
                           '(image :type png :data "fake")))
            (should (equal (plist-get e :content) "")))
          (ejn-panel-clear-entry handle)
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (equal (plist-get e :content) ""))
            (should-not (plist-get e :image)))
          (ejn-panel-finish-entry handle 'ok 7)
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (eq (plist-get e :status) 'ok))
            (should (equal (plist-get e :exec-count) 7))))
      (ejn-test--kill-source-buffer buf))))

;; W2.2: latest-per-cell view
(ert-deftest ejn-w2.2-latest-per-cell-replaces-same-cell ()
  "W2.2: re-evaluating the same cell leaves a single entry in the latest view."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (key '("file" . 10)))
          (ejn-panel-start-entry panel key "first")
          (ejn-panel-start-entry panel key "second")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 1))
              (should (equal (plist-get (car vis) :code) "second")))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.2-latest-per-cell-orders-by-cell-position ()
  "W2.2: latest-per-cell entries render in cell-position order."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (k1 '("file" . 5))
               (k2 '("file" . 50))
               (k3 '("file" . 100)))
          ;; Start in non-position order:
          (ejn-panel-start-entry panel k2 "second")
          (ejn-panel-start-entry panel k3 "third")
          (ejn-panel-start-entry panel k1 "first")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 3))
              (should (equal (plist-get (nth 0 vis) :code) "first"))
              (should (equal (plist-get (nth 1 vis) :code) "second"))
              (should (equal (plist-get (nth 2 vis) :code) "third")))))
      (ejn-test--kill-source-buffer buf))))

;; W2.3: history-log view + toggle
(ert-deftest ejn-w2.3-history-view-keeps-all-evals ()
  "W2.3 + W2.13: history view shows every evaluation in insertion order.
Re-evaluating the same cell key does NOT delete the prior entry; the latest
view dedupes by cell key at render time but the history view shows the full
timeline."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "cell1")
          (ejn-panel-start-entry panel '("f" . 2) "cell2")
          (ejn-panel-start-entry panel nil "region-eval")
          (ejn-panel-start-entry panel '("f" . 1) "cell1-again")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'history)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 4))
              (should (equal (plist-get (nth 0 vis) :code) "cell1"))
              (should (equal (plist-get (nth 1 vis) :code) "cell2"))
              (should (equal (plist-get (nth 2 vis) :code) "region-eval"))
              (should (equal (plist-get (nth 3 vis) :code) "cell1-again")))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-region-eval-absent-from-latest-view ()
  "W2.3: keyless (region/paragraph/defun) evals do not appear in latest view."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel nil "region")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (should-not (emacs-jupyter-notebook-panel--visible-entries))
            (setq emacs-jupyter-notebook-panel--view 'history)
            (should (= 1 (length (emacs-jupyter-notebook-panel--visible-entries))))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-history-view-auto-scrolls-to-bottom ()
  "W2.3: rendering the history view leaves point at the bottom of the panel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'history))
          (ejn-panel-start-entry panel '("f" . 1) "c1")
          (ejn-panel-start-entry panel '("f" . 2) "c2")
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (should (= (point) (point-max)))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-toggle-view-roundtrips ()
  "W2.3: H toggle moves between latest and history views without data loss."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "c1")
          (ejn-panel-start-entry panel nil "region")
          (with-current-buffer panel
            (should (eq emacs-jupyter-notebook-panel--view 'latest))
            (emacs-jupyter-notebook-panel-toggle-view)
            (should (eq emacs-jupyter-notebook-panel--view 'history))
            (emacs-jupyter-notebook-panel-toggle-view)
            (should (eq emacs-jupyter-notebook-panel--view 'latest))
            ;; Data preserved across toggles.
            (should (= 2 (length emacs-jupyter-notebook-panel--entries)))))
      (ejn-test--kill-source-buffer buf))))

;; W2.4: streaming throttle
(ert-deftest ejn-w2.4-streaming-throttle-coalesces-renders ()
  "W2.4: 1000 small stream events produce far fewer than 1000 renders.

The throttle keeps redisplay churn bounded; the exact upper bound depends on
batch timing, but it must be a tiny fraction of the event count."
  (let ((buf (ejn-test--make-source-buffer))
        (emacs-jupyter-notebook-panel-stream-throttle-ms 50))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code")))
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--render-count 0))
          (dotimes (_ 1000)
            (ejn-panel-append-text handle "x"))
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (should (<= emacs-jupyter-notebook-panel--render-count 20))))
      (ejn-test--kill-source-buffer buf))))

;; W2.5: image entry survives toggle / image zoom keys
(ert-deftest ejn-w2.5-image-zoom-in-out-scales-image ()
  "W2.5: + and - on an image entry scale the display image up and down."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "plot")))
          (ejn-panel-set-image
           handle (create-image (make-string 100 ?\0) 'pbm t :scale 1.0))
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (goto-char (point-min))
            ;; Walk to a position where the display property holds the image:
            (let ((pos nil))
              (while (and (not pos) (not (eobp)))
                (when-let ((d (get-text-property (point) 'display)))
                  (when (and (consp d) (eq (car d) 'image))
                    (setq pos (point))))
                (goto-char (or (next-single-property-change (point) 'display)
                               (point-max))))
              (should pos)
              (goto-char pos)
              (let ((before (or (image-property
                                 (get-text-property (point) 'display) :scale)
                                1.0)))
                (emacs-jupyter-notebook-panel-image-zoom-in)
                (should (> (image-property
                            (get-text-property (point) 'display) :scale)
                           before))
                (emacs-jupyter-notebook-panel-image-zoom-out)
                (emacs-jupyter-notebook-panel-image-zoom-out)
                (should (< (image-property
                            (get-text-property (point) 'display) :scale)
                           before))))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.5-image-survives-view-toggle ()
  "W2.5: image-bearing entry remains intact across a view toggle round-trip."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "plot")))
          (ejn-panel-set-image handle '(image :type png :data "data"))
          (with-current-buffer panel
            (emacs-jupyter-notebook-panel-toggle-view)
            (emacs-jupyter-notebook-panel-toggle-view))
          (should (equal (plist-get (ejn-panel-entry-snapshot handle) :image)
                         '(image :type png :data "data"))))
      (ejn-test--kill-source-buffer buf))))

;; W2.6: navigation
(ert-deftest ejn-w2.6-ret-visits-source-cell ()
  "W2.6: RET on an entry header jumps to the originating cell in source."
  (let ((buf (generate-new-buffer "ejn-w2.6-source")))
    (unwind-protect
        (let (cell-pos panel popped)
          (with-current-buffer buf
            (insert "# %% one\nfoo\n# %% two\nbar\n")
            (goto-char (point-min))
            (re-search-forward "# %% two")
            (setq cell-pos (line-beginning-position))
            (setq panel (ejn-panel-ensure buf))
            (ejn-panel-start-entry panel (cons "test.py" cell-pos) "bar")
            (emacs-jupyter-notebook-panel-flush-now panel))
          (with-current-buffer panel
            (goto-char (point-min))
            (let (header-pos)
              (while (and (not header-pos) (not (eobp)))
                (if (get-text-property (point) 'emacs-jupyter-notebook-entry-id)
                    (setq header-pos (point))
                  (goto-char (or (next-single-property-change
                                  (point) 'emacs-jupyter-notebook-entry-id)
                                 (point-max)))))
              (goto-char header-pos))
            ;; Capture pop-to-buffer target+goto destination from inside the
            ;; visit-source command (pop-to-buffer is hard to assert against
            ;; in batch mode otherwise).
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _)
                         (setq popped target)
                         (set-buffer target))))
              (emacs-jupyter-notebook-panel-visit-source)
              (should (eq popped buf))
              (should (= (point) cell-pos)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ejn-w2.6-q-buries-panel-window ()
  "W2.6: q in the panel calls `quit-window' to bury the panel."
  (let ((buf (ejn-test--make-source-buffer))
        quit-called)
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (cl-letf (((symbol-function 'quit-window)
                     (lambda (&rest _) (setq quit-called t))))
            (with-current-buffer panel
              (emacs-jupyter-notebook-panel-quit)))
          (should quit-called))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.6-keymap-bindings ()
  "W2.6: q, H, RET, n, p are bound in the panel keymap."
  (let ((map emacs-jupyter-notebook-panel-mode-map))
    (should (eq (lookup-key map (kbd "q"))
                #'emacs-jupyter-notebook-panel-quit))
    (should (eq (lookup-key map (kbd "H"))
                #'emacs-jupyter-notebook-panel-toggle-view))
    (should (eq (lookup-key map (kbd "RET"))
                #'emacs-jupyter-notebook-panel-visit-source))
    (should (eq (lookup-key map (kbd "n"))
                #'emacs-jupyter-notebook-panel-next-entry))
    (should (eq (lookup-key map (kbd "p"))
                #'emacs-jupyter-notebook-panel-previous-entry))))

(ert-deftest ejn-w2.6-n-p-navigate-headers ()
  "W2.6: n and p step between entry headers in the panel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "a")
          (ejn-panel-start-entry panel '("f" . 50) "b")
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (goto-char (point-min))
            (emacs-jupyter-notebook-panel-next-entry)
            (should (get-text-property (point) 'emacs-jupyter-notebook-entry-id))
            (let ((first-id (get-text-property
                             (point) 'emacs-jupyter-notebook-entry-id)))
              (emacs-jupyter-notebook-panel-next-entry)
              (let ((second-id (get-text-property
                                (point) 'emacs-jupyter-notebook-entry-id)))
                (should second-id)
                (should-not (equal first-id second-id))
                (emacs-jupyter-notebook-panel-previous-entry)
                (should (equal (get-text-property
                                (point) 'emacs-jupyter-notebook-entry-id)
                               first-id))))))
      (ejn-test--kill-source-buffer buf))))

;; W2.7: callback rewrite (additional)
(ert-deftest ejn-w2.7-stream-callback-routes-to-panel-append ()
  "W2.7: a stream message appends to the panel entry, not the source buffer."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle))
               (stream (cadr (assoc "stream" callbacks)))
               (before (with-current-buffer buf (buffer-string))))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:text "hello\n" :name "stdout"))))
            (funcall stream 'mock))
          (should (equal (plist-get (ejn-panel-entry-snapshot handle) :content)
                         "hello\n"))
          (with-current-buffer buf
            (should (equal (buffer-string) before))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-error-callback-uses-error-face ()
  "W2.7: an error message lands in the panel content with the error face."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle))
               (err-fn (cadr (assoc "error" callbacks))))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg)
                       '(:traceback ("a" "b") :ename "Boom" :evalue "x"))))
            (funcall err-fn 'mock))
          (let ((content (plist-get (ejn-panel-entry-snapshot handle) :content)))
            (should (string-match-p "a\nb" content))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-execute-reply-marks-status-and-count ()
  "W2.7: execute_reply finishes the entry with status and exec-count."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle))
               (reply-fn (cadr (assoc "execute_reply" callbacks))))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:status "ok" :execution_count 5))))
            (funcall reply-fn 'mock))
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (eq (plist-get e :status) 'ok))
            (should (equal (plist-get e :exec-count) 5))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-callbacks-do-not-mutate-source-buffer ()
  "W2.7: an entire roundtrip of callbacks does not change source-buffer text."
  (let ((buf (ejn-test--make-source-buffer "# %%\ncode\n")))
    (unwind-protect
        (let* ((before (with-current-buffer buf (buffer-string)))
               (panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle)))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:text "out" :name "stdout"))))
            (funcall (cadr (assoc "stream" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:data (:text/plain "42")))))
            (funcall (cadr (assoc "execute_result" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:wait nil))))
            (funcall (cadr (assoc "clear_output" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:status "ok" :execution_count 1))))
            (funcall (cadr (assoc "execute_reply" callbacks)) 'mock))
          (should (equal (with-current-buffer buf (buffer-string)) before)))
      (ejn-test--kill-source-buffer buf))))

;; W2.8: fringe indicator
(ert-deftest ejn-w2.8-fringe-state-transitions ()
  "W2.8: queued→running→ok and queued→running→error transitions work."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((key (emacs-jupyter-notebook--cell-key-for (point))))
      (emacs-jupyter-notebook-fringe-set key 'queued)
      (should (eq 'queued (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (eq 'running (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'ok 3)
      (should (eq 'ok (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'error)
      (should (eq 'error (emacs-jupyter-notebook-fringe-state key))))))

(ert-deftest ejn-w2.8-fringe-indicator-does-not-mutate-source ()
  "W2.8: setting/clearing fringe indicators does not change source text."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((before (buffer-string))
          (key (emacs-jupyter-notebook--cell-key-for (point))))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (equal (buffer-string) before))
      (emacs-jupyter-notebook-fringe-clear-all)
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-w2.8-typing-on-cell-line-does-not-interfere ()
  "W2.8: typing on the cell marker line does not delete or move the indicator."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'running)))
      (should (overlayp ov))
      (goto-char (line-end-position))
      (insert " extra")
      ;; The overlay must still exist and still mark the cell line.
      (should (overlayp ov))
      (should (overlay-buffer ov))
      (should (eq 'running (emacs-jupyter-notebook-fringe-state key))))))

(ert-deftest ejn-w2.8-glyph-truncates-to-last-digit-when-large ()
  "W2.8: the ok glyph shows only the last digit for exec-counts >= 10."
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 12) "✓2"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 30) "✓0"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 5) "✓5"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'running 99) "►"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'error nil) "✗"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'queued nil) "…")))

(ert-deftest ejn-w2.8-fringe-no-cursor-intangible-adjacency ()
  "W2.8: the indicator carries no cursor-intangible or read-only properties."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'running))
           (before (overlay-get ov 'before-string)))
      (should before)
      (should-not (get-text-property 0 'cursor-intangible before))
      (should-not (get-text-property 0 'read-only before)))))

;; W2.14: panel buffer name disambiguates same-basename sources
(ert-deftest ejn-w2.14-panel-names-distinguish-same-basename ()
  "W2.14: two source buffers whose visited files share a basename get
distinct panel buffers (Emacs already disambiguates `buffer-name' with
`<2>')."
  (let* ((dir1 (make-temp-file "ejn-w214-a-" t))
         (dir2 (make-temp-file "ejn-w214-b-" t))
         (file1 (expand-file-name "foo.py" dir1))
         (file2 (expand-file-name "foo.py" dir2)))
    (unwind-protect
        (let ((buf1 (find-file-noselect file1))
              (buf2 (find-file-noselect file2)))
          (unwind-protect
              (let ((panel1 (ejn-panel-ensure buf1))
                    (panel2 (ejn-panel-ensure buf2)))
                (should (buffer-live-p panel1))
                (should (buffer-live-p panel2))
                (should-not (eq panel1 panel2))
                (should-not (equal (buffer-name panel1)
                                   (buffer-name panel2))))
            (kill-buffer buf1)
            (kill-buffer buf2)))
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

;; W2.12: indicator display spec uses Emacs margin syntax
(ert-deftest ejn-w2.12-indicator-display-uses-margin-syntax ()
  "W2.12: the indicator overlay's `before-string' carries a `display'
property of the form `((margin SIDE) STRING)' as required by Emacs.
The previous implementation used `((SIDE STRING))' which is silently
ignored, so the indicator never actually rendered."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'ok 3))
           (before (overlay-get ov 'before-string))
           (display (get-text-property 0 'display before)))
      (should display)
      ;; The display spec should mention `margin'.
      (should (equal (car display) '(margin left-margin)))
      ;; The string is the second element of the spec.
      (should (stringp (cadr display)))
      (should (string-match-p "✓" (cadr display)))
      (should (string-match-p "3" (cadr display))))))

(ert-deftest ejn-w2.12-fringe-side-falls-back-to-margin ()
  "W2.12: choosing a fringe value for `--fringe-side' falls back to
`left-margin' rendering rather than emitting an invalid display spec."
  (let ((emacs-jupyter-notebook-fringe-side 'left-fringe))
    (with-temp-buffer
      (insert "# %%\nx = 1\n")
      (goto-char (point-min))
      (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
             (ov (emacs-jupyter-notebook-fringe-set key 'running))
             (before (overlay-get ov 'before-string))
             (display (get-text-property 0 'display before)))
        (should (equal (car display) '(margin left-margin)))))))

(ert-deftest ejn-w2.12-fringe-ensures-margin-width ()
  "W2.12: setting an indicator widens the buffer-local left margin so the
glyph has room to render."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((key (emacs-jupyter-notebook--cell-key-for (point))))
      (should (or (null left-margin-width) (zerop left-margin-width)))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (>= (or left-margin-width 0)
                  emacs-jupyter-notebook-fringe-margin-width)))))

;; W2.11: stable cell key across edits
(ert-deftest ejn-w2.11-cell-key-stable-across-edits-above ()
  "W2.11: the cell key returned for the same cell stays `equal' after the
user inserts or deletes text above the cell.  This guarantees that
latest-per-cell replacement and fringe-state lookup keep recognizing the
same cell across ordinary editing."
  (with-temp-buffer
    (insert "before\n# %%\nx = 1\n")
    (goto-char (point-min))
    (search-forward "# %%")
    (beginning-of-line)
    (let ((key-before (emacs-jupyter-notebook--cell-key-for (point))))
      ;; Insert several lines above the cell marker.
      (save-excursion
        (goto-char (point-min))
        (insert "extra1\nextra2\nextra3\n"))
      ;; Re-query at the (now shifted) cell line.  Because cell-key markers
      ;; have insertion-type t, the marker followed the cell line; the id
      ;; stays the same; the key is still `equal'.
      (search-forward "# %%")
      (beginning-of-line)
      (let ((key-after (emacs-jupyter-notebook--cell-key-for (point))))
        (should (equal key-before key-after))))))

(ert-deftest ejn-w2.11-cell-key-distinguishes-different-cells ()
  "W2.11: cell keys are distinct for distinct cell-marker lines."
  (with-temp-buffer
    (insert "# %% one\n1\n# %% two\n2\n")
    (goto-char (point-min))
    (let ((k1 (emacs-jupyter-notebook--cell-key-for (point))))
      (search-forward "# %% two")
      (beginning-of-line)
      (let ((k2 (emacs-jupyter-notebook--cell-key-for (point))))
        (should-not (equal k1 k2))))))

;; W2.9: panel cleanup
(ert-deftest ejn-w2.9-killing-source-buffer-kills-panel ()
  "W2.9: killing the source buffer kills its output panel."
  (let* ((buf (ejn-test--make-source-buffer))
         (panel nil))
    (with-current-buffer buf
      (emacs-jupyter-notebook-mode 1)
      (setq panel (ejn-panel-ensure buf))
      (should (buffer-live-p panel)))
    (let ((file (buffer-file-name buf)))
      (kill-buffer buf)
      (when (and file (file-exists-p file))
        (delete-file file)))
    (should-not (buffer-live-p panel))))

(ert-deftest ejn-w2.9-killing-panel-alone-does-not-affect-kernel-or-registry ()
  "W2.9: killing only the panel buffer leaves --client and registry untouched."
  (let* ((buf (ejn-test--make-source-buffer))
         shutdown-called registry-removed)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq registry-removed t))))
          (with-current-buffer buf
            (emacs-jupyter-notebook-mode 1)
            (setq emacs-jupyter-notebook--client 'mock-client)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "s")))
          (let ((panel (ejn-panel-ensure buf)))
            (kill-buffer panel))
          (with-current-buffer buf
            (should (eq emacs-jupyter-notebook--client 'mock-client))
            (should emacs-jupyter-notebook--session-entry))
          (should-not shutdown-called)
          (should-not registry-removed))
      (ejn-test--kill-source-buffer buf))))

;; W2.10: customization variables exist and have the documented defaults
(ert-deftest ejn-w2.10-customization-defaults ()
  "W2.10: the W2 customization variables have the documented defaults."
  (should (eq emacs-jupyter-notebook-panel-side 'right))
  (should (= emacs-jupyter-notebook-panel-width 80))
  (should (eq emacs-jupyter-notebook-panel-default-view 'latest))
  (should (= emacs-jupyter-notebook-panel-stream-throttle-ms 50))
  ;; W2.12 changed the default from `left-fringe' (invalid for string glyphs)
  ;; to `left-margin' (the working margin syntax).
  (should (eq emacs-jupyter-notebook-fringe-side 'left-margin)))

(ert-deftest ejn-w2.10-inline-overlay-customizations-removed ()
  "W2.10: legacy inline-overlay customizations are gone."
  (should-not (boundp 'emacs-jupyter-notebook-use-inline-overlays))
  (should-not (boundp 'emacs-jupyter-notebook-inline-result-max-lines))
  (should-not (boundp 'emacs-jupyter-notebook-result-inline-lines))
  (should-not (boundp 'emacs-jupyter-notebook-result-inline-max-bytes))
  (should-not (boundp 'emacs-jupyter-notebook-result-max-lines)))

(provide 'emacs-jupyter-notebook-tests)

;;; emacs-jupyter-notebook-tests.el ends here
