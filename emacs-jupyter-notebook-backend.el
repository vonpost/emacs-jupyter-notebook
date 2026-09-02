;;; emacs-jupyter-notebook-backend.el --- Async kernel backend contract  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors

;;; Commentary:
;; The notebook core talks to this small, asynchronous contract rather than
;; to a Jupyter client object.  A session is opaque outside this file and its
;; transport is always the supervised local helper.

;;; Code:

(require 'cl-lib)
(require 'emacs-jupyter-notebook-vars)

(cl-defstruct (emacs-jupyter-notebook-backend-session
               (:constructor emacs-jupyter-notebook-backend--make-session))
  "Opaque local handle for one backend attachment."
  identity
  backend
  data
  owner-buffer
  event-sink
  failure-sink
  failure-emitted
  attached
  installed
  closed
  requests
  timers
  dispatch-depth
  local-disposer)

(cl-defstruct (emacs-jupyter-notebook-backend-request
               (:constructor emacs-jupyter-notebook-backend--make-request))
  "A single asynchronous backend operation."
  id
  operation
  session
  callback
  error-callback
  terminal)

(defvar emacs-jupyter-notebook-backend--request-counter 0
  "Monotonic identifier source for backend operations.")

(defvar emacs-jupyter-notebook-backend-close-timeout 5
  "Maximum seconds to await a backend's local-close acknowledgement.

The deadline is local-only.  Expiry retires the request with an error and
never dispatches a kernel shutdown operation.")

(defvar emacs-jupyter-notebook-backend-implementations nil
  "Alist mapping backend selector symbols to dispatch functions.

A dispatch function receives SESSION, REQUEST, OPERATION, PAYLOAD, SUCCESS,
FAILURE, and EMIT.  It must return immediately; SUCCESS and FAILURE receive
one value, and EMIT receives one normalized event plist.")

(defun emacs-jupyter-notebook-backend-ensure ()
  "Validate that the helper backend dispatcher is installed."
  (emacs-jupyter-notebook-backend--dispatch-for 'helper))

(defun emacs-jupyter-notebook-backend--dispatch-for (backend)
  "Return the helper dispatch function for BACKEND.
Reject every other transport; there is no legacy fallback."
  (unless (eq backend 'helper)
    (error "Unsupported emacs-jupyter-notebook backend: %S" backend))
  (or (cdr (assq 'helper emacs-jupyter-notebook-backend-implementations))
      (error "The emacs-jupyter-notebook helper backend is not loaded")))

(defun emacs-jupyter-notebook-backend-session-create
    (&optional event-sink owner-buffer failure-sink)
  "Create an opaque backend session owned by OWNER-BUFFER.

EVENT-SINK receives normalized event plists as `(SESSION EVENT)'.  Creating a
session allocates no remote or durable resource; `backend-connect' performs
the asynchronous attachment.  FAILURE-SINK receives `(SESSION REASON)' once
when the adapter proves its local transport is unusable independently of any
single request."
  (emacs-jupyter-notebook-backend--make-session
   :identity (gensym "ejn-backend-session-")
   :backend 'helper
   :owner-buffer (or owner-buffer (current-buffer))
   :event-sink event-sink
   :failure-sink failure-sink
   :requests (make-hash-table :test #'eql)
   :timers nil
   :dispatch-depth 0))

(defun emacs-jupyter-notebook-backend--session-live-p (session)
  "Return non-nil when SESSION can still deliver a local callback."
  (and (emacs-jupyter-notebook-backend-session-p session)
       (not (emacs-jupyter-notebook-backend-session-closed session))
       (let ((buffer (emacs-jupyter-notebook-backend-session-owner-buffer session)))
         (or (null buffer) (buffer-live-p buffer)))))

(defun emacs-jupyter-notebook-backend-session-live-p (session)
  "Return non-nil when SESSION still owns a usable local transport.

This predicate exposes only the generic session lifecycle; backend-private
state remains opaque.  In particular, a connect consumer must check this
again when adopting a deferred success because transport failure may retire
the session after the reply was queued."
  (and (emacs-jupyter-notebook-backend--session-live-p session)
       (not (emacs-jupyter-notebook-backend-session-failure-emitted session))))

(defun emacs-jupyter-notebook-backend-session-mark-attached (session)
  "Record that SESSION owns usable local Jupyter channel handles.

This does not assert kernel liveness.  It only permits the existing remote-PID
fallback to retain an attached-but-shell-busy session after verification times
out."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (when (emacs-jupyter-notebook-backend-session-live-p session)
    (setf (emacs-jupyter-notebook-backend-session-attached session) t)
    session))

(defun emacs-jupyter-notebook-backend-session-set-local-disposer (session function)
  "Set SESSION's local-only resource disposer to FUNCTION.

FUNCTION receives one local failure reason.  It is an adapter hook for the
rare case where generic close cannot create its own acknowledgement deadline:
the generic layer still publishes closure first, but must synchronously retire
the adapter's process and temporary files.  It must never perform a remote
kernel operation."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (unless (or (null function) (functionp function))
    (error "Backend local disposer must be a function or nil"))
  (setf (emacs-jupyter-notebook-backend-session-local-disposer session) function)
  session)

(defun emacs-jupyter-notebook-backend--dispose-local (session reason)
  "Run and clear SESSION's adapter-owned local disposer exactly once."
  (when-let ((disposer (emacs-jupyter-notebook-backend-session-local-disposer
                        session)))
    (setf (emacs-jupyter-notebook-backend-session-local-disposer session) nil)
    (emacs-jupyter-notebook-backend--call-safely disposer reason)))

(defun emacs-jupyter-notebook-backend-session-attached-p (session)
  "Return non-nil when SESSION has usable local channel handles."
  (and (emacs-jupyter-notebook-backend-session-live-p session)
       (emacs-jupyter-notebook-backend-session-attached session)))

(defun emacs-jupyter-notebook-backend-session-mark-installed (session)
  "Record that SESSION is now the core's installed local transport.

Attachment only says that local channels exist.  Installation is a later,
backend-neutral lifecycle boundary: the core sets it after durable registry
persistence, immediately before assigning the session as the buffer's current
client.  It lets a backend retire a delayed readiness probe without tearing
down a session that has already been adopted for a busy remote kernel."
  (unless (emacs-jupyter-notebook-backend-session-attached-p session)
    (error "Cannot install an unattached backend session"))
  (setf (emacs-jupyter-notebook-backend-session-installed session) t)
  session)

(defun emacs-jupyter-notebook-backend-session-installed-p (session)
  "Return non-nil when SESSION is the core-installed local transport."
  (and (emacs-jupyter-notebook-backend-session-live-p session)
       (emacs-jupyter-notebook-backend-session-installed session)))

(defun emacs-jupyter-notebook-backend--close-timeout ()
  "Return a finite local-close acknowledgement deadline."
  (if (and (numberp emacs-jupyter-notebook-backend-close-timeout)
           (> emacs-jupyter-notebook-backend-close-timeout 0)
           (<= emacs-jupyter-notebook-backend-close-timeout 300))
      emacs-jupyter-notebook-backend-close-timeout
    5))

(defun emacs-jupyter-notebook-backend--call-safely (function &rest args)
  "Call FUNCTION with ARGS without letting consumer code break the transport."
  (when function
    (condition-case err
        (apply function args)
      (error
       (message "emacs-jupyter-notebook backend callback failed: %s"
                (error-message-string err))))))

(defun emacs-jupyter-notebook-backend--call-in-owner (session function &rest args)
  "Call FUNCTION with ARGS in SESSION's live owner buffer."
  (when (emacs-jupyter-notebook-backend--session-live-p session)
    (let ((owner (emacs-jupyter-notebook-backend-session-owner-buffer session)))
      (if owner
          (with-current-buffer owner
            (apply #'emacs-jupyter-notebook-backend--call-safely function args))
        (apply #'emacs-jupyter-notebook-backend--call-safely function args)))))

(defun emacs-jupyter-notebook-backend--defer (session function &rest args)
  "Run FUNCTION with ARGS after the current backend call returns.

The timer is owned by SESSION and removed before the consumer runs.  Closing a
session cancels its queued consumer deliveries, which makes retirement a hard
barrier even when a dispatcher replied synchronously or re-entrantly."
  (let (timer)
    (setq timer
          (run-at-time
           0 nil
           (lambda ()
             (setf (emacs-jupyter-notebook-backend-session-timers session)
                   (delq timer
                         (emacs-jupyter-notebook-backend-session-timers session)))
             (apply #'emacs-jupyter-notebook-backend--call-in-owner
                    session function args))))
    (push timer (emacs-jupyter-notebook-backend-session-timers session))
    timer))

(defun emacs-jupyter-notebook-backend--defer-close (session function &rest args)
  "Run a terminal close callback in SESSION's owner buffer."
  (run-at-time 0 nil
               (lambda ()
                 (let ((owner (emacs-jupyter-notebook-backend-session-owner-buffer
                               session)))
                   (when (or (null owner) (buffer-live-p owner))
                     (if owner
                         (with-current-buffer owner
                           (apply #'emacs-jupyter-notebook-backend--call-safely
                                  function args))
                       (apply #'emacs-jupyter-notebook-backend--call-safely
                              function args)))))))

(defun emacs-jupyter-notebook-backend--deliver-request
    (session function failure-p &rest args)
  "Deliver a deferred request callback only while SESSION remains usable.
FUNCTION receives ARGS.  A request FAILURE remains observable after a
session-level failure latch, while a previously queued success is fenced."
  (when (or failure-p
            (emacs-jupyter-notebook-backend-session-live-p session))
    (apply #'emacs-jupyter-notebook-backend--call-safely function args)))

(defun emacs-jupyter-notebook-backend--deliver-event
    (session function &rest args)
  "Deliver a deferred event callback only while SESSION remains usable."
  (when (emacs-jupyter-notebook-backend-session-live-p session)
    (apply #'emacs-jupyter-notebook-backend--call-safely function args)))

(defun emacs-jupyter-notebook-backend--finish (request value failure-p)
  "Deliver VALUE for REQUEST once, unless its local session was retired."
  (let ((session (emacs-jupyter-notebook-backend-request-session request)))
    (when (not (emacs-jupyter-notebook-backend-request-terminal request))
      (setf (emacs-jupyter-notebook-backend-request-terminal request) t)
      (remhash (emacs-jupyter-notebook-backend-request-id request)
               (emacs-jupyter-notebook-backend-session-requests session))
      ;; Retirement still consumes the operation.  It only suppresses the
      ;; consumer callback, not request cleanup, so a retained dead session
      ;; cannot accumulate late request objects.
      (when (emacs-jupyter-notebook-backend--session-live-p session)
        (emacs-jupyter-notebook-backend--defer session
         #'emacs-jupyter-notebook-backend--deliver-request
         session
         (if failure-p
             (emacs-jupyter-notebook-backend-request-error-callback request)
           (emacs-jupyter-notebook-backend-request-callback request))
         failure-p (emacs-jupyter-notebook-backend-request-id request) value)))))

(defun emacs-jupyter-notebook-backend-request-fail (request reason)
  "Terminally fail REQUEST without changing its session's local ownership.

This is for a backend operation whose result is no longer required after the
core adopted an attached session.  It consumes the generic request and defers
its error callback as usual, but deliberately does not close or dispose the
session.  Transport failures remain the adapter's responsibility and must use
its normal failure path."
  (unless (emacs-jupyter-notebook-backend-request-p request)
    (error "Not an emacs-jupyter-notebook backend request"))
  (emacs-jupyter-notebook-backend--finish request reason t))

(defun emacs-jupyter-notebook-backend-session-notify-transport-failure
    (session reason)
  "Notify SESSION's owner once that its local transport failed with REASON.

This lifecycle signal is independent of request completion: an installed
session may lose its helper after the connect request already became terminal.
Like ordinary callbacks, a reentrant notification is deferred out of the
backend dispatch stack and consumer errors cannot escape into the transport."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (when (and (emacs-jupyter-notebook-backend--session-live-p session)
             (not (emacs-jupyter-notebook-backend-session-failure-emitted session)))
    (setf (emacs-jupyter-notebook-backend-session-failure-emitted session) t)
    ;; The failure latch is synchronous.  Fence successes/events that were
    ;; queued earlier in this same dispatcher turn before the owner observes
    ;; the failure asynchronously.
    (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
      (when (timerp timer) (cancel-timer timer)))
    (setf (emacs-jupyter-notebook-backend-session-timers session) nil)
    (let ((sink (emacs-jupyter-notebook-backend-session-failure-sink session)))
      (when sink
        (if (> (or (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0) 0)
            ;; This terminal lifecycle delivery must survive the now-failed
            ;; usability predicate and the core's subsequent local close.
            (emacs-jupyter-notebook-backend--defer-close
             session sink session reason)
          (emacs-jupyter-notebook-backend--call-in-owner
           session sink session reason))))))

(defun emacs-jupyter-notebook-backend--emit (session event)
  "Deliver normalized EVENT to SESSION's sink when it is still locally live.

Only an event emitted re-entrantly from the public dispatch call is deferred.
Later transport events run the sink synchronously, so the next backend can
apply backpressure at its real drain boundary instead of accumulating one
timer per output frame."
  (when (emacs-jupyter-notebook-backend-session-live-p session)
    (if (> (or (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0) 0)
        (emacs-jupyter-notebook-backend--defer
         session #'emacs-jupyter-notebook-backend--deliver-event session
         (emacs-jupyter-notebook-backend-session-event-sink session) session event)
      (emacs-jupyter-notebook-backend--call-in-owner
       session (emacs-jupyter-notebook-backend-session-event-sink session)
       session event))))

(defun emacs-jupyter-notebook-backend--start (session operation payload callback error-callback)
  "Start OPERATION with PAYLOAD and return its request id immediately."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (unless (emacs-jupyter-notebook-backend-session-live-p session)
    (error "The backend session is closed"))
  (let* ((id (cl-incf emacs-jupyter-notebook-backend--request-counter))
         (request (emacs-jupyter-notebook-backend--make-request
                   :id id :operation operation :session session
                   :callback callback :error-callback error-callback)))
    (puthash id request (emacs-jupyter-notebook-backend-session-requests session))
    (cl-incf (emacs-jupyter-notebook-backend-session-dispatch-depth session))
    (unwind-protect
        (condition-case err
            (funcall (emacs-jupyter-notebook-backend--dispatch-for
                      (emacs-jupyter-notebook-backend-session-backend session))
                     session request operation payload
                     (lambda (value)
                       (emacs-jupyter-notebook-backend--finish request value nil))
                     (lambda (reason)
                       (emacs-jupyter-notebook-backend--finish request reason t))
                     (lambda (event)
                       (emacs-jupyter-notebook-backend--emit session event)))
          (error
           (emacs-jupyter-notebook-backend--finish request err t)))
      (setf (emacs-jupyter-notebook-backend-session-dispatch-depth session)
            (max 0 (1- (or (emacs-jupyter-notebook-backend-session-dispatch-depth session)
                            0)))))
    id))

(defun emacs-jupyter-notebook-backend-connect (session connection-file callback error-callback)
  "Asynchronously attach SESSION to CONNECTION-FILE and return a request id."
  (emacs-jupyter-notebook-backend--start session 'connect connection-file callback error-callback))

(defun emacs-jupyter-notebook-backend-close-local (session callback error-callback)
  "Release SESSION's local transport only and return a request id.

This operation is intentionally distinct from control `shutdown': it must
never terminate the durable remote kernel."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (if (emacs-jupyter-notebook-backend-session-closed session)
      (let ((id (cl-incf emacs-jupyter-notebook-backend--request-counter)))
        (emacs-jupyter-notebook-backend--defer-close session callback id nil)
        id)
    (let ((id (cl-incf emacs-jupyter-notebook-backend--request-counter))
          (terminal nil)
          deadline)
      (cl-labels ((finish (value failure-p)
                    (unless terminal
                      (setq terminal t)
                      (when (timerp deadline)
                        (cancel-timer deadline))
                      ;; The adapter normally disposes before acknowledging
                      ;; close.  Keep this idempotent fallback on every
                      ;; terminal path so a timeout, dispatcher error, or
                      ;; malformed adapter cannot strand local resources.
                      (emacs-jupyter-notebook-backend--dispose-local session value)
                      (setf (emacs-jupyter-notebook-backend-session-data session) nil
                            (emacs-jupyter-notebook-backend-session-attached session) nil
                            (emacs-jupyter-notebook-backend-session-installed session) nil)
                      ;; The adapter normally retires this itself before its
                      ;; close callback.  Clearing it here also releases a
                      ;; closure after an immediate generic deadline failure.
                      (setf (emacs-jupyter-notebook-backend-session-local-disposer session) nil)
                      (emacs-jupyter-notebook-backend--defer-close
                       session (if failure-p error-callback callback) id value))))
      ;; Retire before the helper disposer runs so re-entrant and late replies
      ;; cannot mutate a replacement session in the same source buffer.
      (setf (emacs-jupyter-notebook-backend-session-closed session) t)
      (clrhash (emacs-jupyter-notebook-backend-session-requests session))
      (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
        (when (timerp timer) (cancel-timer timer)))
      (setf (emacs-jupyter-notebook-backend-session-timers session) nil)
      (condition-case deadline-error
          (setq deadline
                (run-at-time
                 (emacs-jupyter-notebook-backend--close-timeout) nil
                 (lambda ()
                   (finish "Backend local close timed out" t))))
        (error
         ;; There is no finite generic timer to recover this path later.
         ;; Retire adapter-owned local resources synchronously, while leaving
         ;; the durable remote kernel entirely untouched.
         (finish (format "cannot arm backend local close deadline: %s"
                         (error-message-string deadline-error))
                 t)))
      (unless terminal
        (condition-case err
            (funcall (emacs-jupyter-notebook-backend--dispatch-for
                      (emacs-jupyter-notebook-backend-session-backend session))
                     session nil 'close-local nil
                     (lambda (value) (finish value nil))
                     (lambda (reason) (finish reason t))
                     #'ignore)
          (error
           (finish err t))))
      id))))

(defun emacs-jupyter-notebook-backend-execute (session code options callback &optional error-callback)
  "Asynchronously execute CODE with OPTIONS and return a request id."
  (emacs-jupyter-notebook-backend--start
   session 'execute (list :code code :options options) callback
   (or error-callback #'ignore)))

(defun emacs-jupyter-notebook-backend-aux (session operation payload callback &optional error-callback)
  "Run asynchronous auxiliary OPERATION with PAYLOAD and return a request id."
  (emacs-jupyter-notebook-backend--start
   session (cons 'aux operation) payload callback (or error-callback #'ignore)))

(defun emacs-jupyter-notebook-backend-control (session operation payload callback &optional error-callback)
  "Run asynchronous control OPERATION with PAYLOAD and return a request id."
  (emacs-jupyter-notebook-backend--start
   session (cons 'control operation) payload callback (or error-callback #'ignore)))

(defun emacs-jupyter-notebook-backend-input (session request-id value callback &optional error-callback)
  "Send VALUE for REQUEST-ID asynchronously and return a backend request id."
  (emacs-jupyter-notebook-backend--start
   session 'input (list :request-id request-id :value value) callback
   (or error-callback #'ignore)))

(provide 'emacs-jupyter-notebook-backend)

;;; emacs-jupyter-notebook-backend.el ends here
