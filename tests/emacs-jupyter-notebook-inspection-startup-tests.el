;;; emacs-jupyter-notebook-inspection-startup-tests.el --- cold viewer startup -*- lexical-binding: t; -*-

;;; Commentary:
;; This deterministic integration-shaped ERT test uses
;; the real numerical panel card and inspector, while replacing the two OS
;; boundaries (Nix and the viewer executable) with short local processes.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-inspect)

(defun ejn-inspection-startup-test--manifest ()
  (json-parse-string
   "{\"v\":1,\"key\":\"startup\",\"sample_id\":\"cold\",\"publication_id\":\"00000000000000000000000000000001\",\"planes\":[{\"id\":\"0\",\"name\":\"prediction\",\"shape\":[2,3],\"dtype\":\"<u2\",\"offset\":0,\"nbytes\":12}]}"))

(defun ejn-inspection-startup-test--publication (root)
  (let* ((path (expand-file-name
                "ejn-artifact-00000000000000000000000000000001" root))
         ;; The panel admits metadata only.  The local process never opens
         ;; this fixture; the real viewer would receive the exact lease.
         (payload "helper-owned array bytes: bounded fixture\n"))
    (with-temp-file path (insert payload))
    (set-file-modes path #o600)
    (list :root root
          :root-identity (file-attribute-file-identifier
                          (file-attributes root 'integer))
          :path path :size (string-bytes payload)
          :sha256 (secure-hash 'sha256 payload)
          :manifest (ejn-inspection-startup-test--manifest))))

(defun ejn-inspection-startup-test--wait (predicate)
  (let ((deadline (+ (float-time) 5.0)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.03)
      (sleep-for 0.01))
    (funcall predicate)))

(ert-deftest ejn-inspection-cold-start-through-card-builds-once-and-becomes-visible ()
  (let* ((source (generate-new-buffer " *ejn-inspection-startup-source*"))
         (panel (ejn-panel-ensure source))
         (cap (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (emacs-jupyter-notebook-artifacts-capability-root cap))
         (output (make-temp-file "ejn-inspection-viewer-output-" t))
         (viewer (expand-file-name "bin/ejn-viewer" output))
         (real-make-process (symbol-function 'make-process))
         (real-send (symbol-function 'process-send-string))
         (build-commands nil) (viewer-commands nil) (progress nil)
         (created nil)
         (viewer-decoder (ejn-helper-protocol-make-decoder 65536 65536))
         (source-before nil)
         (log-buffer (get-buffer-create " *ejn-inspection-startup-log*"))
         (emacs-jupyter-notebook-runtime--viewer-build nil)
         (emacs-jupyter-notebook-runtime-viewer-directory nil)
         (emacs-jupyter-notebook-inspect--state nil)
         (emacs-jupyter-notebook-inspect--watches nil)
         (emacs-jupyter-notebook-inspector-command nil))
    (make-directory (file-name-directory viewer) t)
    (with-temp-file viewer (insert "#!/bin/sh\nexec sleep 10\n"))
    (set-file-modes viewer #o700)
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "# %%\nejn.view(planes)\n")
            (set-buffer-modified-p nil)
            (setq source-before (buffer-string)))
          (let* ((handle (ejn-panel-start-entry panel '("test.py" . 1)
                                                  "ejn.view(planes)"))
                 (publication (ejn-inspection-startup-test--publication root)))
            (should (ejn-panel-set-published-array handle publication))
            (emacs-jupyter-notebook-panel-flush-now panel)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-runtime--package-root)
                       (lambda () temporary-file-directory))
                      ((symbol-function 'emacs-jupyter-notebook-runtime--nix-program)
                       (lambda () "/mock/nix"))
                      ((symbol-function 'emacs-jupyter-notebook--log-append)
                       (lambda (_phase format-string &rest args)
                         (with-current-buffer log-buffer
                           (goto-char (point-max))
                           (insert (apply #'format format-string args) "\n"))))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) progress)))
                      ((symbol-function 'emacs-jupyter-notebook--transport-lost)
                       (lambda (&rest _) (ert-fail "Inspection must not reconnect transport")))
                      ((symbol-function 'make-process)
                       (lambda (&rest args)
                         (let* ((command (plist-get args :command))
                                (is-viewer (member "--stdio" command))
                                (replacement
                                 (if is-viewer
                                     '("/bin/sh" "-c" "exec sleep 10")
                                   (list "/bin/sh" "-c"
                                         "read line; printf '%s\\n' \"$1\"; printf 'building viewer\\n' >&2"
                                         "ejn-test-nix" output)))
                                (process (apply real-make-process
                                                (plist-put (copy-sequence args)
                                                           :command replacement))))
                           (push process created)
                           (if is-viewer
                               (push command viewer-commands)
                             (push command build-commands))
                           process)))
                      ((symbol-function 'process-send-string)
                       (lambda (process bytes)
                         (if (string= (process-name process) "ejn-inspector")
                             (let* ((request (car (ejn-helper-protocol-decoder-feed
                                                   viewer-decoder bytes)))
                                    (id (gethash "id" request))
                                    (result (if (string= id "hello")
                                                (emacs-jupyter-notebook-inspect--object
                                                 "version" 1 "capabilities"
                                                 ["array-group-v1"])
                                              (emacs-jupyter-notebook-inspect--object
                                               "state" "visible")))
                                    (response
                                     (emacs-jupyter-notebook-inspect--object
                                      "v" 1 "id" id "ok" t "result" result)))
                               (funcall (process-filter process) process
                                        (ejn-helper-protocol-encode response 65536)))
                           (funcall real-send process bytes)))))
              ;; Ensure the button's asynchronous callback is dispatched with
              ;; the test doubles installed (the card activation itself only
              ;; schedules the real inspector's runtime handoff).
              (with-current-buffer panel
                (goto-char (point-min))
                (should (search-forward "[Inspect]" nil t))
                ;; This is the production card action, not a direct inspector
                ;; call: it acquires the exact publication lease first.
                (button-activate (button-at (1- (point)))))
              ;; Hold the fake Nix process until both button gestures have
              ;; passed through the real waiter deduplication path.
              (should emacs-jupyter-notebook-runtime--viewer-build)
              (should-not viewer-commands)
              (should (cl-some (lambda (line) (string-match-p "Building local viewer" line)) progress))
              (with-current-buffer panel
                (button-activate (button-at (1- (point)))))
              (should (= 1 (length build-commands)))
              (should (cl-some (lambda (line) (string-match-p "Waiting for viewer build" line)) progress))
              (funcall real-send
                       (emacs-jupyter-notebook-runtime--build-process
                        emacs-jupyter-notebook-runtime--viewer-build) "continue\n")
              (should (ejn-inspection-startup-test--wait
                       (lambda ()
                         (and emacs-jupyter-notebook-inspect--state
                              (ejn-inspection-ready
                               emacs-jupyter-notebook-inspect--state)
                              (null (ejn-inspection-active
                                     emacs-jupyter-notebook-inspect--state))))))
              (should (= 1 (length build-commands)))
              (should (= 1 (length viewer-commands)))
              (should (member ".#ejn-viewer" (car build-commands)))
              (should (member "--stdio" (car viewer-commands)))
              (should emacs-jupyter-notebook-runtime-viewer-directory)
              (should (string-match-p "Nix" (with-current-buffer log-buffer
                                               (buffer-string))))
              (should (cl-some (lambda (entry)
                                 (or (string-match-p "[Ss]lice loaded" entry)
                                     (string-match-p "visible" entry)))
                               progress))
              (should (string-match-p "building viewer"
                                      (with-current-buffer log-buffer
                                        (buffer-string))))
              ;; The real successful ownership acknowledgement releases the
              ;; viewer handoff; the panel still owns its source artifact.
              (should (file-exists-p (plist-get publication :path)))
              ;; A repeated inspection uses the already-built viewer and does
              ;; not launch another Nix build.
              (let ((before (length build-commands)))
                (with-current-buffer panel
                  (goto-char (point-max))
                  (search-backward "[Inspect]" nil t)
                  (button-activate (button-at (point))))
                (should (ejn-inspection-startup-test--wait
                         (lambda () (and emacs-jupyter-notebook-inspect--state
                                         (null (ejn-inspection-active
                                                emacs-jupyter-notebook-inspect--state))))))
                (should (= before (length build-commands)))
                (ejn-panel-clear-all panel)
                (should-not (file-exists-p (plist-get publication :path)))
                (with-current-buffer source
                  (should (equal source-before (buffer-string)))
                  (should-not (buffer-modified-p)))))))
      (when emacs-jupyter-notebook-inspect--state
        (ignore-errors (emacs-jupyter-notebook-inspect--stop
                        emacs-jupyter-notebook-inspect--state)))
      (dolist (process created)
        (when (process-live-p process)
          (set-process-sentinel process #'ignore)
          (delete-process process)))
      (when (buffer-live-p log-buffer) (kill-buffer log-buffer))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (buffer-live-p source) (kill-buffer source))
      (emacs-jupyter-notebook-artifacts-retire cap)
      (when (file-directory-p output) (delete-directory output t)))))

(provide 'emacs-jupyter-notebook-inspection-startup-tests)
;;; emacs-jupyter-notebook-inspection-startup-tests.el ends here
