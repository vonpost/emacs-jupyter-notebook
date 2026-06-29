;;; emacs-jupyter-notebook.el --- Remote Jupyter kernels for local source files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (jupyter "1.0") (code-cells "0.5"))
;; Keywords: tools, languages, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Edit normal local source files, evaluate # %% style cells against a
;; remote Jupyter kernel, and reconnect through a durable local registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-cell)
(require 'emacs-jupyter-notebook-registry)
(require 'emacs-jupyter-notebook-connection)
(require 'emacs-jupyter-notebook-ssh)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-jupyter)

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function nil
  "Previous buffer-local value of `imenu-create-index-function'.")

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function-local-p nil
  "Whether `imenu-create-index-function' was buffer-local before enabling.")

(defun emacs-jupyter-notebook--imenu-index ()
  "Return an imenu index of code-cell markers in the current buffer."
  (let ((entries nil)
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward code-cells-boundary-regexp nil t)
        (setq count (1+ count))
        (let* ((title (string-trim
                       (buffer-substring-no-properties
                        (match-end 0) (line-end-position))))
               (name (if (string-empty-p title)
                         (format "Cell %d" count)
                       title)))
          (push (cons name (copy-marker (match-beginning 0) t)) entries))))
    (nreverse entries)))

(defun emacs-jupyter-notebook--enable-imenu ()
  "Use cell markers as the imenu index for the current buffer."
  (setq emacs-jupyter-notebook--saved-imenu-create-index-function
        imenu-create-index-function
        emacs-jupyter-notebook--saved-imenu-create-index-function-local-p
        (local-variable-p 'imenu-create-index-function))
  (setq-local imenu-create-index-function
              #'emacs-jupyter-notebook--imenu-index))

(defun emacs-jupyter-notebook--disable-imenu ()
  "Restore the imenu index function that was active before mode enable."
  (let ((saved-function emacs-jupyter-notebook--saved-imenu-create-index-function)
        (saved-local-p emacs-jupyter-notebook--saved-imenu-create-index-function-local-p))
    (if saved-local-p
        (setq-local imenu-create-index-function saved-function)
      (kill-local-variable 'imenu-create-index-function))
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function)
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function-local-p)))

(defvar-local emacs-jupyter-notebook--client nil
  "Current buffer's emacs-jupyter client object.")

(defvar-local emacs-jupyter-notebook--session-entry nil
  "Current buffer's registry entry plist.")

(defvar-local emacs-jupyter-notebook--tunnel-process nil
  "Current buffer's SSH tunnel process.")

(defvar-local emacs-jupyter-notebook--async-context nil
  "Current buffer's in-progress async start or reconnect context.")

(defvar-local emacs-jupyter-notebook--tunnel-dead nil
  "Non-nil when the current buffer's SSH tunnel has disconnected.")

(defvar-local emacs-jupyter-notebook--kernel-status nil
  "Current kernel status: `busy', `idle', or nil.")

(defvar-local emacs-jupyter-notebook--completion-cache nil
  "Buffer-local LRU cache: hash-table mapping context-key -> reply plist.
Created lazily by `emacs-jupyter-notebook--completion-cache-ensure'.")

(defvar-local emacs-jupyter-notebook--completion-cache-order nil
  "LRU order list for the completion cache.
Front of list is most recently used.  Bounded by
`emacs-jupyter-notebook-completion-cache-size'.")

(defvar-local emacs-jupyter-notebook--completion-pending-key nil
  "In-flight completion request context-key (most recent request only).
W3.3 contract: a reply whose key does not match this is dropped on arrival.")

(defvar-local emacs-jupyter-notebook--completion-request-counter 0
  "Monotonic counter for completion request ids.
Bumped every time a request is sent; replies for stale ids are dropped.")

(defvar-local emacs-jupyter-notebook--completion-pending-id nil
  "Numeric request id of the most recent in-flight completion request.")

(defvar-local emacs-jupyter-notebook--completion-idle-timer nil
  "Idle timer for populating completion cache.")

(defvar-local emacs-jupyter-notebook--inspect-request-id 0
  "Monotonic inspect request id.")

(defvar-local emacs-jupyter-notebook--is-complete-request-id 0
  "Monotonic is-complete request id.")

(defvar-local emacs-jupyter-notebook--evaluation-timer nil
  "Timeout timer for current evaluation.")

(defvar-local emacs-jupyter-notebook--evaluation-request nil
  "Buffer-local plist describing the in-flight execute request, or nil.
Set by `--evaluate' when a request is dispatched and cleared by
`execute_reply' (or by the timeout / `cancel-operation' paths).  Keys:
  :request-id   monotonic counter unique per buffer
  :panel-entry  the panel entry handle so the timeout/cancel paths can
                annotate the right entry
  :cell-key     cell key for the request (nil for region/paragraph/defun)
  :started-at   float-time at dispatch (used for the timeout suffix)")

(defvar-local emacs-jupyter-notebook--evaluation-request-counter 0
  "Monotonic counter producing `:request-id' values for `--evaluation-request'.")

(defvar-local emacs-jupyter-notebook--heartbeat-timer nil
  "Buffer-local repeating timer driving the W4.5 kernel-info heartbeat.")

(defvar-local emacs-jupyter-notebook--heartbeat-misses 0
  "Count of consecutive heartbeat misses on the current buffer.
Reset to 0 on every successful `kernel_info_reply'.")

(defvar-local emacs-jupyter-notebook--heartbeat-inflight nil
  "Token identifying the most recently dispatched heartbeat probe.
The reply callback only updates state when the token still matches; this
prevents a late reply from a previous probe from masking a true miss.")

(defvar-local emacs-jupyter-notebook--heartbeat-timeout-timer nil
  "One-shot timer that fires `--heartbeat-on-miss' when a probe is silent.
Stored so it can be cancelled when the reply lands first, when the user
disables the mode, or when the buffer is killed.  Without this reference
the timer would survive cleanup until it fires.")

(defun emacs-jupyter-notebook--heartbeat-start ()
  "Start the per-buffer kernel-info heartbeat.
The repeating timer fires every `emacs-jupyter-notebook-heartbeat-interval'
seconds and sends a `kernel_info_request' through the configured adapter.
After `emacs-jupyter-notebook-heartbeat-misses-allowed' consecutive misses
the tunnel is flagged dead; the remote kernel is NOT shut down."
  (emacs-jupyter-notebook--heartbeat-cancel)
  (setq emacs-jupyter-notebook--heartbeat-misses 0)
  (let* ((buffer (current-buffer))
         (interval (max 1 (or emacs-jupyter-notebook-heartbeat-interval 20))))
    (setq emacs-jupyter-notebook--heartbeat-timer
          (run-with-timer
           interval interval
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (emacs-jupyter-notebook--heartbeat-tick))))))))

(defun emacs-jupyter-notebook--heartbeat-cancel ()
  "Cancel the buffer-local heartbeat timer and reset its state.
W4.8: also cancels any in-flight per-probe timeout timer so it does not
fire (and miss-bump) after the buffer's heartbeat machinery has been
released by `--release-local-resources' or `--mode-disable-cleanup'."
  (when (timerp emacs-jupyter-notebook--heartbeat-timer)
    (cancel-timer emacs-jupyter-notebook--heartbeat-timer))
  (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
    (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
  (setq emacs-jupyter-notebook--heartbeat-timer nil
        emacs-jupyter-notebook--heartbeat-timeout-timer nil
        emacs-jupyter-notebook--heartbeat-misses 0
        emacs-jupyter-notebook--heartbeat-inflight nil))

(defun emacs-jupyter-notebook--heartbeat-tick ()
  "Fire one kernel-info heartbeat probe with a bounded miss window.
The probe sends a `kernel_info_request' via the configured adapter and
arms a one-shot timeout matching `emacs-jupyter-notebook-heartbeat-timeout'.
The reply (or timeout) routes through `--heartbeat-on-reply' or
`--heartbeat-on-miss', which run in the originating buffer only and only
when the inflight token still matches (so late replies are ignored)."
  (when (and emacs-jupyter-notebook--client
             (not emacs-jupyter-notebook--tunnel-dead))
    (let* ((buffer (current-buffer))
           (token (gensym "ejn-heartbeat-")))
      (setq emacs-jupyter-notebook--heartbeat-inflight token)
      (setq emacs-jupyter-notebook--heartbeat-timeout-timer
            (run-with-timer
             (max 0.1 (or emacs-jupyter-notebook-heartbeat-timeout 3))
             nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
                   (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
                     (emacs-jupyter-notebook--heartbeat-on-miss)))))))
      (condition-case _err
          (emacs-jupyter-notebook-jupyter-kernel-info
           emacs-jupyter-notebook--client
           (lambda (reply _error)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
                   ;; The probe answered first; cancel the pending timeout
                   ;; so it does not double-count as a miss.
                   (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
                     (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
                   (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
                   (if reply
                       (emacs-jupyter-notebook--heartbeat-on-reply)
                     (emacs-jupyter-notebook--heartbeat-on-miss)))))))
        (error
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
               (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
                 (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
               (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
               (emacs-jupyter-notebook--heartbeat-on-miss)))))))))

(defun emacs-jupyter-notebook--heartbeat-on-reply ()
  "Handle a successful heartbeat reply: clear inflight and reset misses."
  (setq emacs-jupyter-notebook--heartbeat-inflight nil
        emacs-jupyter-notebook--heartbeat-misses 0))

(defun emacs-jupyter-notebook--heartbeat-on-miss ()
  "Handle a heartbeat miss: increment the counter; on threshold flag dead.
Per the binding rule the remote kernel is NOT shut down — heartbeat-driven
death sets `--tunnel-dead' locally so `--ensure-client-async' routes the
next evaluation through `--tunnel-reconnect'."
  (setq emacs-jupyter-notebook--heartbeat-inflight nil)
  (cl-incf emacs-jupyter-notebook--heartbeat-misses)
  (when (>= emacs-jupyter-notebook--heartbeat-misses
            (max 1 (or emacs-jupyter-notebook-heartbeat-misses-allowed 2)))
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (setq emacs-jupyter-notebook--kernel-status nil)
    (force-mode-line-update t)
    (display-warning
     'emacs-jupyter-notebook
     (format
      "Heartbeat: %d consecutive kernel-info misses in `%s'; tunnel flagged dead."
      emacs-jupyter-notebook--heartbeat-misses (buffer-name)))
    (emacs-jupyter-notebook--heartbeat-cancel)))

(defun emacs-jupyter-notebook--mode-line-string ()
  "Return the mode line lighter string based on kernel state."
  (cond
   (emacs-jupyter-notebook--tunnel-dead " EJN!")
    ((eq emacs-jupyter-notebook--kernel-status 'busy) " EJN*")
    (t " EJN")))

(defun emacs-jupyter-notebook--tunnel-state ()
  "Return the current tunnel state as a symbol."
  (cond
   (emacs-jupyter-notebook--tunnel-dead 'dead)
   ((and (processp emacs-jupyter-notebook--tunnel-process)
         (process-live-p emacs-jupyter-notebook--tunnel-process))
    'alive)
   (emacs-jupyter-notebook--tunnel-process 'exited)
   (t 'none)))

(defun emacs-jupyter-notebook-status-snapshot ()
  "Return a plist describing the current buffer's notebook engine state."
  (let ((entry emacs-jupyter-notebook--session-entry)
        (context emacs-jupyter-notebook--async-context))
    (list :buffer (buffer-name)
          :file buffer-file-name
          :client (and emacs-jupyter-notebook--client t)
          :kernel-status emacs-jupyter-notebook--kernel-status
          :tunnel-state (emacs-jupyter-notebook--tunnel-state)
          :async-phase (plist-get context :phase)
          :async-error (plist-get context :error)
          :profile (or (plist-get entry :profile)
                       (plist-get (plist-get context :entry) :profile))
          :session-id (or (plist-get entry :session-id)
                          (plist-get context :session-id))
          :remote-host (plist-get entry :remote-host)
          :remote-pid (plist-get entry :remote-pid)
          :remote-connection-file (plist-get entry :remote-connection-file)
          :local-connection-file (plist-get entry :local-connection-file)
          :tunnel-ports (plist-get entry :tunnel-ports))))

(defun emacs-jupyter-notebook--format-status (snapshot)
  "Format status SNAPSHOT for display."
  (string-join
   (list
    (format "Buffer: %s" (plist-get snapshot :buffer))
    (format "File: %s" (or (plist-get snapshot :file) "none"))
    (format "Profile: %s" (or (plist-get snapshot :profile) "none"))
    (format "Session: %s" (or (plist-get snapshot :session-id) "none"))
    (format "Client: %s" (if (plist-get snapshot :client) "connected" "none"))
    (format "Kernel status: %s" (or (plist-get snapshot :kernel-status) "unknown"))
    (format "Tunnel: %s" (plist-get snapshot :tunnel-state))
    (format "Async phase: %s" (or (plist-get snapshot :async-phase) "none"))
    (format "Async error: %s" (or (plist-get snapshot :async-error) "none"))
    (format "Remote host: %s" (or (plist-get snapshot :remote-host) "unknown"))
    (format "Remote PID: %s" (or (plist-get snapshot :remote-pid) "unknown"))
    (format "Remote connection: %s"
            (or (plist-get snapshot :remote-connection-file) "none"))
    (format "Local connection: %s"
            (or (plist-get snapshot :local-connection-file) "none"))
    (format "Tunnel ports: %S" (plist-get snapshot :tunnel-ports))
    (emacs-jupyter-notebook--status-suggestions snapshot))
   "\n"))

(defun emacs-jupyter-notebook--status-suggestions (snapshot)
  "Return actionable next steps for engine state SNAPSHOT."
  (let (suggestions)
    (unless (plist-get snapshot :client)
      (push (concat "No client connected: start with `M-x emacs-jupyter-notebook-start-remote-kernel' "
                    "or reconnect with `M-x emacs-jupyter-notebook-reconnect-remote-kernel'.")
            suggestions))
    (when (memq (plist-get snapshot :tunnel-state) '(dead exited))
      (push "Tunnel is not alive: retry with `M-x emacs-jupyter-notebook-retry-fresh-kernel'."
            suggestions))
    (when-let* ((error (plist-get snapshot :async-error)))
      (push (format "Last async failure: %s" error) suggestions))
    (if suggestions
        (concat "Suggested actions:\n- " (string-join (nreverse suggestions) "\n- "))
      "Suggested actions:\n- Engine looks healthy; evaluate with `C-c C-c'.")))

(defvar emacs-jupyter-notebook-cell-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "p") #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "a") #'emacs-jupyter-notebook-beginning-of-cell)
    (define-key map (kbd "e") #'emacs-jupyter-notebook-end-of-cell)
    (define-key map (kbd "s") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "i") #'emacs-jupyter-notebook-insert-cell-below)
    (define-key map (kbd "I") #'emacs-jupyter-notebook-insert-cell-above)
    (define-key map (kbd "d") #'emacs-jupyter-notebook-delete-cell)
    (define-key map (kbd "k") #'emacs-jupyter-notebook-kill-cell)
    (define-key map (kbd "K") #'emacs-jupyter-notebook-clear-cell)
    (define-key map (kbd "y") #'emacs-jupyter-notebook-duplicate-cell)
    (define-key map (kbd "P") #'emacs-jupyter-notebook-move-cell-up)
    (define-key map (kbd "N") #'emacs-jupyter-notebook-move-cell-down)
    (define-key map (kbd "@") #'code-cells-mark-cell)
    map)
  "Cell editing keymap for `emacs-jupyter-notebook-mode'.")

(defvar emacs-jupyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-jupyter-notebook-evaluate-current-cell)
    (define-key map (kbd "C-c C-r") #'emacs-jupyter-notebook-evaluate-region)
    (define-key map (kbd "C-c C-b") #'emacs-jupyter-notebook-evaluate-buffer)
    (define-key map (kbd "C-c TAB") #'emacs-jupyter-notebook-complete-at-point)
    (define-key map (kbd "C-c C-d") #'emacs-jupyter-notebook-inspect-at-point)
    (define-key map (kbd "C-c C-k") #'emacs-jupyter-notebook-interrupt-kernel)
    (define-key map (kbd "C-c C-s") #'emacs-jupyter-notebook-start-remote-kernel)
    (define-key map (kbd "C-c C-n") #'emacs-jupyter-notebook-reconnect-remote-kernel)
    (define-key map (kbd "C-c C-y") #'emacs-jupyter-notebook-retry-fresh-kernel)
    (define-key map (kbd "C-c C-/") #'emacs-jupyter-notebook-status)
    (define-key map (kbd "C-c C-v") #'emacs-jupyter-notebook-fetch-remote-log)
    (define-key map (kbd "C-c C-q") #'emacs-jupyter-notebook-list-remote-processes)
    (define-key map (kbd "C-c C-w") #'emacs-jupyter-notebook-clean-orphaned-kernels)
    (define-key map (kbd "C-c C-l") #'emacs-jupyter-notebook-clear-results)
    (define-key map (kbd "C-c C-x") #'emacs-jupyter-notebook-cancel-operation)
    (define-key map (kbd "C-c C-o") #'emacs-jupyter-notebook-show-output-panel)
    (define-key map (kbd "C-c C-t") #'emacs-jupyter-notebook-toggle-panel-view)
    (define-key map (kbd "C-c C-f") #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "C-c C-p") #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "C-c C-j") #'emacs-jupyter-notebook-evaluate-current-cell-and-advance)
    (define-key map (kbd "C-c %") emacs-jupyter-notebook-cell-map)
    map)
  "Keymap for `emacs-jupyter-notebook-mode'.")

(defun emacs-jupyter-notebook--cancel-async-context-locally (context)
  "Cancel CONTEXT's in-flight local processes, timers, and temp files.
Does NOT call `--async-kill-remote-kernel' (the remote kernel must outlive any
buffer-level cleanup) and does NOT delete the context's `:local-file' (the
caller may have already promoted it into the registry entry as the offline
reconnect key).  Each disposer is independently best-effort: a raise from one
disposer does not prevent the remaining disposers from running."
  (when context
    (ignore-errors (emacs-jupyter-notebook--async-cancel-timer context))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :launch-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :scp-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :tunnel-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-file
       (plist-get context :remote-copy)))))

(defun emacs-jupyter-notebook--clear-buffer-timers ()
  "Cancel the buffer-local evaluation and completion-idle timers."
  (when (timerp emacs-jupyter-notebook--evaluation-timer)
    (cancel-timer emacs-jupyter-notebook--evaluation-timer))
  (setq emacs-jupyter-notebook--evaluation-timer nil)
  (emacs-jupyter-notebook--completion-cancel-idle-timer))

(defun emacs-jupyter-notebook--evaluation-on-timeout (request-id)
  "Handle evaluation-timer expiry for the request identified by REQUEST-ID.
Called in the source buffer.  If `--evaluation-request' no longer matches
REQUEST-ID (the reply arrived first, or another request superseded it) the
timeout is a no-op so a stale closure cannot interrupt the wrong thing.

W5.1 plumbing only: messages the user.  W5.2 wires interrupt + panel
annotation onto this same hook."
  (let ((request emacs-jupyter-notebook--evaluation-request))
    (when (and request
               (eq (plist-get request :request-id) request-id))
      (message "Evaluation timed out after %ss. Kernel may be busy or unresponsive. Use C-c C-k to interrupt."
               emacs-jupyter-notebook-evaluation-timeout)
      (setq emacs-jupyter-notebook--kernel-status 'busy)
      (force-mode-line-update t))))

(defun emacs-jupyter-notebook--release-local-resources ()
  "Drop the current buffer's local kernel handles without touching durable state.
Cancels the in-flight async context's local processes and timers, tears down the
SSH tunnel process and its stderr buffer, cancels the evaluation timer and the
completion idle timer, and drops the buffer-local Jupyter client handle.

This is the disposer used by `kill-buffer-hook' and by the mode-disable
cleanup.  It does not call `jupyter-shutdown', does not call
`--cleanup-remote-entry', does not remove the registry entry, does not delete
the local connection file, and does not touch the remote kernel.  The registry
entry and the remote kernel are the durable reconnect surface and must survive
buffer kill and mode disable.

Each disposer is independently best-effort: a raise from one does not prevent
the remaining disposers from running, and the final state-clearing setq always
executes."
  (ignore-errors
    (emacs-jupyter-notebook--cancel-async-context-locally
     emacs-jupyter-notebook--async-context))
  (ignore-errors (emacs-jupyter-notebook--clear-buffer-timers))
  (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
  (ignore-errors
    (when (processp emacs-jupyter-notebook--tunnel-process)
      (emacs-jupyter-notebook--async-delete-process
       emacs-jupyter-notebook--tunnel-process)))
  (setq emacs-jupyter-notebook--client nil
        emacs-jupyter-notebook--async-context nil
        emacs-jupyter-notebook--tunnel-process nil
        emacs-jupyter-notebook--tunnel-dead nil
        emacs-jupyter-notebook--kernel-status nil
        emacs-jupyter-notebook--evaluation-request nil
        emacs-jupyter-notebook--completion-cache nil
        emacs-jupyter-notebook--completion-cache-order nil
        emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil
        emacs-jupyter-notebook--completion-request-counter 0))

(defun emacs-jupyter-notebook--mode-disable-cleanup ()
  "Cleanup invoked from the mode-disable branch.
Releases the buffer's LOCAL kernel handles via `--release-local-resources':
cancels the in-flight async context, clears buffer-local timers, disposes
the SSH tunnel process and its stderr buffer, and drops the buffer-local
client handle.  Does NOT touch the session entry, the registry, the remote
kernel, or the local connection file — those are durable reconnect surfaces
and survive mode disable.  Errors are swallowed so disable cannot raise."
  (condition-case err
      (emacs-jupyter-notebook--release-local-resources)
    (error
     (message "emacs-jupyter-notebook: mode-disable cleanup failed: %s"
              (error-message-string err)))))

(defun emacs-jupyter-notebook--kill-buffer-hook ()
  "Buffer-local `kill-buffer-hook' that releases local kernel resources.
Errors are swallowed so a failure here cannot prevent the buffer from being
killed.  W2.9 contract: also kills the source buffer's output panel;
killing the panel alone does not touch the kernel or registry (the
panel's own kill-buffer-hook only cancels its flush timer)."
  (condition-case err
      (emacs-jupyter-notebook--release-local-resources)
    (error
     (message "emacs-jupyter-notebook: kill-buffer cleanup failed: %s"
              (error-message-string err))))
  (condition-case err
      (emacs-jupyter-notebook--kill-panel)
    (error
     (message "emacs-jupyter-notebook: panel kill failed: %s"
              (error-message-string err)))))

;;;###autoload
(define-minor-mode emacs-jupyter-notebook-mode
  "Minor mode for evaluating local source cells in remote Jupyter kernels."
  :lighter (:eval (emacs-jupyter-notebook--mode-line-string))
  :keymap emacs-jupyter-notebook-mode-map
  (if emacs-jupyter-notebook-mode
      (progn
        (code-cells-mode 1)
        (add-hook 'completion-at-point-functions
                  #'emacs-jupyter-notebook-completion-at-point nil t)
        (add-hook 'kill-buffer-hook
                  #'emacs-jupyter-notebook--kill-buffer-hook nil t)
        (emacs-jupyter-notebook--enable-imenu)
        (emacs-jupyter-notebook--completion-start-idle-timer))
    (code-cells-mode -1)
    (remove-hook 'completion-at-point-functions
                 #'emacs-jupyter-notebook-completion-at-point t)
    (remove-hook 'kill-buffer-hook
                 #'emacs-jupyter-notebook--kill-buffer-hook t)
    (emacs-jupyter-notebook-fringe-clear-all)
    (emacs-jupyter-notebook--disable-imenu)
    (emacs-jupyter-notebook--mode-disable-cleanup)))

(add-to-list 'code-cells-eval-region-commands
              '(emacs-jupyter-notebook-mode . emacs-jupyter-notebook-evaluate-region))

(defun emacs-jupyter-notebook--clear-cell-region-artifacts (_beg _end)
  "Clear source-side fringe indicators in the BEG..END region.
With the W2 panel design the source buffer carries no result text, so
only the fringe indicators need clearing on a structural cell edit."
  (emacs-jupyter-notebook-fringe-clear-all))

(defun emacs-jupyter-notebook--clear-all-cell-artifacts ()
  "Clear all source-side fringe indicators before structural cell edits."
  (emacs-jupyter-notebook-fringe-clear-all))

(defun emacs-jupyter-notebook--goto-live-cell-start ()
  "Move point to the current cell body when the buffer is nonempty."
  (unless (= (point-min) (point-max))
    (emacs-jupyter-notebook-cell-goto-code-start)))

(defun emacs-jupyter-notebook-beginning-of-cell ()
  "Move to the first editable line of the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-end-of-cell ()
  "Move to the end of the current cell body."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-end))

(defun emacs-jupyter-notebook-insert-cell-below ()
  "Insert an empty cell below the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-below))

(defun emacs-jupyter-notebook-insert-cell-above ()
  "Insert an empty cell above the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-above))

(defun emacs-jupyter-notebook-delete-cell ()
  "Delete the current cell without touching the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-kill-cell ()
  "Kill the current cell, saving it in the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (kill-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-clear-cell ()
  "Delete the current cell body while keeping the cell marker."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (goto-char beg)))

(defun emacs-jupyter-notebook-duplicate-cell ()
  "Duplicate the current cell below itself and move to the duplicate."
  (interactive)
  (pcase-let* ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds))
               (text (buffer-substring beg end)))
    (goto-char end)
    (let ((start (point)))
      (insert text)
      (emacs-jupyter-notebook-cell-goto-code-start start))))

(defun emacs-jupyter-notebook-move-cell-up (&optional arg)
  "Move the current cell up ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-up (or arg 1))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-move-cell-down (&optional arg)
  "Move the current cell down ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-down (or arg 1))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-evaluate-current-cell-and-advance ()
  "Evaluate the current cell, then move to the next cell when one exists."
  (interactive)
  (emacs-jupyter-notebook-evaluate-current-cell)
  (condition-case nil
      (emacs-jupyter-notebook-forward-cell 1)
    (user-error nil)))

(defun emacs-jupyter-notebook--new-session-id (&optional hint)
  "Return a locally unique session id string, optionally containing HINT."
  (let ((base (or hint (format "%s" (emacs-pid)))))
    (format "%s-%s" base
            (md5 (format "%s:%s:%s:%s"
                         (current-time-string) (float-time) (random) (emacs-pid))))))

(defun emacs-jupyter-notebook--timestamp ()
  "Return an ISO-like timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun emacs-jupyter-notebook--read-profile-name ()
  "Read a profile name for interactive commands."
  (let ((names (mapcar (lambda (entry) (format "%s" (car entry)))
                       emacs-jupyter-notebook-remote-profiles)))
    (if names
        (completing-read "Remote profile: " names nil nil nil nil
                         emacs-jupyter-notebook-default-profile)
      emacs-jupyter-notebook-default-profile)))

(defun emacs-jupyter-notebook--read-host-profile (profile-name)
  "Return PROFILE-NAME profile, prompting for :host if needed."
  (let ((profile (emacs-jupyter-notebook-ssh-profile profile-name)))
    (unless (or (plist-get profile :host) (plist-get profile :remote-host))
      (setq profile (plist-put profile :host (read-string "Remote host: "))))
    profile))

(defun emacs-jupyter-notebook--parse-pid (output)
  "Parse a remote background PID from OUTPUT.
Match the W4.2 sentinel `EJN_PID=<digits>' anchored on its own line so
spurious numbers in an SSH banner or MOTD cannot poison the parse."
  (when (string-match "^EJN_PID=\\([0-9]+\\)$" output)
    (string-to-number (match-string 1 output))))

(defun emacs-jupyter-notebook--entry-profile (entry)
  "Return a profile plist reconstructed from registry ENTRY."
  (emacs-jupyter-notebook-ssh-profile
   (list :profile (plist-get entry :profile)
         :host (plist-get entry :remote-host)
         :remote-cwd (plist-get entry :remote-cwd)
          :remote-cache-dir (file-name-directory
                             (plist-get entry :remote-connection-file))
          :kernelspec (plist-get entry :kernelspec)
          :jupyter-command (plist-get entry :jupyter-command))))

(defun emacs-jupyter-notebook--current-file-registry-entry ()
  "Return the latest registry entry for the current buffer's file, or nil."
  (when buffer-file-name
    (emacs-jupyter-notebook-registry-latest-for-file
     buffer-file-name
     (emacs-jupyter-notebook-registry-load))))

(defun emacs-jupyter-notebook--remove-registry-entry (entry)
  "Remove ENTRY from the durable registry when it has an identity key."
  (when-let* ((key (or (plist-get entry :session-id)
                       (plist-get entry :profile))))
    (emacs-jupyter-notebook-registry-remove-entry key)))

(defun emacs-jupyter-notebook--read-registry-entry ()
  "Read and return a registry entry for reconnect."
  (if-let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
      entry
    (let ((entries (emacs-jupyter-notebook-registry-load)))
      (unless entries
        (user-error "No kernel sessions found in registry"))
      (let* ((choices (mapcar (lambda (entry)
                                (cons (format "%s  %s  %s"
                                              (or (plist-get entry :display-name) "kernel")
                                              (or (plist-get entry :profile) "")
                                              (or (plist-get entry :session-id) ""))
                                      entry))
                              entries))
             (choice (completing-read "Reconnect kernel: " choices nil t)))
        (or (cdr (assoc choice choices))
            (error "No registry entry selected"))))))

;; W4.7: the synchronous `--retrieve-connection-file' that polled with
;; `sleep-for' has been removed.  The async retrieve in
;; `--async-retrieve' / `--async-retrieve-attempt' is the only path; it
;; uses a `run-with-timer' loop and never blocks the UI.

(defun emacs-jupyter-notebook--start-tunnel (profile remote-ports local-ports session-id)
  "Start an SSH tunnel for PROFILE from LOCAL-PORTS to REMOTE-PORTS."
  (let* ((argv (emacs-jupyter-notebook-ssh-tunnel-command
                profile remote-ports local-ports))
         (name (format "emacs-jupyter-notebook-tunnel-%s" session-id)))
    (emacs-jupyter-notebook-ssh-start-process
     name argv
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (message "Jupyter tunnel %s: %s" process (string-trim event)))))))

(defun emacs-jupyter-notebook--local-port-open-p (port)
  "Return non-nil when PORT accepts a TCP connection on localhost."
  (condition-case nil
      (let ((proc (open-network-stream
                   (format "emacs-jupyter-notebook-port-%s" port)
                   nil "127.0.0.1" port)))
        (delete-process proc)
        t)
    (error nil)))

;; W4.7: the synchronous `--wait-for-tunnel' that blocked the UI with
;; `sleep-for' has been removed.  The async tunnel-readiness poller in
;; `--async-wait-tunnel-tick' is the only path; it reschedules itself via
;; `run-with-timer' until all ports open or the timeout expires.

(defun emacs-jupyter-notebook--process-output (process)
  "Return PROCESS output buffer contents."
  (string-join
   (delq nil
         (mapcar (lambda (buffer)
                   (when (and buffer (buffer-live-p buffer))
                     (with-current-buffer buffer
                       (let ((text (string-trim (buffer-string))))
                         (unless (string-empty-p text)
                           text)))))
                 (list (process-buffer process)
                       (process-get process 'emacs-jupyter-notebook-stderr-buffer))))
   "\n"))

(defun emacs-jupyter-notebook--install-tunnel-sentinel (process buffer)
  "Install a sentinel on PROCESS that marks the tunnel dead in BUFFER."
  (if (not (process-live-p process))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq emacs-jupyter-notebook--tunnel-dead t)
          (setq emacs-jupyter-notebook--kernel-status nil)
          (force-mode-line-update t)))
    (set-process-sentinel
     process
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq emacs-jupyter-notebook--tunnel-dead t)
             (setq emacs-jupyter-notebook--kernel-status nil)
             (force-mode-line-update t))))))))

;;; Async machinery

(defun emacs-jupyter-notebook--async-new-context (&rest properties)
  "Return a new async operation context initialized with PROPERTIES."
  (let ((context (list :phase nil
                       :profile nil
                       :entry nil
                       :session-id nil
                       :launch nil
                       :launch-process nil
                       :scp-process nil
                       :scp-attempt 0
                       :tunnel-process nil
                       :local-ports nil
                       :remote-ports nil
                       :connection nil
                       :remote-copy nil
                       :local-file nil
                       :timer nil
                       :deadline nil
                       :callback nil
                       :error-callback nil
                       :origin-buffer nil
                       :owns-kernel nil
                       :error nil)))
    (while properties
      (setq context (plist-put context (pop properties) (pop properties))))
    context))

(defun emacs-jupyter-notebook--async-put (context property value)
  "Set PROPERTY to VALUE in async CONTEXT and store it in its buffer."
  (setq context (plist-put context property value))
  (when-let* ((buffer (plist-get context :origin-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-jupyter-notebook--async-context context))))
  context)

(defun emacs-jupyter-notebook--async-get (context property)
  "Return PROPERTY from async CONTEXT."
  (plist-get context property))

(defun emacs-jupyter-notebook--async-in-progress-p ()
  "Return non-nil when an async operation is in progress."
  (and emacs-jupyter-notebook--async-context
       (not (memq (plist-get emacs-jupyter-notebook--async-context :phase)
                  '(done error nil)))))

(defun emacs-jupyter-notebook--ensure-no-async-operation ()
  "Signal when the current buffer already has an async operation running."
  (when (emacs-jupyter-notebook--async-in-progress-p)
    (user-error
     "A Jupyter operation is already in progress; use M-x emacs-jupyter-notebook-cancel-operation to cancel it")))

(defun emacs-jupyter-notebook--active-session-p ()
  "Return non-nil when the current buffer already owns connection state."
  (or emacs-jupyter-notebook--client
      emacs-jupyter-notebook--session-entry
      (and (processp emacs-jupyter-notebook--tunnel-process)
           (process-live-p emacs-jupyter-notebook--tunnel-process))))

(defun emacs-jupyter-notebook--ensure-clean-before-start ()
  "Ensure the current buffer can start or reconnect a kernel without leaking one."
  (when (emacs-jupyter-notebook--active-session-p)
    (user-error "A kernel is already active; shut it down or retry fresh first")))

(defun emacs-jupyter-notebook--async-add-callback (context callback)
  "Add CALLBACK to CONTEXT's callback chain."
  (let ((existing (plist-get context :callback)))
    (emacs-jupyter-notebook--async-put
     context :callback
     (if existing
         (lambda (ctx)
           (funcall existing ctx)
           (funcall callback ctx))
       callback))))

(defun emacs-jupyter-notebook--async-add-error-callback (context callback)
  "Add error CALLBACK to CONTEXT's error-callback chain."
  (let ((existing (plist-get context :error-callback)))
    (emacs-jupyter-notebook--async-put
     context :error-callback
     (if existing
         (lambda (ctx err)
           (funcall existing ctx err)
           (funcall callback ctx err))
       callback))))

(defun emacs-jupyter-notebook--async-buffer-live-p (context)
  "Return non-nil when CONTEXT's origin buffer is live."
  (buffer-live-p (plist-get context :origin-buffer)))

(defun emacs-jupyter-notebook--async-message (_context format-string &rest args)
  "Report async progress using FORMAT-STRING and ARGS."
  (apply #'message (concat "emacs-jupyter-notebook: " format-string) args))

(defun emacs-jupyter-notebook--async-cancel-timer (context)
  "Cancel CONTEXT's timer if present."
  (when-let* ((timer (plist-get context :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (emacs-jupyter-notebook--async-put context :timer nil))

(defun emacs-jupyter-notebook--async-delete-process (process)
  "Delete PROCESS and the buffers it carries.
Kills the process if it is still live, then disposes of both its stdout
`process-buffer' and the stderr buffer stashed under the
`emacs-jupyter-notebook-stderr-buffer' process property.  Without the second
disposer, every SSH launch/scp/tunnel process leaked a hidden \" *NAME stderr*\"
buffer per session (see ssh.el)."
  (when (processp process)
    (when (process-live-p process)
      (delete-process process))
    (let ((stdout (process-buffer process))
          (stderr (process-get process 'emacs-jupyter-notebook-stderr-buffer)))
      (when (buffer-live-p stdout)
        (kill-buffer stdout))
      (when (buffer-live-p stderr)
        (kill-buffer stderr)))))

(defun emacs-jupyter-notebook--async-delete-file (file)
  "Delete FILE if it exists."
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun emacs-jupyter-notebook--async-kill-remote-kernel (context)
  "Start a best-effort asynchronous remote-kernel cleanup for CONTEXT."
  (when (plist-get context :owns-kernel)
    (when-let* ((entry (plist-get context :entry))
                (connection-file (plist-get entry :remote-connection-file)))
      (ignore-errors
        (emacs-jupyter-notebook-ssh-start-process
         (format "emacs-jupyter-notebook-cleanup-%s"
                 (or (plist-get context :session-id) "kernel"))
         (emacs-jupyter-notebook-ssh-build-remote-cleanup
          (plist-get context :profile) connection-file))))))

(defun emacs-jupyter-notebook--cleanup-remote-entry (entry)
  "Start best-effort asynchronous cleanup for remote kernel ENTRY."
  (when-let* ((connection-file (plist-get entry :remote-connection-file)))
    (ignore-errors
      (emacs-jupyter-notebook-ssh-start-process
       (format "emacs-jupyter-notebook-cleanup-%s"
               (or (plist-get entry :session-id) "kernel"))
       (emacs-jupyter-notebook-ssh-build-remote-cleanup
        (emacs-jupyter-notebook--entry-profile entry) connection-file)))))

(defun emacs-jupyter-notebook--enrich-ssh-error (error-data)
  "Return ERROR-DATA prefixed with a W4.3 SSH-error classification when applicable.
When ERROR-DATA is a string, the SSH-stderr classifier inspects it; any
non-`unknown' kind is surfaced as `<KIND>: <text>\\nHint: <actionable hint>'.
Non-string or unrecognized errors are returned verbatim."
  (if (stringp error-data)
      (let* ((classification (emacs-jupyter-notebook-ssh-classify-stderr error-data))
             (kind (plist-get classification :kind))
             (hint (plist-get classification :hint)))
        (if (eq kind 'unknown)
            error-data
          (format "%s: %s\nHint: %s"
                  (upcase (symbol-name kind))
                  error-data
                  hint)))
    error-data))

(defun emacs-jupyter-notebook--async-fail (context error-data)
  "Move CONTEXT to error state with ERROR-DATA and clean up.

Releases only LOCAL resources: cancels the deadline timer, disposes the
launch/scp/tunnel processes (and their stderr buffers), and removes the
fetched :remote-copy.  Does NOT terminate the remote kernel, even when
`:owns-kernel' is set: the binding rule forbids automatic remote-kernel
cleanup from async failure paths.  Does NOT delete `:local-file' either —
once `--async-connect-finalize' runs that same path becomes the registry
entry's `:local-connection-file' (the offline reconnect key), and this
function is also called from failure paths that may race with that
promotion.  A small temp-file leak is acceptable; loss of the reconnect
key is not.

ERROR-DATA is passed through `--enrich-ssh-error' (W4.3) so the
user-visible message carries a kind label and an actionable hint when the
underlying stderr matches a known SSH failure pattern."
  (let ((error-data (emacs-jupyter-notebook--enrich-ssh-error error-data)))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'error))
    (setq context (emacs-jupyter-notebook--async-put context :error error-data))
    (setq context (emacs-jupyter-notebook--async-cancel-timer context))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :launch-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :scp-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :tunnel-process))
    ;; W4.8: dispose the W4.4 PID-probe process too so its stdout/stderr
    ;; buffers do not leak when the probe itself fails the context.
    (emacs-jupyter-notebook--async-delete-process (plist-get context :probe-process))
    (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
    (if-let ((callback (plist-get context :error-callback)))
        (funcall callback context error-data)
      (display-warning 'emacs-jupyter-notebook
                       (format "%s" error-data)))
    context))

(defun emacs-jupyter-notebook--async-process-failed-p (process)
  "Return non-nil when PROCESS exited unsuccessfully."
  (or (eq (process-status process) 'signal)
      (not (zerop (process-exit-status process)))))

(defun emacs-jupyter-notebook--async-launch (context)
  "Asynchronously launch the remote kernel for CONTEXT."
  (let* ((launch (plist-get context :launch))
         (session-id (plist-get context :session-id))
         (process
          (emacs-jupyter-notebook-ssh-start-process
           (format "emacs-jupyter-notebook-launch-%s" session-id)
           (plist-get launch :argv)
           (lambda (process _event)
             (emacs-jupyter-notebook--async-launch-sentinel context process)))))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'launch))
    (setq context (emacs-jupyter-notebook--async-put context :launch-process process))
    (emacs-jupyter-notebook--async-message context "starting remote kernel %s" session-id)
    context))

(defun emacs-jupyter-notebook--async-launch-sentinel (context process)
  "Advance CONTEXT after remote launch PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (if (emacs-jupyter-notebook--async-process-failed-p process)
        (emacs-jupyter-notebook--async-fail
         context (format "Remote kernel launch failed: %s"
                         (emacs-jupyter-notebook--process-output process)))
      (let ((pid (emacs-jupyter-notebook--parse-pid
                  (emacs-jupyter-notebook--process-output process))))
        (if (not pid)
            (emacs-jupyter-notebook--async-fail
             context "Remote kernel launch did not report a PID")
          (let ((entry (plist-put (copy-sequence (plist-get context :entry))
                                  :remote-pid pid)))
            (setq context (emacs-jupyter-notebook--async-put context :entry entry))
            (emacs-jupyter-notebook--async-retrieve context)))))))

(defun emacs-jupyter-notebook--async-retrieve (context)
  "Begin asynchronous connection-file retrieval for CONTEXT."
  (unless (plist-get context :remote-copy)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :remote-copy
           (make-temp-file "emacs-jupyter-notebook-remote-" nil ".json"))))
  (unless (plist-get context :local-file)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :local-file
           (make-temp-file "emacs-jupyter-notebook-local-" nil ".json"))))
  (setq context (emacs-jupyter-notebook--async-put context :phase 'retrieve))
  (emacs-jupyter-notebook--async-retrieve-attempt context))

(defun emacs-jupyter-notebook--async-retrieve-attempt (context)
  "Start one asynchronous SCP attempt for CONTEXT."
  (let ((attempt (1+ (or (plist-get context :scp-attempt) 0))))
    (if (> attempt emacs-jupyter-notebook-connection-retrieve-attempts)
        (emacs-jupyter-notebook--async-fail
         context "Timed out retrieving remote Jupyter connection file")
      (let* ((entry (plist-get context :entry))
             (argv (emacs-jupyter-notebook-ssh-scp-from-command
                    (plist-get context :profile)
                    (plist-get entry :remote-connection-file)
                    (plist-get context :remote-copy)))
             process)
        (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
        (setq context (emacs-jupyter-notebook--async-put context :scp-attempt attempt))
        (setq process
              (emacs-jupyter-notebook-ssh-start-process
               (format "emacs-jupyter-notebook-scp-%s"
                       (plist-get context :session-id))
               argv
               (lambda (process _event)
                 (emacs-jupyter-notebook--async-scp-sentinel context process))))
        (setq context (emacs-jupyter-notebook--async-put context :scp-process process))
        (emacs-jupyter-notebook--async-message
         context "retrieving connection file, attempt %d" attempt)
        context))))

(defun emacs-jupyter-notebook--async-retrieve-retry (context reason)
  "Schedule another connection-file retrieval for CONTEXT because of REASON."
  (if (>= (or (plist-get context :scp-attempt) 0)
          emacs-jupyter-notebook-connection-retrieve-attempts)
      (emacs-jupyter-notebook--async-fail context reason)
    (let ((timer (run-at-time
                  emacs-jupyter-notebook-connection-retrieve-delay nil
                  #'emacs-jupyter-notebook--async-retrieve-attempt context)))
      (emacs-jupyter-notebook--async-put context :timer timer))))

(defun emacs-jupyter-notebook--async-scp-sentinel (context process)
  "Advance CONTEXT after SCP PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (cond
     ((emacs-jupyter-notebook--async-process-failed-p process)
      (emacs-jupyter-notebook--async-retrieve-retry
       context (format "SCP failed: %s"
                       (emacs-jupyter-notebook--process-output process))))
     (t
      (condition-case err
          (let* ((connection
                  (emacs-jupyter-notebook-connection-read-file
                   (plist-get context :remote-copy)))
                 (remote-ports
                  (emacs-jupyter-notebook-connection-ports connection)))
            (emacs-jupyter-notebook--async-delete-file
             (plist-get context :remote-copy))
            (setq context (emacs-jupyter-notebook--async-put
                           context :connection connection))
            (setq context (emacs-jupyter-notebook--async-put
                           context :remote-ports remote-ports))
            (emacs-jupyter-notebook--async-tunnel context))
        (error
         (emacs-jupyter-notebook--async-retrieve-retry
          context (error-message-string err))))))))

(defun emacs-jupyter-notebook--async-tunnel (context)
  "Start local SSH tunnels for CONTEXT."
  (let* ((connection (plist-get context :connection))
         (remote-ports (plist-get context :remote-ports))
         (local-ports (emacs-jupyter-notebook-connection-allocate-local-ports))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports
                     connection local-ports))
         (tunnel (emacs-jupyter-notebook--start-tunnel
                  (plist-get context :profile)
                  remote-ports local-ports
                  (plist-get context :session-id))))
    (emacs-jupyter-notebook-connection-write-file rewritten (plist-get context :local-file))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'tunnel))
    (setq context (emacs-jupyter-notebook--async-put context :local-ports local-ports))
    (setq context (emacs-jupyter-notebook--async-put context :tunnel-process tunnel))
    (when (emacs-jupyter-notebook--async-buffer-live-p context)
      (with-current-buffer (plist-get context :origin-buffer)
        (emacs-jupyter-notebook--install-tunnel-sentinel tunnel (current-buffer))))
    (setq context (emacs-jupyter-notebook--async-put
                   context :deadline
                   (+ (float-time) emacs-jupyter-notebook-tunnel-wait-timeout)))
    (emacs-jupyter-notebook--async-message context "waiting for SSH tunnel ports")
    (emacs-jupyter-notebook--async-wait-tunnel-tick context)))

(defun emacs-jupyter-notebook--async-wait-tunnel-tick (context)
  "Check tunnel readiness for CONTEXT and reschedule if needed."
  (when (eq (plist-get context :phase) 'tunnel)
    (let* ((tunnel (plist-get context :tunnel-process))
           (local-ports (plist-get context :local-ports))
           (pending
            (cl-remove-if
             (lambda (key)
               (emacs-jupyter-notebook--local-port-open-p
                (plist-get local-ports key)))
             emacs-jupyter-notebook-connection-port-keys)))
      (cond
       ((not (process-live-p tunnel))
        (emacs-jupyter-notebook--async-fail
         context "Jupyter SSH tunnel exited before ports were ready"))
       ((null pending)
        (emacs-jupyter-notebook--async-connect context))
       ((>= (float-time) (plist-get context :deadline))
        (emacs-jupyter-notebook--async-fail
         context
         (format "Timed out waiting for Jupyter SSH tunnel ports: %s"
                 (mapconcat #'symbol-name pending ", "))))
       (t
        (let ((timer (run-at-time
                      emacs-jupyter-notebook-tunnel-wait-delay nil
                      #'emacs-jupyter-notebook--async-wait-tunnel-tick context)))
          (emacs-jupyter-notebook--async-put context :timer timer)))))))

(defun emacs-jupyter-notebook--async-connect-finalize (buffer entry local-ports local-file client)
  "Finalize the async connect for BUFFER with CLIENT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect)
        (emacs-jupyter-notebook--async-cancel-timer
         emacs-jupyter-notebook--async-context)
        (if (not client)
            (emacs-jupyter-notebook--async-fail
             emacs-jupyter-notebook--async-context
             "Kernel did not respond to kernel_info_request")
          (setq emacs-jupyter-notebook--client client)
          (setq emacs-jupyter-notebook--tunnel-dead nil)
          (setq entry (plist-put entry :tunnel-ports local-ports))
          (setq entry (plist-put entry :local-connection-file local-file))
          (setq emacs-jupyter-notebook--session-entry entry)
          ;; W4.5: arm the kernel-info heartbeat now that the client is live.
          (emacs-jupyter-notebook--heartbeat-start)
          (let ((ctx emacs-jupyter-notebook--async-context))
            (setq ctx (emacs-jupyter-notebook--async-put ctx :entry entry))
            (setq ctx (emacs-jupyter-notebook--async-put ctx :phase 'done))
            (emacs-jupyter-notebook-registry-save-entry entry)
            (emacs-jupyter-notebook--async-message
             ctx "connected to remote Jupyter kernel %s"
             (plist-get ctx :session-id))
            (let ((cb (plist-get ctx :callback)))
              (when cb
                (funcall cb ctx)))))))))

(defun emacs-jupyter-notebook--async-connect-timeout (buffer)
  "Check if async connect for BUFFER has timed out."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect)
        (emacs-jupyter-notebook--async-fail
         emacs-jupyter-notebook--async-context
         "Timed out waiting for kernel_info_reply")))))

(defun emacs-jupyter-notebook--async-connect (context)
  "Connect emacs-jupyter to the ready tunnel described by CONTEXT."
  (setq context (emacs-jupyter-notebook--async-put context :phase 'connect))
  (setq context (emacs-jupyter-notebook--async-cancel-timer context))
  (if (not (emacs-jupyter-notebook--async-buffer-live-p context))
      (emacs-jupyter-notebook--async-fail context "Origin buffer was killed")
    (with-current-buffer (plist-get context :origin-buffer)
      (condition-case err
          (let* ((entry (copy-sequence (plist-get context :entry)))
                 (local-ports (plist-get context :local-ports))
                 (local-file (plist-get context :local-file))
                 (buffer (current-buffer)))
            (emacs-jupyter-notebook--async-message
             context "connecting emacs-jupyter client")
            (setq emacs-jupyter-notebook--tunnel-process
                  (plist-get context :tunnel-process))
            (emacs-jupyter-notebook--install-tunnel-sentinel
              emacs-jupyter-notebook--tunnel-process buffer)
            (let ((timer (run-at-time
                          emacs-jupyter-notebook-jupyter-connect-timeout nil
                          #'emacs-jupyter-notebook--async-connect-timeout
                          buffer)))
              (setq context (emacs-jupyter-notebook--async-put context :timer timer)))
            (emacs-jupyter-notebook-jupyter-connect-async
             local-file
             (lambda (client)
               (emacs-jupyter-notebook--async-connect-finalize
                buffer entry local-ports local-file client)))
            context)
        (error
         (emacs-jupyter-notebook--async-fail
          context (error-message-string err)))))))

(defun emacs-jupyter-notebook--async-start-context (profile entry session-id launch
                                                     &optional callback error-callback)
  "Create and store an async start context.
PROFILE, ENTRY, SESSION-ID, and LAUNCH describe the kernel.
CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'launch
                  :profile profile
                  :entry entry
                  :session-id session-id
                  :launch launch
                  :origin-buffer (current-buffer)
                  :owns-kernel t
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook--async-reconnect-context (profile entry
                                                        &optional callback error-callback)
  "Create and store an async reconnect context for PROFILE and ENTRY.
CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'retrieve
                  :profile profile
                  :entry entry
                  :session-id (plist-get entry :session-id)
                  :origin-buffer (current-buffer)
                  :owns-kernel nil
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    context))

(defun emacs-jupyter-notebook--tunnel-reconnect (buffer &optional callback error-callback)
  "Reconnect the tunnel for BUFFER asynchronously.
CALLBACK is called on success, ERROR-CALLBACK on failure."
  (when-let* ((entry emacs-jupyter-notebook--session-entry))
    (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
           (context (emacs-jupyter-notebook--async-reconnect-context
                     profile entry callback error-callback)))
      (with-current-buffer buffer
        (setq emacs-jupyter-notebook--async-context context))
      (emacs-jupyter-notebook--async-probe-pid-alive context))))

(defun emacs-jupyter-notebook--async-probe-pid-alive (context)
  "W4.4: probe the remote kernel PID for CONTEXT before reconnect.
The registry entry MUST carry a `:remote-pid' (W4.2 sentinel).  When the
PID is alive (`kill -0 <pid>' exits 0) the context advances to
`--async-retrieve'; otherwise the context fails with a `kernel-dead'
explanation pointing the user at `start-remote-kernel'.  The registry
entry is NOT removed — the user may inspect it or clean it explicitly
via `clean-orphaned-kernels' (per the binding rule that only the
explicit user commands may remove durable state).

W4.8: an entry without `:remote-pid' is a session from before W4.2
landed; per the no-backwards-compat rule we surface a clear failure
rather than silently bypass the probe.  The probe process itself is
stored in the context and disposed in the sentinel via
`--async-delete-process' so its stdout/stderr buffers do not leak."
  (let* ((entry (plist-get context :entry))
         (pid (and entry (plist-get entry :remote-pid)))
         (profile (plist-get context :profile))
         (buffer (plist-get context :origin-buffer)))
    (cond
     ((not pid)
      (emacs-jupyter-notebook--async-fail
       (emacs-jupyter-notebook--async-put context :error-kind 'no-pid)
       (concat "This registry entry has no recorded PID (pre-W4.2 session). "
               "Start a fresh kernel with "
               "`M-x emacs-jupyter-notebook-start-remote-kernel'.")))
     (t
      (setq context (emacs-jupyter-notebook--async-put context :phase 'probe))
      (let* ((argv (emacs-jupyter-notebook-ssh-build-pid-alive profile pid))
             (probe-name (format "emacs-jupyter-notebook-pid-probe-%s"
                                 (or (plist-get context :session-id) pid)))
             (sentinel
              (lambda (process _event)
                (when (memq (process-status process) '(exit signal))
                  (let ((ok (and (eq (process-status process) 'exit)
                                 (zerop (process-exit-status process)))))
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (when (eq emacs-jupyter-notebook--async-context context)
                          (emacs-jupyter-notebook--async-put
                           context :probe-process nil)
                          (emacs-jupyter-notebook--async-delete-process process)
                          (if ok
                              (emacs-jupyter-notebook--async-retrieve context)
                            (emacs-jupyter-notebook--async-fail
                             (emacs-jupyter-notebook--async-put
                              context :error-kind 'kernel-dead)
                             (format
                              (concat
                               "Remote kernel %s is no longer alive on %s. "
                               "Start a new one with "
                               "`M-x emacs-jupyter-notebook-start-remote-kernel'.")
                              pid
                              (or (plist-get entry :remote-host)
                                  "the remote host")))))))))))
             (process (emacs-jupyter-notebook-ssh-start-process
                       probe-name argv sentinel)))
        (emacs-jupyter-notebook--async-put context :probe-process process))))))

;; W4.7: the synchronous `--connect-entry' that drove the now-removed
;; `--retrieve-connection-file' and `--wait-for-tunnel' has been removed.
;; All reconnect goes through `--async-probe-pid-alive' →
;; `--async-retrieve' → `--async-wait-tunnel-tick' → `--async-connect'.

;;; Ensure client (async)

(defun emacs-jupyter-notebook--ensure-client-async (callback error-callback)
  "Ensure a kernel client is connected, then call CALLBACK.
On failure, call ERROR-CALLBACK with (context error-data)."
  (cond
   (emacs-jupyter-notebook--tunnel-dead
    (emacs-jupyter-notebook--tunnel-reconnect
     (current-buffer) callback error-callback))
   (emacs-jupyter-notebook--client
    (funcall callback nil))
   ((emacs-jupyter-notebook--async-in-progress-p)
     (emacs-jupyter-notebook--async-add-callback
      emacs-jupyter-notebook--async-context callback)
     (when error-callback
       (emacs-jupyter-notebook--async-add-error-callback
        emacs-jupyter-notebook--async-context error-callback)))
   (t
    ;; W4.8: when reconnect to a known registry entry fails (including the
    ;; W4.4 dead-PID case) we MUST NOT auto-remove the entry or auto-start
    ;; a fresh kernel — only the explicit user commands `shutdown-kernel'
    ;; and `clean-orphaned-kernels' may terminate / deregister.  Surface
    ;; the error to the caller; the message produced by `--async-fail'
    ;; (W4.3 / W4.4) already points the user at `start-remote-kernel'.
    (if-let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
        (emacs-jupyter-notebook-reconnect-remote-kernel
         entry callback
         (lambda (context error-data)
           (when error-callback
             (funcall error-callback context error-data))))
      (emacs-jupyter-notebook-start-remote-kernel
       emacs-jupyter-notebook-default-profile callback error-callback)))))

;;; Completion (W3: non-blocking capf with LRU cache + idle delay)
;;
;; Design contract (see ROADMAP.md W3):
;; - capf returns IMMEDIATELY with whatever is in the LRU cache.  No call
;;   ever blocks waiting on the kernel; even a 10-second adapter delay must
;;   not slow the capf hot path beyond a few milliseconds.
;; - A new completion request is sent only after the user has been idle for
;;   `emacs-jupyter-notebook-completion-idle' seconds.  Each keystroke
;;   restarts the idle window.
;; - Each request carries a monotonic id and the cache key
;;   `(point . line-up-to-point)'.  When a new request fires, both the
;;   pending key and the pending id are overwritten; the prior reply is
;;   stale and is DROPPED on arrival without rendering.
;; - The cache is a bounded LRU keyed by `(point . line-up-to-point)'.
;;   Eviction is least-recently-used.

(defun emacs-jupyter-notebook--completion-key ()
  "Return the completion cache key for point in the current buffer.
The key is `(point . line-up-to-point)' per W3 design contract."
  (cons (point)
        (buffer-substring-no-properties (line-beginning-position) (point))))

(defun emacs-jupyter-notebook--completion-context ()
  "Build a completion context from the current cell.
Returns a plist with :key (cache key for LRU lookup), :code (cell source
text sent to the kernel), and :cursor-pos (cursor offset into the code)."
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg)))
    (list :key (emacs-jupyter-notebook--completion-key)
          :code code
          :cursor-pos cursor-pos)))

(defun emacs-jupyter-notebook--completion-cache-ensure ()
  "Return the buffer-local completion cache hash-table, creating it if needed."
  (or emacs-jupyter-notebook--completion-cache
      (setq emacs-jupyter-notebook--completion-cache
            (make-hash-table :test 'equal))))

(defun emacs-jupyter-notebook--completion-cache-get (key)
  "Return the cached reply for KEY or nil.
Side-effect: promotes KEY to most-recently-used in the LRU order."
  (when emacs-jupyter-notebook--completion-cache
    (let ((reply (gethash key emacs-jupyter-notebook--completion-cache)))
      (when reply
        (setq emacs-jupyter-notebook--completion-cache-order
              (cons key (delete key emacs-jupyter-notebook--completion-cache-order)))
        reply))))

(defun emacs-jupyter-notebook--completion-cache-put (key reply)
  "Insert REPLY under KEY into the LRU cache, evicting LRU entries past the cap."
  (let ((cache (emacs-jupyter-notebook--completion-cache-ensure))
        (limit (max 1 (or emacs-jupyter-notebook-completion-cache-size 1))))
    (puthash key reply cache)
    (setq emacs-jupyter-notebook--completion-cache-order
          (cons key (delete key emacs-jupyter-notebook--completion-cache-order)))
    (while (> (length emacs-jupyter-notebook--completion-cache-order) limit)
      (let* ((order emacs-jupyter-notebook--completion-cache-order)
             (victim (car (last order))))
        (remhash victim cache)
        (setq emacs-jupyter-notebook--completion-cache-order (butlast order))))
    reply))

(defun emacs-jupyter-notebook--completion-cache-reset ()
  "Discard all cached completion replies in the current buffer."
  (when (hash-table-p emacs-jupyter-notebook--completion-cache)
    (clrhash emacs-jupyter-notebook--completion-cache))
  (setq emacs-jupyter-notebook--completion-cache-order nil))

(defun emacs-jupyter-notebook--completion-result-from-reply (reply)
  "Translate a Jupyter complete_reply plist REPLY into a capf return value."
  (when reply
    (let* ((matches (plist-get reply :matches))
           (cursor-start (plist-get reply :cursor_start))
           (cursor-end (plist-get reply :cursor_end)))
      (when matches
        (list (- (point) (- cursor-end cursor-start))
              (point)
              (append matches nil)
              :exclusive 'no)))))

(defun emacs-jupyter-notebook--completion-result ()
  "Return cached CAPF result for point or nil.
Looks up the LRU cache by the current `(point . line-up-to-point)' key.
Never sends a request and never blocks."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (when-let* ((key (emacs-jupyter-notebook--completion-key))
                (reply (emacs-jupyter-notebook--completion-cache-get key)))
      (emacs-jupyter-notebook--completion-result-from-reply reply))))

(defun emacs-jupyter-notebook--completion-refresh-ui ()
  "Push freshly-cached candidates to the active completion frontend.
Behavior (W3.7):
- If `company-mode' is on and no popup is yet open, kick
  `company-manual-begin' so company picks up the fresh cache.
- If no completion popup is active, drive `completion-in-region'
  directly with the cached result (covers explicit `complete-at-point'
  invocations and the vanilla path).
- If `completion-in-region-mode' is already active (Corfu, vertico,
  consult-completion-in-region, etc.) do nothing: there is no
  cross-version programmatic way to force the popup to re-fetch capf
  candidates.  The next user keystroke causes capf to be re-invoked
  naturally and the popup picks up the new cache then."
  ;; Justification for the missing Corfu hook: `corfu--exhibit' only
  ;; redisplays current corfu state; it does not refresh candidates from
  ;; would stay empty.  We instead rely on the fallback path: when the
  ;; cache fills, the next user keystroke causes capf to be re-invoked
  ;; naturally and the popup picks up the new candidates.  For the
  ;; explicit-completion case (no popup yet active) we drive
  ;; `completion-in-region' directly.
  (cond
   ((and (bound-and-true-p company-mode)
         (not (bound-and-true-p company-candidates))
         (fboundp 'company-manual-begin))
    (funcall 'company-manual-begin))
   ((not (bound-and-true-p completion-in-region-mode))
    (let ((result (emacs-jupyter-notebook--completion-result)))
      (when result
        (apply #'completion-in-region result))))))

(defun emacs-jupyter-notebook--completion-on-reply (buffer key request-id show-results context-snapshot reply _error)
  "Cache REPLY for KEY under REQUEST-ID in BUFFER, optionally refreshing UI.
Stale replies are dropped: a reply is stale when REQUEST-ID no longer
matches the buffer-local pending id, when KEY no longer matches the live
pending key, OR when the buffer's current capf context no longer matches
the request's KEY (i.e. point moved or the line changed).  Only fresh
replies update the cache; this prevents `out-of-date' completions from
being cached for the original context after the user moved away from it
(W3.3 + W3.7)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (equal emacs-jupyter-notebook--completion-pending-id request-id)
                 (equal emacs-jupyter-notebook--completion-pending-key key))
        (setq emacs-jupyter-notebook--completion-pending-key nil
              emacs-jupyter-notebook--completion-pending-id nil)
        (when (and reply
                   (equal (emacs-jupyter-notebook--completion-key) key))
          (emacs-jupyter-notebook--completion-cache-put key reply)
          (when (and show-results
                     (equal (emacs-jupyter-notebook--completion-context)
                            context-snapshot))
            (emacs-jupyter-notebook--completion-refresh-ui)))))))

(defun emacs-jupyter-notebook--request-completion (&optional show-results)
  "Fire an async completion request for point.
SHOW-RESULTS non-nil means push the reply to the active completion UI on
arrival.  The current pending key/id are overwritten so any earlier reply
arriving after this call is dropped (W3.3)."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let* ((context (emacs-jupyter-notebook--completion-context))
           (key (plist-get context :key))
           (code (plist-get context :code))
           (cursor-pos (plist-get context :cursor-pos))
           (buffer (current-buffer))
           (request-id (cl-incf emacs-jupyter-notebook--completion-request-counter)))
      (unless (and (equal emacs-jupyter-notebook--completion-pending-key key)
                   emacs-jupyter-notebook--completion-pending-id)
        (setq emacs-jupyter-notebook--completion-pending-key key
              emacs-jupyter-notebook--completion-pending-id request-id)
        (emacs-jupyter-notebook-jupyter-complete
         emacs-jupyter-notebook--client code cursor-pos
         (lambda (reply error)
           (emacs-jupyter-notebook--completion-on-reply
            buffer key request-id show-results context reply error)))))))

(defun emacs-jupyter-notebook--completion-schedule-request (&optional show-results)
  "Restart the idle timer that fires an async completion request.
Any in-flight request is invalidated by bumping the request counter the
next time `--request-completion' runs; pending key/id are cleared so the
older reply is dropped (W3.3)."
  (emacs-jupyter-notebook--completion-cancel-idle-timer)
  ;; Invalidate any in-flight request so its reply is dropped on arrival.
  (setq emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil)
  (let ((buffer (current-buffer))
        (delay (max 0.0 (or emacs-jupyter-notebook-completion-idle 0.10))))
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-timer
           delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacs-jupyter-notebook--completion-idle-timer nil)
                 (when (and emacs-jupyter-notebook-mode
                            emacs-jupyter-notebook--client
                            (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
                   (emacs-jupyter-notebook--request-completion show-results)))))))))

(defun emacs-jupyter-notebook-completion-at-point ()
  "CAPF function: return cached completions immediately; schedule async fill.
W3.4 contract: this function never blocks.  When the cache misses and the
user just typed, an idle-delayed async request is scheduled; the kernel
reply (whenever it arrives) populates the cache and refreshes the
frontend so subsequent capf calls hit."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let ((result (emacs-jupyter-notebook--completion-result)))
      (if result
          result
        (when (memq this-command
                    '(self-insert-command
                      delete-backward-char
                      backward-delete-char-untabify
                      yank))
          (emacs-jupyter-notebook--completion-schedule-request t))
        nil))))

(defun emacs-jupyter-notebook-complete-at-point ()
  "Explicit completion command.
Returns cached candidates immediately if any are present; otherwise
schedules an idle-delayed async request and lets the frontend refresh
when the reply arrives."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (let ((result (emacs-jupyter-notebook--completion-result)))
    (if result
        (apply #'completion-in-region result)
      (emacs-jupyter-notebook--completion-schedule-request t))))

(defun emacs-jupyter-notebook--completion-start-idle-timer ()
  "Start the completion cache idle timer (one-shot rescheduled on each tick).
The timer captures the current buffer in a closure so it always operates
on the buffer that armed it, not whatever buffer happens to be current
when the timer fires."
  (emacs-jupyter-notebook--completion-cancel-idle-timer)
  (let ((buffer (current-buffer)))
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-idle-timer
           (max 0.0 (or emacs-jupyter-notebook-completion-idle 0.10))
           nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacs-jupyter-notebook--completion-idle-timer nil)
                 (emacs-jupyter-notebook--completion-idle-populate))))))))

(defun emacs-jupyter-notebook--completion-cancel-idle-timer ()
  "Cancel the completion cache idle timer and clear pending request state.
Clearing the pending key/id ensures that any reply for a request that was
in flight when the timer was cancelled is dropped on arrival per the W3.3
in-flight invalidation contract."
  (when (timerp emacs-jupyter-notebook--completion-idle-timer)
    (cancel-timer emacs-jupyter-notebook--completion-idle-timer))
  (setq emacs-jupyter-notebook--completion-idle-timer nil
        emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil))

(defun emacs-jupyter-notebook--completion-idle-populate ()
  "Populate completion cache on idle when point sits at a fresh context."
  (when (and emacs-jupyter-notebook-mode
             emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy))
             (not (emacs-jupyter-notebook--async-in-progress-p)))
    (let ((key (emacs-jupyter-notebook--completion-key)))
      (unless (or (equal key emacs-jupyter-notebook--completion-pending-key)
                  (and emacs-jupyter-notebook--completion-cache
                       (gethash key emacs-jupyter-notebook--completion-cache)))
        (emacs-jupyter-notebook--request-completion)))))

;;; Inspect

(defun emacs-jupyter-notebook-inspect-at-point ()
  "Inspect the symbol at point using the Jupyter kernel."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg)))
    (emacs-jupyter-notebook-jupyter-inspect
     emacs-jupyter-notebook--client code cursor-pos 0
     (lambda (reply _error)
       (when reply
         (let* ((data (plist-get reply :data))
                (text (plist-get data :text/plain)))
           (when text
             (display-message-or-buffer text))))))))

;;; Evaluation

(defun emacs-jupyter-notebook--current-cell-key ()
  "Return the cell key for the current cell, or nil if no marker exists.
Cells without a `# %%' marker (i.e., whole-buffer evaluation in marker-less
files) return nil so they flow only to the history-log view."
  (save-excursion
    (let* ((bounds (emacs-jupyter-notebook-cell-bounds))
           (beg (car bounds)))
      ;; Bounds start at the cell body; the marker line begins just before.
      ;; Walk back to the marker line, if any.
      (goto-char beg)
      (cond
       ((and (> beg (point-min))
             (save-excursion
               (goto-char beg)
               (forward-line -1)
               (looking-at code-cells-boundary-regexp)))
        (forward-line -1)
        (emacs-jupyter-notebook--cell-key-for (line-beginning-position)))
       ((save-excursion
          (goto-char (point-min))
          (looking-at code-cells-boundary-regexp))
        (emacs-jupyter-notebook--cell-key-for (point-min)))
       (t nil)))))

(defun emacs-jupyter-notebook--evaluate-code-now (code cell-key)
  "Evaluate CODE immediately, sending output to CELL-KEY's panel entry.
CELL-KEY may be nil for region/paragraph/defun evaluation."
  (let* ((buffer (current-buffer))
         (panel (ejn-panel-ensure buffer))
         (handle (ejn-panel-start-entry panel cell-key code))
         (modified (buffer-modified-p)))
    (emacs-jupyter-notebook-panel--display panel)
    (when cell-key
      (emacs-jupyter-notebook-fringe-set cell-key 'running))
    (prog1
        (emacs-jupyter-notebook-jupyter-evaluate
         emacs-jupyter-notebook--client code handle)
      (set-buffer-modified-p modified))))

(defun emacs-jupyter-notebook--evaluate-after-completeness-cell (code cell-key)
  "Check CODE completeness and evaluate if complete, posting to CELL-KEY."
  (if (not emacs-jupyter-notebook-check-code-completeness)
      (emacs-jupyter-notebook--evaluate-code-now code cell-key)
    (emacs-jupyter-notebook-jupyter-is-complete
     emacs-jupyter-notebook--client code
     (lambda (reply _error)
       (when (and reply (equal (plist-get reply :status) "complete"))
         (emacs-jupyter-notebook--evaluate-code-now code cell-key))))))

(defun emacs-jupyter-notebook--evaluate-code (code cell-key)
  "Ensure client then evaluate CODE, posting output to CELL-KEY's entry.
CELL-KEY may be nil (region/paragraph/defun evaluation)."
  (let* ((buffer (current-buffer))
         (eval-cb (lambda (_ctx)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (emacs-jupyter-notebook--evaluate-after-completeness-cell
                         code cell-key)))))
         (error-cb (lambda (_ctx err)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (let* ((panel (ejn-panel-ensure buffer))
                                (handle (ejn-panel-start-entry
                                         panel cell-key code)))
                           (ejn-panel-append-text
                            handle (format "Evaluation failed: %s" err)
                            'emacs-jupyter-notebook-result-error-face)
                           (ejn-panel-finish-entry handle 'error nil))))
                     (message "emacs-jupyter-notebook: evaluation failed: %s" err))))
    (emacs-jupyter-notebook--ensure-client-async eval-cb error-cb)))

;;; Commands

(defun emacs-jupyter-notebook--registry-entry-key (entry)
  "Return the registry key for ENTRY, or nil."
  (or (plist-get entry :session-id)
      (plist-get entry :profile)))

(defun emacs-jupyter-notebook--cleanup-current-state (&optional reason skip-jupyter-shutdown)
  "Clean current buffer's client, tunnel, async context, and registry state.
REASON is used when cancelling an async context.  When SKIP-JUPYTER-SHUTDOWN is
non-nil, do not send a Jupyter shutdown request to the current client."
  (let ((entry emacs-jupyter-notebook--session-entry)
        (context emacs-jupyter-notebook--async-context))
    (when (and context (emacs-jupyter-notebook--async-in-progress-p))
      (emacs-jupyter-notebook--async-fail context (or reason "Operation cancelled")))
    (when (and emacs-jupyter-notebook--client (not skip-jupyter-shutdown))
      (ignore-errors
        (emacs-jupyter-notebook-jupyter-shutdown emacs-jupyter-notebook--client)))
    (when (processp emacs-jupyter-notebook--tunnel-process)
      (emacs-jupyter-notebook--async-delete-process
       emacs-jupyter-notebook--tunnel-process))
    (when entry
      (emacs-jupyter-notebook--cleanup-remote-entry entry))
    (when-let* ((key (and entry (emacs-jupyter-notebook--registry-entry-key entry))))
      (emacs-jupyter-notebook-registry-remove-entry key))
    (when-let* ((local-file (plist-get entry :local-connection-file)))
      (emacs-jupyter-notebook--async-delete-file local-file))
    (setq emacs-jupyter-notebook--client nil
          emacs-jupyter-notebook--session-entry nil
          emacs-jupyter-notebook--tunnel-process nil
          emacs-jupyter-notebook--tunnel-dead nil
          emacs-jupyter-notebook--kernel-status nil
          emacs-jupyter-notebook--async-context nil
          emacs-jupyter-notebook--evaluation-timer nil
          emacs-jupyter-notebook--evaluation-request nil)
    (force-mode-line-update t)
    entry))

(defun emacs-jupyter-notebook--display-command-output (buffer-name output)
  "Display OUTPUT in read-only BUFFER-NAME."
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output)
        (goto-char (point-min)))
      (setq buffer-read-only t))
    (display-buffer buf)))

;;;###autoload
(defun emacs-jupyter-notebook-start-remote-kernel (profile-name &optional callback error-callback)
  "Start a detached remote kernel for PROFILE-NAME asynchronously.
  CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (unless buffer-file-name
    (user-error "Buffer has no associated file"))
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (emacs-jupyter-notebook--ensure-clean-before-start)
  (emacs-jupyter-notebook-jupyter--ensure)
  (let* ((profile (emacs-jupyter-notebook--read-host-profile profile-name))
         (session-id (emacs-jupyter-notebook--new-session-id
                      (file-name-base buffer-file-name)))
         (launch (emacs-jupyter-notebook-ssh-build-remote-launch profile session-id))
         (entry (list :profile (plist-get profile :profile)
                       :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                       :remote-cwd (plist-get profile :remote-cwd)
                       :kernelspec (plist-get profile :kernelspec)
                       :jupyter-command (plist-get profile :jupyter-command)
                       :remote-connection-file (plist-get launch :connection-file)
                      :remote-pid nil
                      :created-at (emacs-jupyter-notebook--timestamp)
                      :tunnel-ports nil
                      :display-name (format "%s:%s"
                                            (emacs-jupyter-notebook-ssh-destination profile)
                                            (plist-get profile :kernelspec))
                      :session-id session-id
                      :local-file buffer-file-name))
         (context (emacs-jupyter-notebook--async-start-context
                   profile entry session-id launch callback error-callback)))
    (setq context (emacs-jupyter-notebook--async-launch context))
    context))

;;;###autoload
(defun emacs-jupyter-notebook-reconnect-remote-kernel (entry &optional callback error-callback)
  "Reconnect current buffer to an existing remote kernel ENTRY asynchronously.
  CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (interactive (list (emacs-jupyter-notebook--read-registry-entry)))
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (emacs-jupyter-notebook--ensure-clean-before-start)
  (emacs-jupyter-notebook-jupyter--ensure)
  (let ((profile (emacs-jupyter-notebook--entry-profile entry)))
    (emacs-jupyter-notebook--async-probe-pid-alive
     (emacs-jupyter-notebook--async-reconnect-context profile entry callback error-callback))))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-current-cell ()
  "Evaluate the current # %% cell, sending output to the cell's panel entry."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (let ((code (buffer-substring-no-properties beg end))
          (key (emacs-jupyter-notebook--current-cell-key)))
      (emacs-jupyter-notebook--evaluate-code code key))))

;;;###autoload
(defun emacs-jupyter-notebook-evaluate-region (beg end)
  "Evaluate the active region from BEG to END.
Region evaluations have no cell key and appear only in the history-log
view of the panel."
  (interactive "r")
  (emacs-jupyter-notebook--evaluate-code
   (buffer-substring-no-properties beg end) nil))

(defun emacs-jupyter-notebook-evaluate-buffer ()
  "Evaluate the current buffer.
Buffer evaluations have no cell key and appear only in the history-log
view of the panel."
  (interactive)
  (emacs-jupyter-notebook--evaluate-code
   (buffer-substring-no-properties (point-min) (point-max)) nil))

;;;###autoload
(defun emacs-jupyter-notebook-interrupt-kernel ()
  "Interrupt the current kernel."
  (interactive)
  (emacs-jupyter-notebook-jupyter-interrupt
   (emacs-jupyter-notebook--ensure-client)))

;;;###autoload
(defun emacs-jupyter-notebook-restart-kernel ()
  "Restart the current kernel through emacs-jupyter."
  (interactive)
  (emacs-jupyter-notebook-jupyter-restart
   (emacs-jupyter-notebook--ensure-client)))

;;;###autoload
(defun emacs-jupyter-notebook-shutdown-kernel ()
  "Shut down the current kernel, close tunnel, and reset state."
  (interactive)
  (emacs-jupyter-notebook--cleanup-current-state "Kernel shut down"))

(defun emacs-jupyter-notebook-retry-fresh-kernel (&optional profile-name)
  "Cancel/cleanup current state and start a fresh kernel.
With PROFILE-NAME, start that profile.  Otherwise reuse the current session's
profile, then fall back to `emacs-jupyter-notebook-default-profile'."
  (interactive)
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (context emacs-jupyter-notebook--async-context)
         (profile (or profile-name
                      (plist-get entry :profile)
                      (plist-get (plist-get context :profile) :profile)
                      emacs-jupyter-notebook-default-profile)))
    (emacs-jupyter-notebook--cleanup-current-state "Retrying with fresh kernel" t)
    (emacs-jupyter-notebook-start-remote-kernel profile)))

;;;###autoload
(defun emacs-jupyter-notebook-status ()
  "Display the current buffer's EJN engine state."
  (interactive)
  (let ((text (emacs-jupyter-notebook--format-status
               (emacs-jupyter-notebook-status-snapshot))))
    (if (called-interactively-p 'interactive)
        (emacs-jupyter-notebook--display-command-output "*ejn-status*" text)
      text)))

(defun emacs-jupyter-notebook-fetch-remote-log ()
  "Fetch and display the current session's remote kernel log."
  (interactive)
  (unless emacs-jupyter-notebook--session-entry
    (user-error "No active EJN session"))
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (connection-file (plist-get entry :remote-connection-file)))
    (unless connection-file
      (user-error "Current EJN session has no remote connection file"))
    (emacs-jupyter-notebook--display-command-output
     "*ejn-log*"
     (emacs-jupyter-notebook-ssh-run-command
      (emacs-jupyter-notebook-ssh-build-remote-cat-log
       (emacs-jupyter-notebook--entry-profile entry) connection-file)))))

(defun emacs-jupyter-notebook-list-remote-processes (&optional profile-name)
  "List likely remote EJN kernel processes for PROFILE-NAME."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (emacs-jupyter-notebook--display-command-output
     "*ejn-remote-processes*"
     (emacs-jupyter-notebook-ssh-run-command
      (emacs-jupyter-notebook-ssh-build-remote-ps-command profile)))))

(defun emacs-jupyter-notebook-clean-orphaned-kernels (&optional profile-name)
  "Clean all EJN kernel files and processes in PROFILE-NAME's remote cache."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (when (or (not (called-interactively-p 'interactive))
              (yes-or-no-p (format "Clean EJN kernels in %s on %s? "
                                   (plist-get profile :remote-cache-dir)
                                   (emacs-jupyter-notebook-ssh-destination profile))))
      (emacs-jupyter-notebook-ssh-run-command
       (emacs-jupyter-notebook-ssh-build-remote-cleanup-all profile))
      (message "emacs-jupyter-notebook: requested remote orphan cleanup"))))

;;;###autoload
(defun emacs-jupyter-notebook-clear-results ()
  "Clear the source-side fringe indicators and the output panel contents."
  (interactive)
  (emacs-jupyter-notebook-fringe-clear-all)
  (let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (setq emacs-jupyter-notebook-panel--entries nil)
        (emacs-jupyter-notebook-panel-flush-now panel)))))

(defun emacs-jupyter-notebook-cancel-operation ()
  "Cancel the current buffer's in-progress async Jupyter operation."
  (interactive)
  (if emacs-jupyter-notebook--async-context
      (progn
        (emacs-jupyter-notebook--async-fail
         emacs-jupyter-notebook--async-context "Operation cancelled")
        (setq emacs-jupyter-notebook--async-context nil))
    (user-error "No emacs-jupyter-notebook operation is in progress")))

(defun emacs-jupyter-notebook-toggle-panel-view ()
  "Toggle the source buffer's output panel between latest and history views."
  (interactive)
  (let ((panel (or (emacs-jupyter-notebook-panel-buffer (current-buffer))
                   (ejn-panel-ensure (current-buffer)))))
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel-toggle-view))))

(defun emacs-jupyter-notebook--ensure-client ()
  "Return the current buffer's kernel client or signal an error."
  (or emacs-jupyter-notebook--client
      (error "No Jupyter kernel connected; run `emacs-jupyter-notebook-start-remote-kernel'")))

(provide 'emacs-jupyter-notebook)

;;; emacs-jupyter-notebook.el ends here
