;;; emacs-jupyter-notebook-remote-tests.el --- Optional remote smoke tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; These tests require an explicitly configured remote host.  They do not
;; run as part of normal unit tests.  The emacs-jupyter integration smoke
;; test skips unless emacs-jupyter is on `load-path'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook)

(declare-function jupyter-eval "jupyter-client" (code &optional mime))
(defvar jupyter-current-client)
(defvar jupyter-default-timeout)

(defun ejn-remote-tests--host ()
  "Return the configured remote test host, or nil."
  (getenv "EJN_REMOTE_TEST_HOST"))

(defun ejn-remote-tests--profile ()
  "Return the remote smoke-test profile plist."
  (list :profile "remote-smoke"
        :host (or (ejn-remote-tests--host)
                  (ert-skip "Set EJN_REMOTE_TEST_HOST to run remote smoke tests"))
         :remote-cwd (or (getenv "EJN_REMOTE_TEST_CWD") "~")
         :remote-cache-dir (or (getenv "EJN_REMOTE_TEST_CACHE")
                               "~/.cache/emacs-jupyter-notebook-smoke")
         :kernelspec (or (getenv "EJN_REMOTE_TEST_KERNELSPEC") "python3")
         :jupyter-command (or (getenv "EJN_REMOTE_TEST_JUPYTER_COMMAND")
                              emacs-jupyter-notebook-jupyter-command)))

(defun ejn-remote-tests--session-id ()
  "Return a unique session id for a remote smoke test."
  (format "ert-%s-%s" (emacs-pid) (format-time-string "%Y%m%d%H%M%S")))

(defun ejn-remote-tests--wait-for-local-port (port timeout)
  "Return non-nil when PORT accepts a local TCP connection within TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        connected)
    (while (and (not connected) (< (float-time) deadline))
      (condition-case nil
          (let ((proc (open-network-stream
                       (format "ejn-remote-port-%s" port) nil "127.0.0.1" port)))
            (setq connected t)
            (delete-process proc))
        (error (sleep-for 0.1))))
    connected))

(defun ejn-remote-tests--wait-for-phase (buffer phase timeout)
  "Wait until BUFFER's async context reaches PHASE within TIMEOUT seconds."
  (let ((deadline (+ (float-time) timeout))
        current error)
    (while (and (< (float-time) deadline)
                (not (memq current (list phase 'error))))
      (accept-process-output nil 0.1)
      (with-current-buffer buffer
        (setq current (plist-get emacs-jupyter-notebook--async-context :phase))
        (setq error (plist-get emacs-jupyter-notebook--async-context :error))))
    (when (eq current 'error)
      (ert-fail (format "Async operation failed: %s" error)))
    (eq current phase)))

(defun ejn-remote-tests--wait-for-result-text (buffer text timeout)
  "Return non-nil when BUFFER's output panel has an entry containing TEXT.
W2+: results live in the side-panel buffer's entries, not in source-buffer
overlays."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (let ((panel (emacs-jupyter-notebook-panel-buffer buffer)))
        (when (buffer-live-p panel)
          (with-current-buffer panel
            (setq found
                  (cl-some
                   (lambda (entry)
                     (let ((content (plist-get (cdr entry) :content)))
                       (and content
                            (string-match-p (regexp-quote text) content))))
                   emacs-jupyter-notebook-panel--entries))))))
    found))

(ert-deftest ejn-remote-start-retrieve-and-tunnel-smoke ()
  "Start a remote kernel, retrieve its connection file, and open tunnels."
  :tags '(:remote)
  (let* ((profile (ejn-remote-tests--profile))
         (session-id (ejn-remote-tests--session-id))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (remote-file (plist-get launch :connection-file))
         (remote-log (plist-get launch :log-file))
         (local-copy (make-temp-file "ejn-remote-connection-" nil ".json"))
         pid tunnel connection local-ports remote-ports)
    (unwind-protect
        (progn
          (setq pid (emacs-jupyter-notebook--parse-pid
                     (emacs-jupyter-notebook-ssh-run-command
                      (plist-get launch :argv))))
          (should (integerp pid))
          ;; W4.7 removed the sync `--retrieve-connection-file'; retrieve
          ;; inline via scp + read, polling until the kernel has written it.
          (let ((deadline (+ (float-time) 30)))
            (while (and (not connection) (< (float-time) deadline))
              (ignore-errors
                (emacs-jupyter-notebook-ssh-run-command
                 (emacs-jupyter-notebook-ssh-scp-from-command
                  profile remote-file local-copy))
                (setq connection
                      (emacs-jupyter-notebook-connection-read-file local-copy)))
              (unless connection (sleep-for 0.25))))
          (should (equal (plist-get connection :transport) "tcp"))
          (should (plist-get connection :shell_port))
          ;; The kernel binds all ZMQ ports at startup, so the tunnel/port
          ;; checks below need no remote-side poke (which would require a
          ;; bare `python3' on the remote PATH — not present under nix).
          (setq remote-ports
                (emacs-jupyter-notebook-connection-ports connection))
          (setq local-ports
                (emacs-jupyter-notebook-connection-allocate-local-ports))
          (setq tunnel
                (emacs-jupyter-notebook--start-tunnel
                 profile remote-ports local-ports session-id))
          (dolist (key emacs-jupyter-notebook-connection-port-keys)
            (should (ejn-remote-tests--wait-for-local-port
                     (plist-get local-ports key) 10))))
      (when (and tunnel (process-live-p tunnel))
        (delete-process tunnel))
      (when (integerp pid)
        (ignore-errors
          (emacs-jupyter-notebook-ssh-run-command
           (emacs-jupyter-notebook-ssh-build-remote-kill profile pid))))
      (ignore-errors
        (emacs-jupyter-notebook-ssh-run-command
         (emacs-jupyter-notebook-ssh-command
          profile
          (format "rm -f %s %s"
                  (emacs-jupyter-notebook-ssh--quote-remote-path remote-file)
                  (emacs-jupyter-notebook-ssh--quote-remote-path remote-log)))))
      (when (file-exists-p local-copy)
        (delete-file local-copy)))))

(ert-deftest ejn-remote-async-start-connect-and-evaluate ()
  "Start, connect, and evaluate through the interactive async command path."
  :tags '(:remote :emacs-jupyter :async)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
          (buffer (generate-new-buffer " *ejn-remote-async*"))
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                 (emacs-jupyter-notebook-remote-profiles
                  `((,(plist-get profile :profile) . ,profile)))
                 (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                 (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-async.py")
            (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
            (should (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                        'launch))
            (should (ejn-remote-tests--wait-for-phase buffer 'done 60))
            (let ((jupyter-current-client emacs-jupyter-notebook--client)
                  (jupyter-default-timeout 30))
              (should (equal (string-trim (jupyter-eval "6 * 7")) "42")))))
      (ignore-errors
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (emacs-jupyter-notebook-shutdown-kernel))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

(ert-deftest ejn-remote-evaluate-cell-command ()
  "Test that the send-cell command works with real evaluation."
  :tags '(:remote :emacs-jupyter :evaluation)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
          (buffer (generate-new-buffer " *ejn-remote-eval-cell*"))
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (with-current-buffer buffer
           (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                 (emacs-jupyter-notebook-remote-profiles
                  `((,(plist-get profile :profile) . ,profile)))
                 (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                 (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-eval-cell.py")
            ;; Insert code cell
            (insert "# %%\n6 * 7\n")
            (goto-char (point-min))
            (forward-line 1)
            ;; Evaluate using the actual command; it should start the kernel.
            (emacs-jupyter-notebook-send-cell)
            (should (ejn-remote-tests--wait-for-result-text buffer "42" 80))))
      (ignore-errors
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (emacs-jupyter-notebook-shutdown-kernel))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

(ert-deftest ejn-remote-reconnect-prefers-current-file-kernel ()
  "Start a kernel, then reconnect from another buffer visiting the same file."
  :tags '(:remote :emacs-jupyter :reconnect)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
         (source-file (make-temp-file "ejn-source-" nil ".py"))
         (first-buffer (generate-new-buffer " *ejn-remote-reconnect-a*"))
          (second-buffer (generate-new-buffer " *ejn-remote-reconnect-b*"))
          (emacs-jupyter-notebook-registry-file registry-file))
     (unwind-protect
         (progn
           (with-current-buffer first-buffer
             (setq buffer-file-name source-file)
             (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                   (emacs-jupyter-notebook-remote-profiles
                    `((,(plist-get profile :profile) . ,profile)))
                   (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                   (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
              (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
              (should (ejn-remote-tests--wait-for-phase first-buffer 'done 60))
              (when (process-live-p emacs-jupyter-notebook--tunnel-process)
                (delete-process emacs-jupyter-notebook--tunnel-process))
              (setq emacs-jupyter-notebook--tunnel-process nil)))
          (with-current-buffer second-buffer
            (setq buffer-file-name source-file)
            (insert "# %%\n6 * 7\n")
            (goto-char (point-min))
            (forward-line 1)
            (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                  (emacs-jupyter-notebook-remote-profiles
                   `((,(plist-get profile :profile) . ,profile)))
                  (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                  (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
              (emacs-jupyter-notebook-send-cell)
              (should (ejn-remote-tests--wait-for-result-text second-buffer "42" 80)))))
      (ignore-errors
        (when (buffer-live-p second-buffer)
          (with-current-buffer second-buffer
            (emacs-jupyter-notebook-shutdown-kernel))))
      (when (buffer-live-p first-buffer)
        (kill-buffer first-buffer))
      (when (buffer-live-p second-buffer)
        (kill-buffer second-buffer))
      (when (file-exists-p registry-file)
        (delete-file registry-file))
      (when (file-exists-p source-file)
        (delete-file source-file)))))

(ert-deftest ejn-remote-default-adapters-parse-real-replies ()
  "Exercise the DEFAULT complete/inspect/is-complete/kernel-info adapter
impls against a REAL kernel, with NO adapter-var stubs.  Guards the seam
every unit test mocks: the real `jupyter-*-request' construction, the
reply-type strings, and the `jupyter-message-content' shapes.  This is the
W8-class coverage — the adapters that PRODUCE the parsed replies are never
run in the deterministic suite."
  :tags '(:remote :emacs-jupyter :adapters)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (let* ((profile (ejn-remote-tests--profile))
         (registry-file (let ((f (make-temp-file "ejn-registry-"))) (delete-file f) f))
         (buffer (generate-new-buffer " *ejn-remote-adapters*"))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (with-current-buffer buffer
          (let ((emacs-jupyter-notebook-default-profile (plist-get profile :profile))
                (emacs-jupyter-notebook-remote-profiles
                 `((,(plist-get profile :profile) . ,profile)))
                (emacs-jupyter-notebook-connection-retrieve-attempts 120)
                (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq buffer-file-name "/tmp/ejn-remote-adapters.py")
            (emacs-jupyter-notebook-start-remote-kernel (plist-get profile :profile))
            (should (ejn-remote-tests--wait-for-phase buffer 'done 120))
            (let ((client emacs-jupyter-notebook--client)
                  reply done)
              (should client)
              (cl-flet ((await (fn)
                          (setq reply nil done nil)
                          (funcall fn (lambda (r _e) (setq reply r done t)))
                          (let ((deadline (+ (float-time) 30)))
                            (while (and (not done) (< (float-time) deadline))
                              (accept-process-output nil 0.1)))
                          (should done)))
                ;; kernel_info_reply — the heartbeat's dependency.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-kernel-info client cb)))
                (should reply)
                (should (or (plist-get reply :implementation)
                            (plist-get reply :language_info)))
                ;; complete_reply — real :matches (a vector), real offsets.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-complete client "prin" 4 cb)))
                (should reply)
                (should (member "print" (append (plist-get reply :matches) nil)))
                (should (integerp (plist-get reply :cursor_start)))
                (should (integerp (plist-get reply :cursor_end)))
                ;; inspect_reply — found symbol has non-empty text/plain.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-inspect client "print" 5 0 cb)))
                (should reply)
                (should (eq (plist-get reply :found) t))
                (should (plist-get (plist-get reply :data) :text/plain))
                ;; is_complete_reply — incomplete vs complete.
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-is-complete client "if True:" cb)))
                (should reply)
                (should (member (plist-get reply :status) '("incomplete" "invalid")))
                (await (lambda (cb)
                         (emacs-jupyter-notebook-jupyter-is-complete client "1 + 1" cb)))
                (should reply)
                (should (equal (plist-get reply :status) "complete"))))))
      (ignore-errors
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (emacs-jupyter-notebook-shutdown-kernel))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(provide 'emacs-jupyter-notebook-remote-tests)

;;; emacs-jupyter-notebook-remote-tests.el ends here
