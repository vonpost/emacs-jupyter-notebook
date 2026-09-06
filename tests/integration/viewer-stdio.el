;;; viewer-stdio.el --- Opt-in real local viewer handoff -*- lexical-binding: t; -*-

;; Run separately from the deterministic ERT suite, using a built GUI output:
;; EJN_VIEWER_BIN=/nix/store/.../bin/ejn-viewer QT_QPA_PLATFORM=offscreen \
;;   emacs -Q --batch -L . -L /path/to/code-cells \
;;   -l tests/integration/viewer-stdio.el -f ert-run-tests-batch-and-exit
;; Omit QT_QPA_PLATFORM for an optional actual-display smoke test.
;; No kernel, helper process, SSH, or network access is used. Only the bounded
;; helper descriptor is synthetic; normalization, reduction, panel ownership,
;; inspector manager, stdio protocol and viewer snapshot loading are real.

(require 'ert)
(require 'json)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-inspect)
(require 'emacs-jupyter-notebook-helper-backend)

(defconst ejn-viewer-stdio--fixture
  (expand-file-name "../fixtures/viewer-contract-v1.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun ejn-viewer-stdio--unhex (hex)
  "Decode small test-fixture HEX without involving production array readers."
  (apply #'unibyte-string
         (cl-loop for index from 0 below (length hex) by 2
                  collect (string-to-number (substring hex index (+ index 2)) 16))))

(ert-deftest ejn-viewer-stdio-real-snapshot-outlives-panel-and-artifact ()
  (let ((binary (getenv "EJN_VIEWER_BIN")))
    (unless (and binary (file-name-absolute-p binary) (file-executable-p binary))
      (ert-fail "Set EJN_VIEWER_BIN to the actual built local viewer executable"))
    (let* ((source (generate-new-buffer " *ejn-stdio-integration-source*"))
           (panel (ejn-panel-ensure source))
           (cap (emacs-jupyter-notebook-artifacts-create 'helper))
           (root (emacs-jupyter-notebook-artifacts-capability-root cap))
           (file (expand-file-name "ejn-artifact-0123456789abcdef0123456789abcdef" root))
           (key '("viewer-stdio-test.py" . 1))
           (handle (ejn-panel-start-entry panel key "ejn.view(reference)"))
           (emacs-jupyter-notebook-inspector-command (list binary))
           (emacs-jupyter-notebook-inspect--state nil)
           (emacs-jupyter-notebook-inspect--watches nil)
           (backend (emacs-jupyter-notebook-helper-backend--make-state
                     :artifact-dir root :artifact-capability cap
                     :artifact-identity (file-attribute-file-identifier
                                         (file-attributes root 'integer))))
           (acknowledged nil)
           (observer
            (lambda (_state response)
              ;; Observe the real parsed response after manager validation;
              ;; a negative terminal ACK must never count as test success.
              (when (and (eq (gethash "ok" response) t)
                         (hash-table-p (gethash "result" response))
                         (equal (gethash "state" (gethash "result" response)) "visible"))
                (setq acknowledged t))))
           lease state before)
      (unwind-protect
          (progn
            (with-current-buffer source
              (insert "# %%\n# Real viewer test: source stays untouched.\n")
              (set-buffer-modified-p nil)
              (setq before (buffer-string)))
            (let* ((fixture (with-temp-buffer
                              (insert-file-contents ejn-viewer-stdio--fixture)
                              (json-parse-buffer)))
                   (vector (aref (gethash "valid" fixture) 0))
                   (header (gethash "header_json" vector))
                   (bytes (concat (string-as-unibyte "EJNARR01")
                                  (ejn-viewer-stdio--unhex (gethash "header_length_be_hex" vector))
                                  (encode-coding-string header 'utf-8 t)
                                  (ejn-viewer-stdio--unhex (gethash "raw_hex" vector))))
                   (descriptor (emacs-jupyter-notebook-helper-backend--make-object
                                "path" file "bytes" (length bytes)
                                "sha256" (secure-hash 'sha256 bytes)
                                "manifest" (json-parse-string header)))
                   (event (emacs-jupyter-notebook-helper-backend--make-object
                           "event" "display_data"
                           "data" (emacs-jupyter-notebook-helper-backend--make-object
                                   "data" (emacs-jupyter-notebook-helper-backend--make-object
                                           "application/x-ejn-array-group" descriptor)
                                   "metadata" (make-hash-table :test #'equal)))))
              ;; Test-owned tiny fixture only. Production Emacs does not read
              ;; or construct array payloads; the helper owns that work.
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert bytes)
                (let ((coding-system-for-write 'no-conversion))
                  (write-region (point-min) (point-max) file nil 'silent)))
              (set-file-modes file #o600)
              (should (emacs-jupyter-notebook-events-dispatch
                       (list :buffer source :entry-handle handle)
                       (emacs-jupyter-notebook-helper-backend--normalize-event backend event))))
            (emacs-jupyter-notebook-panel-flush-now panel)
            (with-current-buffer panel
              (should (string-match-p "reference" (buffer-string)))
              (should (string-match-p "\\[Inspect\\]" (buffer-string))))
            (setq lease (emacs-jupyter-notebook-panel-acquire-array-for-cell source key))
            (should lease)
            (advice-add 'emacs-jupyter-notebook-inspect--response :after observer)
            (with-current-buffer source
              (setq state (emacs-jupyter-notebook-inspect-publication lease t)))
            (let ((deadline (+ (float-time) 15)))
              ;; Waiting is deliberately test-only and has a finite deadline.
              (while (and (< (float-time) deadline)
                          (emacs-jupyter-notebook-inspect--live-p state)
                          (not (and acknowledged (ejn-inspection-ready state)
                                    (not (ejn-inspection-active state))
                                    (not (ejn-inspection-pending state)))))
                (accept-process-output nil 0.05)))
            (should acknowledged)
            (should (ejn-inspection-ready state))
            (should-not (ejn-inspection-active state))
            (should-not (ejn-inspection-pending state))
            (should (process-live-p (ejn-inspection-process state)))
            (with-current-buffer source
              (should (equal before (buffer-string)))
              (should-not (buffer-modified-p)))
            (ejn-panel-clear-all panel)
            (kill-buffer panel)
            (emacs-jupyter-notebook-artifacts-retire cap)
            (should-not (file-exists-p file))
            (should (emacs-jupyter-notebook-inspect--live-p state))
            (should (process-live-p (ejn-inspection-process state)))
            (with-current-buffer source
              (should (equal before (buffer-string)))
              (should-not (buffer-modified-p)))
            (kill-buffer source)
            (should (emacs-jupyter-notebook-inspect--live-p state))
            (should (process-live-p (ejn-inspection-process state))))
        (advice-remove 'emacs-jupyter-notebook-inspect--response observer)
        (when state (ignore-errors (emacs-jupyter-notebook-inspect--stop state)))
        (when lease (ignore-errors (funcall (plist-get lease :release))))
        (when (buffer-live-p panel) (kill-buffer panel))
        (when (buffer-live-p source) (kill-buffer source))
        (emacs-jupyter-notebook-artifacts-retire cap)))))

;;; viewer-stdio.el ends here
