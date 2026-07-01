;;; emacs-jupyter-notebook-doom-e2e.el --- Doom end-to-end test  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Optional end-to-end test helpers intended to run inside an Emacs instance
;; that has already loaded the user's Doom configuration.  Use
;; tests/run-doom-e2e.sh to start that Emacs daemon and invoke this file.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-result)

(defun ejn-doom-e2e--timeout ()
  "Return the E2E timeout in seconds."
  (string-to-number (or (getenv "EJN_DOOM_E2E_TIMEOUT") "90")))

(defun ejn-doom-e2e--profile-name ()
  "Return the configured E2E profile name."
  (or (getenv "EJN_DOOM_E2E_PROFILE")
      emacs-jupyter-notebook-default-profile
      "mother"))

(defun ejn-doom-e2e--check-async-error (buffer)
  "Signal if BUFFER's async setup reached the `error' phase."
  (with-current-buffer buffer
    (when (eq (plist-get emacs-jupyter-notebook--async-context :phase)
              'error)
      (error "Notebook async setup failed: %S"
             (plist-get emacs-jupyter-notebook--async-context :error)))))

(defun ejn-doom-e2e--panel-entries-for (buffer)
  "Return the panel entry alist for BUFFER, or nil when the panel is dead."
  (let ((panel (emacs-jupyter-notebook-panel-buffer buffer)))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        emacs-jupyter-notebook-panel--entries))))

(defun ejn-doom-e2e--wait-for-result-text (buffer text timeout)
  "Return non-nil when BUFFER's panel has an entry whose content matches TEXT.
Signal if the notebook async setup enters an error phase before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (setq found
            (cl-some
             (lambda (cell)
               (let* ((entry (cdr cell))
                      (content (or (plist-get entry :content) "")))
                 (string-match-p (regexp-quote text) content)))
             (ejn-doom-e2e--panel-entries-for buffer))))
    found))

(defun ejn-doom-e2e--wait-for-result-image (buffer timeout)
  "Return non-nil when BUFFER's panel has an entry with an :image within TIMEOUT.
Signal if the notebook async setup enters an error phase before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (setq found
            (cl-some
             (lambda (cell)
               (plist-get (cdr cell) :image))
             (ejn-doom-e2e--panel-entries-for buffer))))
    found))

(defun ejn-doom-e2e--wait-for-client (buffer timeout)
  "Return non-nil when BUFFER has a live buffer-local Jupyter client.
Signal if the notebook async setup enters an error phase before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        client)
    (while (and (not client) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (ejn-doom-e2e--check-async-error buffer)
      (with-current-buffer buffer
        (setq client emacs-jupyter-notebook--client)))
    client))

(defun ejn-doom-e2e--cleanup-remote-entry (entry)
  "Best-effort delete of ENTRY's remote connection file on the remote host."
  (when-let* ((remote-file (plist-get entry :remote-connection-file)))
    (ignore-errors
      (emacs-jupyter-notebook-ssh-run-command
       (emacs-jupyter-notebook-ssh-build-remote-cleanup
        (emacs-jupyter-notebook--entry-profile entry)
        remote-file)))))

(defun ejn-doom-e2e-python-cell-evaluates-on-mother ()
  "Open a temp Python file, evaluate an image cell and a text cell, then
verify that shutting down the source buffer and re-opening the same file
lets `reconnect-remote-kernel' pick up the same remote kernel.  The final
`shutdown-kernel' cleanup runs strictly AFTER reconnect succeeds so the
reconnect path is exercised on a live remote kernel.

Uses the Doom-configured `emacs-jupyter-notebook' package and the
configured profile, which defaults to `mother' in the user's Doom config."
  (let* ((profile-name (ejn-doom-e2e--profile-name))
         (profile (assoc profile-name emacs-jupyter-notebook-remote-profiles))
         (source-file (make-temp-file "ejn-doom-e2e-" nil ".py"))
         (registry-file (make-temp-file "ejn-doom-e2e-registry-"))
         (timeout (ejn-doom-e2e--timeout))
         (buffer nil)
         (buffer2 nil)
         (entry-after-image nil)
         (final-entry nil))
    (unless profile
      (error "No emacs-jupyter-notebook profile named %S" profile-name))
    (unwind-protect
        (let ((emacs-jupyter-notebook-registry-file registry-file)
              (emacs-jupyter-notebook-connection-retrieve-attempts 80)
              (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
          ;;; --- Phase 1: cold-start + image cell ---
          (setq buffer (find-file-noselect source-file))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "# %% image\n"
                    "import matplotlib.pyplot as plt\n"
                    "import numpy as np\n"
                    "plt.imshow(np.random.uniform(size=(64, 64)))\n"
                    "plt.show()\n"
                    "# %% text\n"
                    "print('W7.4 doom e2e text output ok')\n")
            (save-buffer)
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (goto-char (point-min))
            (forward-line 1)
            (emacs-jupyter-notebook-send-cell)
            (unless (ejn-doom-e2e--wait-for-result-image buffer timeout)
              (error "Timed out waiting for plot result from %S" profile-name))
            ;;; --- Phase 2: text cell in the same session ---
            (setq entry-after-image emacs-jupyter-notebook--session-entry)
            (goto-char (point-min))
            (search-forward "# %% text")
            (forward-line 1)
            (emacs-jupyter-notebook-send-cell)
            (unless (ejn-doom-e2e--wait-for-result-text
                     buffer "W7.4 doom e2e text output ok" timeout)
              (error "Timed out waiting for text result from %S" profile-name)))
          ;;; --- Phase 3: kill source buffer WITHOUT shutdown, reopen, reconnect ---
          ;; Killing the source buffer must NOT touch the registry or the
          ;; remote kernel (W1 binding rule): the registry entry is the
          ;; durable reconnect key we are about to use.
          (kill-buffer buffer)
          (setq buffer nil)
          (setq buffer2 (find-file-noselect source-file))
          (with-current-buffer buffer2
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
              (unless entry
                (error "No registry entry for %S after buffer kill" source-file))
              (emacs-jupyter-notebook-reconnect-remote-kernel entry))
            (unless (ejn-doom-e2e--wait-for-client buffer2 timeout)
              (error "Timed out waiting for reconnect client on %S"
                     profile-name))
            (setq final-entry emacs-jupyter-notebook--session-entry)))
      ;;; --- Teardown: shutdown AFTER reconnect succeeded ---
      (let ((emacs-jupyter-notebook-registry-file registry-file))
        (when (buffer-live-p buffer2)
          (with-current-buffer buffer2
            (ignore-errors
              (emacs-jupyter-notebook-shutdown-kernel :force))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (ignore-errors
              (emacs-jupyter-notebook-shutdown-kernel :force)))))
      (ejn-doom-e2e--cleanup-remote-entry (or final-entry entry-after-image))
      (when (buffer-live-p buffer2) (kill-buffer buffer2))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p source-file) (delete-file source-file))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(ert-deftest ejn-doom-e2e-python-cell-evaluates-on-mother-test ()
  "ERT wrapper for `ejn-doom-e2e-python-cell-evaluates-on-mother'."
  :tags '(:remote :doom :e2e)
  (ejn-doom-e2e-python-cell-evaluates-on-mother))

(defun ejn-doom-e2e-run ()
  "Run the Doom E2E test and return a simple success value."
  (ejn-doom-e2e-python-cell-evaluates-on-mother)
  'ejn-doom-e2e-ok)

(provide 'emacs-jupyter-notebook-doom-e2e)

;;; emacs-jupyter-notebook-doom-e2e.el ends here
