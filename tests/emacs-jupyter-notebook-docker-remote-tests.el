;;; emacs-jupyter-notebook-docker-remote-tests.el --- Optional real Docker gate -*- lexical-binding: t; -*-

;;; Commentary:
;; Run through tests/run-docker-e2e.sh against an explicitly selected Linux
;; Docker host and pre-pulled image.  SSH, Docker and Jupyter are never mocked.
;; This optional module is excluded from the canonical local test runner.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'emacs-jupyter-notebook-remote-tests)

(defvar ejn-docker-remote--journal nil
  "Bounded diagnostic lines for the current explicitly requested Docker test.")

(defun ejn-docker-remote--note (format-string &rest args)
  "Retain bounded FORMAT-STRING and ARGS without connection-file contents."
  (let* ((text (apply #'format format-string args))
         (line (format "%.3f %s" (float-time)
                       (substring text 0 (min 2048 (length text))))))
    (push line ejn-docker-remote--journal)
    (when (> (length ejn-docker-remote--journal) 128)
      (setcdr (nthcdr 127 ejn-docker-remote--journal) nil))
    (message "Docker E2E: %s" line)))

(defun ejn-docker-remote--required (name)
  "Return nonempty environment variable NAME before any remote work."
  (let ((value (getenv name)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "Docker E2E requires %s" name))
    value))

(defun ejn-docker-remote--argv (name)
  "Read optional JSON string-array NAME without shell parsing."
  (when-let ((raw (getenv name)))
    (unless (<= (string-bytes raw) 16384)
      (error "%s exceeds the test option limit" name))
    (let ((value (json-parse-string raw :array-type 'array)))
      (unless (and (vectorp value) (<= (length value) 64)
                   (cl-every (lambda (part)
                               (and (stringp part) (not (string-empty-p part))
                                    (not (string-match-p "[\000\n\r]" part))))
                             value))
        (error "%s must be a JSON array of bounded argv strings" name))
      (append value nil))))

(defun ejn-docker-remote--await (source predicate seconds description)
  "Wait boundedly for SOURCE's PREDICATE within SECONDS for DESCRIPTION."
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (unless (buffer-live-p source) (error "Docker E2E source buffer disappeared"))
      (with-current-buffer source
        (when (or (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error)
                  (and emacs-jupyter-notebook--tunnel-dead
                       (not (emacs-jupyter-notebook--async-in-progress-p))))
          (error "%s failed: %s" description
                 (or emacs-jupyter-notebook--async-last-error
                     emacs-jupyter-notebook--last-bounded-error
                     "local transport marked unavailable")))
        (setq done (funcall predicate)))
      (unless done (accept-process-output nil 0.05)))
    (unless done (error "%s timed out after %ss" description seconds))
    (ejn-docker-remote--note "%s completed" description)
    done))

(defun ejn-docker-remote--connected-p ()
  "Whether the real current session has finished connection and setup."
  (and (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)
       (emacs-jupyter-notebook-backend-session-installed-p
        emacs-jupyter-notebook--client)
       (not emacs-jupyter-notebook--execution-setup-pending)))

(defun ejn-docker-remote--result-p (source expected)
  "Whether SOURCE's completed latest panel contains exact EXPECTED output."
  (and (not emacs-jupyter-notebook--execution-active-id)
       (not emacs-jupyter-notebook--execution-queue)
       (when-let ((panel (emacs-jupyter-notebook-panel-buffer source)))
         (when (buffer-live-p panel)
           (with-current-buffer panel
             (cl-some
              (lambda (pair)
                (string-match-p
                 (concat "\\(?:\\`\\|\n\\)" (regexp-quote expected)
                         "\\(?:\n\\|\\'\\)")
                 (ejn-panel-entry-text (cdr pair))))
              emacs-jupyter-notebook-panel--entries))))))

(defun ejn-docker-remote--recover-identity (profile entry registry)
  "Recover ENTRY's exact Docker ID if provisional; persist it in REGISTRY."
  (unless (emacs-jupyter-notebook-docker-entry-valid-p entry)
    (error "Test registry contains no valid Docker identity"))
  (if (plist-get entry :docker-container-id)
      entry
    (let ((deadline (+ (float-time) 15)) candidate last-error)
      (while (and (not candidate) (< (float-time) deadline))
        (condition-case err
            (setq candidate
                  (emacs-jupyter-notebook-launcher-parse-identity
                   entry
                   (ejn-remote-tests--run-command
                    (emacs-jupyter-notebook-launcher-build-read-identity profile entry)
                    (min 5 (max 0.1 (- deadline (float-time)))))))
          (error (setq last-error (error-message-string err))))
        (unless candidate (accept-process-output nil 0.1)))
      ;; Absence after a lost launch reply cannot authorize discarding the
      ;; provisional registry: a remote launch may still be completing.
      (unless candidate
        (error "Docker identity recovery unconfirmed; retaining registry: %s"
               (or last-error "no immutable container identity returned")))
      (ejn-remote-tests--registry-replace
       registry candidate (plist-get entry :registry-revision)))))

(defun ejn-docker-remote--cleanup (profile registry source-file)
  "Clean only exact test Docker identities in REGISTRY for SOURCE-FILE.
Return t only after exact cleanup markers and independent dead probes."
  (let ((entries (ejn-remote-tests--registry-read registry)) directories)
    (when (> (length entries) 1)
      (error "Single-launch Docker test found multiple registry entries; retaining evidence"))
    (dolist (entry entries)
      (unless (and (eq (plist-get entry :launch-kind) 'docker)
                   (equal (plist-get entry :profile) (plist-get profile :profile))
                   (equal (plist-get entry :local-file) source-file))
        (error "Refusing cleanup of a registry entry outside this Docker test")))
    (dolist (entry entries)
      (setq entry (ejn-docker-remote--recover-identity profile entry registry))
      (let* ((entry-profile (emacs-jupyter-notebook--entry-profile entry))
             (output (ejn-remote-tests--run-command
                      (emacs-jupyter-notebook-launcher-build-cleanup entry-profile entry))))
        (unless (equal (string-trim output) "__EJN_CLEANUP_DONE__")
          (error "Docker cleanup did not return its exact completion marker"))
        (unless (eq 'dead
                    (emacs-jupyter-notebook--classify-entry-probe
                     entry
                     (ejn-remote-tests--run-command
                      (emacs-jupyter-notebook-launcher-build-probe entry-profile entry))))
          (error "Docker cleanup did not independently confirm container absence"))
        (push (directory-file-name
               (file-name-directory (plist-get entry :remote-connection-file)))
              directories)
        (ejn-docker-remote--note "exact container cleanup confirmed: %s"
                               (plist-get entry :docker-container-id))))
    (when entries
      ;; Empty-directory removal is confined to the unique test cache.  Never
      ;; use a recursive removal or a profile-wide container stop operation.
      (ejn-remote-tests--run-command
       (emacs-jupyter-notebook-ssh-command
        profile
        (concat "rmdir -- "
                (mapconcat #'shell-quote-argument (delete-dups directories) " ")
                " && rmdir -- "
                (emacs-jupyter-notebook-ssh--quote-remote-path
                 (plist-get profile :remote-cache-dir))))))
    t))

(defun ejn-docker-remote--save-diagnostics (root source)
  "Write bounded local diagnostics beneath ROOT, without connection keys."
  (when (buffer-live-p source)
    (with-current-buffer source
      (ejn-docker-remote--note
       "state: %S"
       (list :phase (plist-get emacs-jupyter-notebook--async-context :phase)
             :setup emacs-jupyter-notebook--execution-setup-pending
             :kernel-status emacs-jupyter-notebook--kernel-status
             :tunnel-dead emacs-jupyter-notebook--tunnel-dead
             :heartbeat-misses emacs-jupyter-notebook--heartbeat-misses
             :error emacs-jupyter-notebook--last-bounded-error
             :container-id (plist-get emacs-jupyter-notebook--session-entry
                                      :docker-container-id)))))
  (let ((file (expand-file-name "diagnostics.txt" root)))
    (with-temp-file file
      (insert (mapconcat #'identity (reverse ejn-docker-remote--journal) "\n") "\n")
      (when-let ((log (get-buffer emacs-jupyter-notebook--log-buffer-name)))
        (insert "\nEJN log (tail):\n")
        (insert (with-current-buffer log
                  (buffer-substring-no-properties (max (point-min) (- (point-max) 16384))
                                                  (point-max))))))
    (set-file-modes file #o600)))

(ert-deftest ejn-docker-remote-real-launch-heartbeats-reconnect ()
  "Launch Docker, evaluate, observe idle heartbeats, reconnect and clean up."
  :tags '(:remote :docker :helper)
  (let* ((host (ejn-docker-remote--required "EJN_DOCKER_TEST_HOST"))
         (image (ejn-docker-remote--required "EJN_DOCKER_TEST_IMAGE"))
         (runtime (file-name-as-directory
                   (expand-file-name (ejn-docker-remote--required "EJN_DOCKER_TEST_RUNTIME"))))
         (helper (expand-file-name "bin/ejn-helper" runtime))
         (worker (expand-file-name "bin/ejn-registry-worker" runtime))
         (root (file-name-as-directory
                (expand-file-name (ejn-docker-remote--required "EJN_DOCKER_TEST_ARTIFACT_DIR"))))
         (source-file (expand-file-name "source.py" root))
         (registry (expand-file-name "registry-v1.json" root))
         (name (format "docker-smoke-%s-%x" (emacs-pid) (random most-positive-fixnum)))
         (profile (list :profile name :host host :launcher 'docker :docker-image image
                        :docker-options (ejn-docker-remote--argv "EJN_DOCKER_TEST_OPTIONS_JSON")
                        :remote-cwd (or (getenv "EJN_DOCKER_TEST_CWD") "/tmp")
                        :remote-cache-dir (concat "~/.cache/ejn-docker-smoke/" name)
                        :python-command (list (or (getenv "EJN_DOCKER_TEST_PYTHON") "python3"))
                        :kernelspec "python3"))
         (user-emacs-directory (expand-file-name "emacs/" root))
         (emacs-jupyter-notebook-helper-command (list helper "--protocol"))
         (emacs-jupyter-notebook-registry-worker-command (list worker))
         (emacs-jupyter-notebook--runtime-directory runtime)
         (emacs-jupyter-notebook-auto-build-runtime nil)
         (emacs-jupyter-notebook-registry-file registry)
         (emacs-jupyter-notebook-remote-profiles (list (cons name profile)))
         (emacs-jupyter-notebook-default-profile name)
         (emacs-jupyter-notebook-ssh-options
          (append '("-o" "BatchMode=yes" "-o" "ConnectTimeout=8")
                  (ejn-docker-remote--argv "EJN_DOCKER_TEST_SSH_OPTIONS_JSON")))
         (emacs-jupyter-notebook-ssh-batch-mode t)
         (emacs-jupyter-notebook-ssh-connect-timeout 8)
         (emacs-jupyter-notebook-ssh-process-timeout 25)
         (emacs-jupyter-notebook-management-process-timeout 25)
         (emacs-jupyter-notebook-connection-attempt-timeout 90)
         (emacs-jupyter-notebook-connect-arbitration-timeout 30)
         (emacs-jupyter-notebook-auto-reconnect nil)
         (emacs-jupyter-notebook-heartbeat-interval 2)
         (emacs-jupyter-notebook-heartbeat-timeout 3)
         (emacs-jupyter-notebook-heartbeat-misses-allowed 2)
         (emacs-jupyter-notebook-kernel-idle-timeout 600)
         (ejn-docker-remote--journal nil)
         (code (concat "# %%\n"
                       "ejn_docker_smoke_runs = globals().get('ejn_docker_smoke_runs', 0) + 1\n"
                       "41 + ejn_docker_smoke_runs\n"))
         source entry original-id heartbeat-advice miss-advice aux-advice
         (heartbeat-replies 0) (heartbeat-misses 0) cleanup-confirmed body-error cleanup-error)
    (when (or (file-remote-p runtime) (file-remote-p root))
      (error "Docker E2E runtime and artifacts must be local paths"))
    (unless (and (file-executable-p helper) (file-executable-p worker))
      (error "EJN_DOCKER_TEST_RUNTIME must contain executable helper and registry worker"))
    (unless (file-directory-p root) (error "Docker E2E artifact directory is missing"))
    (when (or (file-exists-p source-file) (file-exists-p registry))
      (error "Docker E2E requires a fresh artifact directory"))
    (setq profile (emacs-jupyter-notebook-ssh-profile profile))
    (make-directory user-emacs-directory t)
    (with-temp-file source-file (insert code))
    (set-file-modes source-file #o600)
    (setq source (find-file-noselect source-file))
    (setq heartbeat-advice
          (lambda (&rest _)
            (when (eq (current-buffer) source)
              (cl-incf heartbeat-replies)
              (ejn-docker-remote--note "idle heartbeat reply %d" heartbeat-replies))))
    (setq miss-advice
          (lambda (&rest _)
            (when (eq (current-buffer) source)
              (cl-incf heartbeat-misses)
              (ejn-docker-remote--note "heartbeat miss callback; setup=%S kernel-status=%S"
                                     emacs-jupyter-notebook--execution-setup-pending
                                     emacs-jupyter-notebook--kernel-status))))
    (setq aux-advice
          (lambda (original session operation payload callback &optional error-callback)
            (if (or (not (eq (current-buffer) source)) (not (eq operation 'kernel-info)))
                (funcall original session operation payload callback error-callback)
              (let ((started (float-time)))
                (ejn-docker-remote--note "kernel-info auxiliary dispatched")
                (condition-case err
                    (funcall original session operation payload
                             (lambda (id result)
                               (ejn-docker-remote--note "kernel-info reply after %.3fs"
                                                      (- (float-time) started))
                               (funcall callback id result))
                             (lambda (id reason)
                               (ejn-docker-remote--note "kernel-info rejected after %.3fs: %s"
                                                      (- (float-time) started) reason)
                               (when error-callback (funcall error-callback id reason))))
                  (error
                   (ejn-docker-remote--note "kernel-info dispatch error: %s"
                                          (error-message-string err))
                   (signal (car err) (cdr err))))))))
    (unwind-protect
        (condition-case err
            (progn
              (advice-add 'emacs-jupyter-notebook--heartbeat-on-reply :after heartbeat-advice)
              (advice-add 'emacs-jupyter-notebook--heartbeat-on-miss :before miss-advice)
              (advice-add 'emacs-jupyter-notebook-backend-aux :around aux-advice)
              (with-current-buffer source
                (emacs-jupyter-notebook-mode 1)
                (emacs-jupyter-notebook-start-remote-kernel name)
                (ejn-docker-remote--await source #'ejn-docker-remote--connected-p 100 "Docker startup and setup")
                (setq entry (copy-tree emacs-jupyter-notebook--session-entry)
                      original-id (plist-get entry :docker-container-id))
                (should (emacs-jupyter-notebook-launcher-entry-cleanup-valid-p entry))
                (ejn-docker-remote--note "connected container %s" original-id)
                (goto-char (point-min))
                (forward-line 1)
                (emacs-jupyter-notebook-send-cell)
                (ejn-docker-remote--await
                 source (lambda () (ejn-docker-remote--result-p source "42")) 40 "First cell result 42")
                (should (equal (buffer-string) code))
                (should-not (buffer-modified-p))
                (setq heartbeat-replies 0)
                (ejn-docker-remote--await source (lambda () (>= heartbeat-replies 3))
                                          25 "Three real idle heartbeat replies")
                (should (= heartbeat-misses 0))
                (should (= emacs-jupyter-notebook--heartbeat-misses 0))
                (emacs-jupyter-notebook--release-local-resources)
                (should-not emacs-jupyter-notebook--client)
                (should-not emacs-jupyter-notebook--tunnel-process)
                (should (eq 'alive
                            (emacs-jupyter-notebook--classify-entry-probe
                             entry (ejn-remote-tests--run-command
                                    (emacs-jupyter-notebook-launcher-build-probe profile entry)))))
                (emacs-jupyter-notebook-reconnect-remote-kernel entry)
                (ejn-docker-remote--await source #'ejn-docker-remote--connected-p 100 "Reconnect and setup")
                (should (equal original-id
                               (plist-get emacs-jupyter-notebook--session-entry :docker-container-id)))
                (emacs-jupyter-notebook-send-cell)
                (ejn-docker-remote--await
                 source (lambda () (ejn-docker-remote--result-p source "43")) 40 "Second cell result 43 in same kernel")
                (should (equal (buffer-string) code))
                (should-not (buffer-modified-p))
                (should (= heartbeat-misses 0))))
          (error
           (setq body-error err)
           (ejn-docker-remote--note "test failure: %s" (error-message-string err))))
      (advice-remove 'emacs-jupyter-notebook--heartbeat-on-reply heartbeat-advice)
      (advice-remove 'emacs-jupyter-notebook--heartbeat-on-miss miss-advice)
      (advice-remove 'emacs-jupyter-notebook-backend-aux aux-advice)
      (ignore-errors (ejn-docker-remote--save-diagnostics root source))
      (when (buffer-live-p source)
        (condition-case err
            (with-current-buffer source (emacs-jupyter-notebook--release-local-resources))
          (error (ejn-docker-remote--note "local release failed before exact cleanup: %s"
                                         (error-message-string err)))))
      (condition-case err
          (setq cleanup-confirmed (ejn-docker-remote--cleanup profile registry source-file))
        (error
         (setq cleanup-error err)
         (ejn-docker-remote--note "cleanup unconfirmed; retain %s: %s"
                                registry (error-message-string err))))
      (ignore-errors (ejn-docker-remote--save-diagnostics root source))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (when cleanup-confirmed
        (dolist (file (list source-file registry))
          (when (file-exists-p file) (delete-file file)))
        (when (file-directory-p user-emacs-directory)
          (delete-directory user-emacs-directory t))))
    (when body-error (signal (car body-error) (cdr body-error)))
    (when cleanup-error (signal (car cleanup-error) (cdr cleanup-error)))
    (should cleanup-confirmed)))

(provide 'emacs-jupyter-notebook-docker-remote-tests)
;;; emacs-jupyter-notebook-docker-remote-tests.el ends here
