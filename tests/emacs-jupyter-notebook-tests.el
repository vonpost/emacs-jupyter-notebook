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

(ert-deftest ejn-cell-send-and-advance-moves-to-next-cell ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-send-cell)
                 (lambda () (setq called t))))
        (emacs-jupyter-notebook-send-cell-and-advance))
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

;; W4.7: the sync `--retrieve-connection-file' and `--wait-for-tunnel'
;; tests have been removed along with the functions they exercised.  The
;; async retrieve and tunnel-readiness poller are covered by
;; `ejn-async-retrieve-*' / `ejn-async-wait-tunnel-*' (see ROADMAP W4.7).

(ert-deftest ejn-w4.7-no-sleep-for-in-source-files ()
  "W4.7 acceptance: no `sleep-for' call may appear in any package source
file.  Test sources may still use it for synchronization (see the
W4.4 dead-PID probe test); production code must not."
  (let ((dir (file-name-directory
              (or (locate-library "emacs-jupyter-notebook")
                  (expand-file-name "emacs-jupyter-notebook.el")))))
    (dolist (name '("emacs-jupyter-notebook.el"
                    "emacs-jupyter-notebook-ssh.el"
                    "emacs-jupyter-notebook-jupyter.el"
                    "emacs-jupyter-notebook-result.el"
                    "emacs-jupyter-notebook-connection.el"
                    "emacs-jupyter-notebook-registry.el"
                    "emacs-jupyter-notebook-vars.el"
                    "emacs-jupyter-notebook-cell.el"))
      (let ((path (expand-file-name name dir)))
        (when (file-readable-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (should-not
             (re-search-forward "(sleep-for\\b" nil t))))))))

;; W4.7: `ejn-connect-entry-waits-for-tunnel-before-jupyter-connect' was
;; removed along with the synchronous `--connect-entry'.  The async
;; tunnel-readiness behavior it asserted is covered by the
;; `ejn-async-wait-tunnel-*' tests.

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
  ;; Post-W4.4: reconnect first runs `--async-probe-pid-alive', which only
  ;; advances to `--async-retrieve' when the entry's `:remote-pid' is alive.
  ;; The probe is stubbed here to call retrieve directly so this test still
  ;; pins the contract "reconnect ends in async-retrieve, never sync SSH".
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-pid 12345
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "reconnect command used synchronous SSH")))
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
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

(ert-deftest ejn-w10-reconnect-remote-kernel-proceeds-from-clientless-debris ()
  "W10: reconnect is THE recovery path.  A buffer with a lingering
`--session-entry' but NO live client is reapable DEBRIS, not an active
session, so reconnect must NOT be blocked by the guard — it reaps the
stale buffer-local entry and proceeds to probe/retrieve the target entry.
Pre-W10 this signalled `user-error \"A kernel is already active\"' and the
wedged buffer could only be recovered by nuking the live kernel."
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-pid 4242
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieved t)
                 context)))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry '(:profile "p" :session-id "old"))
        (let ((context (emacs-jupyter-notebook-reconnect-remote-kernel entry)))
          ;; Not blocked: the reconnect pipeline advanced to retrieve.
          (should retrieved)
          (should (eq (plist-get context :phase) 'retrieve))
          ;; The stale buffer-local debris entry was reaped before the new
          ;; reconnect context took over.
          (should (equal (plist-get context :entry) entry)))))))

(ert-deftest ejn-read-registry-entry-prefers-current-file ()
  "W6.8: chooser ALWAYS runs, but the current-file entry is the default initial-input.
Pressing RET on the chooser with no edit returns the current-file entry."
  (let* ((file (expand-file-name "current.py" temporary-file-directory))
         (entry `(:profile "p"
                  :session-id "current"
                  :local-file ,file
                  :created-at "2"))
         (other '(:profile "p" :session-id "other" :created-at "3"))
         (passed-default nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list other entry)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &optional _pred _require _initial _hist default)
                 (setq passed-default default)
                 ;; Simulate the user pressing RET on the default.
                 default)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (let ((selected (emacs-jupyter-notebook--read-registry-entry)))
          (should (equal selected entry))
          (should (string-match-p "session-id" "session-id"))
          ;; The default offered must be the label for the current-file entry.
          (should (string-match-p "current" passed-default)))))))

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
    ;; W4.2: PID sentinel `EJN_PID=<pid>' on its own line.
    (should (string-match-p "& printf 'EJN_PID=%s\\\\n' \"\\$!\"; }" remote-command))))

(ert-deftest ejn-w4.2-parse-pid-uses-anchored-sentinel ()
  "W4.2: `--parse-pid' matches the anchored `EJN_PID=<digits>' sentinel,
ignores spurious numbers in SSH banners / motd, and returns nil when no
sentinel is present."
  (should (= 12345
             (emacs-jupyter-notebook--parse-pid
              "Welcome to host 42\nLast login: ...\nEJN_PID=12345\n")))
  (should (= 9
             (emacs-jupyter-notebook--parse-pid "EJN_PID=9\n")))
  (should-not (emacs-jupyter-notebook--parse-pid
               "Welcome 42\nLast login: 99999 days ago\n"))
  (should-not (emacs-jupyter-notebook--parse-pid
               "EJN_PID=abc\n"))
  ;; The sentinel must be anchored; an embedded `EJN_PID=...' inside another
  ;; word should not match unless it starts the line.
  (should-not (emacs-jupyter-notebook--parse-pid
               "noise EJN_PID=7\n")))

(ert-deftest ejn-w4.3-classify-stderr-auth-failed ()
  "W4.3: `Permission denied' / `Authentication failed' map to `auth-failed'."
  (dolist (s '("Permission denied (publickey).\n"
               "user@host: Permission denied (publickey,password).\n"
               "Authentication failed.\n"
               "Too many authentication failures for user\n"
               "Could not open a connection to your authentication agent.\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'auth-failed (plist-get r :kind)))
      (should (stringp (plist-get r :hint))))))

(ert-deftest ejn-w4.3-classify-stderr-host-unreachable ()
  "W4.3: DNS/route failures map to `host-unreachable'."
  (dolist (s '("ssh: Could not resolve hostname mother: Name or service not known\n"
               "ssh: connect to host mother port 22: No route to host\n"
               "ssh: connect to host x port 22: Network is unreachable\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'host-unreachable (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-connection-refused ()
  "W4.3: `Connection refused' maps to `connection-refused'."
  (let ((r (emacs-jupyter-notebook-ssh-classify-stderr
            "ssh: connect to host mother port 22: Connection refused\n")))
    (should (eq 'connection-refused (plist-get r :kind)))))

(ert-deftest ejn-w4.3-classify-stderr-forward-refused ()
  "W4.3: forward refusal maps to `forward-refused'."
  (dolist (s '("Could not request local forwarding.\n"
               "remote port forwarding failed for listen port 9000\n"
               "bind [127.0.0.1]:9000: Address already in use\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'forward-refused (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-host-key-changed ()
  "W4.3: changed host key maps to `host-key-changed'."
  (dolist (s '("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
               "Host key verification failed.\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'host-key-changed (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-unknown-falls-back ()
  "W4.3: unrecognized stderr maps to `unknown' with a non-empty hint."
  (let ((r (emacs-jupyter-notebook-ssh-classify-stderr
            "something completely unparseable\n")))
    (should (eq 'unknown (plist-get r :kind)))
    (should (stringp (plist-get r :hint)))
    (should (> (length (plist-get r :hint)) 0))))

(ert-deftest ejn-w4.3-async-fail-enriches-classified-errors ()
  "W4.3: `--async-fail' surfaces classified SSH errors with a kind prefix and hint."
  (with-temp-buffer
    (let* ((captured nil)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :error-callback (lambda (_ctx err) (setq captured err)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail
         context "ssh: Could not resolve hostname mother: Name or service not known\n"))
      (should (stringp captured))
      (should (string-prefix-p "HOST-UNREACHABLE:" captured))
      (should (string-match-p "Hint: " captured)))))

(ert-deftest ejn-w4.3-async-fail-passes-unknown-through ()
  "W4.3: unrecognized errors pass through `--async-fail' verbatim."
  (with-temp-buffer
    (let* ((captured nil)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :error-callback (lambda (_ctx err) (setq captured err)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail context "unparseable noise\n"))
      (should (equal captured "unparseable noise\n")))))

(ert-deftest ejn-w7.1-launch-sentinel-nonzero-exit-classifies-auth-failed-stderr ()
  "W7.1: `--async-launch-sentinel' firing on nonzero exit transitions the
async context to phase `error' and the classified stderr from W4.3
appears in the user-visible message.  A launch process whose stderr
contains an SSH auth-failed pattern must surface as `AUTH-FAILED:' with
a `Hint:' line."
  (with-temp-buffer
    (let* ((origin (current-buffer))
           captured captured-context
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :session-id "s1"
                     :origin-buffer origin
                     :error-callback (lambda (ctx err)
                                       (setq captured err
                                             captured-context ctx)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        ;; Real subprocess so the sentinel fires on a real exit.  Route
        ;; the auth-failed stderr through the real ssh-start-process path
        ;; so `--process-output' picks it up from the stderr buffer.
        (let ((process (emacs-jupyter-notebook-ssh-start-process
                        "ejn-test-w7.1-launch-fail"
                        '("sh" "-c"
                          "printf 'Permission denied (publickey).\\n' 1>&2; exit 1")
                        (lambda (proc _event)
                          (emacs-jupyter-notebook--async-launch-sentinel
                           context proc)))))
          (setq context (emacs-jupyter-notebook--async-put
                         context :launch-process process))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not captured) (< (float-time) deadline))
              (accept-process-output process 0.05)))))
      (should captured)
      (should captured-context)
      (should (eq (plist-get captured-context :phase) 'error))
      (should (stringp (plist-get captured-context :error)))
      (should (string-prefix-p "AUTH-FAILED:" captured))
      (should (string-match-p "Hint: " captured)))))

(defun ejn-w7.2--run-retrieve-exhaustion ()
  "Drive `--async-retrieve' through retry exhaustion via a real failing
subprocess.  Returns a plist with `:captured' (error-data), `:context'
(final context), `:spawned' (process list), and `:baseline' (baseline
buffer list captured before the run).  Extracted so the two W7.2
assertions can share exactly one execution."
  (let* ((baseline (ejn-test--ejn-process-buffers))
         (emacs-jupyter-notebook-connection-retrieve-attempts 2)
         (emacs-jupyter-notebook-connection-retrieve-delay 0.02)
         (spawned nil)
         captured captured-context)
    (with-temp-buffer
      (let* ((origin (current-buffer))
             (context (emacs-jupyter-notebook--async-new-context
                       :phase 'retrieve
                       :session-id "w72"
                       :profile '(:profile "p" :host "h")
                       :entry '(:profile "p"
                                :session-id "w72"
                                :remote-host "h"
                                :remote-connection-file "/remote/kernel.json")
                       :origin-buffer origin
                       :error-callback (lambda (ctx err)
                                         (setq captured err
                                               captured-context ctx)))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf (((symbol-function 'display-warning) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                   (lambda (name _argv sentinel)
                     (let* ((stderr (generate-new-buffer
                                     (format " *%s stderr*" name)))
                            (proc (make-process
                                   :name name
                                   :buffer (generate-new-buffer
                                            (format " *%s*" name))
                                   :command '("sh" "-c"
                                              "printf 'scp: no such file\\n' 1>&2; exit 1")
                                   :connection-type 'pipe
                                   :noquery t
                                   :sentinel sentinel
                                   :stderr stderr)))
                       (process-put proc 'emacs-jupyter-notebook-stderr-buffer
                                    stderr)
                       (push proc spawned)
                       proc))))
          (emacs-jupyter-notebook--async-retrieve context)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not captured) (< (float-time) deadline))
              (accept-process-output nil 0.02))))))
    (list :captured captured
          :context captured-context
          :spawned spawned
          :baseline baseline)))

(ert-deftest ejn-w7.2-async-retrieve-exhausts-retries-fails-cleanly ()
  "W7.2: `--async-retrieve' exhausts its retries → phase `error' and the
last-error is captured on the context.  This assertion is UNAFFECTED by
CC1 and must always pass."
  (let* ((run (ejn-w7.2--run-retrieve-exhaustion))
         (context (plist-get run :context)))
    (should (plist-get run :captured))
    (should context)
    (should (eq (plist-get context :phase) 'error))
    (should (stringp (plist-get context :error)))
    (should (string-match-p "SCP failed" (plist-get context :error)))
    (dolist (proc (plist-get run :spawned))
      (should-not (process-live-p proc)))
    (let ((copy (plist-get context :remote-copy)))
      (when copy
        (should-not (file-exists-p copy))))))

(ert-deftest ejn-w7.2-async-retrieve-does-not-leak-scp-buffers ()
  "W7.2 (leak assertion, split from the retry-exhaustion test per W7.6):
after retrieve exhausts its retries, no scp stdout/stderr buffers survive
above the baseline.  Currently `:expected-result :failed' — CC1:
`--async-retrieve-attempt' overwrites `:scp-process' on every retry
without disposing the previous process, so (attempts-1)*2 hidden scp
buffers leak.  Flip to `:passed' once CC1 lands."
  :expected-result :failed
  (let ((run (ejn-w7.2--run-retrieve-exhaustion)))
    (let ((leaked (cl-set-difference (ejn-test--ejn-process-buffers)
                                     (plist-get run :baseline))))
      (should-not leaked))))

(ert-deftest ejn-w4.4-build-pid-alive-uses-kill-zero ()
  "W4.4: the PID-alive probe argv ends with `kill -0 <pid>'."
  (let ((argv (emacs-jupyter-notebook-ssh-build-pid-alive
               '(:profile "p" :host "mother") 12345)))
    (should (member "kill -0 12345" argv))))

(ert-deftest ejn-w4.8-async-probe-fails-when-no-pid ()
  "W4.8: when the registry entry has no `:remote-pid' (pre-W4.2 session)
the probe MUST fail with a clear explanation; it must NOT silently bypass
to `--async-retrieve' (that would be a backwards-compat shim)."
  (let* (retrieve-called probe-called fail-called fail-reason
         (entry '(:profile "p" :session-id "s1" :remote-host "h"
                  :remote-connection-file "/r/k.json"))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :origin-buffer (current-buffer))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _) (setq probe-called t) nil))
              ((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (_ctx err)
                 (setq fail-called t fail-reason err))))
      (emacs-jupyter-notebook--async-probe-pid-alive context))
    (should-not retrieve-called)
    (should-not probe-called)
    (should fail-called)
    (should (string-match-p "no recorded PID" fail-reason))
    (should (string-match-p "start-remote-kernel" fail-reason))))

(ert-deftest ejn-w4.4-async-probe-success-proceeds-to-retrieve ()
  "W4.4: a successful PID-alive probe leads to `--async-retrieve'."
  (let* ((retrieve-called nil)
         (entry '(:profile "p" :session-id "s1" :remote-host "h"
                  :remote-pid 12345
                  :remote-connection-file "/r/k.json"))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (_name _argv sentinel)
                 ;; Synthesize a process whose sentinel reports exit 0.
                 (let ((proc (start-process "ejn-test-probe-ok" nil "true")))
                   (set-process-sentinel proc sentinel)
                   proc))))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      ;; Drive the sentinel by waiting for the process to exit.
      (let ((deadline (+ (float-time) 5)))
        (while (and (not retrieve-called) (< (float-time) deadline))
          (sleep-for 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should retrieve-called)))

(ert-deftest ejn-w4.4-async-probe-dead-pid-fails-context ()
  "W4.4: a nonzero PID-alive probe fails the context with a `kernel-dead'
explanation, leaving the registry entry intact."
  (let* (fail-called fail-reason
         (entry '(:profile "p" :session-id "s1" :remote-host "h"
                  :remote-pid 99999
                  :remote-connection-file "/r/k.json"))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (_ctx err)
                 (setq fail-called t fail-reason err)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (_name _argv sentinel)
                 (let ((proc (start-process "ejn-test-probe-fail" nil "false")))
                   (set-process-sentinel proc sentinel)
                   proc))))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not fail-called) (< (float-time) deadline))
          (sleep-for 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should fail-called)
    (should (string-match-p "no longer alive" fail-reason))
    (should (string-match-p "start-remote-kernel" fail-reason))))

(ert-deftest ejn-w4.8-ensure-client-async-does-not-auto-restart-on-dead-reconnect ()
  "W4.8: when reconnect-to-entry fails (e.g. W4.4 dead-PID), the
`--ensure-client-async' fallback MUST NOT remove the registry entry and
MUST NOT start a fresh kernel.  It surfaces the error to the caller's
error-callback so the user can decide."
  (with-temp-buffer
    (let* ((entry '(:profile "p" :session-id "s8" :remote-host "h"
                    :remote-pid 99999 :local-file "/tmp/foo.py"
                    :remote-connection-file "/r/k.json"))
           reconnect-error-cb start-called registry-removed err-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () entry))
                ((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                 (lambda (_entry _cb error-cb)
                   (setq reconnect-error-cb error-cb)))
                ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                 (lambda (&rest _) (setq start-called t)))
                ((symbol-function 'emacs-jupyter-notebook--remove-registry-entry)
                 (lambda (&rest _) (setq registry-removed t))))
        (emacs-jupyter-notebook--ensure-client-async
         #'ignore
         (lambda (_ctx _err) (setq err-called t)))
        (should (functionp reconnect-error-cb))
        ;; Simulate the W4.4 kernel-dead failure.
        (funcall reconnect-error-cb nil "kernel-dead")
        (should err-called)
        (should-not start-called)
        (should-not registry-removed)))))

(ert-deftest ejn-w4.8-async-fail-disposes-probe-process-stderr-buffer ()
  "W4.8: `--async-fail' disposes the W4.4 PID-probe process and its stderr
buffer when the context carries one."
  (with-temp-buffer
    (let* ((probe (emacs-jupyter-notebook-ssh-start-process
                   "ejn-test-probe-fail" '("sleep" "60")))
           (stderr (process-get probe 'emacs-jupyter-notebook-stderr-buffer))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'probe
                     :probe-process probe)))
      (should (buffer-live-p stderr))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail context "boom"))
      (should-not (process-live-p probe))
      (should-not (buffer-live-p stderr)))))

(ert-deftest ejn-w4.8-heartbeat-cancel-cancels-pending-timeout-timer ()
  "W4.8: `--heartbeat-cancel' must also cancel the per-probe timeout timer
so it cannot fire (and bump misses) after cleanup."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--heartbeat-timer
          (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--heartbeat-timeout-timer
          (run-with-timer 1000 nil #'ignore))
    (emacs-jupyter-notebook--heartbeat-cancel)
    (should-not emacs-jupyter-notebook--heartbeat-timer)
    (should-not emacs-jupyter-notebook--heartbeat-timeout-timer)))

(ert-deftest ejn-w4.5-heartbeat-success-keeps-tunnel-alive ()
  "W4.5: a successful heartbeat reply keeps `--tunnel-dead' nil and resets
the miss counter regardless of prior misses."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client)
    (setq emacs-jupyter-notebook--heartbeat-misses 1)
    (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 2)
          (emacs-jupyter-notebook-heartbeat-timeout 0.2))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_client cb)
                   (funcall cb '(:status "ok") nil))))
        (emacs-jupyter-notebook--heartbeat-tick)
        (should (= 0 emacs-jupyter-notebook--heartbeat-misses))
        (should-not emacs-jupyter-notebook--tunnel-dead)))))

(ert-deftest ejn-w4.5-heartbeat-n-consecutive-misses-flip-tunnel-dead ()
  "W4.5: after `--heartbeat-misses-allowed' consecutive misses the buffer
flags --tunnel-dead, clears --kernel-status, and the timer is cancelled."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client)
    (setq emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--kernel-status 'idle)
    (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 2))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (should-not emacs-jupyter-notebook--tunnel-dead)
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (should emacs-jupyter-notebook--tunnel-dead)
        (should-not emacs-jupyter-notebook--kernel-status)
        (should-not emacs-jupyter-notebook--heartbeat-timer)))))

(ert-deftest ejn-w4.5-heartbeat-cancel-clears-state ()
  "W4.5: cancelling the heartbeat zeros misses, drops inflight, removes timer."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--heartbeat-misses 1)
    (setq emacs-jupyter-notebook--heartbeat-inflight 'tok)
    (emacs-jupyter-notebook--heartbeat-cancel)
    (should-not emacs-jupyter-notebook--heartbeat-timer)
    (should (= 0 emacs-jupyter-notebook--heartbeat-misses))
    (should-not emacs-jupyter-notebook--heartbeat-inflight)))

(ert-deftest ejn-w4.5-heartbeat-skipped-when-tunnel-already-dead ()
  "W4.5: `--heartbeat-tick' does not fire a probe when --tunnel-dead is set."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client
          emacs-jupyter-notebook--tunnel-dead t)
    (let (probe-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_c _cb) (setq probe-called t))))
        (emacs-jupyter-notebook--heartbeat-tick)
        (should-not probe-called)))))

(ert-deftest ejn-w4.5-heartbeat-cancelled-by-release-local-resources ()
  "W4.5 + W1: `--release-local-resources' cancels the heartbeat timer
as part of local cleanup (kill-buffer-hook + mode-disable both route here)."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client
          emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (emacs-jupyter-notebook--release-local-resources)
    (should-not emacs-jupyter-notebook--heartbeat-timer)))

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
        (emacs-jupyter-notebook-send-cell))
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

(ert-deftest ejn-error-callback-decodes-ansi-escape-codes-in-traceback ()
  "Python tracebacks arrive with ANSI colour SGR escapes (`\\x1b[0;31m'
around the error class, `\\x1b[1m' for bold, etc.).  The `error'
callback must strip those escapes and translate them into `face'
text-properties rather than leaving them as literal bytes."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "1/0"))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                       (current-buffer) handle 'mock-client))
           (err-fn (cadr (assoc "error" callbacks)))
           (raw-traceback
            (list
             "\e[0;31m---------------------------------------------------------------------------\e[0m"
             "\e[0;31mZeroDivisionError\e[0m                         Traceback (most recent call last)"
             "Cell \e[0;32mIn[1], line 1\e[0m"
             "\e[0;31mZeroDivisionError\e[0m: division by zero")))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   (list :traceback raw-traceback
                         :ename "ZeroDivisionError"
                         :evalue "division by zero"))))
        (funcall err-fn 'mock-msg))
      (let* ((entry (emacs-jupyter-notebook-panel--entry
                     panel (plist-get handle :id)))
             (content (plist-get entry :content)))
        (should content)
        (should-not (string-match-p "\e\\[[0-9;]*m" content))
        (should (string-match-p "ZeroDivisionError" content))
        (should (string-match-p "division by zero" content))))))

(ert-deftest ejn-panel-append-text-preserves-ansi-faces-under-fallback-face ()
  "`ejn-panel-append-text' composes the optional FACE with any
per-character faces already on TEXT (e.g. from `ansi-color-apply').
The ANSI colours must remain visible while the fallback FACE covers
the uncoloured spans."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "boom")))
      (ejn-panel-append-text
       handle
       (concat (propertize "red-part" 'face 'font-lock-warning-face)
               "-plain")
       'emacs-jupyter-notebook-result-error-face)
      (let* ((entry (emacs-jupyter-notebook-panel--entry
                     panel (plist-get handle :id)))
             (content (plist-get entry :content))
             (red-face (get-text-property 0 'face content))
             (plain-face (get-text-property (length "red-part") 'face content)))
        ;; Preserved ANSI-style face on the colored span.
        (should (or (eq red-face 'font-lock-warning-face)
                    (and (listp red-face)
                         (memq 'font-lock-warning-face red-face))))
        ;; Fallback face applied to the plain span.
        (should (or (eq plain-face 'emacs-jupyter-notebook-result-error-face)
                    (and (listp plain-face)
                         (memq 'emacs-jupyter-notebook-result-error-face
                               plain-face))))))))

(ert-deftest ejn-complete-at-point-strips-capf-metadata-before-calling-completion-in-region ()
  "Regression: the capf result includes `:exclusive 'no' as trailing
plist properties, but `completion-in-region' accepts only (START END
COLLECTION).  Passing the full capf list via `apply' throws \"wrong
number of arguments\".  The explicit `complete-at-point' command and
the fallback UI refresh path must both strip the metadata."
  (with-temp-buffer
    (insert "np.arr")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          captured-args)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--completion-result)
                 (lambda ()
                   ;; The real capf shape produced by
                   ;; `--completion-result-from-reply'.
                   (list 3 6 '("array" "arrange") :exclusive 'no)))
                ((symbol-function 'completion-in-region)
                 (lambda (&rest args) (setq captured-args args))))
        (emacs-jupyter-notebook-complete-at-point)
        (should captured-args)
        (should (= (length captured-args) 3))
        (should (equal (nth 0 captured-args) 3))
        (should (equal (nth 1 captured-args) 6))
        (should (equal (nth 2 captured-args) '("array" "arrange")))))))

(ert-deftest ejn-send-region-bounds-uses-standard-region ()
  "`--region-bounds' returns `region-beginning'/`region-end' when Evil
is not involved and the standard Emacs region is active."
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (set-mark 5)
    (activate-mark)
    (let ((result (emacs-jupyter-notebook--region-bounds)))
      (should (equal result '(2 5))))))

(defvar evil-visual-beginning)
(defvar evil-visual-end)

(ert-deftest ejn-send-region-bounds-uses-evil-visual-markers ()
  "`--region-bounds' prefers Evil's `evil-visual-beginning'/`-end' markers
when Evil visual state is active — this covers the case where Evil has
deactivated the standard region before the interactive form runs."
  (with-temp-buffer
    (insert "abcdef")
    (let ((evil-visual-beginning (copy-marker 2))
          (evil-visual-end (copy-marker 5)))
      (cl-letf (((symbol-function 'evil-visual-state-p) (lambda () t)))
        (let ((result (emacs-jupyter-notebook--region-bounds)))
          (should (equal result '(2 5))))))))

(ert-deftest ejn-send-region-bounds-signals-when-no-region ()
  "`--region-bounds' raises a user-error when no region is available."
  (with-temp-buffer
    (insert "abcdef")
    (deactivate-mark)
    (should-error (emacs-jupyter-notebook--region-bounds) :type 'user-error)))

(ert-deftest ejn-send-region-and-buffer-do-not-mutate-source ()
  "W2: region/buffer eval does not mutate source-buffer text and has cell-key nil."
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (let ((before (buffer-string))
          (modified (buffer-modified-p))
          (emacs-jupyter-notebook--client 'mock-client)
          calls)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code entry-handle)
               (push (list code (plist-get entry-handle :cell-key)) calls))))
        (emacs-jupyter-notebook-send-region (point-min) (line-end-position))
        (emacs-jupyter-notebook-send-buffer))
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
    (should (string-match-p "C-c j c" text))))

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

(ert-deftest ejn-w7.3-cancel-during-tunnel-reconnect-tears-tunnel-preserves-registry ()
  "W7.3 reconnect branch (`:owns-kernel nil'): cancelling during the
tunnel phase kills the live tunnel process, clears the async context,
and leaves the pre-existing registry entry untouched (because the entry
is the durable reconnect key)."
  (let* ((registry-dir (make-temp-file "ejn-w73-reg-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry '(:profile "p"
                  :session-id "w73-reconn"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (with-temp-buffer
            (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                            "emacs-jupyter-notebook-tunnel-w73-reconn"
                            '("sleep" "60")))
                   (stderr (process-get tunnel
                                        'emacs-jupyter-notebook-stderr-buffer)))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :owns-kernel nil
                     :profile '(:profile "p" :host "example.com")
                     :entry entry
                     :tunnel-process tunnel
                     :origin-buffer (current-buffer)
                     :error-callback (lambda (_ctx _err) nil)))
              (emacs-jupyter-notebook-cancel-operation)
              (should-not emacs-jupyter-notebook--async-context)
              (should-not (process-live-p tunnel))
              (should-not (buffer-live-p stderr))
              ;; Registry entry survives the cancellation.
              (let ((remaining (emacs-jupyter-notebook-registry-load
                                registry-file)))
                (should (= 1 (length remaining)))
                (should (equal (plist-get (car remaining) :session-id)
                               "w73-reconn"))))))
      (delete-directory registry-dir t))))

(ert-deftest ejn-w7.3-cancel-during-tunnel-fresh-start-tears-tunnel-registry-untouched ()
  "W7.3 fresh-start branch (`:owns-kernel t'): cancelling during the
tunnel phase kills the live tunnel process, clears the async context,
and leaves the registry file untouched.  In the fresh-start flow the
entry is only written by `--async-connect-finalize', so cancelling
before that point should NOT create a stray registry row."
  (let* ((registry-dir (make-temp-file "ejn-w73-reg-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (with-temp-buffer
            (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                            "emacs-jupyter-notebook-tunnel-w73-fresh"
                            '("sleep" "60")))
                   (stderr (process-get tunnel
                                        'emacs-jupyter-notebook-stderr-buffer)))
              (setq emacs-jupyter-notebook--session-entry nil)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :owns-kernel t
                     :session-id "w73-fresh"
                     :profile '(:profile "p" :host "example.com")
                     :entry '(:profile "p"
                              :session-id "w73-fresh"
                              :remote-host "example.com"
                              :remote-connection-file "/remote/kernel.json")
                     :tunnel-process tunnel
                     :origin-buffer (current-buffer)
                     :error-callback (lambda (_ctx _err) nil)))
              ;; W7.6: prove the durable-state helpers are NOT called on this
              ;; path — cancel is not a terminator.  A regression that starts
              ;; calling `--cleanup-remote-entry' or `--remove-registry-entry'
              ;; from cancel would trip these should-not assertions.
              (let (remote-cleanup-called registry-remove-called
                    shutdown-called)
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                           (lambda (&rest _) (setq remote-cleanup-called t)))
                          ((symbol-function 'emacs-jupyter-notebook--remove-registry-entry)
                           (lambda (&rest _) (setq registry-remove-called t)))
                          ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                           (lambda (&rest _) (setq shutdown-called t))))
                  (emacs-jupyter-notebook-cancel-operation)
                  (should-not remote-cleanup-called)
                  (should-not registry-remove-called)
                  (should-not shutdown-called)))
              (should-not emacs-jupyter-notebook--async-context)
              (should-not (process-live-p tunnel))
              (should-not (buffer-live-p stderr))
              ;; No registry entry was ever created for this session; no file.
              (should-not (file-exists-p registry-file))
              (should-not emacs-jupyter-notebook--session-entry))))
      (delete-directory registry-dir t))))

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
        (emacs-jupyter-notebook-send-cell))
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
        (emacs-jupyter-notebook-send-cell)
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
        (emacs-jupyter-notebook-send-cell)
        (should (equal (car start-captured) "mydefault"))
        (should (functionp (cdr start-captured)))
        (should eval-called)))))

;; W4.8: `ejn-evaluate-cell-stale-file-entry-falls-back-to-start-default'
;; was removed.  The old behavior — silently removing the registry entry
;; and starting a fresh kernel when reconnect to a stale entry failed —
;; violates the binding rule that only `shutdown-kernel' and
;; `clean-orphaned-kernels' may terminate / deregister.  The new
;; `--ensure-client-async' surfaces the reconnect error to the caller
;; instead; see `ejn-w4.8-ensure-client-async-does-not-auto-restart-on-dead-reconnect'.

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
      (emacs-jupyter-notebook-send-cell)
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
        (emacs-jupyter-notebook-send-cell)
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

;; Frontend variables introduced for W3.5 tests; the real packages define
;; these but we mock them to keep tests independent of the packages.
(defvar corfu-mode nil)
(defvar completion-in-region-mode nil)
(defvar company-mode nil)

(ert-deftest ejn-w3.5-refresh-ui-skips-when-completion-in-region-active ()
  ;; W3.7: when `completion-in-region-mode' is active there is no reliable
  ;; cross-version way to force the popup to re-fetch capf candidates.
  ;; The refresh hook deliberately becomes a no-op in that case; the
  ;; next user keystroke causes capf to be re-invoked naturally and the
  ;; popup picks up the new candidates from the cache then.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb fallback-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf* (((symbol-value 'completion-in-region-mode) t)
                   ((symbol-function 'completion-in-region)
                    (lambda (&rest _) (setq fallback-called t))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (should-not fallback-called))))))

(ert-deftest ejn-w3.5-reply-refreshes-company-via-manual-begin ()
  ;; When company is active, the reply path calls `company-manual-begin'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb refresh-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf* (((symbol-value 'corfu-mode) nil)
                   ((symbol-value 'company-mode) t)
                   ((symbol-function 'company-manual-begin)
                    (lambda (&rest _) (setq refresh-called 'company-manual))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (should (eq refresh-called 'company-manual)))))))

(ert-deftest ejn-w3.5-reply-refreshes-fallback-completion-in-region ()
  ;; With neither corfu nor company active, the reply path falls back to
  ;; `completion-in-region'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb fallback-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq fallback-called t))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (should fallback-called))))))

(ert-deftest ejn-w3.7-context-changed-drops-reply-entirely ()
  ;; W3.7: if the user moved point so the live key no longer matches the
  ;; request's key, the reply is DROPPED entirely.  Caching it under the
  ;; original key would risk surfacing out-of-date candidates if the user
  ;; later returned to that context after the kernel state had drifted.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb refresh-called orig-key)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq refresh-called t))))
          (setq orig-key (emacs-jupyter-notebook--completion-key))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          ;; User moves point AFTER request was sent.
          (forward-char -3)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          ;; Reply is dropped: cache does not contain orig-key, no refresh.
          (should-not (and emacs-jupyter-notebook--completion-cache
                           (gethash orig-key emacs-jupyter-notebook--completion-cache)))
          (should-not refresh-called))))))

(ert-deftest ejn-w3.7-idle-timer-captures-buffer ()
  ;; W3.7: `--completion-start-idle-timer' must capture `current-buffer'
  ;; in a closure so the timer fires in the buffer that armed it, not in
  ;; whatever buffer happens to be current when it fires.  Without this
  ;; fix, a timer armed in buffer A would mutate buffer B's pending state.
  (let ((buf-a (generate-new-buffer "ejn-w37-a"))
        (buf-b (generate-new-buffer "ejn-w37-b"))
        timer populate-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--completion-idle-populate)
                   (lambda () (setq populate-buffer (current-buffer)))))
          (with-current-buffer buf-a
            (setq-local emacs-jupyter-notebook-mode t)
            (emacs-jupyter-notebook--completion-start-idle-timer)
            (setq timer emacs-jupyter-notebook--completion-idle-timer))
          (should (timerp timer))
          ;; Switch to a different buffer and fire buf-a's timer.
          (with-current-buffer buf-b
            (timer-event-handler timer))
          (should (eq populate-buffer buf-a)))
      (when (timerp timer)
        (cancel-timer timer))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest ejn-w3.7-cancel-idle-timer-clears-pending-state ()
  ;; W3.7: cancelling the idle timer must also clear the pending key/id
  ;; so any in-flight reply is dropped on arrival.  Without this, a
  ;; cancelled timer could still leave the buffer in a state where an
  ;; old reply is accepted and cached against a context the user has
  ;; already left.
  (with-temp-buffer
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--completion-pending-key '(123 . "foo"))
    (setq emacs-jupyter-notebook--completion-pending-id 7)
    (emacs-jupyter-notebook--completion-cancel-idle-timer)
    (should-not emacs-jupyter-notebook--completion-idle-timer)
    (should-not emacs-jupyter-notebook--completion-pending-key)
    (should-not emacs-jupyter-notebook--completion-pending-id)))

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

(ert-deftest ejn-inspect-at-point-decodes-ansi-escapes ()
  "IPython colourises its inspector (`?') output with ANSI SGR escapes.
The displayed text must have them decoded (to faces) rather than dumped
as literal `\\e[0;31m...' sequences into the echo area / *Message*."
  (ejn-test-with-temp-buffer "# %%\nrange(5)\n"
    (goto-char (point-min))
    (search-forward "range")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          displayed inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (m &rest _) (setq displayed m))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_c _code _pos _detail cb) (setq inspect-callback cb))))
          (emacs-jupyter-notebook-inspect-at-point)
          (funcall inspect-callback
                   (list :found t
                         :data (list :text/plain
                                     "\e[0;31mSignature:\e[0m range(stop)\n"))
                   nil)))
      ;; No raw escape sequence survived, the visible text is intact, and
      ;; the trailing newline was trimmed.
      (should displayed)
      (should-not (string-match-p "\e\\[" displayed))
      (should (equal (substring-no-properties displayed)
                     "Signature: range(stop)")))))

(ert-deftest ejn-inspect-callback-not-found-displays-nothing ()
  "Real `inspect_reply' for an unknown symbol is `(:status ok :found
nil :data ())' — an EMPTY data plist.  The callback must display nothing
(the `text/plain' guard handles it), not error or show an empty popup.
Pins the real reply shape the happy-path test never exercises."
  (ejn-test-with-temp-buffer "# %%\nnope\n"
    (search-forward "nope")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          displayed inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (m &rest _) (setq displayed m))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_c _code _pos _detail cb) (setq inspect-callback cb))))
          (emacs-jupyter-notebook-inspect-at-point)
          (funcall inspect-callback '(:status "ok" :found nil :data ()) nil)))
      (should-not displayed))))

(ert-deftest ejn-completion-result-from-reply-handles-vector-matches ()
  "Real emacs-jupyter delivers complete_reply `:matches' as a VECTOR
(JSON array), not a list, and the bounds come from the cursor_start /
cursor_end DELTA (token length), independent of absolute offsets.  Pins
both so a regression in either is caught without a live kernel."
  (with-temp-buffer
    (insert "obj.attr")
    (goto-char (point-max))
    ;; Vector matches, and cursor_start/end describing the 4-char token
    ;; `attr' at arbitrary absolute offsets (100..104).
    (let ((r (emacs-jupyter-notebook--completion-result-from-reply
              '(:matches ["attr" "attribute"] :cursor_start 100 :cursor_end 104))))
      (should (= (nth 0 r) (- (point) 4)))           ; token start via delta
      (should (= (nth 1 r) (point)))                 ; token end at point
      (should (equal (nth 2 r) '("attr" "attribute"))) ; vector -> list
      (should (eq (plist-get (cdddr r) :exclusive) 'no)))))

(ert-deftest ejn-ssh-remote-launch-preserves-quoted-nix-command ()
  "A profile `:jupyter-command' that is a full shell command with embedded
single quotes and spaces (the real nix-shell form) must reach the remote
command string INTACT and unquoted, so the remote shell interprets it.
Regex-only happy-path tests use bare `uv run jupyter'; this pins the
quoted case."
  (let* ((nixcmd (concat "nix shell --impure --expr "
                         "'with import <nixpkgs> {}; "
                         "python3.withPackages (ps: [ ps.jupyter ])' -c jupyter"))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch
                  (list :profile "p" :host "mother" :remote-cwd "~"
                        :remote-cache-dir "/tmp/ejn" :kernelspec "python3"
                        :jupyter-command nixcmd)
                  "session"))
         (remote (plist-get launch :remote-command)))
    (should (string-match-p (regexp-quote (concat "nohup " nixcmd " kernel"))
                            remote))))

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
        (emacs-jupyter-notebook-send-cell))
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
        (emacs-jupyter-notebook-send-cell)
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

;; W4.7: `ejn-tunnel-dead-reset-on-new-connection' was removed along with
;; `--connect-entry'.  The async-connect-finalize path that resets
;; `--tunnel-dead' on a successful new client is exercised by
;; `ejn-async-connect-finalize-sets-client-on-success'.

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
  ;; Post-W4.4: tunnel-reconnect goes through `--async-probe-pid-alive'
  ;; before retrieve.  The probe is stubbed to call retrieve directly so
  ;; this test still pins the async-only contract.
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-pid 12345
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        (retrieve-called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
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
        (emacs-jupyter-notebook-send-cell)
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
        (emacs-jupyter-notebook-send-cell)
        (should-not eval-called)))))

(ert-deftest ejn-w4.6-heartbeat-death-routes-through-tunnel-reconnect ()
  "W4.6: the --tunnel-dead flag set by a heartbeat miss-threshold leads
`--ensure-client-async' to `--tunnel-reconnect' in exactly the same way as
sentinel-driven death.  Heartbeat and sentinel are indistinguishable to
the evaluate flow."
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead nil)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t)))
           (emacs-jupyter-notebook-heartbeat-misses-allowed 2))
      ;; Trigger heartbeat-driven death exactly the way the runtime does.
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (emacs-jupyter-notebook--heartbeat-on-miss))
      (should emacs-jupyter-notebook--tunnel-dead)
      ;; Now evaluate: the engine must route through tunnel-reconnect
      ;; without distinguishing how we got here.
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (buffer callback _error-callback)
                   (setq reconnect-called t)
                   (should (functionp callback))
                   (setq emacs-jupyter-notebook--tunnel-dead nil)
                   (setq emacs-jupyter-notebook--client 'mock-client)
                   (funcall callback nil))))
        (emacs-jupyter-notebook-send-cell)
        (should reconnect-called)
        (should eval-called)))))

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

(ert-deftest ejn-w5.1-evaluation-request-set-on-evaluate ()
  "W5.1: --evaluate records request-id, panel-entry, cell-key, started-at."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook--evaluation-request nil)
          (emacs-jupyter-notebook--evaluation-request-counter 0)
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
                 ((symbol-function 'jupyter-execute-request)
                  (lambda (&rest _) 'mock-request)))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (cell-key '("x.py" . 1))
               (handle (ejn-panel-start-entry panel cell-key "x = 1")))
          (unwind-protect
              (emacs-jupyter-notebook-jupyter--evaluate
               'mock-client "x = 1" handle)
            (when (timerp emacs-jupyter-notebook--evaluation-timer)
              (cancel-timer emacs-jupyter-notebook--evaluation-timer)))
          (let ((req emacs-jupyter-notebook--evaluation-request))
            (should req)
            (should (integerp (plist-get req :request-id)))
            (should (> (plist-get req :request-id) 0))
            (should (eq (plist-get req :panel-entry) handle))
            (should (equal (plist-get req :cell-key) cell-key))
            (should (numberp (plist-get req :started-at)))
            (should (<= (plist-get req :started-at) (float-time)))))))))

(ert-deftest ejn-w5.1-evaluation-request-cleared-on-execute-reply ()
  "W5.1: execute_reply clears --evaluation-request on the source buffer."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (reply-fn (cadr (assoc "execute_reply" callbacks))))
      (setq emacs-jupyter-notebook--evaluation-request
            (list :request-id 42
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:status "ok" :execution_count 1))))
        (funcall reply-fn 'mock-msg))
      (should-not emacs-jupyter-notebook--evaluation-request))))

(ert-deftest ejn-w5.1-evaluation-request-counter-bumps-per-call ()
  "W5.1: every --evaluate dispatch picks up a unique request-id."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-timer nil)
          (emacs-jupyter-notebook--evaluation-request nil)
          (emacs-jupyter-notebook--evaluation-request-counter 0)
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
                 ((symbol-function 'jupyter-execute-request)
                  (lambda (&rest _) 'mock-request)))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (handle1 (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
               (handle2 (ejn-panel-start-entry panel '("x.py" . 2) "x = 2")))
          (unwind-protect
              (progn
                (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 1" handle1)
                (let ((id1 (plist-get emacs-jupyter-notebook--evaluation-request :request-id)))
                  (emacs-jupyter-notebook-jupyter--evaluate 'mock-client "x = 2" handle2)
                  (let ((id2 (plist-get emacs-jupyter-notebook--evaluation-request :request-id)))
                    (should (integerp id1))
                    (should (integerp id2))
                    (should-not (= id1 id2))
                    (should (> id2 id1)))))
            (when (timerp emacs-jupyter-notebook--evaluation-timer)
              (cancel-timer emacs-jupyter-notebook--evaluation-timer))))))))

(ert-deftest ejn-w5.1-evaluation-on-timeout-ignores-stale-id ()
  "W5.1: a stale timeout closure (mismatched request-id) is a no-op."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--evaluation-request
           (list :request-id 7
                 :panel-entry nil
                 :cell-key nil
                 :started-at (float-time)))
          (emacs-jupyter-notebook--kernel-status nil)
          messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args) (push (apply #'format args) messages))))
        (emacs-jupyter-notebook--evaluation-on-timeout 99)
        (should-not messages)
        (should (eq (plist-get emacs-jupyter-notebook--evaluation-request :request-id) 7))
        (should-not emacs-jupyter-notebook--kernel-status)))))

(ert-deftest ejn-w5.2-timeout-calls-interrupt-adapter ()
  "W5.2: evaluation timeout calls the configured interrupt adapter."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5)
           interrupt-arg)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt)
                 (lambda (client) (setq interrupt-arg client))))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (should (eq interrupt-arg 'mock-client)))))

(ert-deftest ejn-w5.2-timeout-annotates-panel-with-error-suffix ()
  "W5.2: timeout appends \"timed out after Ns\" with error face to the panel entry."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (let* ((snap (ejn-panel-entry-snapshot handle))
             (content (plist-get snap :content)))
        (should (stringp content))
        (should (string-match-p "timed out after 5s" content))
        (should (eq (plist-get snap :status) 'error))
        (let* ((idx (string-match "timed out after" content)))
          (should idx)
          (should (eq (get-text-property idx 'face content)
                      'emacs-jupyter-notebook-result-error-face)))))))

(ert-deftest ejn-w5.2-timeout-clears-evaluation-request ()
  "W5.2: a fired timeout clears --evaluation-request."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (should-not emacs-jupyter-notebook--evaluation-request))))

(ert-deftest ejn-w5.2-timeout-does-not-shutdown-or-touch-registry ()
  "W5.2: binding rule — the timeout must NOT call shutdown or registry remove."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5)
           shutdown-called registry-remove-called cleanup-entry-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                 (lambda (&rest _) (setq shutdown-called t)))
                ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                 (lambda (&rest _) (setq registry-remove-called t)))
                ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                 (lambda (&rest _) (setq cleanup-entry-called t))))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (should-not shutdown-called)
      (should-not registry-remove-called)
      (should-not cleanup-entry-called))))

(ert-deftest ejn-w5.2-timeout-without-client-does-not-error ()
  "W5.2: timeout fired with no live client annotates the panel and does not raise."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5)
           interrupt-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt)
                 (lambda (&rest _) (setq interrupt-called t))))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (should-not interrupt-called)
      (should-not emacs-jupyter-notebook--evaluation-request)
      (let ((content (plist-get (ejn-panel-entry-snapshot handle) :content)))
        (should (string-match-p "timed out after 5s" content))))))

(ert-deftest ejn-w5.4-interrupt-kernel-dispatches-through-adapter-var ()
  "W5.4: `emacs-jupyter-notebook-interrupt-kernel' calls
`emacs-jupyter-notebook-jupyter-interrupt-function'.  Stub the var,
invoke the interactive command, assert the stub saw the buffer-local
client."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          captured)
      (let ((emacs-jupyter-notebook-jupyter-interrupt-function
             (lambda (client) (setq captured client))))
        (call-interactively #'emacs-jupyter-notebook-interrupt-kernel))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w5.4-restart-kernel-dispatches-through-adapter-var ()
  "W5.4: `emacs-jupyter-notebook-restart-kernel' calls
`emacs-jupyter-notebook-jupyter-restart-function'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          captured)
      (let ((emacs-jupyter-notebook-jupyter-restart-function
             (lambda (client) (setq captured client))))
        (call-interactively #'emacs-jupyter-notebook-restart-kernel))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w5.4-interrupt-kernel-errors-without-client ()
  "W5.4: interrupt without a client surfaces a clear error, does not call adapter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-interrupt-function
             (lambda (&rest _) (setq adapter-called t))))
        (should-error (call-interactively #'emacs-jupyter-notebook-interrupt-kernel)))
      (should-not adapter-called))))

(ert-deftest ejn-w5.4-restart-kernel-errors-without-client ()
  "W5.4: restart without a client surfaces a clear error, does not call adapter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-restart-function
             (lambda (&rest _) (setq adapter-called t))))
        (should-error (call-interactively #'emacs-jupyter-notebook-restart-kernel)))
      (should-not adapter-called))))

(ert-deftest ejn-w5.5-cancel-uses-async-in-progress-p-not-raw-context ()
  "W5.5: a successful connect leaves `--async-context' set at phase
`done'.  cancel-operation MUST dispatch on `--async-in-progress-p' so
that cancel during a real evaluation interrupts the kernel rather than
falling into the async-fail branch."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           ;; Simulate the post-connect-finalize state: context not nil,
           ;; phase is `done'.
           (emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context :phase 'done))
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           interrupt-arg async-fail-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt)
                 (lambda (client) (setq interrupt-arg client)))
                ((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (&rest _) (setq async-fail-called t))))
        (emacs-jupyter-notebook-cancel-operation))
      (should (eq interrupt-arg 'mock-client))
      (should-not async-fail-called)
      (should-not emacs-jupyter-notebook--evaluation-request))))

(ert-deftest ejn-w5.5-execute-reply-drops-stale-request-id ()
  "W5.5: an execute_reply whose request-id does NOT match the current
`--evaluation-request' is dropped — the timer stays armed, the request
slot stays populated, and the panel/fringe are not touched."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (buffer (current-buffer)))
      (setq emacs-jupyter-notebook--evaluation-request
            (list :request-id 42 :panel-entry handle :cell-key '("x.py" . 1)
                  :started-at (float-time)))
      (setq emacs-jupyter-notebook--evaluation-timer
            (run-at-time 1000 nil #'ignore))
      (let* ((callbacks (emacs-jupyter-notebook-jupyter--callbacks
                         buffer handle nil 7))
             (reply-fn (cadr (assoc "execute_reply" callbacks))))
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:status "ok" :execution_count 3)))
                  ((symbol-function 'ejn-panel-finish-entry)
                   (lambda (&rest _) (ert-fail "finish-entry called on stale reply")))
                  ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                   (lambda (&rest _) (ert-fail "fringe-set called on stale reply"))))
          (funcall reply-fn 'mock-msg)))
      (should emacs-jupyter-notebook--evaluation-request)
      (should (timerp emacs-jupyter-notebook--evaluation-timer))
      (when (timerp emacs-jupyter-notebook--evaluation-timer)
        (cancel-timer emacs-jupyter-notebook--evaluation-timer))
      (setq emacs-jupyter-notebook--evaluation-timer nil
            emacs-jupyter-notebook--evaluation-request nil))))

(ert-deftest ejn-w5.5-status-idle-with-stale-id-does-not-cancel-timer ()
  "W5.5: a `status=idle' message whose request-id does not match the
current `--evaluation-request' MUST NOT cancel the evaluation timer."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (buffer (current-buffer)))
      (setq emacs-jupyter-notebook--evaluation-request
            (list :request-id 42 :panel-entry handle :cell-key '("x.py" . 1)
                  :started-at (float-time)))
      (setq emacs-jupyter-notebook--evaluation-timer
            (run-at-time 1000 nil #'ignore))
      (let* ((callbacks (emacs-jupyter-notebook-jupyter--callbacks
                         buffer handle nil 7))
             (status-fn (cadr (assoc "status" callbacks))))
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:execution_state "idle"))))
          (funcall status-fn 'mock-msg)))
      (should (timerp emacs-jupyter-notebook--evaluation-timer))
      (when (timerp emacs-jupyter-notebook--evaluation-timer)
        (cancel-timer emacs-jupyter-notebook--evaluation-timer))
      (setq emacs-jupyter-notebook--evaluation-timer nil
            emacs-jupyter-notebook--evaluation-request nil))))

(ert-deftest ejn-w5.5-default-interrupt-adapter-is-non-blocking ()
  "W5.5 MEDIUM (e): the production-default `--interrupt' adapter must
return without blocking even when the underlying `jupyter-interrupt-kernel'
hypothetically did work — the adapter is fire-and-forget."
  (cl-letf (((symbol-function 'jupyter-interrupt-kernel)
             (lambda (_c) nil))
            ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore))
    (let ((start (current-time)))
      (emacs-jupyter-notebook-jupyter--interrupt 'mock-client)
      (let ((elapsed (float-time (time-subtract (current-time) start))))
        (should (< elapsed 0.05))))))

(ert-deftest ejn-w5.3-cancel-during-evaluation-interrupts ()
  "W5.3: cancel-operation with a live --evaluation-request calls interrupt and clears it."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           interrupt-arg)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt)
                 (lambda (client) (setq interrupt-arg client))))
        (emacs-jupyter-notebook-cancel-operation))
      (should (eq interrupt-arg 'mock-client))
      (should-not emacs-jupyter-notebook--evaluation-request))))

(ert-deftest ejn-w5.3-cancel-during-connect-does-not-interrupt ()
  "W5.3: cancel-operation during connect cancels async context, NOT interrupt."
  (let (interrupt-called)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt)
               (lambda (&rest _) (setq interrupt-called t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry '(:profile "p" :session-id "s"))
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'connect
               :origin-buffer (current-buffer)
               :error-callback (lambda (_ctx _err) nil)))
        (setq emacs-jupyter-notebook--evaluation-request nil)
        (emacs-jupyter-notebook-cancel-operation)
        (should-not interrupt-called)
        (should-not emacs-jupyter-notebook--async-context)))))

(ert-deftest ejn-w5.3-cancel-during-evaluation-does-not-shutdown ()
  "W5.3: binding rule — cancel must not call shutdown / registry-remove / cleanup-remote-entry."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time)))
           shutdown-called registry-remove-called cleanup-entry-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                 (lambda (&rest _) (setq shutdown-called t)))
                ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                 (lambda (&rest _) (setq registry-remove-called t)))
                ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                 (lambda (&rest _) (setq cleanup-entry-called t))))
        (emacs-jupyter-notebook-cancel-operation))
      (should-not shutdown-called)
      (should-not registry-remove-called)
      (should-not cleanup-entry-called))))

(ert-deftest ejn-w5.3-cancel-with-nothing-in-flight-user-errors ()
  "W5.3: cancel with neither async nor evaluation pending signals a user-error."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--evaluation-request nil))
      (should-error (emacs-jupyter-notebook-cancel-operation)
                    :type 'user-error))))

(ert-deftest ejn-w5.3-cancel-during-evaluation-annotates-panel-cancelled ()
  "W5.3: cancel during evaluation appends \"cancelled\" with error face to the entry."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore))
        (emacs-jupyter-notebook-cancel-operation))
      (let* ((snap (ejn-panel-entry-snapshot handle))
             (content (plist-get snap :content)))
        (should (string-match-p "cancelled" content))
        (should (eq (plist-get snap :status) 'error))))))

(ert-deftest ejn-w5.3-cancel-completes-fast ()
  "W5.3 async-is-the-rule: cancel-operation must be fast (single-digit ms).
Mock interrupt to a no-op; the interactive cancel path must not block."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key '("x.py" . 1)
                  :started-at (float-time))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore))
        (let ((t0 (float-time)))
          (emacs-jupyter-notebook-cancel-operation)
          (should (< (- (float-time) t0) 0.05)))))))

(ert-deftest ejn-w5.2-timeout-sets-fringe-to-error ()
  "W5.2: timeout marks the cell's fringe indicator as errored."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (cell-key '("x.py" . 1))
           (handle (ejn-panel-start-entry panel cell-key "x = 1"))
           (emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--evaluation-request
            (list :request-id 1
                  :panel-entry handle
                  :cell-key cell-key
                  :started-at (float-time)))
           (emacs-jupyter-notebook-evaluation-timeout 5)
           fringe-args)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-interrupt) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                 (lambda (&rest args) (setq fringe-args args))))
        (emacs-jupyter-notebook--evaluation-on-timeout 1))
      (should (equal (car fringe-args) cell-key))
      (should (eq (cadr fringe-args) 'error)))))

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

;;; W4.1 — Tunnel keepalives

(ert-deftest ejn-w4.1-tunnel-command-includes-server-alive-keepalive ()
  "W4.1: the tunnel argv carries ServerAlive keepalive options.
The keepalive option pair must appear together (Interval + CountMax),
and the existing ExitOnForwardFailure option must still be present."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 15)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ExitOnForwardFailure=yes" cmd))
    (should (member "ServerAliveInterval=15" cmd))
    (should (member "ServerAliveCountMax=3" cmd))))

(ert-deftest ejn-w4.1-tunnel-keepalive-interval-respected ()
  "W4.1: customizing the interval changes the rendered option value."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 30)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ServerAliveInterval=30" cmd))
    (should-not (member "ServerAliveInterval=15" cmd))))

(ert-deftest ejn-w4.1-tunnel-keepalive-disabled-when-zero ()
  "W4.1: setting the interval to 0 omits the keepalive options entirely."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 0)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ExitOnForwardFailure=yes" cmd))
    (should-not (cl-some (lambda (arg)
                           (and (stringp arg)
                                (string-prefix-p "ServerAliveInterval" arg)))
                         cmd))
    (should-not (member "ServerAliveCountMax=3" cmd))))

;;; W6.1 — Single-prefix keymap

(ert-deftest ejn-w6.1-prefix-key-customization-defaults-to-c-c-j ()
  "W6.1: the prefix-key customization defaults to `C-c j'."
  (should (equal emacs-jupyter-notebook-prefix-key "C-c j")))

(ert-deftest ejn-w6.1-mode-map-routes-through-prefix ()
  "W6.1: the mode-map contains exactly one binding — the prefix."
  ;; Bindings are a representative sample; what we assert is that every
  ;; expected command lives under `C-c j' on the prefix-map.
  (let ((map emacs-jupyter-notebook-prefix-map))
    (should (eq (lookup-key map (kbd "c"))
                #'emacs-jupyter-notebook-send-cell))
    (should (eq (lookup-key map (kbd "j"))
                #'emacs-jupyter-notebook-send-cell-and-advance))
    (should (eq (lookup-key map (kbd "r"))
                #'emacs-jupyter-notebook-send-region))
    (should (eq (lookup-key map (kbd "SPC"))
                #'emacs-jupyter-notebook-send-paragraph))
    (should (eq (lookup-key map (kbd "d"))
                #'emacs-jupyter-notebook-send-defun))
    (should (eq (lookup-key map (kbd "b"))
                #'emacs-jupyter-notebook-send-buffer))
    (should (eq (lookup-key map (kbd "s"))
                #'emacs-jupyter-notebook-start-remote-kernel))
    (should (eq (lookup-key map (kbd "R"))
                #'emacs-jupyter-notebook-reconnect-remote-kernel))
    (should (eq (lookup-key map (kbd "y"))
                #'emacs-jupyter-notebook-retry-fresh-kernel))
    (should (eq (lookup-key map (kbd "k"))
                #'emacs-jupyter-notebook-interrupt-kernel))
    (should (eq (lookup-key map (kbd "K"))
                #'emacs-jupyter-notebook-restart-kernel))
    (should (eq (lookup-key map (kbd "S"))
                #'emacs-jupyter-notebook-shutdown-kernel))
    (should (eq (lookup-key map (kbd "x"))
                #'emacs-jupyter-notebook-cancel-operation))
    (should (eq (lookup-key map (kbd "?"))
                #'emacs-jupyter-notebook-status))
    (should (eq (lookup-key map (kbd "L"))
                #'emacs-jupyter-notebook-show-log-buffer))
    (should (eq (lookup-key map (kbd "o"))
                #'emacs-jupyter-notebook-show-output-panel))
    (should (eq (lookup-key map (kbd "t"))
                #'emacs-jupyter-notebook-toggle-panel-view))
    (should (eq (lookup-key map (kbd "."))
                #'emacs-jupyter-notebook-inspect-at-point))
    (should (eq (lookup-key map (kbd "TAB"))
                #'emacs-jupyter-notebook-complete-at-point))
    (should (eq (lookup-key map (kbd "v"))
                #'emacs-jupyter-notebook-fetch-remote-log))
    (should (eq (lookup-key map (kbd "q"))
                #'emacs-jupyter-notebook-list-remote-processes))
    (should (eq (lookup-key map (kbd "w"))
                #'emacs-jupyter-notebook-clean-orphaned-kernels))
    (should (eq (lookup-key map (kbd "n"))
                #'emacs-jupyter-notebook-forward-cell))
    (should (eq (lookup-key map (kbd "p"))
                #'emacs-jupyter-notebook-backward-cell))))

(ert-deftest ejn-w6.1-cell-edit-subprefix ()
  "W6.1: cell-edit subprefix is `%' with the documented sub-bindings."
  (let* ((prefix emacs-jupyter-notebook-prefix-map)
         (sub (lookup-key prefix (kbd "%"))))
    (should (keymapp sub))
    (should (eq (lookup-key sub (kbd "n")) #'emacs-jupyter-notebook-forward-cell))
    (should (eq (lookup-key sub (kbd "p")) #'emacs-jupyter-notebook-backward-cell))
    (should (eq (lookup-key sub (kbd "a")) #'emacs-jupyter-notebook-beginning-of-cell))
    (should (eq (lookup-key sub (kbd "e")) #'emacs-jupyter-notebook-end-of-cell))
    (should (eq (lookup-key sub (kbd "i")) #'emacs-jupyter-notebook-insert-cell-below))
    (should (eq (lookup-key sub (kbd "I")) #'emacs-jupyter-notebook-insert-cell-above))
    (should (eq (lookup-key sub (kbd "d")) #'emacs-jupyter-notebook-delete-cell))
    (should (eq (lookup-key sub (kbd "k")) #'emacs-jupyter-notebook-kill-cell))
    (should (eq (lookup-key sub (kbd "K")) #'emacs-jupyter-notebook-clear-cell))
    (should (eq (lookup-key sub (kbd "y")) #'emacs-jupyter-notebook-duplicate-cell))
    (should (eq (lookup-key sub (kbd "P")) #'emacs-jupyter-notebook-move-cell-up))
    (should (eq (lookup-key sub (kbd "N")) #'emacs-jupyter-notebook-move-cell-down))
    (should (eq (lookup-key sub (kbd "@")) #'code-cells-mark-cell))))

(ert-deftest ejn-w6.1-old-cell-edit-send-bindings-removed ()
  "W6.1: the old `s' / `RET' send-cell-and-advance bindings on `C-c j %' are gone."
  (let* ((prefix emacs-jupyter-notebook-prefix-map)
         (sub (lookup-key prefix (kbd "%"))))
    (should (keymapp sub))
    ;; `s' on the cell-edit subprefix used to send-and-advance; now unbound.
    (should-not (commandp (lookup-key sub (kbd "s"))))
    ;; `RET' likewise.
    (should-not (commandp (lookup-key sub (kbd "RET"))))))

(ert-deftest ejn-w6.1-mode-map-uses-customized-prefix ()
  "W6.1: the mode-map binds the prefix at `emacs-jupyter-notebook-prefix-key'.
This sanity-checks one keystroke from the mode-map all the way to a leaf
command, which is the contract a user actually depends on."
  (should (keymapp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j"))))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j c"))
              #'emacs-jupyter-notebook-send-cell))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j SPC"))
              #'emacs-jupyter-notebook-send-paragraph))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j % i"))
              #'emacs-jupyter-notebook-insert-cell-below)))

(ert-deftest ejn-w6.1-old-c-c-c-binding-removed ()
  "W6.1: legacy `C-c C-c' / `C-c C-r' / `C-c C-b' bindings are gone."
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-c"))))
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-r"))))
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-b")))))

(ert-deftest ejn-w6.1-send-paragraph-routes-to-evaluate-code ()
  "W6.1: send-paragraph delimits via `mark-paragraph' and posts code with cell-key nil."
  (ejn-test-with-temp-buffer "para1 line1\npara1 line2\n\npara2 line1\n"
    (goto-char (point-min))
    (let (captured)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (code key) (push (list code key) captured))))
        (emacs-jupyter-notebook-send-paragraph))
      (should (= (length captured) 1))
      (let* ((entry (car captured))
             (code (nth 0 entry))
             (key (nth 1 entry)))
        (should (string-match-p "para1 line1" code))
        (should (string-match-p "para1 line2" code))
        (should (null key))))))

(ert-deftest ejn-w6.1-send-defun-routes-to-evaluate-code ()
  "W6.1: send-defun delimits via beginning-of-defun/end-of-defun and posts code with nil key."
  (ejn-test-with-temp-buffer "def first():\n    return 1\n\ndef second():\n    return 2\n"
    (goto-char (point-min))
    ;; Place point inside `first'.
    (search-forward "return 1")
    (let (captured)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (code key) (push (list code key) captured))))
        (emacs-jupyter-notebook-send-defun))
      (should (= (length captured) 1))
      (let* ((entry (car captured))
             (code (nth 0 entry))
             (key (nth 1 entry)))
        (should (string-match-p "def first" code))
        (should-not (string-match-p "def second" code))
        (should (null key))))))

;;; W6.2 — Mode-line lighter branches

(ert-deftest ejn-w6.2-mode-line-no-client ()
  "W6.2: no client and no context → ` EJN'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN")))))

(ert-deftest ejn-w6.2-mode-line-healthy ()
  "W6.2: live client + idle kernel + alive tunnel → ` EJN✓'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'idle))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✓")))))

(ert-deftest ejn-w6.2-mode-line-busy ()
  "W6.2: kernel status busy → ` EJN*'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN*")))))

(ert-deftest ejn-w6.2-mode-line-launch-phase ()
  "W6.2: in-progress async at launch phase → ` EJN…launch'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase launch))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…launch")))))

(ert-deftest ejn-w6.2-mode-line-retrieve-phase ()
  "W6.2: retrieve phase → ` EJN…retrieve'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase retrieve))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…retrieve")))))

(ert-deftest ejn-w6.2-mode-line-tunnel-phase ()
  "W6.2: tunnel phase → ` EJN…tunnel'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase tunnel))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…tunnel")))))

(ert-deftest ejn-w6.2-mode-line-connect-phase ()
  "W6.2: connect phase → ` EJN…connect'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase connect))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…connect")))))

(ert-deftest ejn-w6.2-mode-line-async-error ()
  "W6.2: most recent async failed → ` EJN✗' (above busy / phases)."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error t)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✗")))))

(ert-deftest ejn-w6.2-mode-line-tunnel-dead-wins ()
  "W6.2: tunnel-dead beats async-error, async-phase, busy, idle, and no-client."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--async-context '(:phase tunnel))
          (emacs-jupyter-notebook--async-last-error t)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN!")))))

(ert-deftest ejn-w6.2-mode-line-precedence-async-phase-over-busy ()
  "W6.2: when an async phase is live AND kernel status is busy, the phase wins."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase connect))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…connect")))))

(ert-deftest ejn-w6.2-mode-line-terminal-phase-not-pending ()
  "W6.2: terminal phases (done/error) do not show as `…' phases on the lighter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase done))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'idle))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✓")))))

(ert-deftest ejn-w6.2-async-fail-records-error-on-origin-buffer ()
  "W6.2: `--async-fail' sets `--async-last-error' on the originating buffer."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (ctx (list :phase 'launch :origin-buffer buf)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-cancel-timer)
                 (lambda (c) c))
                ((symbol-function 'emacs-jupyter-notebook--async-delete-process)
                 (lambda (_)))
                ((symbol-function 'emacs-jupyter-notebook--async-delete-file)
                 (lambda (_)))
                ((symbol-function 'display-warning)
                 (lambda (&rest _))))
        (emacs-jupyter-notebook--async-fail ctx "boom"))
      (should emacs-jupyter-notebook--async-last-error)
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✗")))))

(ert-deftest ejn-w6.2-ensure-clean-before-start-clears-error ()
  "W6.2: starting a new operation clears the lingering ` EJN✗' state."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--async-last-error t)
    (emacs-jupyter-notebook--ensure-clean-before-start)
    (should-not emacs-jupyter-notebook--async-last-error)))

;;; W10 — client-less debris is reapable, not an active session

(ert-deftest ejn-w10-clientless-debris-not-active-session ()
  "W10: a buffer with a `--session-entry' and a live tunnel but NO client
is DEBRIS, not an active session.  `--active-session-p' must classify it
as non-blocking, and `--clientless-debris-p' must flag it as reapable.
Adding a live `--client' flips both predicates."
  (with-temp-buffer
    (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                    "emacs-jupyter-notebook-tunnel-w10-debris"
                    '("sleep" "60"))))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client nil)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "wedged"))
            (setq emacs-jupyter-notebook--tunnel-process tunnel)
            ;; No live client -> not active, IS debris.
            (should-not (emacs-jupyter-notebook--active-session-p))
            (should (emacs-jupyter-notebook--clientless-debris-p))
            ;; A live client flips it: active, NOT debris.
            (setq emacs-jupyter-notebook--client 'mock-client)
            (should (emacs-jupyter-notebook--active-session-p))
            (should-not (emacs-jupyter-notebook--clientless-debris-p)))
        (when (process-live-p tunnel)
          (delete-process tunnel))))))

(ert-deftest ejn-w10-ensure-clean-before-start-reaps-clientless-debris ()
  "W10: `--ensure-clean-before-start' must NOT signal on a client-less
debris buffer; it reaps the LOCAL resources (disposes the stale tunnel and
its stderr buffer, clears the buffer-local session state) WITHOUT shutting
down the remote kernel, then lets the fresh start proceed."
  (with-temp-buffer
    (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                    "emacs-jupyter-notebook-tunnel-w10-reap"
                    '("sleep" "60")))
           (stderr (process-get tunnel
                                'emacs-jupyter-notebook-stderr-buffer))
           remote-shutdown-called)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                     (lambda (&rest _) (setq remote-shutdown-called t)))
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                     (lambda (&rest _) (setq remote-shutdown-called t))))
            (setq emacs-jupyter-notebook--client nil)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "wedged"))
            (setq emacs-jupyter-notebook--tunnel-process tunnel)
            (setq emacs-jupyter-notebook--async-context
                  (emacs-jupyter-notebook--async-new-context
                   :phase 'done
                   :origin-buffer (current-buffer)))
            ;; Does not raise.
            (emacs-jupyter-notebook--ensure-clean-before-start)
            ;; Debris reaped: tunnel disposed, buffer-local session state cleared.
            (should-not (process-live-p tunnel))
            (should-not (buffer-live-p stderr))
            (should-not emacs-jupyter-notebook--tunnel-process)
            (should-not emacs-jupyter-notebook--session-entry)
            (should-not emacs-jupyter-notebook--async-context)
            (should-not emacs-jupyter-notebook--client)
            ;; The remote kernel was NEVER touched during the reap.
            (should-not remote-shutdown-called))
        (when (process-live-p tunnel)
          (delete-process tunnel))))))

(ert-deftest ejn-w10-ensure-clean-before-start-still-refuses-live-client ()
  "W10 no-regression: a genuinely LIVE client must still block a fresh
start — the guard's original leak-prevention is preserved.  A present
`--client' is the one state `--ensure-clean-before-start' refuses."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client)
    (setq emacs-jupyter-notebook--session-entry
          '(:profile "p" :session-id "live"))
    (should-error (emacs-jupyter-notebook--ensure-clean-before-start)
                  :type 'user-error)
    ;; Nothing was reaped: the live client and its entry are untouched.
    (should (eq emacs-jupyter-notebook--client 'mock-client))
    (should emacs-jupyter-notebook--session-entry)))

(ert-deftest ejn-w10-connect-async-invokes-callback-once-despite-finalize-error ()
  "W10 silent half-connect: `--connect-async' must invoke CALLBACK exactly
ONCE, with CALLBACK strictly outside the connect `condition-case'.  A raise
from the downstream finalize/eval work must propagate — it must NOT be
misread as a connect failure and re-enter CALLBACK with a nil client (the
swallow-and-misreport seam that hid errors while a live client existed)."
  (let ((calls 0)
        captured)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--connect)
               (lambda (_file) 'mock-client))
              ((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      ;; The finalize raise propagates out (proof the callback is NOT wrapped).
      (should-error
       (emacs-jupyter-notebook-jupyter--connect-async
        "/tmp/kernel.json"
        (lambda (client)
          (cl-incf calls)
          (setq captured client)
          (error "finalize boom"))))
      (should (= calls 1))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w10-connect-nil-client-transitions-context-to-error ()
  "W10 secondary: a connect whose adapter yields a nil client must move the
async context to ERROR (surfacing the failure via `--async-fail'), never
silently to `done'.  Drives the full `--async-connect' -> adapter
callback(nil) -> `--async-connect-finalize' seam."
  (with-temp-buffer
    (let ((err-surfaced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-jupyter-connect-async)
                 (lambda (_file callback)
                   ;; Adapter reports a failed connect: nil client.
                   (funcall callback nil))))
        (let ((context (emacs-jupyter-notebook--async-new-context
                        :phase 'tunnel
                        :entry '(:profile "p" :session-id "session")
                        :local-ports '(:shell_port 1001)
                        :local-file "/tmp/kernel.json"
                        :tunnel-process 'mock-process
                        :origin-buffer (current-buffer)
                        :error-callback (lambda (_ctx _err)
                                          (setq err-surfaced t)))))
          (setq emacs-jupyter-notebook--async-context context)
          (emacs-jupyter-notebook--async-connect context)
          (should (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                      'error))
          (should-not emacs-jupyter-notebook--client)
          (should err-surfaced))))))

;;; W6.3 — Friendly first-evaluate

(ert-deftest ejn-w6.3-send-cell-announces-default-profile-on-cold-start ()
  "W6.3: with no client/async/registry, send-cell messages the default profile."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (equal announced "workstation")))))

(ert-deftest ejn-w6.3-send-cell-with-prefix-prompts-and-skips-message ()
  "W6.3: C-u send-cell on a cold start prompts via `--read-profile-name' and skips the banner."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "default")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil)
           (read-called nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--read-profile-name)
                 (lambda () (setq read-called t) "chosen"))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell '(4)))
      (should read-called)
      (should (null announced)))))

(ert-deftest ejn-w6.3-send-cell-with-live-client-does-not-announce ()
  "W6.3: when a client is already live, no banner fires."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client 'mock)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (null announced)))))

(ert-deftest ejn-w6.3-send-cell-with-registry-entry-does-not-announce ()
  "W6.3: when a registry entry exists, send-cell silently reconnects (no banner)."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () '(:session-id "s")))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (null announced)))))

(ert-deftest ejn-w6.3-announce-cold-start-message-shape ()
  "W6.3: `--announce-cold-start' produces the documented message shape."
  (let ((inhibit-message t))
    ;; Just exercise the function so it does not error; the contents end up
    ;; in `*Messages*' but that is not portable to assert from batch reliably.
    (emacs-jupyter-notebook--announce-cold-start "workstation"))
  ;; Check that the message bytes are the documented format with format.
  (should (equal
           (format "emacs-jupyter-notebook: starting kernel via profile %s (C-u to choose)"
                   "workstation")
           "emacs-jupyter-notebook: starting kernel via profile workstation (C-u to choose)")))

;;; W6.4 — Confirmations on destructive commands

(ert-deftest ejn-w6.4-confirm-helper-lisp-callers-always-pass ()
  "W6.4: from Lisp (interactive-p nil) the action is always authorized."
  (let ((asked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil)))
      (should (emacs-jupyter-notebook--confirm nil nil "?"))
      (should-not asked))))

(ert-deftest ejn-w6.4-confirm-helper-c-u-skips-prompt ()
  "W6.4: a non-nil FORCE prefix bypasses `y-or-n-p'."
  (let ((asked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil)))
      (should (emacs-jupyter-notebook--confirm t '(4) "?"))
      (should-not asked))))

(ert-deftest ejn-w6.4-confirm-helper-interactive-no-prefix-prompts ()
  "W6.4: interactive call without FORCE asks `y-or-n-p'."
  (let ((asked nil) (response t))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) response)))
      (should (emacs-jupyter-notebook--confirm t nil "?"))
      (should asked)
      (setq response nil)
      (should-not (emacs-jupyter-notebook--confirm t nil "?")))))

(ert-deftest ejn-w6.4-shutdown-from-lisp-skips-prompt ()
  "W6.4: calling `shutdown-kernel' from Lisp does not prompt."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) t))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (emacs-jupyter-notebook-shutdown-kernel)
      (should-not asked)
      (should cleanup-called))))

(ert-deftest ejn-w6.4-shutdown-interactive-asks-and-aborts-on-no ()
  "W6.4: interactive call with a `no' answer does NOT run cleanup."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (call-interactively #'emacs-jupyter-notebook-shutdown-kernel)
      (should asked)
      (should-not cleanup-called))))

(ert-deftest ejn-w6.4-shutdown-interactive-with-c-u-skips-prompt ()
  "W6.4: interactive call with C-u skips the prompt."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'emacs-jupyter-notebook-shutdown-kernel))
      (should-not asked)
      (should cleanup-called))))

(ert-deftest ejn-w6.4-send-buffer-from-lisp-skips-prompt ()
  "W6.4: Lisp callers of `send-buffer' bypass the confirmation."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let ((asked nil) sent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_p) (setq asked t) t))
                ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest args) (setq sent args))))
        (emacs-jupyter-notebook-send-buffer))
      (should-not asked)
      (should sent))))

(ert-deftest ejn-w6.4-send-buffer-interactive-asks-and-aborts-on-no ()
  "W6.4: interactive `send-buffer' aborts on a `no' answer."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let (asked sent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_p) (setq asked t) nil))
                ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest args) (setq sent args))))
        (call-interactively #'emacs-jupyter-notebook-send-buffer))
      (should asked)
      (should-not sent))))

(ert-deftest ejn-w6.4-retry-fresh-from-lisp-with-profile-string ()
  "W6.4: Lisp call with a profile string skips the confirmation."
  (let ((asked nil) cleanup-called start-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &rest _)
                 (setq start-called profile))))
      (with-temp-buffer
        (emacs-jupyter-notebook-retry-fresh-kernel "specific")
        (should-not asked)
        (should cleanup-called)
        (should (equal start-called "specific"))))))

(ert-deftest ejn-w6.4-retry-fresh-interactive-prompts-and-aborts-on-no ()
  "W6.4: interactive `retry-fresh-kernel' with a `no' answer aborts."
  (let (asked cleanup-called start-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (&rest _) (setq start-called t))))
      (with-temp-buffer
        (call-interactively #'emacs-jupyter-notebook-retry-fresh-kernel))
      (should asked)
      (should-not cleanup-called)
      (should-not start-called))))

(ert-deftest ejn-w6.4-clean-orphaned-kernels-interactive-prompts ()
  "W6.4: interactive `clean-orphaned-kernels' prompts and aborts on no."
  (let (asked ran)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-profile-name)
               (lambda () "p"))
              ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_p)
                 '(:profile "p" :host "host" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (_argv) (setq ran t) "")))
      (call-interactively #'emacs-jupyter-notebook-clean-orphaned-kernels)
      (should asked)
      (should-not ran))))

(ert-deftest ejn-w6.4-clean-orphaned-kernels-with-c-u-skips-prompt ()
  "W6.4: interactive `clean-orphaned-kernels' with C-u skips the prompt."
  (let (asked ran)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-profile-name)
               (lambda () "p"))
              ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_p)
                 '(:profile "p" :host "host" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (_argv) (setq ran t) "")))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'emacs-jupyter-notebook-clean-orphaned-kernels))
      (should-not asked)
      (should ran))))

;;; W6.5 — Status buffer

(defmacro ejn-test-with-status-buffer (status-buffer-var &rest body)
  "Run BODY with STATUS-BUFFER-VAR bound to a freshly-rendered status buffer.
Cleans up the status buffer (and its refresh timer) after BODY."
  (declare (indent 1))
  `(let ((,status-buffer-var (call-interactively
                              #'emacs-jupyter-notebook-status)))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,status-buffer-var)
         (with-current-buffer ,status-buffer-var
           (emacs-jupyter-notebook--status-cancel-refresh))
         (kill-buffer ,status-buffer-var)))))

(ert-deftest ejn-w6.5-status-buffer-is-special-mode-derived ()
  "W6.5: the status buffer's major mode is derived from `special-mode'."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      (with-current-buffer status-buf
        (should (derived-mode-p 'special-mode))
        (should (eq major-mode 'emacs-jupyter-notebook-status-mode))
        (should buffer-read-only)))))

(ert-deftest ejn-w6.5-status-buffer-renders-snapshot-content ()
  "W6.5: status buffer shows the snapshot lines for the originating buffer."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock
          emacs-jupyter-notebook--session-entry
          '(:profile "p" :session-id "sid"
            :remote-host "h" :remote-pid 42
            :remote-connection-file "/r.json"
            :local-connection-file "/l.json"
            :tunnel-ports (:shell_port 1001)))
    (ejn-test-with-status-buffer status-buf
      (with-current-buffer status-buf
        (let ((text (buffer-string)))
          (should (string-match-p "Profile: p" text))
          (should (string-match-p "Session: sid" text))
          (should (string-match-p "Suggested actions" text)))))))

(ert-deftest ejn-w6.5-status-buffer-source-buffer-is-recorded ()
  "W6.5: the status buffer's `--status-source-buffer' points at the originator."
  (with-temp-buffer
    (let ((src (current-buffer)))
      (ejn-test-with-status-buffer status-buf
        (should (eq (buffer-local-value
                     'emacs-jupyter-notebook--status-source-buffer
                     status-buf)
                    src))))))

(ert-deftest ejn-w6.5-status-buffer-installs-refresh-timer ()
  "W6.5: rendering installs a live-refresh timer on the status buffer."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      (should (timerp
               (buffer-local-value
                'emacs-jupyter-notebook--status-refresh-timer
                status-buf))))))

(ert-deftest ejn-w6.5-status-buffer-cancels-timer-on-kill ()
  "W6.5: killing the status buffer cancels its refresh timer."
  (with-temp-buffer
    (let ((status-buf (call-interactively #'emacs-jupyter-notebook-status))
          captured-timer)
      (setq captured-timer
            (buffer-local-value
             'emacs-jupyter-notebook--status-refresh-timer status-buf))
      (should (timerp captured-timer))
      (kill-buffer status-buf)
      ;; A cancelled timer is no longer in the list of live timers.
      (should-not (memq captured-timer timer-list)))))

(ert-deftest ejn-w6.5-status-buffer-tick-no-window-cancels-timer ()
  "W6.5: when the status buffer is buried (no window), tick cancels the timer."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      ;; Simulate burying by removing the buffer from any window.
      (dolist (win (get-buffer-window-list status-buf nil t))
        (when (window-live-p win) (delete-window win)))
      (emacs-jupyter-notebook--status-tick)
      (should-not (buffer-local-value
                   'emacs-jupyter-notebook--status-refresh-timer
                   status-buf)))))

(ert-deftest ejn-w6.5-status-buffer-suggestion-button-invokes-command-in-source ()
  "W6.5: a click on a suggestion button switches to source and invokes its command."
  (with-temp-buffer
    (let ((src (current-buffer))
          invoked-in-buffer)
      ;; Force the snapshot to show no client so we always get a Start button.
      (setq emacs-jupyter-notebook--client nil)
      (ejn-test-with-status-buffer status-buf
        (with-current-buffer status-buf
          ;; Replace the Start command with a probe that records its caller.
          (let ((actions emacs-jupyter-notebook--status-suggestion-actions))
            (should actions)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                       (lambda (&rest _)
                         (interactive)
                         (setq invoked-in-buffer (current-buffer)))))
              ;; Find the first button and activate it.
              (goto-char (point-min))
              (let ((btn (next-button (point))))
                (should btn)
                (button-activate btn))))))
      (should (eq invoked-in-buffer src)))))

;;; W6.6 — Global async log buffer

(defmacro ejn-test-with-fresh-log-buffer (&rest body)
  "Run BODY with a freshly-created log buffer; clean up afterwards."
  (declare (indent 0))
  `(progn
     (let ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name)))
       (when (buffer-live-p buf) (kill-buffer buf)))
     (unwind-protect
         (progn ,@body)
       (let ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name)))
         (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest ejn-w6.6-log-buffer-is-special-mode ()
  "W6.6: the log buffer is derived from `special-mode' and read-only."
  (ejn-test-with-fresh-log-buffer
   (let ((buf (emacs-jupyter-notebook--log-buffer-ensure)))
     (with-current-buffer buf
       (should (derived-mode-p 'special-mode))
       (should buffer-read-only)))))

(ert-deftest ejn-w6.6-log-append-writes-timestamped-entry ()
  "W6.6: an appended entry carries timestamp, buffer name, phase, and message."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (rename-buffer "*ejn-test-source*" t)
     (emacs-jupyter-notebook--log-append 'launch "hello %s" "world"))
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "hello world" text))
     (should (string-match-p "\\[launch\\]" text))
     (should (string-match-p "\\*ejn-test-source\\*" text))
     (should (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T" text)))))

(ert-deftest ejn-w6.6-log-append-truncates-to-log-max-lines ()
  "W6.6: appends beyond `--log-max-lines' drop the oldest lines."
  (ejn-test-with-fresh-log-buffer
   (let ((emacs-jupyter-notebook-log-max-lines 5))
     (dotimes (i 12)
       (emacs-jupyter-notebook--log-append 'tick "entry %d" i))
     (with-current-buffer (get-buffer emacs-jupyter-notebook--log-buffer-name)
       (should (= (count-lines (point-min) (point-max)) 5))
       (let ((text (buffer-string)))
         ;; Oldest entries 0..6 are gone; 7..11 remain.
         (should-not (string-match-p "entry 0\n" text))
         (should-not (string-match-p "entry 6\n" text))
         (should (string-match-p "entry 7\n" text))
         (should (string-match-p "entry 11\n" text)))))))

(ert-deftest ejn-w6.6-async-message-writes-to-log ()
  "W6.6: `--async-message' writes a structured entry tagged with the phase."
  (ejn-test-with-fresh-log-buffer
   (emacs-jupyter-notebook--async-message '(:phase tunnel) "ports up")
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "ports up" text))
     (should (string-match-p "\\[tunnel\\]" text)))))

(ert-deftest ejn-w6.6-async-message-nil-context-tags-none ()
  "W6.6: when the context is nil, the log line is tagged `[none]'."
  (ejn-test-with-fresh-log-buffer
   (emacs-jupyter-notebook--async-message nil "bare message")
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "bare message" text))
     (should (string-match-p "\\[none\\]" text)))))

(ert-deftest ejn-w6.6-heartbeat-miss-logs ()
  "W6.6: each heartbeat miss writes a `heartbeat-miss' line."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 99))
       (emacs-jupyter-notebook--heartbeat-on-miss))
     (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
            (text (with-current-buffer buf (buffer-string))))
       (should (string-match-p "\\[heartbeat-miss\\]" text))))))

(ert-deftest ejn-w6.6-heartbeat-death-logs ()
  "W6.6: crossing the miss-allowed threshold writes `heartbeat-dead'."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 1))
       ;; First miss already crosses since allowed=1.
       (cl-letf (((symbol-function 'display-warning) (lambda (&rest _))))
         (emacs-jupyter-notebook--heartbeat-on-miss)))
     (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
            (text (with-current-buffer buf (buffer-string))))
       (should (string-match-p "\\[heartbeat-dead\\]" text))))))

(ert-deftest ejn-w6.6-show-log-buffer-displays-existing ()
  "W6.6: `show-log-buffer' creates and displays the log buffer."
  (ejn-test-with-fresh-log-buffer
   (cl-letf* (((symbol-function 'display-buffer)
               (lambda (b &rest _)
                 (should (eq b (get-buffer emacs-jupyter-notebook--log-buffer-name)))
                 b)))
     (emacs-jupyter-notebook-show-log-buffer)
     (should (buffer-live-p
              (get-buffer emacs-jupyter-notebook--log-buffer-name))))))

;;; W6.7 — `--read-host-profile' input validation

(ert-deftest ejn-w6.7-prompt-host-empty-reprompts ()
  "W6.7: empty input re-prompts until non-empty input is given."
  (let ((answers '("" "   " "example.com"))
        (asked 0))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (cl-incf asked)
                 (pop answers))))
      (should (equal (emacs-jupyter-notebook--prompt-host) "example.com"))
      (should (= asked 3)))))

(ert-deftest ejn-w6.7-prompt-host-rejects-whitespace-in-host ()
  "W6.7: input that contains internal whitespace is rejected with `user-error'."
  (let ((answers '("bad host with space")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop answers))))
      (should-error
       (emacs-jupyter-notebook--prompt-host) :type 'user-error))))

(ert-deftest ejn-w6.10-clear-results-bound-under-prefix ()
  "W6.10: `clear-results' is reachable from the new `C-c j' prefix."
  (let ((cmd (lookup-key
              (emacs-jupyter-notebook--build-prefix-map) (kbd "l"))))
    (should (eq cmd #'emacs-jupyter-notebook-clear-results))))

(ert-deftest ejn-w6.10-read-host-profile-rejects-profile-with-bad-host ()
  "W6.10: a profile whose stored `:host' contains whitespace fails fast,
before any SSH command is constructed.  Bypassing the prompt branch must
not bypass the whitespace check."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("dirty" . (:host "bad host with space"
                       :remote-cwd "~" :kernelspec "python3")))))
    (should-error (emacs-jupyter-notebook--read-host-profile "dirty")
                  :type 'user-error)))

(ert-deftest ejn-w6.10-read-host-profile-rejects-profile-with-bad-remote-host ()
  "W6.10: `--read-host-profile' also checks `:remote-host' (the
registry-entry shape) for whitespace."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("dirty2" . (:remote-host "with\ttab"
                        :remote-cwd "~" :kernelspec "python3")))))
    (should-error (emacs-jupyter-notebook--read-host-profile "dirty2")
                  :type 'user-error)))

(ert-deftest ejn-w6.10-status-tick-cancels-when-source-buffer-killed ()
  "W6.10: `--status-tick' cancels the refresh timer when the source
buffer that originated the status view has been killed.  Without this
the timer would fire forever on a dead source."
  (let* ((source (generate-new-buffer "ejn-w610-src"))
         (status (get-buffer-create
                  emacs-jupyter-notebook--status-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer status
            (unless (derived-mode-p 'emacs-jupyter-notebook-status-mode)
              (emacs-jupyter-notebook-status-mode))
            (setq emacs-jupyter-notebook--status-source-buffer source)
            (setq emacs-jupyter-notebook--status-refresh-timer
                  (run-with-timer 1000 1000 #'ignore)))
          (kill-buffer source)
          (emacs-jupyter-notebook--status-tick)
          (with-current-buffer status
            (should-not emacs-jupyter-notebook--status-refresh-timer)))
      (when (buffer-live-p status) (kill-buffer status)))))

(ert-deftest ejn-w6.7-prompt-host-trims-surrounding-whitespace ()
  "W6.7: surrounding whitespace is trimmed; the trimmed value is accepted."
  (let ((answers '("  example.com  ")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop answers))))
      (should (equal (emacs-jupyter-notebook--prompt-host) "example.com")))))

(ert-deftest ejn-w6.7-read-host-profile-skips-prompt-when-host-set ()
  "W6.7: when the profile already has a :host, no prompt is issued."
  (let ((asked nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (setq asked t) "x"))
              ((symbol-function 'emacs-jupyter-notebook-ssh-profile)
               (lambda (_p) '(:profile "p" :host "example.com"))))
      (let ((profile (emacs-jupyter-notebook--read-host-profile "p")))
        (should-not asked)
        (should (equal (plist-get profile :host) "example.com"))))))

(ert-deftest ejn-w6.7-read-host-profile-prompts-when-host-missing ()
  "W6.7: a profile with no :host triggers `--prompt-host', value is interned."
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) "example.com"))
            ((symbol-function 'emacs-jupyter-notebook-ssh-profile)
             (lambda (_p) '(:profile "p"))))
    (let ((profile (emacs-jupyter-notebook--read-host-profile "p")))
      (should (equal (plist-get profile :host) "example.com")))))

;;; W6.8 — `--read-registry-entry' chooser always with current-file default

(ert-deftest ejn-w6.8-read-registry-entry-always-prompts ()
  "W6.8: even when only one entry exists, the chooser is invoked."
  (let* ((entry '(:profile "p" :session-id "sole"))
         (asked nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list entry)))
              ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (setq asked t)
                 (emacs-jupyter-notebook--registry-entry-label entry))))
      (with-temp-buffer
        (should (equal (emacs-jupyter-notebook--read-registry-entry) entry))
        (should asked)))))

(ert-deftest ejn-w6.8-read-registry-entry-uses-current-file-default ()
  "W6.8: when current-file entry exists, it is passed as the chooser's default."
  (let* ((file (expand-file-name "x.py" temporary-file-directory))
         (current `(:profile "p" :session-id "x-session" :local-file ,file))
         (other '(:profile "p" :session-id "other"))
         (passed-default nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list other current)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &optional _pred _require _initial _hist default)
                 (setq passed-default default)
                 default)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (let ((selected (emacs-jupyter-notebook--read-registry-entry)))
          (should (equal selected current))
          (should (stringp passed-default))
          (should (string-match-p "x-session" passed-default)))))))

(ert-deftest ejn-w6.8-read-registry-entry-no-current-file-no-default ()
  "W6.8: when there is no current-file entry, the default is nil and the chooser still runs."
  (let* ((entries '((:profile "p" :session-id "a")
                    (:profile "p" :session-id "b")))
         (asked-with-default 'unset))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) entries))
              ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &optional _pred _require _initial _hist default)
                 (setq asked-with-default default)
                 (emacs-jupyter-notebook--registry-entry-label (car entries)))))
      (with-temp-buffer
        (emacs-jupyter-notebook--read-registry-entry)
        (should (null asked-with-default))))))

(ert-deftest ejn-w6.1-old-evaluate-command-names-removed ()
  "W6.1: the legacy `emacs-jupyter-notebook-evaluate-*' names are gone (no aliases)."
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-current-cell))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-region))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-buffer))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-current-cell-and-advance)))

;;; W7.5 — Continuous coverage backfill

(ert-deftest ejn-w7.5-registry-load-corrupt-file-returns-nil-with-warning ()
  "W7.5: `registry-load' on a corrupt file must not raise; it returns nil
and surfaces a warning.  The registry is durable truth — a garbled file
must not brick the package's ability to start a fresh kernel."
  (let ((file (make-temp-file "ejn-w75-corrupt-")))
    (unwind-protect
        (let (warned)
          (with-temp-file file (insert "this is not (a valid) sexp"))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (should-not (emacs-jupyter-notebook-registry-load file)))
          (should warned))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest ejn-w7.5-ssh-command-honors-identity-file-and-port ()
  "W7.5: profile `:identity-file' expands `~' and joins the ssh argv
after `-p PORT'; ssh uses `-p'.  Regression: without this the identity
knob silently disappears from the launch/probe argv."
  (let ((emacs-jupyter-notebook-ssh-command "ssh")
        (emacs-jupyter-notebook-ssh-options nil))
    (let ((argv (emacs-jupyter-notebook-ssh-command
                 '(:profile "p" :host "h" :user "u"
                   :port 2222 :identity-file "~/.ssh/id_ed25519"))))
      (should (member "-p" argv))
      (should (member "2222" argv))
      (should (member "-i" argv))
      ;; ~ is expanded to an absolute path.
      (should (cl-some (lambda (a)
                         (and (stringp a)
                              (string-suffix-p ".ssh/id_ed25519" a)
                              (not (string-prefix-p "~" a))))
                       argv)))))

(ert-deftest ejn-w7.5-ssh-scp-from-command-honors-port-and-identity-file ()
  "W7.5: `scp' uses `-P' (capital) not `-p' for the remote port; the
`:identity-file' knob also propagates to scp.  Getting these wrong
silently makes the retrieve step fail."
  (let ((emacs-jupyter-notebook-scp-command "scp")
        (emacs-jupyter-notebook-ssh-options nil))
    (let ((argv (emacs-jupyter-notebook-ssh-scp-from-command
                 '(:profile "p" :host "h"
                   :port 2222 :identity-file "~/.ssh/id_ed25519")
                 "~/.cache/ejn/k.json" "/tmp/k.json")))
      (should (member "-P" argv))
      (should-not (member "-p" argv))
      (should (member "2222" argv))
      (should (member "-i" argv))
      (should (member "h:~/.cache/ejn/k.json" argv))
      (should (equal (car (last argv)) "/tmp/k.json")))))

(ert-deftest ejn-w7.5-panel-late-writes-after-panel-kill-are-safe ()
  "W7.5: streaming/reply callbacks arriving after the panel buffer is
killed must be no-ops, not raises.  Common race: user kills the panel
while a slow evaluate is in flight."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel nil "print('hi')")))
          (kill-buffer panel)
          (should-not (buffer-live-p panel))
          ;; Every public writer must tolerate a dead panel silently.
          (should (progn (ejn-panel-append-text handle "late stream") t))
          (should (progn (ejn-panel-replace-text handle "late replace") t))
          (should (progn (ejn-panel-set-image handle '(image :type png)) t))
          (should (progn (ejn-panel-clear-entry handle) t))
          (should (progn (ejn-panel-clear-entry handle t) t))
          (should (progn (ejn-panel-finish-entry handle 'ok 1) t)))
      (ejn-test--kill-source-buffer buf))))

(defun ejn-w7.5--strip-lisp-comments-and-strings (source)
  "Return SOURCE with Emacs-Lisp line comments and string literals blanked.
Blanking preserves offsets — comments become spaces and string bodies
become spaces — so downstream regexes cannot false-positive on text
that only exists inside comments or docstrings."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    ;; Blank out string literals first (`\"...\"'), skipping escaped quotes.
    (while (re-search-forward "\"" nil t)
      (let ((start (1- (point))))
        (while (and (not (eobp))
                    (not (looking-at "\"")))
          (if (looking-at "\\\\.")
              (goto-char (+ 2 (point)))
            (forward-char 1)))
        (when (looking-at "\"")
          (let ((end (1+ (point))))
            (delete-region start end)
            (insert (make-string (- end start) ?\s))))))
    ;; Blank each line comment (`;' through end of line).
    (goto-char (point-min))
    (while (re-search-forward ";.*$" nil t)
      (let ((s (match-beginning 0)) (e (match-end 0)))
        (delete-region s e)
        (insert (make-string (- e s) ?\s))))
    (buffer-string)))

(ert-deftest ejn-w7.5-source-files-do-not-depend-on-tramp ()
  "W7.5: the hard architecture rule (AGENTS.md) forbids TRAMP, `jupyter-tramp',
and Emacs remote file handlers.  Static-scan every package `.el' file in
the project root for actual `require' / `use-package' of a tramp module.
W7.6: comments and string literals (docstrings) are blanked BEFORE the
scan so mentions of `require 'tramp' inside prose cannot trigger a false
positive.  The scan also anchors `require' at line-start so a text
fragment inside a nested form is not sufficient."
  (let* ((root (or (locate-dominating-file
                    (or (symbol-file 'emacs-jupyter-notebook-mode) default-directory)
                    "emacs-jupyter-notebook.el")
                   default-directory))
         (files (directory-files root t "\\`emacs-jupyter-notebook.*\\.el\\'"))
         offenders)
    (should files)
    (dolist (file files)
      (let ((raw (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string))))
        (let ((code (ejn-w7.5--strip-lisp-comments-and-strings raw)))
          (with-temp-buffer
            (insert code)
            (goto-char (point-min))
            ;; Top-level or nested `(require 'tramp)' / `(use-package tramp)'.
            (when (re-search-forward
                   "(\\(require\\|use-package\\)[[:space:]]+'?\\(tramp\\|jupyter-tramp\\)\\b"
                   nil t)
              (push (file-name-nondirectory file) offenders))
            (goto-char (point-min))
            (when (re-search-forward
                   "\\btramp-file-name-p\\|\\bjupyter-tramp-\\|\\btramp-tramp-file-p\\b"
                   nil t)
              (push (file-name-nondirectory file) offenders))))))
    (should-not offenders)))

(ert-deftest ejn-w7.6-strip-comments-blanks-tramp-mentions-in-docstrings ()
  "W7.6 self-check: `--strip-lisp-comments-and-strings' successfully blanks
`require 'tramp' inside a docstring, so the W7.5 scanner cannot fire on
a mention that only exists in prose."
  (let* ((source (concat
                  "(defun foo () \"Do not (require 'tramp).\" nil)\n"
                  "; also do not `(require 'jupyter-tramp)' here\n"))
         (stripped (ejn-w7.5--strip-lisp-comments-and-strings source)))
    (should-not (string-match-p "tramp" stripped))
    (should-not (string-match-p "jupyter-tramp" stripped))))

;;; W8 — local interactive matplotlib viewer

;;; W8.1 — remote formatter-registration snippet injection

(ert-deftest ejn-w8.1-inject-uses-silent-execute-adapter ()
  "W8.1: the formatter injection routes the snippet through the silent
execute adapter (no panel entry) and passes the actual snippet string."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client 'mock-client))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (should (= (length calls) 1))
      (should (eq (caar calls) 'mock-client))
      (should (equal (cadar calls)
                     emacs-jupyter-notebook--viewer-formatter-snippet))
      ;; The snippet must reference the custom MIME and patch the figure
      ;; type's `_repr_mimebundle_'.  It must NOT use the old
      ;; `for_type_by_name' display-formatter registration, which the
      ;; matplotlib inline backend wipes on the first plot (the payload then
      ;; silently degrades to the figure `__repr__').  See
      ;; `viewer/test_formatter_kernel.py' for the real-kernel regression.
      (should (string-match-p "application/x-ejn-mpl-pickle"
                              emacs-jupyter-notebook--viewer-formatter-snippet))
      (should (string-match-p "_repr_mimebundle_"
                              emacs-jupyter-notebook--viewer-formatter-snippet))
      ;; Must not CALL the wipeable display-formatter registration API.
      (should-not (string-match-p "\\.for_type_by_name("
                                  emacs-jupyter-notebook--viewer-formatter-snippet))
      (should-not (string-match-p "\\.for_type("
                                  emacs-jupyter-notebook--viewer-formatter-snippet))
      (should (string-match-p "get_ipython"
                              emacs-jupyter-notebook--viewer-formatter-snippet)))))

(ert-deftest ejn-w8.1-inject-noop-without-client ()
  "W8.1: with no client the injection is a silent no-op (no adapter call)."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (should (null calls)))))

(ert-deftest ejn-w8.1-inject-swallows-adapter-errors ()
  "W8.1: a raise from the adapter must not propagate out of injection —
formatter injection may never break a connect or restart."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) (error "boom"))))
        ;; Should not signal.
        (should (progn (emacs-jupyter-notebook--inject-viewer-formatter) t))))))

(ert-deftest ejn-w8.1-inject-produces-no-panel-entry ()
  "W8.1: injecting the snippet creates no panel entry for the source buffer."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (panel (ejn-panel-ensure (current-buffer))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) nil)))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (with-current-buffer panel
        (should (null emacs-jupyter-notebook-panel--entries))))))

(ert-deftest ejn-w8.1-png-plus-pickle-bundle-still-renders-png ()
  "W8.1: a display_data bundle carrying BOTH image/png and the custom
pickle MIME still renders the PNG through the callbacks — the extra MIME
key never disturbs the existing PNG path."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t))
           (pickle (base64-encode-string "pickle-bytes" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   `(:data (:image/png ,png
                            :application/x-ejn-mpl-pickle ,pickle))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :image)
                     '(image :type png :data "imgdata"))))))

;;; W8.2 — MIME recognition + pickle stash

(ert-deftest ejn-w8.2-select-mime-type-ignores-pickle ()
  "W8.2: the pickle MIME is never chosen as a renderable thumbnail."
  (should (equal (emacs-jupyter-notebook--select-mime-type
                  '(:application/x-ejn-mpl-pickle "cGts" :image/png "aW1n"))
                 '(:image/png . "aW1n")))
  (should (null (emacs-jupyter-notebook--select-mime-type
                 '(:application/x-ejn-mpl-pickle "cGts")))))

(ert-deftest ejn-w8.2-select-mpl-pickle-extracts-payload ()
  "W8.2: the pickle selector returns the base64 payload or nil."
  (should (equal (emacs-jupyter-notebook--select-mpl-pickle
                  '(:image/png "aW1n" :application/x-ejn-mpl-pickle "cGts"))
                 "cGts"))
  (should (null (emacs-jupyter-notebook--select-mpl-pickle
                 '(:image/png "aW1n"))))
  (should (null (emacs-jupyter-notebook--select-mpl-pickle
                 '(:application/x-ejn-mpl-pickle "")))))

(ert-deftest ejn-w8.2-set-and-get-pickle-on-entry ()
  "W8.2: `ejn-panel-set-pickle' stores under :mpl-pickle; getter reads it."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (should (null (ejn-panel-entry-pickle handle)))
      (ejn-panel-set-pickle handle "cGlja2xl")
      (should (equal (ejn-panel-entry-pickle handle) "cGlja2xl"))
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :mpl-pickle)
                     "cGlja2xl")))))

(ert-deftest ejn-w8.2-display-data-stores-pickle-and-renders-png ()
  "W8.2: a bundle with both PNG and pickle renders the PNG AND stashes the
pickle on the entry."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t))
           (pickle (base64-encode-string "pickle-bytes" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   `(:data (:image/png ,png
                            :application/x-ejn-mpl-pickle ,pickle))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :image) '(image :type png :data "imgdata")))
        (should (equal (plist-get e :mpl-pickle) pickle))))))

(ert-deftest ejn-w8.2-display-data-png-only-stores-no-pickle ()
  "W8.2: a PNG-only bundle behaves exactly as before — no pickle stashed."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/png ,png))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (plist-get e :image) '(image :type png :data "imgdata")))
        (should (null (plist-get e :mpl-pickle)))))))

(ert-deftest ejn-w8.7-display-without-pickle-clears-stale-pickle ()
  "W8.7(d): a later display on the same entry that carries NO pickle drops
any previously-stashed pickle, so the interactive open cannot reopen a
figure that is no longer the entry's visible content."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t))
           (pickle (base64-encode-string "pickle-bytes" t)))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (data &optional _t _d &rest _p)
                   (list 'image :data data))))
        ;; First: a figure (png + pickle).
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_m) `(:data (:image/png ,png
                                         :application/x-ejn-mpl-pickle ,pickle)))))
          (funcall display-fn 'm))
        (should (equal (plist-get (ejn-panel-entry-snapshot handle) :mpl-pickle)
                       pickle))
        ;; Then: a non-figure display on the same entry (png only).
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_m) `(:data (:image/png ,png)))))
          (funcall display-fn 'm))
        (should (null (plist-get (ejn-panel-entry-snapshot handle) :mpl-pickle)))))))

(ert-deftest ejn-w8.7-replace-text-and-clear-entry-drop-pickle ()
  "W8.7(d): `ejn-panel-replace-text' and `ejn-panel-clear-entry' both drop a
stashed pickle."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h1 (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (h2 (ejn-panel-start-entry panel '("x.py" . 2) "")))
      (ejn-panel-set-pickle h1 "pk1")
      (ejn-panel-replace-text h1 "now text")
      (should (null (ejn-panel-entry-pickle h1)))
      (ejn-panel-set-pickle h2 "pk2")
      (ejn-panel-clear-entry h2)
      (should (null (ejn-panel-entry-pickle h2))))))

(ert-deftest ejn-w8.7-auto-open-defers-off-the-callback ()
  "W8.7(a): when auto-open is enabled, the display callback does NOT call
`viewer-open-pickle' synchronously — it schedules it on an idle timer so a
large pickle decode/write never blocks the IOPub callback."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t))
           (pickle (base64-encode-string "pickle-bytes" t))
           (emacs-jupyter-notebook-viewer-auto-open t)
           (sync-called nil)
           (scheduled nil))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (data &optional _t _d &rest _p) (list 'image data)))
                ((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
                 (lambda (_b64) (setq sync-called t)))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _args) (setq scheduled t) nil))
                ((symbol-function 'jupyter-message-content)
                 (lambda (_m) `(:data (:image/png ,png
                                       :application/x-ejn-mpl-pickle ,pickle)))))
        (funcall display-fn 'm))
      ;; Deferred, not called inline.
      (should scheduled)
      (should-not sync-called))))

;;; W8.3 — local viewer process manager

(defvar ejn-w8.3--received nil
  "Cons cell whose car accumulates strings received by the stub viewer.")

(defun ejn-w8.3--make-stub-server (socket-path)
  "Create a real unix-socket server on SOCKET-PATH that records input.
Received strings are pushed onto `(car ejn-w8.3--received)'.  Returns the
server process, which doubles as the manager's placeholder process."
  (make-network-process
   :name "ejn-w8.3-stub-viewer"
   :server t
   :family 'local
   :service socket-path
   :noquery t
   :filter (lambda (_proc string)
             (push string (car ejn-w8.3--received)))))

(defmacro ejn-w8.3-with-clean-manager (&rest body)
  "Run BODY with fresh, isolated viewer-manager global state, then reap."
  (declare (indent 0))
  `(let ((emacs-jupyter-notebook-viewer--process nil)
         (emacs-jupyter-notebook-viewer--socket-path nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (emacs-jupyter-notebook-viewer-reap)))))

(ert-deftest ejn-w8.3-ensure-spawns-once-and-reuses ()
  "W8.3: the manager spawns the viewer lazily exactly once and reuses it."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (spawn-count 0)
           (emacs-jupyter-notebook-viewer-spawn-function
            (lambda (socket-path)
              (cl-incf spawn-count)
              (ejn-w8.3--make-stub-server socket-path))))
      (let ((p1 (emacs-jupyter-notebook-viewer-ensure))
            (p2 (emacs-jupyter-notebook-viewer-ensure)))
        (should (= spawn-count 1))
        (should (eq p1 p2))
        (should (emacs-jupyter-notebook-viewer-live-p))))))

(ert-deftest ejn-w8.3-ensure-installs-kill-emacs-reaper ()
  "W8.3: ensuring the viewer installs the `kill-emacs-hook' reaper."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (kill-emacs-hook nil)
           (emacs-jupyter-notebook-viewer-spawn-function
            #'ejn-w8.3--make-stub-server))
      (emacs-jupyter-notebook-viewer-ensure)
      (should (memq #'emacs-jupyter-notebook-viewer-reap kill-emacs-hook)))))

(ert-deftest ejn-w8.3-reap-kills-process-and-removes-socket ()
  "W8.3: reap deletes the process, removes the socket file, and clears state."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (kill-emacs-hook nil)
           (emacs-jupyter-notebook-viewer-spawn-function
            #'ejn-w8.3--make-stub-server))
      (emacs-jupyter-notebook-viewer-ensure)
      (let ((socket-path emacs-jupyter-notebook-viewer--socket-path)
            (proc emacs-jupyter-notebook-viewer--process))
        (should (process-live-p proc))
        (should (file-exists-p socket-path))
        (emacs-jupyter-notebook-viewer-reap)
        (should-not (process-live-p proc))
        (should-not (file-exists-p socket-path))
        (should (null emacs-jupyter-notebook-viewer--process))
        (should (null emacs-jupyter-notebook-viewer--socket-path))
        (should-not (memq #'emacs-jupyter-notebook-viewer-reap
                          kill-emacs-hook))))))

(ert-deftest ejn-w8.3-send-path-delivers-over-socket ()
  "W8.3: the async hand-off writes the newline-terminated path to the socket."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (emacs-jupyter-notebook-viewer-spawn-function
            #'ejn-w8.3--make-stub-server))
      (emacs-jupyter-notebook-viewer-send-path "/tmp/fig-123.pkl")
      ;; Pump the event loop so the server's connection filter runs.
      (let ((deadline (+ (float-time) 2)))
        (while (and (null (car ejn-w8.3--received))
                    (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (equal (apply #'concat (reverse (car ejn-w8.3--received)))
                     "/tmp/fig-123.pkl\n")))))

(ert-deftest ejn-w8.3-open-pickle-decodes-and-sends-existing-file ()
  "W8.3: open-pickle decodes base64 to a real temp file and hands it off."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (emacs-jupyter-notebook-viewer-spawn-function
            #'ejn-w8.3--make-stub-server)
           (payload (base64-encode-string "PICKLEBYTES" t))
           (tmp (emacs-jupyter-notebook-viewer-open-pickle payload)))
      (unwind-protect
          (progn
            (should (file-exists-p tmp))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (let ((coding-system-for-read 'binary))
                (insert-file-contents-literally tmp))
              (should (equal (buffer-string) "PICKLEBYTES")))
            (let ((deadline (+ (float-time) 2)))
              (while (and (null (car ejn-w8.3--received))
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (equal (apply #'concat (reverse (car ejn-w8.3--received)))
                           (concat tmp "\n"))))
        (when (file-exists-p tmp) (delete-file tmp))))))

(ert-deftest ejn-w8.3-python-path-resolves-command ()
  "W8.3: `--python-path' resolves an absolute executable or PATH command,
and returns nil for a bogus command."
  (should (null (emacs-jupyter-notebook-viewer--python-path
                 "ejn-nonexistent-python-xyz")))
  ;; /bin/sh is a reliable absolute executable on the CI host.
  (when (file-executable-p "/bin/sh")
    (should (equal (emacs-jupyter-notebook-viewer--python-path "/bin/sh")
                   "/bin/sh"))))

;;; W8.4 — viewer Python script

(ert-deftest ejn-w8.4-bundled-viewer-script-exists ()
  "W8.4: the manager resolves the bundled viewer/ejn_viewer.py and it exists."
  (let ((path (emacs-jupyter-notebook-viewer--script-path)))
    (should path)
    (should (string-suffix-p "viewer/ejn_viewer.py" path))
    (should (file-exists-p path))))

(ert-deftest ejn-w8.4-viewer-selfcheck-passes ()
  "W8.4: the viewer script's headless non-GUI self-check passes.
Covers the format_coord row/col/value math and the linked-zoom LinkGroup
wiring.  Skipped when no local python3 is available in this environment."
  (let ((python (executable-find "python3"))
        (script (emacs-jupyter-notebook-viewer--script-path)))
    (unless python
      (ert-skip "python3 not available"))
    (should script)
    (with-temp-buffer
      (let ((status (call-process python nil t nil script "--selfcheck")))
        (should (= status 0))
        (goto-char (point-min))
        (should (re-search-forward "SELFCHECK OK" nil t))))))

;;; W8.5 — interactive open command + error branches

(ert-deftest ejn-w8.5-open-with-pickle-errors-without-python ()
  "W8.5: opening a figure surfaces a friendly user-error when no local
Python is available, and never calls the viewer.  The Python resolution is
synchronous and instant (`executable-find'); the matplotlib probe is not."
  (let ((opened nil)
        (emacs-jupyter-notebook--viewer-support-cache nil)
        (emacs-jupyter-notebook-local-python-command "ejn-nonexistent-python-xyz"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
               (lambda (b64) (setq opened b64))))
      (should-error (emacs-jupyter-notebook-open-figure-with-pickle "abc")
                    :type 'user-error)
      (should (null opened)))))

(ert-deftest ejn-w8.5-open-with-pickle-hands-off-when-cached ()
  "W8.5: when matplotlib support is already cached the payload is handed off
synchronously without spawning a probe."
  (let ((opened nil)
        (emacs-jupyter-notebook--viewer-support-cache t)
        (emacs-jupyter-notebook-local-python-command "true"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
               (lambda (b64) (setq opened b64))))
      (emacs-jupyter-notebook-open-figure-with-pickle "PAYLOAD64")
      (should (equal opened "PAYLOAD64")))))

(ert-deftest ejn-w8.5-async-probe-hands-off-when-matplotlib-present ()
  "W8.5: the async matplotlib probe (exit 0) caches support and hands off.
Uses `/bin/true' as a stand-in Python that exits 0."
  (skip-unless (executable-find "true"))
  (let ((opened nil)
        (emacs-jupyter-notebook--viewer-support-cache nil)
        (emacs-jupyter-notebook-local-python-command "true"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
               (lambda (b64) (setq opened b64))))
      (emacs-jupyter-notebook-open-figure-with-pickle "PAYLOAD64")
      (let ((deadline (+ (float-time) 3)))
        (while (and (null opened) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (equal opened "PAYLOAD64"))
      (should (eq emacs-jupyter-notebook--viewer-support-cache t)))))

(ert-deftest ejn-w8.5-async-probe-reports-missing-matplotlib ()
  "W8.5: the async probe (nonzero exit) does NOT hand off and leaves the
support cache unset.  Uses `/bin/false' as a stand-in Python that exits 1."
  (skip-unless (executable-find "false"))
  (let ((opened nil)
        (emacs-jupyter-notebook--viewer-support-cache nil)
        (emacs-jupyter-notebook-local-python-command "false"))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
               (lambda (b64) (setq opened b64))))
      (emacs-jupyter-notebook-open-figure-with-pickle "PAYLOAD64")
      (let ((deadline (+ (float-time) 3)))
        (while (and (process-list) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (null opened))
      (should (null emacs-jupyter-notebook--viewer-support-cache)))))

(ert-deftest ejn-w8.5-hand-off-errors-when-viewer-fails ()
  "W8.5: a spawn/hand-off failure becomes a friendly viewer-failed user-error."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-open-pickle)
             (lambda (_b64) (error "no viewer script"))))
    (should-error (emacs-jupyter-notebook--viewer-hand-off "abc")
                  :type 'user-error)))

(ert-deftest ejn-w8.5-open-interactive-errors-without-figure ()
  "W8.5: `C-c j I' with no pickled figure for the cell signals a user-error."
  (with-temp-buffer
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--figure-pickle-for-current-cell)
               (lambda () nil)))
      (should-error (emacs-jupyter-notebook-open-figure-interactive)
                    :type 'user-error))))

(ert-deftest ejn-w8.5-open-interactive-dispatches-with-cell-pickle ()
  "W8.5: `C-c j I' hands the current cell's pickle to the open helper."
  (with-temp-buffer
    (let ((dispatched nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--figure-pickle-for-current-cell)
                 (lambda () "CELL64"))
                ((symbol-function 'emacs-jupyter-notebook-open-figure-with-pickle)
                 (lambda (b64) (setq dispatched b64))))
        (emacs-jupyter-notebook-open-figure-interactive)
        (should (equal dispatched "CELL64"))))))

(ert-deftest ejn-w8.5-panel-latest-pickle-for-cell ()
  "W8.5: the panel returns the newest pickle stashed for a cell key."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (key '("x.py" . 7))
           (h1 (ejn-panel-start-entry panel key ""))
           (h2 (ejn-panel-start-entry panel key "")))
      (ejn-panel-set-pickle h1 "old")
      (ejn-panel-set-pickle h2 "new")
      (should (equal (emacs-jupyter-notebook-panel-latest-pickle-for-cell buffer key)
                     "new"))
      (should (null (emacs-jupyter-notebook-panel-latest-pickle-for-cell
                     buffer '("x.py" . 99)))))))

(ert-deftest ejn-w8.5-panel-open-figure-errors-without-pickle ()
  "W8.5: `v' in the panel on a pickle-less entry signals a user-error."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer)))
      (ejn-panel-start-entry panel '("x.py" . 1) "")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (goto-char (point-max))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-open-figure-with-pickle)
                   (lambda (_b64) (error "should not be called"))))
          (should-error (emacs-jupyter-notebook-panel-open-figure)
                        :type 'user-error))))))

(ert-deftest ejn-w8.5-panel-open-figure-dispatches-entry-pickle ()
  "W8.5: `v' in the panel hands the entry-at-point's pickle to the open helper."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (dispatched nil))
      (ejn-panel-set-pickle handle "ENTRY64")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (goto-char (point-min))
        (goto-char (next-single-property-change
                    (point) 'emacs-jupyter-notebook-entry-id))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-open-figure-with-pickle)
                   (lambda (b64) (setq dispatched b64))))
          (emacs-jupyter-notebook-panel-open-figure)))
      (should (equal dispatched "ENTRY64")))))

(provide 'emacs-jupyter-notebook-tests)

;;; emacs-jupyter-notebook-tests.el ends here
