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

(defun ejn-doom-e2e--wait-for-result-text (buffer text timeout)
  "Return non-nil when BUFFER has an inline result containing TEXT.
Signal if the notebook async setup enters an error phase before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (with-current-buffer buffer
        (when (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                  'error)
          (error "Notebook async setup failed: %S"
                 (plist-get emacs-jupyter-notebook--async-context :error)))
        (setq found
              (cl-some
               (lambda (ov)
                 (let ((content (overlay-get ov 'emacs-jupyter-notebook-content))
                       (display (overlay-get ov 'after-string)))
                   (or (and content (string-match-p (regexp-quote text) content))
                       (and display (string-match-p (regexp-quote text) display)))))
                (emacs-jupyter-notebook-result--all-overlays)))))
    found))

(defun ejn-doom-e2e--wait-for-result-image (buffer timeout)
  "Return non-nil when BUFFER has an inline image result within TIMEOUT.
Signal if the notebook async setup enters an error phase before TIMEOUT."
  (let ((deadline (+ (float-time) timeout))
        found)
    (while (and (not found) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (unless (buffer-live-p buffer)
        (error "E2E source buffer was killed"))
      (with-current-buffer buffer
        (when (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                  'error)
          (error "Notebook async setup failed: %S"
                 (plist-get emacs-jupyter-notebook--async-context :error)))
        (setq found
              (cl-some
               (lambda (ov)
                 (overlay-get ov 'emacs-jupyter-notebook-image))
               (emacs-jupyter-notebook-result--all-overlays)))))
    found))

(defun ejn-doom-e2e-python-cell-evaluates-on-mother ()
  "Open a temp Python file, add a code-cell marker, and evaluate imports.
This uses the Doom-configured `emacs-jupyter-notebook' package and the
configured profile, which defaults to `mother' in the user's Doom config."
  (let* ((profile-name (ejn-doom-e2e--profile-name))
         (profile (assoc profile-name emacs-jupyter-notebook-remote-profiles))
         (source-file (make-temp-file "ejn-doom-e2e-" nil ".py"))
         (registry-file (make-temp-file "ejn-doom-e2e-registry-"))
         (buffer nil))
    (unless profile
      (error "No emacs-jupyter-notebook profile named %S" profile-name))
    (unwind-protect
        (let ((emacs-jupyter-notebook-registry-file registry-file)
              (emacs-jupyter-notebook-connection-retrieve-attempts 80)
              (emacs-jupyter-notebook-connection-retrieve-delay 0.25))
          (setq buffer (find-file-noselect source-file))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "# %%\nimport matplotlib.pyplot as plt\nimport numpy as np\nplt.imshow(np.random.uniform(size=(64, 64)))\nplt.show()\n")
            (save-buffer)
            (python-mode)
            (emacs-jupyter-notebook-mode 1)
            (goto-char (point-min))
            (forward-line 1)
            (emacs-jupyter-notebook-evaluate-current-cell)
            (unless (ejn-doom-e2e--wait-for-result-image
                     buffer (ejn-doom-e2e--timeout))
              (error "Timed out waiting for plot result from %S" profile-name))))
      (when (buffer-live-p buffer)
        (let ((emacs-jupyter-notebook-registry-file registry-file)
              entry)
          (with-current-buffer buffer
            (setq entry emacs-jupyter-notebook--session-entry)
            (ignore-errors
              (emacs-jupyter-notebook-shutdown-kernel)))
          (when-let* ((remote-file (plist-get entry :remote-connection-file)))
            (ignore-errors
              (emacs-jupyter-notebook-ssh-run-command
               (emacs-jupyter-notebook-ssh-build-remote-cleanup
                (emacs-jupyter-notebook--entry-profile entry)
                remote-file)))))
        (kill-buffer buffer))
      (when (file-exists-p source-file)
        (delete-file source-file))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

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
