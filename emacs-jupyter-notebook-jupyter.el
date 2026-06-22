;;; emacs-jupyter-notebook-jupyter.el --- Lazy emacs-jupyter adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Thin, mockable adapter around emacs-jupyter.  This file intentionally
;; avoids requiring emacs-jupyter at top level so local ERT tests can run
;; without that package installed.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-result)

(declare-function jupyter-kernel "jupyter-kernel" (&rest args))
(declare-function jupyter-client "jupyter-client" (kernel &optional client-class))
(declare-function jupyter-io "jupyter-kernel-process" (kernel))
(declare-function jupyter-eval-string "jupyter-client" (str &optional insert beg end))
(declare-function jupyter-execute-request "jupyter-messages" (&rest args))
(declare-function jupyter-complete-request "jupyter-messages" (&rest args))
(declare-function jupyter-inspect-request "jupyter-messages" (&rest args))
(declare-function jupyter-input-reply "jupyter-messages" (&rest args))
(declare-function jupyter-is-complete-request "jupyter-messages" (&rest args))
(declare-function jupyter-message-content "jupyter-messages" (msg))
(declare-function jupyter-message-data "jupyter-messages" (msg mimetype))
(declare-function jupyter-message-subscribed "jupyter-monads" (dreq cbs))
(declare-function jupyter-run-with-state "jupyter-monads" (state mvalue))
(declare-function jupyter-sent "jupyter-monads" (dreq))
(declare-function jupyter-kernel-info-request "jupyter-messages" (&rest args))
(declare-function jupyter-canonicalize-language-string "jupyter-base" (str))
(declare-function jupyter-interrupt-kernel "jupyter-client" (client))
(declare-function jupyter-restart-kernel "jupyter-client" (client))
(declare-function jupyter-shutdown-kernel "jupyter-client" (client))
(declare-function jupyter-insert "jupyter-mime" (mime-or-plist &optional metadata))
(declare-function jupyter-eval-remove-overlays "jupyter-client" ())
(declare-function jupyter-eval-ov--fold-string "jupyter-client" (text))
(defvar jupyter-current-client)
(defvar jupyter-default-timeout)
(defvar jupyter-long-timeout)
(defvar jupyter-eval-use-overlays)
(defvar jupyter-eval-short-result-max-lines)
(defvar emacs-jupyter-notebook--kernel-status nil)
(defvar emacs-jupyter-notebook--evaluation-timer nil)

(defun emacs-jupyter-notebook-jupyter--message-content-value (msg key)
  "Return KEY from MSG content."
  (plist-get (jupyter-message-content msg) key))

(defun emacs-jupyter-notebook-jupyter--result-mime-data (msg)
  "Return the MIME data plist from result MSG, or nil."
  (plist-get (jupyter-message-content msg) :data))

(defun emacs-jupyter-notebook-jupyter--set-image-result (buffer ov rendered)
  "Set image from RENDERED propertized string in OV in BUFFER."
  (when (and rendered (buffer-live-p buffer) (overlayp ov))
    (with-current-buffer buffer
      (when-let ((image-spec (get-text-property 0 'display rendered)))
        (emacs-jupyter-notebook-result-set-image ov image-spec)))))

(defun emacs-jupyter-notebook-jupyter--append-result (buffer ov text &optional face)
  "Append TEXT to OV in BUFFER when both are still live."
  (when (and text (buffer-live-p buffer) (overlayp ov))
    (with-current-buffer buffer
      (emacs-jupyter-notebook-result-append ov (ansi-color-apply text) face))))

(defun emacs-jupyter-notebook-jupyter--replace-result (buffer ov text &optional face)
  "Replace OV content with TEXT in BUFFER when both are still live."
  (when (and text (buffer-live-p buffer) (overlayp ov))
    (with-current-buffer buffer
      (emacs-jupyter-notebook-result-replace ov (ansi-color-apply text) face))))

(defun emacs-jupyter-notebook-jupyter--finish-result (buffer ov)
  "Mark OV in BUFFER as finished when both are still live."
  (when (and (buffer-live-p buffer) (overlayp ov))
    (with-current-buffer buffer
      (emacs-jupyter-notebook-result-finish ov))))

(defun emacs-jupyter-notebook-jupyter--send-input-reply (client value)
  "Send an input_reply with VALUE through CLIENT."
  (jupyter-run-with-state client
    (jupyter-sent (jupyter-input-reply :value value))))

(defun emacs-jupyter-notebook-jupyter--watch-expressions-plist ()
  "Return configured watch expressions as a JSON plist for Jupyter."
  (cl-loop for (name . expression) in emacs-jupyter-notebook-watch-expressions
           when (and (stringp name)
                     (not (string-empty-p name))
                     (stringp expression)
                     (not (string-empty-p expression)))
           append (list (intern (concat ":" name)) expression)))

(defun emacs-jupyter-notebook-jupyter--watch-name (key)
  "Return display name for user expression KEY."
  (let ((name (if (symbolp key) (symbol-name key) (format "%s" key))))
    (if (string-prefix-p ":" name)
        (substring name 1)
      name)))

(defun emacs-jupyter-notebook-jupyter--watch-value-text (value)
  "Return display text for a Jupyter user expression VALUE plist."
  (let ((status (plist-get value :status)))
    (cond
     ((equal status "ok")
      (let ((rendered (emacs-jupyter-notebook--render-mime-result
                       (plist-get value :data))))
        (cond
         ((null rendered) "[unsupported output format]")
         ((and (> (length rendered) 0)
               (get-text-property 0 'display rendered))
          "[image]")
         (t (string-trim-right rendered)))))
     ((equal status "error")
      (format "%s: %s"
              (or (plist-get value :ename) "Error")
              (or (plist-get value :evalue) "")))
     (t (format "%S" value)))))

(defun emacs-jupyter-notebook-jupyter--watch-results-text (user-expressions)
  "Return display text for USER-EXPRESSIONS from an execute_reply."
  (when (and user-expressions (listp user-expressions))
    (let (lines)
      (while user-expressions
        (let ((name (pop user-expressions))
              (value (pop user-expressions)))
          (push (format "%s: %s"
                        (emacs-jupyter-notebook-jupyter--watch-name name)
                        (emacs-jupyter-notebook-jupyter--watch-value-text value))
                lines)))
      (concat "\n[watch]\n" (string-join (nreverse lines) "\n") "\n"))))

(defun emacs-jupyter-notebook-jupyter--callbacks (buffer ov &optional client)
  "Return execution callbacks that render into OV in BUFFER."
  (let ((had-result nil))
    `(("input_request"
       ,(lambda (msg)
          (condition-case nil
              (let* ((content (jupyter-message-content msg))
                     (prompt (or (plist-get content :prompt) ""))
                     (password (plist-get content :password)))
                (emacs-jupyter-notebook-jupyter--append-result buffer ov prompt)
                (let ((value (condition-case nil
                                 (if (eq password t)
                                     (read-passwd prompt)
                                   (read-string prompt))
                               (quit ""))))
                  (when client
                    (emacs-jupyter-notebook-jupyter--send-input-reply client value))
                  (when (eq password t)
                    (clear-string value))))
            (error nil))))
       ("clear_output"
       ,(lambda (msg)
          (condition-case nil
              (when (and (buffer-live-p buffer) (overlayp ov))
                (with-current-buffer buffer
                  (let ((wait (plist-get (jupyter-message-content msg) :wait)))
                    (if wait
                        (overlay-put ov 'emacs-jupyter-notebook-pending-clear t)
                      (emacs-jupyter-notebook-result-clear ov)))))
            (error nil))))
      ("stream"
       ,(lambda (msg)
          (condition-case nil
              (let ((text (emacs-jupyter-notebook-jupyter--message-content-value msg :text))
                    (name (emacs-jupyter-notebook-jupyter--message-content-value msg :name)))
                (when (and text (not (string-empty-p text)))
                  (setq had-result t)
                  (emacs-jupyter-notebook-jupyter--append-result
                   buffer ov text
                   (when (equal name "stderr") 'emacs-jupyter-notebook-result-error-face))))
            (error nil))))
      ("execute_result"
       ,(lambda (msg)
          (condition-case nil
              (when-let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg))
                         (rendered (emacs-jupyter-notebook--render-mime-result data)))
                (setq had-result t)
                (if (get-text-property 0 'display rendered)
                    (emacs-jupyter-notebook-jupyter--set-image-result buffer ov rendered)
                  (emacs-jupyter-notebook-jupyter--append-result buffer ov rendered)))
            (error nil))))
      ("display_data"
       ,(lambda (msg)
          (condition-case nil
              (let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg)))
                (when data
                  (let ((rendered (emacs-jupyter-notebook--render-mime-result data)))
                    (setq had-result t)
                    (if rendered
                        (if (get-text-property 0 'display rendered)
                            (emacs-jupyter-notebook-jupyter--set-image-result buffer ov rendered)
                          (emacs-jupyter-notebook-jupyter--append-result buffer ov rendered))
                      (emacs-jupyter-notebook-jupyter--append-result
                       buffer ov "[unsupported output format]")))))
            (error nil))))
      ("update_display_data"
       ,(lambda (msg)
          (condition-case nil
              (let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg)))
                (when data
                  (let ((rendered (emacs-jupyter-notebook--render-mime-result data)))
                    (setq had-result t)
                    (if rendered
                        (if (get-text-property 0 'display rendered)
                            (emacs-jupyter-notebook-jupyter--set-image-result buffer ov rendered)
                          (emacs-jupyter-notebook-jupyter--replace-result buffer ov rendered))
                      (emacs-jupyter-notebook-jupyter--replace-result
                       buffer ov "[unsupported output format]")))))
            (error nil))))
      ("error"
       ,(lambda (msg)
          (condition-case nil
              (let* ((content (jupyter-message-content msg))
                     (traceback (plist-get content :traceback))
                     (ename (or (plist-get content :ename) "Error"))
                     (evalue (or (plist-get content :evalue) ""))
                     (text (if traceback
                               (string-join traceback "\n")
                             (format "%s: %s" ename evalue))))
                (setq had-result t)
                (emacs-jupyter-notebook-jupyter--append-result
                 buffer ov text 'emacs-jupyter-notebook-result-error-face))
            (error nil))))
      ("execute_reply"
       ,(lambda (msg)
          (condition-case nil
              (progn
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (timerp emacs-jupyter-notebook--evaluation-timer)
                      (cancel-timer emacs-jupyter-notebook--evaluation-timer))
                    (setq emacs-jupyter-notebook--evaluation-timer nil)))
                (let ((status (emacs-jupyter-notebook-jupyter--message-content-value msg :status))
                      (count (emacs-jupyter-notebook-jupyter--message-content-value msg :execution_count))
                      (watch-text (emacs-jupyter-notebook-jupyter--watch-results-text
                                   (emacs-jupyter-notebook-jupyter--message-content-value
                                    msg :user_expressions))))
                  (when watch-text
                    (setq had-result t)
                    (emacs-jupyter-notebook-jupyter--append-result buffer ov watch-text))
                  (unless had-result
                    (when (equal status "error")
                      (emacs-jupyter-notebook-jupyter--append-result
                       buffer ov
                       (format "%s: %s"
                               (or (emacs-jupyter-notebook-jupyter--message-content-value msg :ename) "Error")
                               (or (emacs-jupyter-notebook-jupyter--message-content-value msg :evalue) ""))
                       'emacs-jupyter-notebook-result-error-face)))
                  (when (and count (buffer-live-p buffer))
                    (with-current-buffer buffer
                       (emacs-jupyter-notebook-result--set-execution-count ov count)))
                  (emacs-jupyter-notebook-jupyter--finish-result buffer ov)))
            (error nil))))
      ("status"
       ,(lambda (msg)
          (condition-case nil
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (let ((state (emacs-jupyter-notebook-jupyter--message-content-value
                                msg :execution_state)))
                    (setq emacs-jupyter-notebook--kernel-status
                          (cond ((equal state "busy") 'busy)
                                ((equal state "idle") 'idle)
                                (t nil)))
                    (when (equal state "idle")
                      (when (timerp emacs-jupyter-notebook--evaluation-timer)
                        (cancel-timer emacs-jupyter-notebook--evaluation-timer))
                      (setq emacs-jupyter-notebook--evaluation-timer nil))
                    (force-mode-line-update t))))
            (error nil)))))))

(defun emacs-jupyter-notebook-jupyter--maybe-fold-overlay (orig-fn text)
  "Prevent overlay folding in `emacs-jupyter-notebook-mode' buffers.
In other buffers, call ORIG-FN normally."
  (if (bound-and-true-p emacs-jupyter-notebook-mode)
      text
    (funcall orig-fn text)))

(with-eval-after-load 'jupyter-client
  (advice-add 'jupyter-eval-ov--fold-string :around
              #'emacs-jupyter-notebook-jupyter--maybe-fold-overlay))

(defvar emacs-jupyter-notebook-jupyter-connect-function
  #'emacs-jupyter-notebook-jupyter--connect
  "Function used by `emacs-jupyter-notebook-jupyter-connect'.")

(defvar emacs-jupyter-notebook-jupyter-connect-async-function
  #'emacs-jupyter-notebook-jupyter--connect-async
  "Function used by `emacs-jupyter-notebook-jupyter-connect-async'.")

(defvar emacs-jupyter-notebook-jupyter-evaluate-function
  #'emacs-jupyter-notebook-jupyter--evaluate
  "Function used by `emacs-jupyter-notebook-jupyter-evaluate'.")

(defvar emacs-jupyter-notebook-jupyter-interrupt-function
  #'emacs-jupyter-notebook-jupyter--interrupt
  "Function used by `emacs-jupyter-notebook-jupyter-interrupt'.")

(defvar emacs-jupyter-notebook-jupyter-restart-function
  #'emacs-jupyter-notebook-jupyter--restart
  "Function used by `emacs-jupyter-notebook-jupyter-restart'.")

(defvar emacs-jupyter-notebook-jupyter-shutdown-function
  #'emacs-jupyter-notebook-jupyter--shutdown
  "Function used by `emacs-jupyter-notebook-jupyter-shutdown'.")

(defvar emacs-jupyter-notebook-jupyter-complete-function
  #'emacs-jupyter-notebook-jupyter--complete
  "Function used by `emacs-jupyter-notebook-jupyter-complete'.
The function is called with CLIENT, CODE, CURSOR-POS, and CALLBACK.
CALLBACK receives two arguments: reply content and error data.")

(defvar emacs-jupyter-notebook-jupyter-inspect-function
  #'emacs-jupyter-notebook-jupyter--inspect
  "Function used by `emacs-jupyter-notebook-jupyter-inspect'.
The function is called with CLIENT, CODE, CURSOR-POS, DETAIL, and CALLBACK.
CALLBACK receives two arguments: reply content and error data.")

(defvar emacs-jupyter-notebook-jupyter-is-complete-function
  #'emacs-jupyter-notebook-jupyter--is-complete
  "Function used by `emacs-jupyter-notebook-jupyter-is-complete'.
The function is called with CLIENT, CODE, and CALLBACK.  CALLBACK
receives two arguments: reply content and error data.")

(defun emacs-jupyter-notebook-jupyter-available-p ()
  "Return non-nil when emacs-jupyter can be loaded."
  (require 'jupyter nil t))

(defun emacs-jupyter-notebook-jupyter--ensure ()
  "Ensure emacs-jupyter is loaded or signal a helpful error."
  (unless (emacs-jupyter-notebook-jupyter-available-p)
    (error "emacs-jupyter is not installed or not on `load-path'")))

(defun emacs-jupyter-notebook-jupyter--connect (connection-file)
  "Connect to an existing kernel described by CONNECTION-FILE."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-kernel)
  (require 'jupyter-client)
  (let ((jupyter-default-timeout emacs-jupyter-notebook-jupyter-connect-timeout)
        (jupyter-long-timeout (/ emacs-jupyter-notebook-jupyter-connect-timeout 3.0)))
    (jupyter-client (jupyter-kernel :conn-info connection-file :connect-p t))))

(defun emacs-jupyter-notebook-jupyter--connect-async (connection-file callback)
  "Connect to CONNECTION-FILE and call CALLBACK with the client.
The actual connect is deferred to the next command loop iteration
via `run-at-time' so the current keystroke/command finishes before
the synchronous emacs-jupyter connect blocks the event loop."
  (message "Connecting to Jupyter kernel (this may take a moment)...")
  (run-at-time
   0 nil
   (lambda ()
     (condition-case err
         (let ((client (catch 'timeout
                         (emacs-jupyter-notebook-jupyter--connect connection-file))))
           (if (eq client 'timeout)
               (progn
                 (message "Timed out connecting to Jupyter kernel")
                 (funcall callback nil))
             (message "Connected to Jupyter kernel")
             (funcall callback client)))
       (error
        (message "Failed to connect to Jupyter kernel: %s" (error-message-string err))
        (funcall callback nil))))))

(defun emacs-jupyter-notebook-jupyter--evaluate (client code beg end)
  "Evaluate CODE using CLIENT with source bounds BEG and END."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-client)
  (require 'jupyter-messages)
  (require 'jupyter-monads)
  (if (not emacs-jupyter-notebook-use-inline-overlays)
      (let ((jupyter-current-client client)
            (jupyter-eval-use-overlays nil)
            (jupyter-eval-short-result-max-lines
             emacs-jupyter-notebook-inline-result-max-lines))
        (jupyter-eval-string code nil beg end))
    (let* ((buffer (current-buffer))
           (ov (emacs-jupyter-notebook-result-start beg end))
            (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer ov))
           (watch-expressions
            (emacs-jupyter-notebook-jupyter--watch-expressions-plist)))
       (emacs-jupyter-notebook-result--set-busy-indicator ov)
      (when (timerp emacs-jupyter-notebook--evaluation-timer)
        (cancel-timer emacs-jupyter-notebook--evaluation-timer))
      (setq emacs-jupyter-notebook--evaluation-timer
            (run-at-time emacs-jupyter-notebook-evaluation-timeout nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (message "Evaluation timed out after %ss. Kernel may be busy or unresponsive. Use C-c C-k to interrupt."
                                        emacs-jupyter-notebook-evaluation-timeout)
                               (setq emacs-jupyter-notebook--kernel-status 'busy)
                               (force-mode-line-update t))))))
      (jupyter-run-with-state
       client
       (jupyter-sent
        (jupyter-message-subscribed
          (jupyter-execute-request
           :code code
           :store-history nil
           :user-expressions watch-expressions
           :handlers '("input_request"))
          callbacks))))))

(defun emacs-jupyter-notebook-jupyter--interrupt (client)
  "Interrupt CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-interrupt-kernel client))

(defun emacs-jupyter-notebook-jupyter--restart (client)
  "Restart CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-restart-kernel client))

(defun emacs-jupyter-notebook-jupyter--shutdown (client)
  "Shut down CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-shutdown-kernel client))

(defun emacs-jupyter-notebook-jupyter--safe-callback (callback reply error-data)
  "Call CALLBACK with REPLY and ERROR-DATA without leaking callback errors."
  (condition-case err
      (funcall callback reply error-data)
    (error
     (message "emacs-jupyter-notebook: callback failed: %s"
              (error-message-string err)))))

(defun emacs-jupyter-notebook-jupyter--send-request (client request reply-type callback)
  "Send REQUEST through CLIENT and call CALLBACK when REPLY-TYPE arrives."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-messages)
  (require 'jupyter-monads)
  (condition-case err
      (jupyter-run-with-state
       client
       (jupyter-sent
        (jupyter-message-subscribed
         request
         `((,reply-type
            ,(lambda (msg)
               (emacs-jupyter-notebook-jupyter--safe-callback
                callback (jupyter-message-content msg) nil)))))))
    (error
     (emacs-jupyter-notebook-jupyter--safe-callback callback nil err))))

(defun emacs-jupyter-notebook-jupyter--complete (client code cursor-pos callback)
  "Send a Jupyter completion request for CODE at CURSOR-POS."
  (emacs-jupyter-notebook-jupyter--send-request
   client
   (jupyter-complete-request :code code :pos cursor-pos :handlers nil)
   "complete_reply"
   callback))

(defun emacs-jupyter-notebook-jupyter--inspect (client code cursor-pos detail callback)
  "Send a Jupyter inspect request for CODE at CURSOR-POS."
  (emacs-jupyter-notebook-jupyter--send-request
   client
   (jupyter-inspect-request
    :code code :pos cursor-pos :detail detail :handlers nil)
   "inspect_reply"
   callback))

(defun emacs-jupyter-notebook-jupyter--is-complete (client code callback)
  "Send a Jupyter is-complete request for CODE."
  (emacs-jupyter-notebook-jupyter--send-request
   client
   (jupyter-is-complete-request :code code :handlers nil)
   "is_complete_reply"
   callback))

(defun emacs-jupyter-notebook-jupyter-connect (connection-file)
  "Connect to CONNECTION-FILE through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-connect-function connection-file))

(defun emacs-jupyter-notebook-jupyter-connect-async (connection-file callback)
  "Connect to CONNECTION-FILE asynchronously through the configured adapter.
Call CALLBACK with the client on success, or nil on failure."
  (funcall emacs-jupyter-notebook-jupyter-connect-async-function
           connection-file callback))

(defun emacs-jupyter-notebook-jupyter-evaluate (client code beg end)
  "Evaluate CODE through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-evaluate-function client code beg end))

(defun emacs-jupyter-notebook-jupyter-interrupt (client)
  "Interrupt CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-interrupt-function client))

(defun emacs-jupyter-notebook-jupyter-restart (client)
  "Restart CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-restart-function client))

(defun emacs-jupyter-notebook-jupyter-shutdown (client)
  "Shut down CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-shutdown-function client))

(defun emacs-jupyter-notebook-jupyter-complete (client code cursor-pos callback)
  "Complete CODE at CURSOR-POS through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-complete-function
           client code cursor-pos callback))

(defun emacs-jupyter-notebook-jupyter-inspect (client code cursor-pos detail callback)
  "Inspect CODE at CURSOR-POS through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-inspect-function
           client code cursor-pos detail callback))

(defun emacs-jupyter-notebook-jupyter-is-complete (client code callback)
  "Check whether CODE is complete through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-is-complete-function
           client code callback))

(defun emacs-jupyter-notebook-jupyter-clear-overlays ()
  "Clear emacs-jupyter's own evaluation overlays when available."
  (when (and (featurep 'jupyter-client)
             (fboundp 'jupyter-eval-remove-overlays))
    (jupyter-eval-remove-overlays)))

(provide 'emacs-jupyter-notebook-jupyter)

;;; emacs-jupyter-notebook-jupyter.el ends here
