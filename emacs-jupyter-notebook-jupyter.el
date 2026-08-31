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
(require 'eieio)                        ; oset/make-instance (W15-B)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-events)
(require 'emacs-jupyter-notebook-backend)

(declare-function jupyter-kernel "jupyter-kernel" (&rest args))
(declare-function jupyter-client "jupyter-client" (kernel &optional client-class))
(declare-function jupyter-io "jupyter-kernel-process" (kernel))
(declare-function jupyter-execute-request "jupyter-messages" (&rest args))
(declare-function jupyter-complete-request "jupyter-messages" (&rest args))
(declare-function jupyter-inspect-request "jupyter-messages" (&rest args))
(declare-function jupyter-input-reply "jupyter-messages" (&rest args))
(declare-function jupyter-is-complete-request "jupyter-messages" (&rest args))
(declare-function jupyter-message-content "jupyter-messages" (msg))
(declare-function jupyter-message-subscribed "jupyter-monads" (dreq cbs))
(declare-function jupyter-run-with-state "jupyter-monads" (state mvalue))
(declare-function jupyter-sent "jupyter-monads" (dreq))
(declare-function jupyter-kernel-info-request "jupyter-messages" (&rest args))
(declare-function jupyter-canonicalize-language-string "jupyter-base" (str))
(declare-function jupyter-interrupt-kernel "jupyter-client" (client))
(declare-function jupyter-restart-kernel "jupyter-client" (client))
(declare-function jupyter-shutdown-kernel "jupyter-client" (client))
(declare-function jupyter-disconnect "jupyter-client" (client))
(declare-function jupyter-insert "jupyter-mime" (mime-or-plist &optional metadata))
(declare-function jupyter-eval-ov--fold-string "jupyter-client" (text))
(defvar jupyter-current-client)
(defvar jupyter-default-timeout)
(defvar jupyter-long-timeout)
(defvar emacs-jupyter-notebook--kernel-status nil)
(defconst emacs-jupyter-notebook-jupyter--late-callback-log-limit 20
  "Maximum number of retired-entry callback drops logged per Emacs session.")

(defvar emacs-jupyter-notebook-jupyter--late-callback-log-count 0
  "Number of retired-entry callback drops logged this Emacs session.")
(declare-function emacs-jupyter-notebook-backend-session-data
                  "emacs-jupyter-notebook-backend" (session))
(declare-function emacs-jupyter-notebook-backend-session-owner-buffer
                  "emacs-jupyter-notebook-backend" (session))
(declare-function emacs-jupyter-notebook-backend-session-data--set
                  "emacs-jupyter-notebook-backend" (value session))
(declare-function emacs-jupyter-notebook-backend-session-mark-attached
                  "emacs-jupyter-notebook-backend" (session))

(defun emacs-jupyter-notebook-jupyter--message-content-value (msg key)
  "Return KEY from MSG content."
  (plist-get (jupyter-message-content msg) key))

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

(defun emacs-jupyter-notebook-jupyter--callback-entry-live-p (type handle)
  "Return non-nil when TYPE may still mutate HANDLE's presentation entry.
Late callbacks are expected after `clear-results'.  Log a bounded diagnostic
and make output callbacks inert before MIME decode, artifact materialization,
or pickle storage can happen."
  (if (ejn-panel-entry-live-p handle)
      t
    (when (< emacs-jupyter-notebook-jupyter--late-callback-log-count
             emacs-jupyter-notebook-jupyter--late-callback-log-limit)
      (cl-incf emacs-jupyter-notebook-jupyter--late-callback-log-count)
      (message "emacs-jupyter-notebook: discarded late %s callback for retired output"
               type))
    nil))

(defun emacs-jupyter-notebook-jupyter--legacy-event (message-type msg)
  "Translate legacy MESSAGE-TYPE and MSG into one normalized event plist."
  (let* ((content (and (fboundp 'jupyter-message-content)
                       (jupyter-message-content msg)))
         (value (lambda (key)
                  (if content
                      (plist-get content key)
                    ;; Existing adapter callers may stub this narrow seam
                    ;; without loading emacs-jupyter in deterministic ERT.
                    (emacs-jupyter-notebook-jupyter--message-content-value msg key)))))
    (pcase message-type
      ("input_request" (list :type 'input-request :prompt (funcall value :prompt)
                             :password (funcall value :password)))
      ("clear_output" (list :type 'clear :wait (funcall value :wait)))
      ("stream" (list :type 'stream :text (funcall value :text)
                      :name (funcall value :name)))
      ("execute_result" (list :type 'result :data (funcall value :data)))
      ("display_data" (list :type 'display :data (funcall value :data)))
      ("update_display_data" (list :type 'update-display :data (funcall value :data)))
      ("error" (list :type 'error :traceback (funcall value :traceback)
                     :ename (funcall value :ename) :evalue (funcall value :evalue)))
      ("execute_reply" (list :type 'execute-reply :status (funcall value :status)
                             :execution-count (funcall value :execution_count)
                             :watch-text (emacs-jupyter-notebook-jupyter--watch-results-text
                                          (funcall value :user_expressions))
                             :ename (funcall value :ename) :evalue (funcall value :evalue)))
      ("status" (list :type 'status :execution-state (funcall value :execution_state)))
      (_ (error "Unsupported legacy Jupyter message type: %s" message-type)))))

(defun emacs-jupyter-notebook-jupyter--callbacks
    (buffer entry-handle &optional client request-id backend-request-id)
  "Return legacy callbacks which only translate then dispatch normalized events."
  (let ((had-result nil))
    (cl-labels ((dispatch (message-type msg)
                  (emacs-jupyter-notebook-events-dispatch
                   (list :buffer buffer :entry-handle entry-handle :request-id request-id
                         :backend-request-id backend-request-id
                         :panel-generation (plist-get entry-handle :generation)
                         :had-result had-result
                         :set-had-result (lambda (_value) (setq had-result t))
                         :input-reply (and client
                                           (lambda (value)
                                             (emacs-jupyter-notebook-jupyter--send-input-reply
                                              client value))) )
                   ;; Retired output must be rejected before asking
                   ;; emacs-jupyter to decode MIME/base64.  execute_reply still
                   ;; reaches the reducer with a shape-only event so matching
                   ;; request/timer bookkeeping can settle after panel clear.
                   (cond
                    ((member message-type '("clear_output" "stream" "execute_result"
                                             "display_data" "update_display_data" "error"))
                     (if (emacs-jupyter-notebook-jupyter--callback-entry-live-p
                          message-type entry-handle)
                         (emacs-jupyter-notebook-jupyter--legacy-event message-type msg)
                       (list :type (cdr (assoc message-type
                                                '(("clear_output" . clear)
                                                  ("stream" . stream)
                                                  ("execute_result" . result)
                                                  ("display_data" . display)
                                                  ("update_display_data" . update-display)
                                                  ("error" . error)))))))
                    ((and (not (ejn-panel-entry-live-p entry-handle))
                          (equal message-type "execute_reply"))
                     '(:type execute-reply))
                    (t (emacs-jupyter-notebook-jupyter--legacy-event message-type msg))))))
      (mapcar (lambda (type) (list type (lambda (msg) (dispatch type msg))))
              '("input_request" "clear_output" "stream" "execute_result" "display_data"
                "update_display_data" "error" "execute_reply" "status")))))

(defvar emacs-jupyter-notebook-jupyter-connect-function
  #'emacs-jupyter-notebook-jupyter--connect
  "Function used by `emacs-jupyter-notebook-jupyter-connect'.")

(defvar emacs-jupyter-notebook-jupyter-connect-async-function
  #'emacs-jupyter-notebook-jupyter--connect-async
  "Function used by `emacs-jupyter-notebook-jupyter-connect-async'.")

(defvar emacs-jupyter-notebook-jupyter-evaluate-function
  #'emacs-jupyter-notebook-jupyter--evaluate
  "Function used by `emacs-jupyter-notebook-jupyter-evaluate'.")

(defvar emacs-jupyter-notebook-jupyter--ledger-id nil
  "Dynamically bound execution ledger id for one legacy execute send.")

(defvar emacs-jupyter-notebook-jupyter--backend-request-id nil
  "Dynamically bound generic backend id for one legacy execute send.")

(defvar emacs-jupyter-notebook-jupyter-execute-silent-function
  #'emacs-jupyter-notebook-jupyter--execute-silent
  "Function used by `emacs-jupyter-notebook-jupyter-execute-silent'.
Called with CLIENT and CODE; sends a silent `execute_request' that
produces no output and no panel entry.  Stubbed in W8.1 tests.")

(defvar emacs-jupyter-notebook-jupyter-interrupt-function
  #'emacs-jupyter-notebook-jupyter--interrupt
  "Function used by `emacs-jupyter-notebook-jupyter-interrupt'.")

(defvar emacs-jupyter-notebook-jupyter-restart-function
  #'emacs-jupyter-notebook-jupyter--restart
  "Function used by `emacs-jupyter-notebook-jupyter-restart'.")

(defvar emacs-jupyter-notebook-jupyter-shutdown-function
  #'emacs-jupyter-notebook-jupyter--shutdown
  "Function used by `emacs-jupyter-notebook-jupyter-shutdown'.")

(defvar emacs-jupyter-notebook-jupyter-disconnect-function
  #'emacs-jupyter-notebook-jupyter--disconnect
  "Function used by `emacs-jupyter-notebook-jupyter-disconnect'.
Called with CLIENT; disconnects the local client I/O WITHOUT terminating
the remote kernel.  Stubbed in tests so local teardown can be verified
without a real Jupyter kernel.")

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

(defun emacs-jupyter-notebook-jupyter--connect-unverified (connection-file)
  "Attach a client to the kernel at CONNECTION-FILE without any blocking gate.
Replicates upstream `jupyter-client' on a `jupyter-kernel' MINUS its
constructor's synchronous `jupyter-kernel-info' wait: that gate requires a
shell-channel `kernel_info_reply', which a BUSY kernel queues behind the
currently-running cell — so reconnecting to a kernel mid-training could
never succeed (and blocked the UI for the whole timeout, the old H4 seam).
Construction here is non-blocking: it builds the ZMQ I/O for the session
and returns immediately.  Liveness verification is the caller's job
(W15-B: async kernel-info + PID-probe fallback in the core)."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-kernel)
  (require 'jupyter-client)
  (let ((kernel (jupyter-kernel :conn-info connection-file :connect-p t))
        (client (make-instance 'jupyter-kernel-client)))
    (oset client io (jupyter-io kernel))
    client))

(defun emacs-jupyter-notebook-jupyter--store-kernel-info (client content)
  "Store kernel-info CONTENT on CLIENT the way upstream `jupyter-kernel-info' does.
Populating the slot keeps any later upstream `jupyter-kernel-info' call a
cache hit instead of a blocking shell round trip.  Mirrors the upstream
slot bookkeeping including interning the language name for method
dispatch.  Best-effort: errors are swallowed."
  (ignore-errors
    (oset client kernel-info content)
    (let* ((info (plist-get content :language_info))
           (lang (plist-get info :name)))
      (when (and info (stringp lang))
        (plist-put info :name
                   (intern (jupyter-canonicalize-language-string lang)))))))

(defun emacs-jupyter-notebook-jupyter--connect-async (connection-file callback)
  "Attach to CONNECTION-FILE now; call CALLBACK with the client once verified.
W15-B: returns the UNVERIFIED client immediately (or nil when construction
fails) without blocking the UI.  An async `kernel_info_request' is fired as
the verification probe; when its reply arrives CALLBACK is invoked exactly
once with the client — possibly MUCH later for a busy kernel, whose shell
channel queues the request behind the running cell.  CALLBACK is never
invoked with nil and never invoked on failure: timeout policy belongs to
the caller (`--async-connect-timeout' arbitrates alive-but-busy vs dead via
a remote PID probe)."
  (message "Connecting to Jupyter kernel...")
  (condition-case err
      (let ((client (emacs-jupyter-notebook-jupyter--connect-unverified
                     connection-file))
            (called nil))
        (emacs-jupyter-notebook-jupyter-kernel-info
         client
         (lambda (reply _error)
           (when (and reply (not called))
             (setq called t)
             (emacs-jupyter-notebook-jupyter--store-kernel-info client reply)
             (funcall callback client))))
        client)
    (error
     (message "Failed to connect to Jupyter kernel: %s"
              (error-message-string err))
     nil)))

(defun emacs-jupyter-notebook-jupyter--evaluate
    (client code entry-handle &optional ledger-id backend-request-id)
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
                     buffer entry-handle client
                     (or ledger-id emacs-jupyter-notebook-jupyter--ledger-id)
                     (or backend-request-id
                         emacs-jupyter-notebook-jupyter--backend-request-id)))
         (watch-expressions
          (emacs-jupyter-notebook-jupyter--watch-expressions-plist)))
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

(defun emacs-jupyter-notebook-jupyter--execute-silent (client code)
  "Send CODE to CLIENT as a silent `execute_request'.

W8.1: used to inject the in-memory matplotlib pickle formatter on
connect/restart.  The request sets `:silent t' and `:store-history nil'
and subscribes no callbacks, so it produces no output, no execution
count, and no panel entry.  This is the ONLY remote interaction the W8
feature adds — it registers an in-memory formatter and writes nothing to
the remote filesystem."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-client)
  (require 'jupyter-messages)
  (require 'jupyter-monads)
  (jupyter-run-with-state
   client
   (jupyter-sent
    (jupyter-execute-request
     :code code
     :silent t
     :store-history nil
     :handlers nil))))

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

(defun emacs-jupyter-notebook-jupyter--disconnect (client)
  "Release CLIENT's local I/O WITHOUT terminating the remote kernel.
The remote kernel is durable and outlives the local client; this only drops
the local channel handles so a stale or abandoned client can be reclaimed.

emacs-jupyter's own `jupyter-disconnect' is NOT used: for this client path
its kernel-action handler is inverted — the `disconnect' action runs the
ioloop START, which is a silent no-op while the ioloop is alive — so it
releases nothing.  Instead we unbind the client's `io' slot, which makes the
whole I/O graph (the ZMQ channels and the ioloop subprocess behind them)
unreachable; emacs-jupyter's GC finalizer then deletes the subprocess.  This
is purely local: it sends no message to the kernel, and our clients are
conn-info attachments (the kernel is launched out-of-band over SSH), so
nothing remote is started or stopped.  Best-effort: errors are swallowed
because a half-dead client is exactly the case this is called for."
  (when (emacs-jupyter-notebook-jupyter-available-p)
    (ignore-errors
      (require 'jupyter-client)
      (when (and (eieio-object-p client) (slot-boundp client 'io))
        (slot-makeunbound client 'io)))))

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

(defun emacs-jupyter-notebook-jupyter-evaluate
    (client code entry-handle request-id backend-request-id)
  "Evaluate CODE through the configured adapter driving ENTRY-HANDLE."
  (let ((emacs-jupyter-notebook-jupyter--ledger-id request-id)
        (emacs-jupyter-notebook-jupyter--backend-request-id backend-request-id))
    (funcall emacs-jupyter-notebook-jupyter-evaluate-function client code entry-handle)))

(defun emacs-jupyter-notebook-jupyter-kernel-info (client callback)
  "Send a kernel-info request through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-kernel-info-function client callback))

(defun emacs-jupyter-notebook-jupyter-execute-silent (client code)
  "Send CODE to CLIENT silently through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-execute-silent-function client code))

(defun emacs-jupyter-notebook-jupyter-interrupt (client)
  "Interrupt CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-interrupt-function client))

(defun emacs-jupyter-notebook-jupyter-restart (client)
  "Restart CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-restart-function client))

(defun emacs-jupyter-notebook-jupyter-shutdown (client)
  "Shut down CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-shutdown-function client))

(defun emacs-jupyter-notebook-jupyter-disconnect (client)
  "Disconnect CLIENT's local I/O through the configured adapter.
Never terminates the remote kernel."
  (funcall emacs-jupyter-notebook-jupyter-disconnect-function client))

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

(defun emacs-jupyter-notebook-jupyter--backend-client (session)
  "Return SESSION's private legacy client, if it has been attached."
  (emacs-jupyter-notebook-backend-session-data session))

(defun emacs-jupyter-notebook-jupyter-backend-ensure ()
  "Validate that the legacy emacs-jupyter implementation is available."
  (emacs-jupyter-notebook-jupyter--ensure))

(defun emacs-jupyter-notebook-jupyter--backend-store-client (session client)
  "Store CLIENT inside opaque SESSION at the legacy adapter boundary."
  (setf (emacs-jupyter-notebook-backend-session-data session) client))

(defun emacs-jupyter-notebook-jupyter--backend-reply (success failure)
  "Adapt a legacy REPLY/ERROR CALLBACK to contract SUCCESS and FAILURE."
  (lambda (reply error-data)
    (if error-data
        (funcall failure error-data)
      (funcall success reply))))

(defun emacs-jupyter-notebook-jupyter-backend-dispatch
    (session request operation payload success failure emit)
  "Dispatch one opaque backend OPERATION through the legacy emacs-jupyter API.

This is the sole compatibility implementation during EI1.  It owns all
legacy-client access; callers above the backend contract never inspect the
EIEIO client.  SUCCESS and FAILURE are request-terminal callbacks and EMIT
receives normalized local lifecycle events."
  (let ((client (emacs-jupyter-notebook-jupyter--backend-client session)))
    (condition-case err
        (pcase operation
          ('connect
           (let (verified connected)
             (setq connected
                   (emacs-jupyter-notebook-jupyter-connect-async
                    payload
                    (lambda (raw-client)
                      (when (and raw-client
                                 (emacs-jupyter-notebook-backend-session-mark-attached
                                  session))
                        (setq verified t)
                        (emacs-jupyter-notebook-jupyter--backend-store-client
                         session raw-client)
                        (funcall emit (list :type 'connected))
                        (funcall success session)))))
             ;; The legacy adapter deliberately exposes an unverified client
             ;; immediately for the busy-kernel timeout arbitration.  It is
             ;; still opaque to the core as SESSION.
             (if connected
                 (when (emacs-jupyter-notebook-backend-session-mark-attached
                        session)
                   (emacs-jupyter-notebook-jupyter--backend-store-client
                    session connected)
                   (unless verified
                     (funcall emit (list :type 'connecting))))
               (unless verified
                 (funcall failure "Could not attach to the kernel connection file")))))
          ('close-local
           (when client
             (emacs-jupyter-notebook-jupyter-disconnect client))
           (funcall emit (list :type 'closed-local))
           (funcall success nil))
          ('execute
           (let ((code (plist-get payload :code))
                 (options (plist-get payload :options)))
             (if (plist-get options :silent)
                 (emacs-jupyter-notebook-jupyter-execute-silent client code)
               (emacs-jupyter-notebook-jupyter-evaluate
                client code (plist-get options :entry-handle)
                (plist-get options :ledger-id)
                (emacs-jupyter-notebook-backend-request-id request)))
             (funcall emit (list :type 'execute-sent
                                 :silent (and (plist-get options :silent) t)))
             (funcall success nil)))
          (`(aux . complete)
           (emacs-jupyter-notebook-jupyter-complete
            client (plist-get payload :code) (plist-get payload :cursor-pos)
            (emacs-jupyter-notebook-jupyter--backend-reply success failure)))
          (`(aux . inspect)
           (emacs-jupyter-notebook-jupyter-inspect
            client (plist-get payload :code) (plist-get payload :cursor-pos)
            (or (plist-get payload :detail) 0)
            (emacs-jupyter-notebook-jupyter--backend-reply success failure)))
          (`(aux . is-complete)
           (emacs-jupyter-notebook-jupyter-is-complete
            client (plist-get payload :code)
            (emacs-jupyter-notebook-jupyter--backend-reply success failure)))
          (`(aux . kernel-info)
           (emacs-jupyter-notebook-jupyter-kernel-info
            client (emacs-jupyter-notebook-jupyter--backend-reply success failure)))
          (`(control . interrupt)
           (emacs-jupyter-notebook-jupyter-interrupt client)
           (funcall emit (list :type 'interrupt-sent))
           (funcall success nil))
          (`(control . restart)
           (emacs-jupyter-notebook-jupyter-restart client)
           (funcall emit (list :type 'restart-sent))
           (funcall success nil))
          (`(control . shutdown)
           (emacs-jupyter-notebook-jupyter-shutdown client)
           (funcall emit (list :type 'shutdown-sent))
           (funcall success nil))
          ('input
           (emacs-jupyter-notebook-jupyter--send-input-reply
            client (plist-get payload :value))
           (funcall emit (list :type 'input-sent
                               :request-id (plist-get payload :request-id)))
           (funcall success nil))
          (_ (funcall failure (format "Unsupported backend operation %S" operation))))
      (error (funcall failure err)))))

(provide 'emacs-jupyter-notebook-jupyter)

;;; emacs-jupyter-notebook-jupyter.el ends here
