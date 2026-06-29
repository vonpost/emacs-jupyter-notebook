;;; emacs-jupyter-notebook-jupyter.el --- Lazy emacs-jupyter adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Thin, mockable adapter around emacs-jupyter.  This file intentionally
;; avoids requiring emacs-jupyter at top level so local ERT tests can run
;; without that package installed.
;;
;; W2: callbacks drive the panel API in `emacs-jupyter-notebook-result.el'
;; rather than mutating source-buffer overlays.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-result)

(declare-function jupyter-kernel "jupyter-kernel" (&rest args))
(declare-function jupyter-client "jupyter-client" (kernel &optional client-class))
(declare-function jupyter-io "jupyter-kernel-process" (kernel))
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
(declare-function jupyter-eval-ov--fold-string "jupyter-client" (text))
(defvar jupyter-current-client)
(defvar jupyter-default-timeout)
(defvar jupyter-long-timeout)
(defvar emacs-jupyter-notebook--kernel-status nil)
(defvar emacs-jupyter-notebook--evaluation-timer nil)
(defvar emacs-jupyter-notebook--evaluation-request nil)
(defvar emacs-jupyter-notebook--evaluation-request-counter 0)
(declare-function emacs-jupyter-notebook--evaluation-on-timeout
                  "emacs-jupyter-notebook" (request-id))

(defun emacs-jupyter-notebook-jupyter--message-content-value (msg key)
  "Return KEY from MSG content."
  (plist-get (jupyter-message-content msg) key))

(defun emacs-jupyter-notebook-jupyter--result-mime-data (msg)
  "Return the MIME data plist from result MSG, or nil."
  (plist-get (jupyter-message-content msg) :data))

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

(defun emacs-jupyter-notebook-jupyter--ansi (text)
  "Apply ANSI color escapes in TEXT for panel display."
  (when text (ansi-color-apply text)))

(defun emacs-jupyter-notebook-jupyter--callbacks (buffer entry-handle &optional client)
  "Return execution callbacks that drive panel ENTRY-HANDLE in BUFFER.

Stream/execute_result/display_data/update_display_data/error/clear_output/
execute_reply/status all flow through the panel API; the source BUFFER
is not mutated.  The optional CLIENT is used to reply to input_request
prompts."
  (let ((had-result nil))
    `(("input_request"
       ,(lambda (msg)
          (condition-case nil
              (let* ((content (jupyter-message-content msg))
                     (prompt (or (plist-get content :prompt) ""))
                     (password (plist-get content :password)))
                (ejn-panel-append-text entry-handle prompt)
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
              (let ((wait (plist-get (jupyter-message-content msg) :wait)))
                (ejn-panel-clear-entry entry-handle wait))
            (error nil))))
      ("stream"
       ,(lambda (msg)
          (condition-case nil
              (let ((text (emacs-jupyter-notebook-jupyter--message-content-value msg :text))
                    (name (emacs-jupyter-notebook-jupyter--message-content-value msg :name)))
                (when (and text (not (string-empty-p text)))
                  (setq had-result t)
                  (ejn-panel-append-text
                   entry-handle
                   (emacs-jupyter-notebook-jupyter--ansi text)
                   (when (equal name "stderr")
                     'emacs-jupyter-notebook-result-error-face))))
            (error nil))))
      ("execute_result"
       ,(lambda (msg)
          (condition-case nil
              (when-let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg))
                         (rendered (emacs-jupyter-notebook--render-mime-result data)))
                (setq had-result t)
                (if (get-text-property 0 'display rendered)
                    (ejn-panel-set-image
                     entry-handle (get-text-property 0 'display rendered))
                  (ejn-panel-replace-text
                   entry-handle
                   (emacs-jupyter-notebook-jupyter--ansi rendered))))
            (error nil))))
      ("display_data"
       ,(lambda (msg)
          (condition-case nil
              (let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg)))
                (when data
                  (let ((rendered (emacs-jupyter-notebook--render-mime-result data)))
                    (setq had-result t)
                    (cond
                     ((null rendered)
                      (ejn-panel-append-text
                       entry-handle "[unsupported output format]"))
                     ((get-text-property 0 'display rendered)
                      (ejn-panel-set-image
                       entry-handle (get-text-property 0 'display rendered)))
                     (t
                      (ejn-panel-append-text
                       entry-handle
                       (emacs-jupyter-notebook-jupyter--ansi rendered)))))))
            (error nil))))
      ("update_display_data"
       ,(lambda (msg)
          (condition-case nil
              (let ((data (emacs-jupyter-notebook-jupyter--result-mime-data msg)))
                (when data
                  (let ((rendered (emacs-jupyter-notebook--render-mime-result data)))
                    (setq had-result t)
                    (cond
                     ((null rendered)
                      (ejn-panel-replace-text
                       entry-handle "[unsupported output format]"))
                     ((get-text-property 0 'display rendered)
                      (ejn-panel-set-image
                       entry-handle (get-text-property 0 'display rendered)))
                     (t
                      (ejn-panel-replace-text
                       entry-handle
                       (emacs-jupyter-notebook-jupyter--ansi rendered)))))))
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
                (ejn-panel-append-text
                 entry-handle text
                 'emacs-jupyter-notebook-result-error-face))
            (error nil))))
      ("execute_reply"
       ,(lambda (msg)
          (condition-case nil
              (progn
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (timerp emacs-jupyter-notebook--evaluation-timer)
                      (cancel-timer emacs-jupyter-notebook--evaluation-timer))
                    (setq emacs-jupyter-notebook--evaluation-timer nil)
                    ;; W5.1: clear the in-flight request record.  The reply
                    ;; for *this* request is the canonical termination
                    ;; signal; the timeout path keys off the same slot to
                    ;; know there is something to interrupt.
                    (setq emacs-jupyter-notebook--evaluation-request nil)))
                (let* ((status-s (emacs-jupyter-notebook-jupyter--message-content-value
                                  msg :status))
                       (count (emacs-jupyter-notebook-jupyter--message-content-value
                               msg :execution_count))
                       (watch-text (emacs-jupyter-notebook-jupyter--watch-results-text
                                    (emacs-jupyter-notebook-jupyter--message-content-value
                                     msg :user_expressions)))
                       (status-sym (cond ((equal status-s "ok") 'ok)
                                         ((equal status-s "error") 'error)
                                         (t 'ok))))
                  (when watch-text
                    (setq had-result t)
                    (ejn-panel-append-text entry-handle watch-text))
                  (unless had-result
                    (when (equal status-s "error")
                      (ejn-panel-append-text
                       entry-handle
                       (format "%s: %s"
                               (or (emacs-jupyter-notebook-jupyter--message-content-value
                                    msg :ename) "Error")
                               (or (emacs-jupyter-notebook-jupyter--message-content-value
                                    msg :evalue) ""))
                       'emacs-jupyter-notebook-result-error-face)))
                  (ejn-panel-finish-entry entry-handle status-sym count)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (let ((cell-key (plist-get entry-handle :cell-key)))
                        (when cell-key
                          (emacs-jupyter-notebook-fringe-set
                           cell-key status-sym count)))))))
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

(defvar emacs-jupyter-notebook-jupyter-kernel-info-function
  #'emacs-jupyter-notebook-jupyter--kernel-info
  "Function used by `emacs-jupyter-notebook-jupyter-kernel-info'.
The function is called with CLIENT and CALLBACK.  CALLBACK receives two
arguments: reply content (or nil) and error data (or nil).  The W4.5
heartbeat uses this adapter so the kernel-info request can be mocked
without requiring a real Jupyter kernel in tests.")

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

(defun emacs-jupyter-notebook-jupyter--evaluate (client code entry-handle)
  "Evaluate CODE through CLIENT, sending callbacks driving ENTRY-HANDLE.

The caller (the eval entry-point) creates ENTRY-HANDLE on the source
buffer's panel before calling this function.  This function is
adapter-only: the buffer-local evaluation timer and panel wiring live
in the caller's surface."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-client)
  (require 'jupyter-messages)
  (require 'jupyter-monads)
  (let* ((buffer (current-buffer))
         (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                     buffer entry-handle client))
         (watch-expressions
          (emacs-jupyter-notebook-jupyter--watch-expressions-plist))
         (request-id (cl-incf emacs-jupyter-notebook--evaluation-request-counter))
         (cell-key (plist-get entry-handle :cell-key)))
    (when (timerp emacs-jupyter-notebook--evaluation-timer)
      (cancel-timer emacs-jupyter-notebook--evaluation-timer))
    ;; W5.1: record the in-flight request so the timeout, cancel, and
    ;; future-reply paths can correlate this dispatch with its panel
    ;; entry.  Cleared by `execute_reply' (in --callbacks) on normal
    ;; completion, and by the timeout/cancel paths on abnormal exits.
    (setq emacs-jupyter-notebook--evaluation-request
          (list :request-id request-id
                :panel-entry entry-handle
                :cell-key cell-key
                :started-at (float-time)))
    (setq emacs-jupyter-notebook--evaluation-timer
          (run-at-time
           emacs-jupyter-notebook-evaluation-timeout nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (emacs-jupyter-notebook--evaluation-on-timeout
                  request-id))))))
    (jupyter-run-with-state
     client
     (jupyter-sent
      (jupyter-message-subscribed
       (jupyter-execute-request
        :code code
        :store-history nil
        :user-expressions watch-expressions
        :handlers '("input_request"))
       callbacks)))))

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

(defun emacs-jupyter-notebook-jupyter--kernel-info (client callback)
  "Send a Jupyter kernel-info request through CLIENT.
CALLBACK is invoked with the reply content and error data when the
`kernel_info_reply' arrives; if the request errors out before sending,
CALLBACK is called with nil reply and the error data."
  (emacs-jupyter-notebook-jupyter--send-request
   client
   (jupyter-kernel-info-request :handlers nil)
   "kernel_info_reply"
   callback))

(defun emacs-jupyter-notebook-jupyter-connect (connection-file)
  "Connect to CONNECTION-FILE through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-connect-function connection-file))

(defun emacs-jupyter-notebook-jupyter-connect-async (connection-file callback)
  "Connect to CONNECTION-FILE asynchronously through the configured adapter.
Call CALLBACK with the client on success, or nil on failure."
  (funcall emacs-jupyter-notebook-jupyter-connect-async-function
           connection-file callback))

(defun emacs-jupyter-notebook-jupyter-evaluate (client code entry-handle)
  "Evaluate CODE through the configured adapter driving ENTRY-HANDLE."
  (funcall emacs-jupyter-notebook-jupyter-evaluate-function client code entry-handle))

(defun emacs-jupyter-notebook-jupyter-kernel-info (client callback)
  "Send a kernel-info request through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-kernel-info-function client callback))

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

(provide 'emacs-jupyter-notebook-jupyter)

;;; emacs-jupyter-notebook-jupyter.el ends here

