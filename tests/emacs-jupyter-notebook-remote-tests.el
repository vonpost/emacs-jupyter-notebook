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
        :kernelspec (or (getenv "EJN_REMOTE_TEST_KERNELSPEC") "python3")))

(defun ejn-remote-tests--session-id ()
  "Return a unique session id for a remote smoke test."
  (format "ert-%s-%s" (emacs-pid) (format-time-string "%Y%m%d%H%M%S")))

(defun ejn-remote-tests--remote-python-exec-command (connection-file)
  "Return a remote shell command that executes code via CONNECTION-FILE."
  (let ((python-code
         (string-join
          '("import sys, time"
            "from queue import Empty"
            "from jupyter_client import BlockingKernelClient"
            "kc = BlockingKernelClient(connection_file=sys.argv[1])"
            "kc.load_connection_file()"
            "kc.start_channels()"
            "kc.wait_for_ready(timeout=20)"
            "msg_id = kc.execute('print(6 * 7)')"
            "deadline = time.time() + 20"
            "seen = False"
            "while time.time() < deadline:"
            "    try:"
            "        msg = kc.get_iopub_msg(timeout=1)"
            "    except Empty:"
            "        continue"
            "    if msg.get('parent_header', {}).get('msg_id') != msg_id:"
            "        continue"
            "    msg_type = msg['header']['msg_type']"
            "    content = msg['content']"
            "    if msg_type == 'stream' and content.get('text', '').strip() == '42':"
            "        seen = True"
            "    if msg_type == 'status' and content.get('execution_state') == 'idle':"
            "        break"
            "kc.stop_channels()"
            "raise SystemExit(0 if seen else 1)")
          "\n")))
    (format "python3 -c %s %s"
            (shell-quote-argument python-code)
            (emacs-jupyter-notebook-ssh--quote-remote-path connection-file))))

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
          (setq connection
                (emacs-jupyter-notebook--retrieve-connection-file
                 profile remote-file local-copy))
          (should (equal (plist-get connection :transport) "tcp"))
          (should (plist-get connection :shell_port))
          (emacs-jupyter-notebook-ssh-run-command
           (emacs-jupyter-notebook-ssh-command
            profile
            (ejn-remote-tests--remote-python-exec-command remote-file)))
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

(ert-deftest ejn-remote-emacs-jupyter-connect-and-evaluate ()
  "Connect to a remote kernel with emacs-jupyter and evaluate code."
  :tags '(:remote :emacs-jupyter)
  (unless (require 'jupyter nil t)
    (ert-skip "emacs-jupyter is not on load-path"))
  (require 'jupyter-client)
  (let* ((profile (ejn-remote-tests--profile))
         (session-id (ejn-remote-tests--session-id))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (remote-file (plist-get launch :connection-file))
         (remote-log (plist-get launch :log-file))
         (registry-file (let ((file (make-temp-file "ejn-registry-")))
                          (delete-file file)
                          file))
         (entry (list :profile (plist-get profile :profile)
                      :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                      :remote-cwd (plist-get profile :remote-cwd)
                      :kernelspec (plist-get profile :kernelspec)
                      :remote-connection-file remote-file
                      :remote-pid nil
                      :created-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                      :tunnel-ports nil
                      :display-name (format "%s:%s"
                                            (emacs-jupyter-notebook-ssh-destination profile)
                                            (plist-get profile :kernelspec))
                      :session-id session-id))
         (buffer (generate-new-buffer " *ejn-remote-emacs-jupyter*"))
         pid)
    (unwind-protect
        (with-current-buffer buffer
          (let ((emacs-jupyter-notebook-registry-file registry-file)
                (emacs-jupyter-notebook-connection-retrieve-attempts 80)
                (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
            (setq pid (emacs-jupyter-notebook--parse-pid
                       (emacs-jupyter-notebook-ssh-run-command
                        (plist-get launch :argv))))
            (setq entry (plist-put entry :remote-pid pid))
            (emacs-jupyter-notebook--connect-entry entry profile)
            (let ((jupyter-current-client emacs-jupyter-notebook--client))
              (should (equal (string-trim (jupyter-eval "6 * 7")) "42")))))
      (ignore-errors
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (emacs-jupyter-notebook-shutdown-kernel))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
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
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

(provide 'emacs-jupyter-notebook-remote-tests)

;;; emacs-jupyter-notebook-remote-tests.el ends here
