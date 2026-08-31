;;; emacs-jupyter-notebook-backend.el --- Async kernel backend contract  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors

;;; Commentary:
;; The notebook core talks to this small, asynchronous contract rather than
;; to an emacs-jupyter object.  A session is opaque outside this file.  The
;; temporary `legacy' implementation is deliberately selected by default;
;; future transports only need to implement `backend-dispatch'.

;;; Code:

(require 'cl-lib)
(require 'emacs-jupyter-notebook-vars)

(cl-defstruct (emacs-jupyter-notebook-backend-session
               (:constructor emacs-jupyter-notebook-backend--make-session))
  "Opaque local handle for one backend attachment."
  backend
  data
  owner-buffer
  event-sink
  attached
  closed
  requests
  timers
  dispatch-depth)

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

(declare-function emacs-jupyter-notebook-jupyter-backend-dispatch
                  "emacs-jupyter-notebook-jupyter"
                  (session request operation payload success failure emit))
(declare-function emacs-jupyter-notebook-jupyter-backend-ensure
                  "emacs-jupyter-notebook-jupyter" ())

(defun emacs-jupyter-notebook-backend--legacy-dispatch ()
  "Return the legacy dispatcher, loading only the legacy adapter on demand."
  (require 'emacs-jupyter-notebook-jupyter)
  #'emacs-jupyter-notebook-jupyter-backend-dispatch)

(defun emacs-jupyter-notebook-backend-ensure ()
  "Validate that the selected backend can be started without connecting.

This preserves the legacy adapter's early missing-package diagnostic while
keeping that dependency behind the backend boundary."
  (pcase emacs-jupyter-notebook-backend
    ('legacy
     (require 'emacs-jupyter-notebook-jupyter)
     (emacs-jupyter-notebook-jupyter-backend-ensure))
    (_ (emacs-jupyter-notebook-backend--dispatch-for
        emacs-jupyter-notebook-backend))))

(defun emacs-jupyter-notebook-backend--dispatch-for (backend)
  "Return dispatch function for BACKEND or signal a concise configuration error."
  (or (cdr (assq backend emacs-jupyter-notebook-backend-implementations))
      (pcase backend
        ('legacy (emacs-jupyter-notebook-backend--legacy-dispatch))
        (_ (error "No emacs-jupyter-notebook backend is configured for %S" backend)))))

(defun emacs-jupyter-notebook-backend-session-create (&optional event-sink owner-buffer)
  "Create an opaque backend session owned by OWNER-BUFFER.

EVENT-SINK receives normalized event plists as `(SESSION EVENT)'.  Creating a
session allocates no remote or durable resource; `backend-connect' performs
the asynchronous attachment."
  (emacs-jupyter-notebook-backend--make-session
   :backend emacs-jupyter-notebook-backend
   :owner-buffer (or owner-buffer (current-buffer))
   :event-sink event-sink
   :requests (make-hash-table :test #'eql)
   :timers nil
   :dispatch-depth 0))

(defun emacs-jupyter-notebook-backend--session-live-p (session)
  "Return non-nil when SESSION can still deliver a local callback."
  (and (emacs-jupyter-notebook-backend-session-p session)
       (not (emacs-jupyter-notebook-backend-session-closed session))
       (let ((buffer (emacs-jupyter-notebook-backend-session-owner-buffer session)))
         (or (null buffer) (buffer-live-p buffer)))))

(defun emacs-jupyter-notebook-backend-session-mark-attached (session)
  "Record that SESSION owns usable local Jupyter channel handles.

This does not assert kernel liveness.  It only permits the existing remote-PID
fallback to retain an attached-but-shell-busy session after verification times
out."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (when (emacs-jupyter-notebook-backend--session-live-p session)
    (setf (emacs-jupyter-notebook-backend-session-attached session) t)
    session))

(defun emacs-jupyter-notebook-backend-session-attached-p (session)
  "Return non-nil when SESSION has usable local channel handles."
  (and (emacs-jupyter-notebook-backend--session-live-p session)
       (emacs-jupyter-notebook-backend-session-attached session)))

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
         (if failure-p
             (emacs-jupyter-notebook-backend-request-error-callback request)
           (emacs-jupyter-notebook-backend-request-callback request))
         (emacs-jupyter-notebook-backend-request-id request) value)))))

(defun emacs-jupyter-notebook-backend--emit (session event)
  "Deliver normalized EVENT to SESSION's sink when it is still locally live.

Only an event emitted re-entrantly from the public dispatch call is deferred.
Later transport events run the sink synchronously, so the next backend can
apply backpressure at its real drain boundary instead of accumulating one
timer per output frame."
  (when (emacs-jupyter-notebook-backend--session-live-p session)
    (if (> (or (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0) 0)
        (emacs-jupyter-notebook-backend--defer
         session
         (emacs-jupyter-notebook-backend-session-event-sink session) session event)
      (emacs-jupyter-notebook-backend--call-in-owner
       session (emacs-jupyter-notebook-backend-session-event-sink session)
       session event))))

(defun emacs-jupyter-notebook-backend--start (session operation payload callback error-callback)
  "Start OPERATION with PAYLOAD and return its request id immediately."
  (unless (emacs-jupyter-notebook-backend-session-p session)
    (error "Not an emacs-jupyter-notebook backend session"))
  (unless (emacs-jupyter-notebook-backend--session-live-p session)
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
                      (setf (emacs-jupyter-notebook-backend-session-data session) nil
                            (emacs-jupyter-notebook-backend-session-attached session) nil)
                      (emacs-jupyter-notebook-backend--defer-close
                       session (if failure-p error-callback callback) id value))))
      ;; Retire before the legacy disposer runs so re-entrant and late replies
      ;; cannot mutate a replacement session in the same source buffer.
      (setf (emacs-jupyter-notebook-backend-session-closed session) t)
      (clrhash (emacs-jupyter-notebook-backend-session-requests session))
      (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
        (when (timerp timer) (cancel-timer timer)))
      (setf (emacs-jupyter-notebook-backend-session-timers session) nil)
      (setq deadline
            (run-at-time
             (emacs-jupyter-notebook-backend--close-timeout) nil
             (lambda ()
               (finish "Backend local close timed out" t))))
      (condition-case err
          (funcall (emacs-jupyter-notebook-backend--dispatch-for
                    (emacs-jupyter-notebook-backend-session-backend session))
                   session nil 'close-local nil
                   (lambda (value) (finish value nil))
                   (lambda (reason) (finish reason t))
                   #'ignore)
        (error
         (finish err t)))
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
