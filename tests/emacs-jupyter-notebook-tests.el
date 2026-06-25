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

(ert-deftest ejn-evaluate-code-error-creates-result-overlay ()
  (ejn-test-with-temp-buffer "x = 1\n"
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (_callback error-callback)
                   (funcall error-callback nil "connect failed"))))
        (emacs-jupyter-notebook--evaluate-code "x = 1\n" (point-min) (point-max)))
      (should (equal (buffer-string) before))
      (let ((overlays (emacs-jupyter-notebook-result--all-overlays)))
        (should (= (length overlays) 1))
        (should (string-match-p "Evaluation failed: connect failed"
                                (overlay-get (car overlays) 'after-string)))))))

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

(ert-deftest ejn-result-line-count-without-splitting ()
  (should (= (emacs-jupyter-notebook-result--line-count "") 0))
  (should (= (emacs-jupyter-notebook-result--line-count "a") 1))
  (should (= (emacs-jupyter-notebook-result--line-count "a\nb") 2))
  (should (= (emacs-jupyter-notebook-result--line-count "a\nb\nc") 3))
  (should (= (emacs-jupyter-notebook-result--line-count "a\n") 2)))

(ert-deftest ejn-result-last-bytes-truncates-to-tail ()
  (let ((text "abcdefghij"))
    (should (equal (emacs-jupyter-notebook-result--last-bytes text 100) text))
    (should (equal (emacs-jupyter-notebook-result--last-bytes text 5) "fghij"))
    (should (equal (emacs-jupyter-notebook-result--last-bytes text 1) "j"))
    (should (equal (emacs-jupyter-notebook-result--last-bytes text 10) text))))

(ert-deftest ejn-result-append-caps-by-bytes ()
  (let ((emacs-jupyter-notebook-result-max-bytes 20)
        (emacs-jupyter-notebook-result-max-lines 10000))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "aaaaaaaaaa bbbbbbbbbb ccccc")
        (let ((content (overlay-get ov 'emacs-jupyter-notebook-content)))
          (should (<= (string-bytes content) 20))
          (should (string-suffix-p "ccccc" content)))))))

(ert-deftest ejn-result-replace-caps-by-bytes ()
  (let ((emacs-jupyter-notebook-result-max-bytes 15)
        (emacs-jupyter-notebook-result-max-lines 10000))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-replace ov "aaaaaaaaaa bbbbbbbbbb")
        (let ((content (overlay-get ov 'emacs-jupyter-notebook-content)))
          (should (<= (string-bytes content) 15)))))))

(ert-deftest ejn-result-render-byte-truncated-shows-summary ()
  (let ((emacs-jupyter-notebook-result-inline-max-bytes 10)
        (emacs-jupyter-notebook-result-inline-lines 100)
        (emacs-jupyter-notebook-result-max-lines 10000)
        (emacs-jupyter-notebook-result-max-bytes 100000))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "aaaaaaaaaa bbbbbbbbbb cc")
        (let ((after (overlay-get ov 'after-string)))
          (should (string-match-p "bytes" after))
          (should (string-match-p "C-c C-o" after))
          (should-not (string-match-p "aaaa" after)))))))

(ert-deftest ejn-result-render-no-byte-summary-when-under-limit ()
  (let ((emacs-jupyter-notebook-result-inline-max-bytes 100000)
        (emacs-jupyter-notebook-result-inline-lines 100)
        (emacs-jupyter-notebook-result-max-lines 10000))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "small")
        (let ((after (overlay-get ov 'after-string)))
          (should (string-match-p "small" after))
          (should-not (string-match-p "bytes" after)))))))

(ert-deftest ejn-result-append-caps-to-max-lines-retaining-newest ()
  (let ((emacs-jupyter-notebook-result-max-lines 5))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append
         ov (mapconcat #'number-to-string (number-sequence 1 10) "\n"))
        (let ((content (overlay-get ov 'emacs-jupyter-notebook-content)))
          (should (= (emacs-jupyter-notebook-result--line-count content) 5))
          (should (string-prefix-p "6" content))
          (should (string-suffix-p "10" content)))))))

(ert-deftest ejn-result-render-truncates-to-inline-lines ()
  (let ((emacs-jupyter-notebook-result-inline-lines 3)
        (emacs-jupyter-notebook-result-max-lines 200))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "a\nb\nc\nd\ne\nf\ng")
        (let ((after (overlay-get ov 'after-string)))
          (should (string-match-p "a" after))
          (should (string-match-p "c" after))
          (should-not (string-match-p "d" after))
          (should (string-match-p "4 more lines" after))
          (should (string-match-p "C-c C-o" after)))))))

(ert-deftest ejn-result-render-no-truncation-summary-when-fits ()
  (let ((emacs-jupyter-notebook-result-inline-lines 10)
        (emacs-jupyter-notebook-result-max-lines 200))
    (with-temp-buffer
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "a\nb\nc")
        (let ((after (overlay-get ov 'after-string)))
          (should (string-match-p "a" after))
          (should (string-match-p "c" after))
          (should-not (string-match-p "more lines" after)))))))

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
             (lambda (_client code _beg _end)
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
            (lambda (_client _code _beg _end)
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
            (lambda (_client _code _beg _end)
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
            (lambda (_client _code _beg _end)
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
            (lambda (_client code _beg _end)
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
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (this-command 'next-line)
          called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not called)))))

(ert-deftest ejn-completion-at-point-requests-after-self-insert ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (this-command 'self-insert-command)
          called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should called)))))

(ert-deftest ejn-completion-at-point-returns-cached-data ()
  (ejn-test-with-temp-buffer "# %% setup\nx = 1\n# %% work\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (context (emacs-jupyter-notebook--completion-context))
           (emacs-jupyter-notebook--completion-cache
            (list :key (plist-get context :key)
                  :reply '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))))
      (should (equal (emacs-jupyter-notebook-completion-at-point)
                     (list (- (point) 10) (point) '("my_obj.method")))))))

(ert-deftest ejn-completion-at-point-returns-nil-when-kernel-busy ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--kernel-status 'busy)
           (context (emacs-jupyter-notebook--completion-context))
           (emacs-jupyter-notebook--completion-cache
            (list :key (plist-get context :key)
                  :reply '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))))
      (should-not (emacs-jupyter-notebook-completion-at-point)))))

(ert-deftest ejn-completion-callback-triggers-completion-in-region ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-pending-key nil)
           (emacs-jupyter-notebook--completion-cache nil)
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
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (context (emacs-jupyter-notebook--completion-context))
           (key (plist-get context :key))
           (emacs-jupyter-notebook--completion-pending-key key)
           (emacs-jupyter-notebook--completion-cache nil)
           call-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq call-count (1+ (or call-count 0))))))
        (emacs-jupyter-notebook--request-completion)
        (should-not call-count)))))

(ert-deftest ejn-completion-explicit-command-fires-request ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-cache nil)
          called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq called t))))
        (emacs-jupyter-notebook-complete-at-point)
        (should called)))))

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

(ert-deftest ejn-result-overlay-clear-resets-content ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-append ov "hello\nworld")
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "hello\nworld"))
      (emacs-jupyter-notebook-result-clear ov)
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) ""))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-pending-clear)))))

(ert-deftest ejn-result-overlay-replace-swaps-content ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-append ov "old-content")
      (emacs-jupyter-notebook-result-replace ov "new-content")
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "new-content")))))

(ert-deftest ejn-result-overlay-append-after-pending-clear-replaces ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-append ov "existing")
      (overlay-put ov 'emacs-jupyter-notebook-pending-clear t)
      (emacs-jupyter-notebook-result-append ov "fresh")
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "fresh"))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-pending-clear)))))

(ert-deftest ejn-callback-clear-output-immediate ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (emacs-jupyter-notebook-result-append ov "some output")
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "some output"))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait nil))))
        (funcall clear-fn 'mock-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) ""))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-pending-clear)))))

(ert-deftest ejn-callback-clear-output-wait-defers-clear ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (emacs-jupyter-notebook-result-append ov "some output")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait t))))
        (funcall clear-fn 'mock-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "some output"))
      (should (overlay-get ov 'emacs-jupyter-notebook-pending-clear)))))

(ert-deftest ejn-callback-update-display-data-replaces-content ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (update-fn (cadr (assoc "update_display_data" callbacks))))
      (emacs-jupyter-notebook-result-append ov "old display")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "updated output")
                                        :transient (:display_id "abc"))))
                ((symbol-function 'jupyter-message-data)
                 (lambda (_msg mimetype)
                   (when (eq mimetype :text/plain) "updated output"))))
        (funcall update-fn 'mock-update-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "updated output")))))

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
    (let ((buffer (current-buffer))
          (ov (make-overlay (point-min) (point-max))))
      (let* ((callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
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

(ert-deftest ejn-execution-count-overlay-created-with-correct-text ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result--set-execution-count ov 42)
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-execution-count) 42))
      (should (string-match-p "\\[42\\]" (overlay-get ov 'after-string))))))

(ert-deftest ejn-busy-indicator-shows-star ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result--set-busy-indicator ov)
      (should (string-match-p "\\[\\*\\]" (overlay-get ov 'after-string))))))

(ert-deftest ejn-clear-results-removes-execution-count-overlays ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n# %%\ny = 2\n")
    (let ((ov1 (emacs-jupyter-notebook-result-start (point-min) 7))
          (ov2 (emacs-jupyter-notebook-result-start 8 (point-max))))
      (emacs-jupyter-notebook-result--set-execution-count ov1 1)
      (emacs-jupyter-notebook-result--set-execution-count ov2 2)
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))
      (emacs-jupyter-notebook-result-clear-all)
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0)))))

(ert-deftest ejn-execution-count-replaced-on-reevaluation ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result--set-busy-indicator ov)
      (should (string-match-p "\\[\\*\\]" (overlay-get ov 'after-string)))
      (emacs-jupyter-notebook-result--set-execution-count ov 5)
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-execution-count) 5))
      (should (string-match-p "\\[5\\]" (overlay-get ov 'after-string))))))

(ert-deftest ejn-callback-execute-reply-sets-execution-count ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (reply-fn (cadr (assoc "execute_reply" callbacks))))
      (emacs-jupyter-notebook-result--set-busy-indicator ov)
      (should (string-match-p "\\[\\*\\]" (overlay-get ov 'after-string)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:status "ok" :execution_count 7))))
        (funcall reply-fn 'mock-reply-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-execution-count) 7))
      (should (string-match-p "\\[7\\]" (overlay-get ov 'after-string))))))

(ert-deftest ejn-clear-region-removes-execution-count-overlays ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n# %%\ny = 2\n")
    (let ((pos1 (point-min))
          pos2)
      (goto-char (point-min))
      (search-forward "# %%" nil t 2)
      (setq pos2 (match-beginning 0))
      (let ((ov1 (emacs-jupyter-notebook-result-start pos1 7))
            (ov2 (emacs-jupyter-notebook-result-start pos2 (point-max))))
        (emacs-jupyter-notebook-result--set-execution-count ov1 1)
        (emacs-jupyter-notebook-result--set-execution-count ov2 2)
        (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))
        (emacs-jupyter-notebook-result-clear-region (point-min) (point-max))
        (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0))))))

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

(ert-deftest ejn-result-set-image-clears-text-content ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-append ov "some text")
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "some text"))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) ""))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-image)
                     '(image :type png :data "fake")))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-running)))))

(ert-deftest ejn-result-overlay-stays-before-inserted-text-at-anchor ()
  (with-temp-buffer
    (insert "# %%\nplt.show()")
    (emacs-jupyter-notebook-mode 1)
    (let* ((end (point-max))
           (ov (emacs-jupyter-notebook-result-start (point-min) end)))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (goto-char end)
      (insert "\n# %%\n")
      (should (= (overlay-start ov) end))
      (should (= (overlay-end ov) end))
      (should (equal (buffer-substring-no-properties end (point-max))
                     "\n# %%\n")))))

(ert-deftest ejn-result-overlay-stays-before-text-inserted-after-source-newline ()
  (with-temp-buffer
    (insert "# %%\nplt.show()\n")
    (emacs-jupyter-notebook-mode 1)
    (let* ((end (point-max))
           (ov (emacs-jupyter-notebook-result-start (point-min) end)))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (goto-char end)
      (insert "typed below output")
      (should (= (overlay-start ov) end))
      (should (= (overlay-end ov) end))
      (should (= (overlay-get ov 'emacs-jupyter-notebook-source-end) end))
      (should (equal (buffer-substring-no-properties end (point-max))
                     "typed below output")))))

(ert-deftest ejn-result-overlay-moves-after-source-edit-at-anchor ()
  (with-temp-buffer
    (insert "# %%\nplt.show()")
    (emacs-jupyter-notebook-mode 1)
    (let* ((anchor (point-max))
           (ov (emacs-jupyter-notebook-result-start (point-min) anchor)))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (goto-char anchor)
      (insert "  # edited")
      (should (= (overlay-start ov) (point-max)))
      (should (= (overlay-end ov) (point-max)))
      (should (= (overlay-get ov 'emacs-jupyter-notebook-source-end)
                 (point-max)))
      (should (equal (buffer-substring-no-properties anchor (point-max))
                     "  # edited")))))

(ert-deftest ejn-result-append-clears-image ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (should (overlay-get ov 'emacs-jupyter-notebook-image))
      (emacs-jupyter-notebook-result-append ov "text after image")
      (should-not (overlay-get ov 'emacs-jupyter-notebook-image))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "text after image")))))

(ert-deftest ejn-result-clear-removes-image ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (should (overlay-get ov 'emacs-jupyter-notebook-image))
      (emacs-jupyter-notebook-result-clear ov)
      (should-not (overlay-get ov 'emacs-jupyter-notebook-image))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "")))))

(ert-deftest ejn-callback-execute-result-renders-text-via-mime ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (exec-fn (cadr (assoc "execute_result" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "42")))))
        (funcall exec-fn 'mock-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "42"))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-image)))))

(ert-deftest ejn-callback-execute-result-renders-image-via-mime ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (encoded (base64-encode-string "imgdata" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/png ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-image)
                     '(image :type png :data "imgdata"))))))

(ert-deftest ejn-callback-update-display-data-replaces-image ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (update-fn (cadr (assoc "update_display_data" callbacks)))
           (encoded (base64-encode-string "newimg" t)))
      (emacs-jupyter-notebook-result-append ov "old text")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/jpeg ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'jpeg :data data))))
        (funcall update-fn 'mock-msg))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-image)
                     '(image :type jpeg :data "newimg")))
      (should (equal (overlay-get ov 'emacs-jupyter-notebook-content) "")))))

(ert-deftest ejn-result-image-render-has-header-in-after-string ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (let ((after-string (overlay-get ov 'after-string)))
        (should after-string)
        (should (string-match-p "\\[output\\]" after-string))))))

(ert-deftest ejn-result-image-render-does-not-add-cursor-spacer ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (let ((after-string (overlay-get ov 'after-string)))
        (should after-string)
        (should (equal (substring-no-properties after-string 0 1) "\n"))
        (should-not (text-property-any 0 (length after-string) 'cursor t after-string))))))

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
            (lambda (_client _code _beg _end)
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

(ert-deftest ejn-source-text-not-mutated-by-image-result ()
  (ejn-test-with-temp-buffer "# %%\nimport matplotlib\n"
    (let ((before (buffer-string)))
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake")))
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-toggle-output-sets-collapsed-property ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-create (point-min) (point-max) "result")))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-collapsed))
      (goto-char (point-min))
      (emacs-jupyter-notebook-toggle-output)
      (should (overlay-get ov 'emacs-jupyter-notebook-collapsed))
      (emacs-jupyter-notebook-toggle-output)
      (should-not (overlay-get ov 'emacs-jupyter-notebook-collapsed)))))

(ert-deftest ejn-toggle-output-collapsed-render-shows-summary ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-create (point-min) (point-max)
                                                   "line1\nline2\nline3")))
      (overlay-put ov 'emacs-jupyter-notebook-collapsed t)
      (emacs-jupyter-notebook-result--render ov)
      (let ((after (overlay-get ov 'after-string)))
        (should (string-match-p "output: 3 lines, hidden" after))
        (should-not (string-match-p "line1" after))
        (should-not (text-property-any 0 (length after) 'cursor t after))))))

(ert-deftest ejn-toggle-output-expanded-render-shows-content ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-create (point-min) (point-max)
                                                   "line1\nline2")))
      (should-not (overlay-get ov 'emacs-jupyter-notebook-collapsed))
      (let ((after (overlay-get ov 'after-string)))
        (should (string-match-p "line1" after))
        (should (string-match-p "line2" after))
        (should (equal (substring-no-properties after 0 1) "\n"))
        (should-not (text-property-any 0 (length after) 'cursor t after)))))
  )

(ert-deftest ejn-nearest-overlay-finds-overlay-at-point ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-create (point-min) (point-max) "ok")))
      (goto-char (point-min))
      (should (eq (emacs-jupyter-notebook-result--nearest-overlay) ov)))))

(ert-deftest ejn-nearest-overlay-finds-overlay-above-point ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n\n\nsome text below\n")
    (let ((ov (emacs-jupyter-notebook-result-create
               (point-min) (save-excursion (goto-char (point-min)) (line-end-position))
               "result")))
      (goto-char (point-max))
      (should (eq (emacs-jupyter-notebook-result--nearest-overlay) ov)))))

(ert-deftest ejn-nearest-overlay-returns-nil-when-no-overlays ()
  (with-temp-buffer
    (insert "no overlays here\n")
    (should-not (emacs-jupyter-notebook-result--nearest-overlay))))

(ert-deftest ejn-toggle-output-errors-when-no-overlay ()
  (with-temp-buffer
    (insert "nothing here\n")
    (should-error (emacs-jupyter-notebook-toggle-output) :type 'user-error)))

(ert-deftest ejn-toggle-output-collapsed-image-overlay ()
  (with-temp-buffer
    (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
      (emacs-jupyter-notebook-result-set-image ov '(image :type png :data "fake"))
      (overlay-put ov 'emacs-jupyter-notebook-collapsed t)
      (emacs-jupyter-notebook-result--render ov)
      (let ((after (overlay-get ov 'after-string)))
        (should (string-match-p "output: image, hidden" after))
        (should-not (text-property-any 0 (length after) 'cursor t after))))))

(ert-deftest ejn-clear-results-works-with-collapsed-overlays ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((ov (emacs-jupyter-notebook-result-create (point-min) (point-max) "data")))
      (overlay-put ov 'emacs-jupyter-notebook-collapsed t)
      (emacs-jupyter-notebook-result--render ov)
      (emacs-jupyter-notebook-result-clear-all)
      (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0)))))

(ert-deftest ejn-callback-input-request-appends-prompt-to-overlay ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer ov 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Enter value: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt) (should (equal prompt "Enter value: ")) "42"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (_client _value) nil)))
        (funcall input-fn 'mock-input-msg))
      (should (string-match-p "Enter value: "
                              (overlay-get ov 'emacs-jupyter-notebook-content))))))

(ert-deftest ejn-callback-input-request-sends-reply-with-user-input ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer ov 'mock-client))
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
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer ov 'mock-client))
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
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer ov))
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
                              (overlay-get ov 'emacs-jupyter-notebook-content))))))

(ert-deftest ejn-callback-input-request-extracts-prompt-and-password-fields ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer ov 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           captured-prompt captured-password)
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
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-use-inline-overlays t)
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
        (unwind-protect
            (emacs-jupyter-notebook-jupyter--evaluate
             'mock-client "x = 1" (point-min) (point-max))
          (when (timerp emacs-jupyter-notebook--evaluation-timer)
            (cancel-timer emacs-jupyter-notebook--evaluation-timer)))
        (should (equal (plist-get captured-args :user-expressions)
                       '(:x "x" :total "sum(xs)")))))))

(ert-deftest ejn-execute-reply-appends-watch-results ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (reply-fn (cadr (assoc "execute_reply" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   '(:status "ok"
                     :execution_count 9
                     :user_expressions
                     (:x (:status "ok" :data (:text/plain "10"))
                      :bad (:status "error" :ename "NameError" :evalue "name 'bad' is not defined"))))))
        (funcall reply-fn 'mock-reply-msg))
      (let ((content (overlay-get ov 'emacs-jupyter-notebook-content)))
        (should (string-match-p "\\[watch\\]" content))
        (should (string-match-p "x: 10" content))
        (should (string-match-p "bad: NameError: name 'bad' is not defined" content))))))

(ert-deftest ejn-evaluation-timer-started-on-evaluate ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-use-inline-overlays t)
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
        (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 1" (point-min) (point-max))
        (should (timerp emacs-jupyter-notebook--evaluation-timer))
        (cancel-timer emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-cancelled-on-execute-reply ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (reply-fn (cadr (assoc "execute_reply" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:status "ok" :execution_count 1))))
        (funcall reply-fn 'mock-msg))
      (should-not (timerp emacs-jupyter-notebook--evaluation-timer))
      (should (null emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-cancelled-on-status-idle ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (ov (make-overlay (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (status-fn (cadr (assoc "status" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:execution_state "idle"))))
        (funcall status-fn 'mock-msg))
      (should-not (timerp emacs-jupyter-notebook--evaluation-timer))
      (should (null emacs-jupyter-notebook--evaluation-timer)))))

(ert-deftest ejn-evaluation-timer-not-cancelled-on-status-busy ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (ov (make-overlay (point-min) (point-max)))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (status-fn (cadr (assoc "status" callbacks)))
           (dummy-timer (run-at-time 999 nil #'ignore)))
      (setq emacs-jupyter-notebook--evaluation-timer dummy-timer)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:execution_state "busy"))))
        (funcall status-fn 'mock-msg))
      (should (timerp emacs-jupyter-notebook--evaluation-timer))
      (cancel-timer dummy-timer))))

(ert-deftest ejn-evaluation-timer-fires-warning-message ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook-use-inline-overlays t)
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
        (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 1" (point-min) (point-max))
        (should (timerp emacs-jupyter-notebook--evaluation-timer))
        (sit-for 2)
        (should (cl-some (lambda (m) (string-match-p "[Ee]valuation timed out" m)) messages))))))

(ert-deftest ejn-show-output-opens-buffer-with-full-content ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let* ((emacs-jupyter-notebook-result-inline-lines 2)
           (emacs-jupyter-notebook-result-max-lines 200)
           (ov (emacs-jupyter-notebook-result-create
                (point-min) (point-max)
                "line1\nline2\nline3\nline4\nline5")))
      (goto-char (point-min))
      (let ((buf (get-buffer "*ejn-output*")))
        (when buf (kill-buffer buf)))
      (emacs-jupyter-notebook-show-output)
      (let ((buf (get-buffer "*ejn-output*")))
        (should buf)
        (with-current-buffer buf
          (should (equal (buffer-string) "line1\nline2\nline3\nline4\nline5"))
          (should buffer-read-only))
        (kill-buffer buf)))))

(ert-deftest ejn-show-output-buffer-contains-real-text ()
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (let ((emacs-jupyter-notebook-result-inline-lines 2)
          (emacs-jupyter-notebook-result-max-lines 200))
      (emacs-jupyter-notebook-result-create
       (point-min) (point-max) "alpha\nbeta\ngamma")
      (goto-char (point-min))
      (let ((buf (get-buffer "*ejn-output*")))
        (when buf (kill-buffer buf)))
      (emacs-jupyter-notebook-show-output)
      (let ((buf (get-buffer "*ejn-output*")))
        (should buf)
        (with-current-buffer buf
          (should (equal (buffer-string) "alpha\nbeta\ngamma"))
          (should (= (point-min) 1))
          (goto-char (point-min))
          (should (search-forward "beta" nil t))
          (should (equal (buffer-substring-no-properties
                          (match-beginning 0) (match-end 0))
                         "beta")))
        (kill-buffer buf)))))

(ert-deftest ejn-show-output-errors-when-no-overlay ()
  (with-temp-buffer
    (insert "nothing here\n")
    (should-error (emacs-jupyter-notebook-show-output) :type 'user-error)))

(ert-deftest ejn-result-full-content-property-stores-uncapped-content ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-result-inline-lines 2)
          (emacs-jupyter-notebook-result-max-lines 200))
      (let ((ov (emacs-jupyter-notebook-result-start (point-min) (point-max))))
        (emacs-jupyter-notebook-result-append ov "a\nb\nc\nd\ne")
        (should (equal (overlay-get ov 'emacs-jupyter-notebook-result-full-content)
                       "a\nb\nc\nd\ne"))))))

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

(ert-deftest ejn-after-change-clears-overlays-when-cell-marker-removed ()
  (with-temp-buffer
    (insert "# %%\na = 1\n# %%\nb = 2\n")
    (emacs-jupyter-notebook-mode 1)
    (emacs-jupyter-notebook-result-create 6 11 "result1")
    (emacs-jupyter-notebook-result-create 17 22 "result2")
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))
    (goto-char (point-min))
    (search-forward "# %%" nil t 2)
    (delete-region (match-beginning 0) (1+ (match-end 0)))
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0))))

(ert-deftest ejn-after-change-does-not-clear-overlays-for-normal-deletion ()
  (with-temp-buffer
    (insert "# %%\na = 1\n# %%\nb = 2\n")
    (emacs-jupyter-notebook-mode 1)
    (emacs-jupyter-notebook-result-create 6 11 "result1")
    (emacs-jupyter-notebook-result-create 17 22 "result2")
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))
    (goto-char (point-min))
    (search-forward "1")
    (delete-region (match-beginning 0) (match-end 0))
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))))

(ert-deftest ejn-after-change-does-not-clear-overlays-on-insertion ()
  (with-temp-buffer
    (insert "# %%\na = 1\n")
    (emacs-jupyter-notebook-mode 1)
    (emacs-jupyter-notebook-result-create 6 11 "result1")
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 1))
    (goto-char (point-min))
    (insert "x = 0\n")
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 1))))

(ert-deftest ejn-after-change-clears-overlays-when-replacing-cell-marker ()
  (with-temp-buffer
    (insert "# %%\na = 1\n# %%\nb = 2\n")
    (emacs-jupyter-notebook-mode 1)
    (emacs-jupyter-notebook-result-create 6 11 "result1")
    (emacs-jupyter-notebook-result-create 17 22 "result2")
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 2))
    (goto-char (point-min))
    (search-forward "# %%" nil t 2)
    (let ((beg (match-beginning 0)))
      (delete-region beg (1+ (match-end 0)))
      (goto-char beg)
      (insert "replaced"))
    (should (= (length (emacs-jupyter-notebook-result--all-overlays)) 0))))

(ert-deftest ejn-mode-disable-removes-change-hooks ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (memq 'emacs-jupyter-notebook--after-change-cleanup
                  after-change-functions))
    (should (memq 'emacs-jupyter-notebook--before-change
                  before-change-functions))
    (emacs-jupyter-notebook-mode -1)
    (should-not (memq 'emacs-jupyter-notebook--after-change-cleanup
                      after-change-functions))
    (should-not (memq 'emacs-jupyter-notebook--before-change
                      before-change-functions))))

(provide 'emacs-jupyter-notebook-tests)

;;; emacs-jupyter-notebook-tests.el ends here
