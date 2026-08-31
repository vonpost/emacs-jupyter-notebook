;;; emacs-jupyter-notebook-helper.el --- Local helper supervision -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; This module owns only the local helper process and its initial protocol
;; handshake.  It never contacts a kernel, SSH, or the durable registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-helper-protocol)

(defconst emacs-jupyter-notebook-helper--hard-timeout 300)
(defconst emacs-jupyter-notebook-helper--hard-stderr-bytes 1048576)
(defconst emacs-jupyter-notebook-helper--initial-event-credit 262144)
(defconst emacs-jupyter-notebook-helper--max-event-queue 1048576)
(defconst emacs-jupyter-notebook-helper--max-priority-queue 524288)
(defconst emacs-jupyter-notebook-helper--max-response-frame 65536)
(defconst emacs-jupyter-notebook-helper--filter-max-frames 16)
(defconst emacs-jupyter-notebook-helper--filter-max-payload-bytes 262144)
(defconst emacs-jupyter-notebook-helper--max-late-responses 64)
(defvar emacs-jupyter-notebook-helper--ping-interval 5)
(defvar emacs-jupyter-notebook-helper--ping-timeout 2)
(defvar emacs-jupyter-notebook-helper--control-ack-timeout 2)
(defconst emacs-jupyter-notebook-helper--module-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory))))

(cl-defstruct (emacs-jupyter-notebook-helper-request
               (:constructor emacs-jupyter-notebook-helper--make-request))
  id op callback timer finished)

(cl-defstruct (emacs-jupyter-notebook-helper-session
               (:constructor emacs-jupyter-notebook-helper--make-session))
  id owner-buffer process stderr-process stderr-buffer decoder state hello-id
  hello-timer partial-timer ready-callback failure-callback closed-callback
  failure-emitted disposed event-callback event-credit requests request-sequence
  control-sequence raw-chunks raw-tail raw-bytes decode-prefix decode-remaining
  decode-wire-size decode-timer event-queue event-tail event-queue-bytes
  priority-queue priority-tail priority-queue-bytes drain-timer pending-failure
  ping-id ping-timer late-responses last-event-seq control-sent control-acked control-timer
  wire-sequence)

(defvar-local emacs-jupyter-notebook--helper-session nil
  "The local helper session currently owned by this source buffer.")

(defvar emacs-jupyter-notebook-helper--sessions nil
  "Live local helper sessions, used exclusively for local cleanup.")

(defvar emacs-jupyter-notebook-helper--next-id 0)

(defun emacs-jupyter-notebook-helper--bounded-positive-number (value fallback)
  "Return VALUE when it is a sensible finite timeout, otherwise FALLBACK."
  (if (and (numberp value) (> value 0) (<= value emacs-jupyter-notebook-helper--hard-timeout))
      value
    fallback))

(defun emacs-jupyter-notebook-helper--frame-limit ()
  "Return the configured, protocol-safe complete frame ceiling."
  (let ((value emacs-jupyter-notebook-helper-max-to-emacs-frame))
    (if (and (integerp value) (> value 4)
             (<= value ejn-helper-protocol-max-to-emacs-frame))
        value
      ejn-helper-protocol-max-to-emacs-frame)))

(defun emacs-jupyter-notebook-helper--accumulator-limit (frame-limit)
  "Return the configured, protocol-safe stdout accumulator ceiling."
  (let ((value emacs-jupyter-notebook-helper-raw-accumulator-max-bytes))
    (if (and (integerp value) (>= value frame-limit)
             (<= value ejn-helper-protocol-max-raw-accumulator))
        value
      ejn-helper-protocol-max-raw-accumulator)))

(defun emacs-jupyter-notebook-helper--stderr-limit ()
  "Return the finite stderr retention ceiling."
  (let ((value emacs-jupyter-notebook-helper-stderr-max-bytes))
    (if (and (integerp value) (> value 0)
             (<= value emacs-jupyter-notebook-helper--hard-stderr-bytes))
        value
      65536)))

(defun emacs-jupyter-notebook-helper--source-directory ()
  "Return the physical directory containing this module.
`file-truename' deliberately crosses checkout/build symlinks before command
resolution, while the fallback candidates below retain their normal names."
  emacs-jupyter-notebook-helper--module-directory)

(defun emacs-jupyter-notebook-helper--resolve-program (program)
  "Resolve PROGRAM without depending on `default-directory'."
  (cond
   ((not (and (stringp program) (not (string-empty-p program)))) nil)
   ((file-name-absolute-p program)
    (and (file-executable-p program) (file-truename program)))
   ((file-name-directory program)
    (let ((candidate (expand-file-name program
                                       (emacs-jupyter-notebook-helper--source-directory))))
      (and (file-executable-p candidate) (file-truename candidate))))
   ((executable-find program))
   (t
    (let* ((source (emacs-jupyter-notebook-helper--source-directory))
           (candidates
            (list (expand-file-name (concat "result/bin/" program) source)
                  (expand-file-name (concat "../result/bin/" program) source)
                  (expand-file-name (concat "bin/" program) source))))
      (cl-loop for candidate in candidates
               when (file-executable-p candidate)
               return (file-truename candidate))))))

(defun emacs-jupyter-notebook-helper-resolve-argv (&optional command)
  "Resolve configured helper COMMAND to an executable argv list.
Signals a normal error before starting a process when the configuration is
empty or the executable cannot be found."
  (let ((argv (or command emacs-jupyter-notebook-helper-command)))
    (unless (and (listp argv) (stringp (car argv))
                 (cl-every #'stringp argv))
      (error "Helper command must be a non-empty argv list of strings"))
    (let ((program (emacs-jupyter-notebook-helper--resolve-program (car argv))))
      (unless program
        (error "Cannot resolve helper executable: %s" (car argv)))
      (cons program (cdr argv)))))

(defun emacs-jupyter-notebook-helper--owned-p (session process)
  "Return non-nil when PROCESS may still mutate SESSION's local state."
  (and (not (emacs-jupyter-notebook-helper-session-disposed session))
       (eq process (emacs-jupyter-notebook-helper-session-process session))
       (eq (process-get process 'emacs-jupyter-notebook-helper-session) session)
       (let ((owner (emacs-jupyter-notebook-helper-session-owner-buffer session)))
         (or (null owner)
             (and (buffer-live-p owner)
                  (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner)
                      session))))))

(defun emacs-jupyter-notebook-helper--cancel-timer (timer)
  (when (timerp timer) (cancel-timer timer)))

(defun emacs-jupyter-notebook-helper--run-callback (callback session &optional reason)
  "Run CALLBACK defensively; callback errors must not strand local resources."
  (when callback
    (condition-case err
        (funcall callback session reason)
      (error
       (message "emacs-jupyter-notebook helper callback failed: %s"
                (error-message-string err))
       nil))))

(defun emacs-jupyter-notebook-helper--append-stderr (session bytes)
  "Append unibyte BYTES to SESSION's bounded stderr buffer."
  (let ((buffer (emacs-jupyter-notebook-helper-session-stderr-buffer session))
        (limit (emacs-jupyter-notebook-helper--stderr-limit)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              ;; Retain at most LIMIT characters before conversion.  UTF-8 can
              ;; expand this bounded suffix, so apply the byte tail below too.
              (incoming (if (multibyte-string-p bytes)
                            (encode-coding-string
                             (if (> (length bytes) limit)
                                 (substring bytes (- (length bytes) limit))
                               bytes)
                             'binary t)
                          bytes)))
          (set-buffer-multibyte nil)
          ;; Trim both sides before insertion, so one hostile pipe chunk never
          ;; makes this buffer temporarily exceed its hard retention limit.
          (when (> (length incoming) limit)
            (setq incoming (substring incoming (- (length incoming) limit))))
          (let ((room (- limit (length incoming))))
            (when (> (buffer-size) room)
              (delete-region (point-min) (+ (point-min) (- (buffer-size) room)))))
          (goto-char (point-max))
          (insert incoming))))))

(defun emacs-jupyter-notebook-helper--stderr-filter (pipe bytes)
  (let ((session (process-get pipe 'emacs-jupyter-notebook-helper-session)))
    (when (and session
               (not (emacs-jupyter-notebook-helper-session-disposed session)))
      (emacs-jupyter-notebook-helper--append-stderr session bytes))))

(defun emacs-jupyter-notebook-helper--clear-partial-deadline (session)
  (emacs-jupyter-notebook-helper--cancel-timer
   (emacs-jupyter-notebook-helper-session-partial-timer session))
  (setf (emacs-jupyter-notebook-helper-session-partial-timer session) nil))

(defun emacs-jupyter-notebook-helper--partial-deadline (session)
  (let ((process (emacs-jupyter-notebook-helper-session-process session)))
    (when (and (processp process)
               (emacs-jupyter-notebook-helper--owned-p session process)
               (ejn-helper-protocol-decoder-partial-p
                (emacs-jupyter-notebook-helper-session-decoder session)))
      (condition-case nil
          (ejn-helper-protocol-decoder-expire-partial
           (emacs-jupyter-notebook-helper-session-decoder session))
        (error nil))
      (emacs-jupyter-notebook-helper--fail session "partial frame timeout"))))

(defun emacs-jupyter-notebook-helper--update-partial-deadline (session)
  (if (ejn-helper-protocol-decoder-partial-p
       (emacs-jupyter-notebook-helper-session-decoder session))
      (unless (timerp (emacs-jupyter-notebook-helper-session-partial-timer session))
        (setf (emacs-jupyter-notebook-helper-session-partial-timer session)
              (run-at-time
               (emacs-jupyter-notebook-helper--bounded-positive-number
                emacs-jupyter-notebook-helper-partial-frame-timeout 5)
               nil #'emacs-jupyter-notebook-helper--partial-deadline session)))
    (emacs-jupyter-notebook-helper--clear-partial-deadline session)))

(defun emacs-jupyter-notebook-helper--queue-push (session priority item bytes)
  "Append ITEM of BYTES to SESSION's ordinary or PRIORITY FIFO queue."
  ;; The two bounded lanes are accounting lanes, not dispatch-priority lanes.
  ;; Keep the arrival serial on every item so a terminal frame can bypass
  ;; credit while still never overtaking output already received on stdout.
  (aset item 3 (cl-incf (emacs-jupyter-notebook-helper-session-wire-sequence session)))
  (let ((cell (list item)))
    (if priority
        (progn
          (if (emacs-jupyter-notebook-helper-session-priority-tail session)
              (setcdr (emacs-jupyter-notebook-helper-session-priority-tail session) cell)
            (setf (emacs-jupyter-notebook-helper-session-priority-queue session) cell))
          (setf (emacs-jupyter-notebook-helper-session-priority-tail session) cell)
          (cl-incf (emacs-jupyter-notebook-helper-session-priority-queue-bytes session) bytes))
      (if (emacs-jupyter-notebook-helper-session-event-tail session)
          (setcdr (emacs-jupyter-notebook-helper-session-event-tail session) cell)
        (setf (emacs-jupyter-notebook-helper-session-event-queue session) cell))
      (setf (emacs-jupyter-notebook-helper-session-event-tail session) cell)
      (cl-incf (emacs-jupyter-notebook-helper-session-event-queue-bytes session) bytes))))

(defun emacs-jupyter-notebook-helper--queue-pop (session priority)
  "Remove and return the oldest item from SESSION's PRIORITY queue when set."
  (let ((head (if priority
                  (emacs-jupyter-notebook-helper-session-priority-queue session)
                (emacs-jupyter-notebook-helper-session-event-queue session))))
    (when head
      (let* ((item (car head))
             (bytes (aref item 1))
             (next (cdr head)))
        (if priority
            (progn
              (setf (emacs-jupyter-notebook-helper-session-priority-queue session) next)
              (unless next (setf (emacs-jupyter-notebook-helper-session-priority-tail session) nil))
              (cl-decf (emacs-jupyter-notebook-helper-session-priority-queue-bytes session) bytes))
          (setf (emacs-jupyter-notebook-helper-session-event-queue session) next)
          (unless next (setf (emacs-jupyter-notebook-helper-session-event-tail session) nil))
          (cl-decf (emacs-jupyter-notebook-helper-session-event-queue-bytes session) bytes))
        item))))

(defun emacs-jupyter-notebook-helper--queue-next (session)
  "Pop SESSION's oldest received item across its bounded accounting lanes."
  (let ((priority (car (emacs-jupyter-notebook-helper-session-priority-queue session)))
        (ordinary (car (emacs-jupyter-notebook-helper-session-event-queue session))))
    (cond
     ((null priority) (emacs-jupyter-notebook-helper--queue-pop session nil))
     ((null ordinary) (emacs-jupyter-notebook-helper--queue-pop session t))
     ((< (aref priority 3) (aref ordinary 3))
      (emacs-jupyter-notebook-helper--queue-pop session t))
     (t (emacs-jupyter-notebook-helper--queue-pop session nil)))))

(defun emacs-jupyter-notebook-helper--schedule-drain (session)
  "Schedule one callback-capable drain for SESSION."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (timerp (emacs-jupyter-notebook-helper-session-drain-timer session)))
    (setf (emacs-jupyter-notebook-helper-session-drain-timer session)
          (run-at-time 0 nil #'emacs-jupyter-notebook-helper--drain session))))

(defun emacs-jupyter-notebook-helper--queue-failure (session reason)
  "Defer local failure of SESSION until its scheduled drain.
This is used by the process filter so it never runs user callbacks."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (emacs-jupyter-notebook-helper-session-pending-failure session))
    (setf (emacs-jupyter-notebook-helper-session-pending-failure session) reason)
    (emacs-jupyter-notebook-helper--schedule-drain session)))

(defun emacs-jupyter-notebook-helper--send-envelope (session id op params)
  "Send one v1 request envelope through SESSION's binary process."
  (let ((process (emacs-jupyter-notebook-helper-session-process session)))
    (unless (and (processp process)
                 (emacs-jupyter-notebook-helper--owned-p session process))
      (error "helper process is no longer live"))
    (let ((envelope (make-hash-table :test 'equal)))
      (puthash "v" ejn-helper-protocol-version envelope)
      (puthash "kind" "request" envelope)
      (puthash "id" id envelope)
      (puthash "op" op envelope)
      (puthash "params" params envelope)
      (process-send-string
       process
       (ejn-helper-protocol-encode envelope ejn-helper-protocol-max-to-helper-frame)))))

(defun emacs-jupyter-notebook-helper--control-deadline (session sequence)
  "Fail SESSION when its oldest outstanding credit SEQUENCE is not acknowledged."
  (when (and (not (emacs-jupyter-notebook-helper-session-disposed session))
             (= sequence (1+ (emacs-jupyter-notebook-helper-session-control-acked session)))
             (<= sequence (emacs-jupyter-notebook-helper-session-control-sent session)))
    (emacs-jupyter-notebook-helper--fail session "helper credit acknowledgement timed out")))

(defun emacs-jupyter-notebook-helper--schedule-control-deadline (session)
  "Arm a finite deadline for SESSION's oldest unacknowledged control grant."
  (emacs-jupyter-notebook-helper--cancel-timer
   (emacs-jupyter-notebook-helper-session-control-timer session))
  (setf (emacs-jupyter-notebook-helper-session-control-timer session) nil)
  (when (> (emacs-jupyter-notebook-helper-session-control-sent session)
           (emacs-jupyter-notebook-helper-session-control-acked session))
    (let ((sequence (1+ (emacs-jupyter-notebook-helper-session-control-acked session))))
      (setf (emacs-jupyter-notebook-helper-session-control-timer session)
            (run-at-time
             (emacs-jupyter-notebook-helper--bounded-positive-number
              emacs-jupyter-notebook-helper--control-ack-timeout 2)
             nil #'emacs-jupyter-notebook-helper--control-deadline session sequence)))))

(defun emacs-jupyter-notebook-helper--send-credit (session bytes)
  "Grant BYTES of ordinary event credit after dispatching an event."
  (when (> bytes 0)
    (let ((params (make-hash-table :test 'equal))
          (was-fully-acked (= (emacs-jupyter-notebook-helper-session-control-sent session)
                               (emacs-jupyter-notebook-helper-session-control-acked session)))
          (id (format "ejn-control-%d-%d"
                      (emacs-jupyter-notebook-helper-session-id session)
                      (cl-incf (emacs-jupyter-notebook-helper-session-control-sequence session)))))
      (puthash "bytes" bytes params)
      (emacs-jupyter-notebook-helper--send-envelope
       session id "grant_event_credit" params)
      (setf (emacs-jupyter-notebook-helper-session-control-sent session)
            (emacs-jupyter-notebook-helper-session-control-sequence session))
      (when was-fully-acked
        (emacs-jupyter-notebook-helper--schedule-control-deadline session))
      (cl-incf (emacs-jupyter-notebook-helper-session-event-credit session) bytes))))

(defun emacs-jupyter-notebook-helper--run-request-callback (request session response error)
  "Run REQUEST's terminal callback without interrupting the drain."
  (when (emacs-jupyter-notebook-helper-request-callback request)
    (condition-case err
        (funcall (emacs-jupyter-notebook-helper-request-callback request)
                 session response error)
      (error
       (message "emacs-jupyter-notebook helper request callback failed: %s"
                (error-message-string err))))))

(defun emacs-jupyter-notebook-helper--finish-request (session request response error)
  "Complete REQUEST exactly once, cancelling only its own timer."
  (unless (emacs-jupyter-notebook-helper-request-finished request)
    (setf (emacs-jupyter-notebook-helper-request-finished request) t)
    (let ((requests (emacs-jupyter-notebook-helper-session-requests session)))
      (when (hash-table-p requests)
        (remhash (emacs-jupyter-notebook-helper-request-id request) requests)))
    (emacs-jupyter-notebook-helper--cancel-timer
     (emacs-jupyter-notebook-helper-request-timer request))
    (setf (emacs-jupyter-notebook-helper-request-timer request) nil)
    (emacs-jupyter-notebook-helper--run-request-callback request session response error)))

(defun emacs-jupyter-notebook-helper--request-deadline (session id request)
  "Fail REQUEST if ID remains pending when its independent timer fires."
  (when (and (not (emacs-jupyter-notebook-helper-session-disposed session))
             (eq request (gethash id (emacs-jupyter-notebook-helper-session-requests session))))
    (emacs-jupyter-notebook-helper--finish-request
     session request nil (format "helper %s request timed out" (emacs-jupyter-notebook-helper-request-op request)))))

(cl-defun emacs-jupyter-notebook-helper-request (session op params callback &key timeout internal)
  "Send OP with PARAMS and invoke CALLBACK once with (SESSION RESPONSE ERROR).
TIMEOUT is bounded independently for this request.  RESPONSE is nil on a
local deadline or transport failure; ERROR is then a short local reason."
  (unless (and (stringp op) (hash-table-p params))
    (error "Helper request requires a string op and object params"))
  (unless (and (not (emacs-jupyter-notebook-helper-session-disposed session))
               (eq (emacs-jupyter-notebook-helper-session-state session) 'ready))
    (error "Helper session is not ready"))
  (let ((requests (emacs-jupyter-notebook-helper-session-requests session)))
    ;; Keep one protocol slot available for the liveness ping.
    (when (>= (hash-table-count requests) (if internal 8 7))
      (error "Too many helper requests are in flight"))
    (let* ((id (format "ejn-request-%d-%d"
                       (emacs-jupyter-notebook-helper-session-id session)
                       (cl-incf (emacs-jupyter-notebook-helper-session-request-sequence session))))
           (request (emacs-jupyter-notebook-helper--make-request
                     :id id :op op :callback callback)))
      (puthash id request requests)
      (setf (emacs-jupyter-notebook-helper-request-timer request)
            (run-at-time
             (emacs-jupyter-notebook-helper--bounded-positive-number timeout 5)
             nil #'emacs-jupyter-notebook-helper--request-deadline session id request))
      (condition-case err
          (emacs-jupyter-notebook-helper--send-envelope session id op params)
        (error
         (emacs-jupyter-notebook-helper--finish-request
          session request nil (format "cannot send helper request: %s"
                                      (error-message-string err)))))
      id)))

(defun emacs-jupyter-notebook-helper--fail-pending-requests (session reason)
  "Terminally fail every pending request in SESSION exactly once."
  (let (requests)
    (when (hash-table-p (emacs-jupyter-notebook-helper-session-requests session))
      (maphash (lambda (_id request) (push request requests))
               (emacs-jupyter-notebook-helper-session-requests session)))
    (dolist (request requests)
      (emacs-jupyter-notebook-helper--finish-request session request nil reason))))

(defun emacs-jupyter-notebook-helper--late-response (session object)
  "Retain a bounded diagnostic for an uncorrelated response OBJECT."
  (let ((entry (format "late response %s" (gethash "id" object))))
    (push entry (emacs-jupyter-notebook-helper-session-late-responses session))
    (when (> (length (emacs-jupyter-notebook-helper-session-late-responses session))
             emacs-jupyter-notebook-helper--max-late-responses)
      (setcdr (nthcdr (1- emacs-jupyter-notebook-helper--max-late-responses)
                      (emacs-jupyter-notebook-helper-session-late-responses session))
              nil))))

(defun emacs-jupyter-notebook-helper--hello-result-p (session object)
  "Validate the one response permitted during SESSION startup."
  (let ((result (gethash "result" object)))
    (and (hash-table-p object)
         (integerp (gethash "v" object))
         (= (gethash "v" object) ejn-helper-protocol-version)
         (equal (gethash "kind" object) "response")
         (equal (gethash "id" object) (emacs-jupyter-notebook-helper-session-hello-id session))
         (eq (gethash "ok" object) t)
         (hash-table-p result)
         (integerp (gethash "version" result))
         (= (gethash "version" result) ejn-helper-protocol-version)
         (stringp (gethash "helper_version" result))
         (vectorp (gethash "capabilities" result)))))

(defun emacs-jupyter-notebook-helper--hello-deadline (session)
  (let ((process (emacs-jupyter-notebook-helper-session-process session)))
    (when (and (processp process)
               (emacs-jupyter-notebook-helper--owned-p session process)
               (eq (emacs-jupyter-notebook-helper-session-state session) 'starting))
      (emacs-jupyter-notebook-helper--fail session "helper hello timed out"))))

(defun emacs-jupyter-notebook-helper--fail (session reason)
  "Fail SESSION once, releasing only its local resources."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (emacs-jupyter-notebook-helper-session-failure-emitted session))
    (let ((failure-callback
           (emacs-jupyter-notebook-helper-session-failure-callback session)))
      (setf (emacs-jupyter-notebook-helper-session-failure-emitted session) t
            (emacs-jupyter-notebook-helper-session-state session) 'failed)
      (emacs-jupyter-notebook-helper-dispose session reason)
      (emacs-jupyter-notebook-helper--run-callback
       failure-callback session reason))))

(defun emacs-jupyter-notebook-helper--handle-startup-object (session object)
  (if (emacs-jupyter-notebook-helper--hello-result-p session object)
      (progn
        (emacs-jupyter-notebook-helper--cancel-timer
         (emacs-jupyter-notebook-helper-session-hello-timer session))
        (setf (emacs-jupyter-notebook-helper-session-hello-timer session) nil
              (emacs-jupyter-notebook-helper-session-state session) 'ready)
        (emacs-jupyter-notebook-helper--send-credit
         session emacs-jupyter-notebook-helper--initial-event-credit)
        (emacs-jupyter-notebook-helper--schedule-ping session)
        (emacs-jupyter-notebook-helper--run-callback
         (emacs-jupyter-notebook-helper-session-ready-callback session) session))
    (emacs-jupyter-notebook-helper--fail session "invalid helper hello response")))

(defun emacs-jupyter-notebook-helper--priority-event-p (object)
  "Return non-nil when event OBJECT bypasses ordinary output credit."
  (member (gethash "event" object)
          '("status" "execute_reply" "input_request" "transport_error" "output_truncated")))

(defconst emacs-jupyter-notebook-helper--event-names
  '("stream" "display_data" "execute_result" "clear_output" "status"
    "execute_reply" "input_request" "transport_error" "output_truncated"))

(defun emacs-jupyter-notebook-helper--bounded-id-p (value &optional allow-empty)
  "Return non-nil for a UTF-8 bounded protocol identifier VALUE."
  (and (stringp value)
       (or allow-empty (> (length value) 0))
       (<= (length (encode-coding-string value 'utf-8 t)) 256)))

(defun emacs-jupyter-notebook-helper--post-hello-envelope-p (session object)
  "Validate OBJECT at wire-arrival time, before priority reordering."
  (and (hash-table-p object)
       (integerp (gethash "v" object)) (= (gethash "v" object) 1)
       (pcase (gethash "kind" object)
         ("response"
          (let ((id (gethash "id" object)) (ok (gethash "ok" object)))
            (and (emacs-jupyter-notebook-helper--bounded-id-p id)
                 (or (eq ok t) (eq ok :false))
                 (if (eq ok t) (hash-table-p (gethash "result" object))
                   (hash-table-p (gethash "error" object))))))
         ("event"
          (let ((seq (gethash "seq" object)) (event (gethash "event" object))
                (request-id (gethash "request_id" object)))
            (and (integerp seq) (> seq (emacs-jupyter-notebook-helper-session-last-event-seq session))
                 (member event emacs-jupyter-notebook-helper--event-names)
                 (hash-table-p (gethash "data" object))
                 (or (emacs-jupyter-notebook-helper--bounded-id-p request-id)
                     (and (equal event "transport_error") (null request-id)))
                 (progn (setf (emacs-jupyter-notebook-helper-session-last-event-seq session) seq) t))))
         (_ nil))))

(defun emacs-jupyter-notebook-helper--enqueue-object (session object wire-bytes)
  "Classify decoded OBJECT and place it in one finite dispatch queue."
  (cond
   ((not (hash-table-p object))
    (emacs-jupyter-notebook-helper--queue-failure session "helper envelope is not an object"))
   ((and (eq (emacs-jupyter-notebook-helper-session-state session) 'starting)
         (not (emacs-jupyter-notebook-helper--hello-result-p session object)))
    (emacs-jupyter-notebook-helper--queue-failure session "invalid helper hello response"))
   ((and (eq (emacs-jupyter-notebook-helper-session-state session) 'ready)
         (not (emacs-jupyter-notebook-helper--post-hello-envelope-p session object)))
    (emacs-jupyter-notebook-helper--queue-failure session "invalid helper post-hello envelope"))
   ((equal (gethash "kind" object) "response")
    (if (> wire-bytes emacs-jupyter-notebook-helper--max-response-frame)
        (emacs-jupyter-notebook-helper--queue-failure session "helper response frame exceeds limit")
      (if (> (+ (emacs-jupyter-notebook-helper-session-priority-queue-bytes session) wire-bytes)
             emacs-jupyter-notebook-helper--max-priority-queue)
          (emacs-jupyter-notebook-helper--queue-failure session "helper priority queue exceeded")
        (emacs-jupyter-notebook-helper--queue-push session t (vector object wire-bytes 'response nil) wire-bytes))))
   ((equal (gethash "kind" object) "event")
    (let ((priority (emacs-jupyter-notebook-helper--priority-event-p object)))
      (cond
       ((not (stringp (gethash "event" object)))
        (emacs-jupyter-notebook-helper--queue-failure session "helper event is malformed"))
       ((and priority (> wire-bytes emacs-jupyter-notebook-helper--max-response-frame))
        (emacs-jupyter-notebook-helper--queue-failure session "helper priority event frame exceeds limit"))
       ((> (+ (if priority
                   (emacs-jupyter-notebook-helper-session-priority-queue-bytes session)
                 (emacs-jupyter-notebook-helper-session-event-queue-bytes session))
               wire-bytes)
           (if priority emacs-jupyter-notebook-helper--max-priority-queue
             emacs-jupyter-notebook-helper--max-event-queue))
        (emacs-jupyter-notebook-helper--queue-failure
         session (if priority "helper priority queue exceeded" "helper event queue exceeded")))
       (t
        (unless (emacs-jupyter-notebook-helper-session-pending-failure session)
          (when (not priority)
            (if (< (emacs-jupyter-notebook-helper-session-event-credit session) wire-bytes)
                (emacs-jupyter-notebook-helper--queue-failure session "helper exceeded event credit")
              (cl-decf (emacs-jupyter-notebook-helper-session-event-credit session) wire-bytes)))
          ;; A rejected arrival neither reaches a callback nor earns credit.
          (unless (emacs-jupyter-notebook-helper-session-pending-failure session)
          (emacs-jupyter-notebook-helper--queue-push
           session priority (vector object wire-bytes (if priority 'priority-event 'event) nil) wire-bytes)))))))
   (t (emacs-jupyter-notebook-helper--queue-failure session "unexpected helper envelope"))))

(defun emacs-jupyter-notebook-helper--raw-append (session bytes)
  "Append unibyte BYTES to SESSION's finite undecoded raw FIFO."
  (let ((decoder (emacs-jupyter-notebook-helper-session-decoder session)))
    (if (> (+ (emacs-jupyter-notebook-helper-session-raw-bytes session)
              (ejn-helper-protocol-decoder-buffered-bytes decoder)
              (length bytes))
           (emacs-jupyter-notebook-helper--accumulator-limit
            (emacs-jupyter-notebook-helper--frame-limit)))
        (emacs-jupyter-notebook-helper--queue-failure session "helper raw accumulator exceeded")
      (let ((cell (list (copy-sequence bytes))))
        (if (emacs-jupyter-notebook-helper-session-raw-tail session)
            (setcdr (emacs-jupyter-notebook-helper-session-raw-tail session) cell)
          (setf (emacs-jupyter-notebook-helper-session-raw-chunks session) cell))
        (setf (emacs-jupyter-notebook-helper-session-raw-tail session) cell)
        (cl-incf (emacs-jupyter-notebook-helper-session-raw-bytes session) (length bytes))))))

(defun emacs-jupyter-notebook-helper--raw-take (session count)
  "Consume up to COUNT raw bytes from SESSION's undecoded FIFO."
  (let ((head (emacs-jupyter-notebook-helper-session-raw-chunks session)))
    (when head
      (let* ((chunk (car head))
             (amount (min count (length chunk)))
             (piece (substring chunk 0 amount)))
        (if (= amount (length chunk))
            (setf (emacs-jupyter-notebook-helper-session-raw-chunks session) (cdr head))
          (setcar head (substring chunk amount)))
        (unless (emacs-jupyter-notebook-helper-session-raw-chunks session)
          (setf (emacs-jupyter-notebook-helper-session-raw-tail session) nil))
        (cl-decf (emacs-jupyter-notebook-helper-session-raw-bytes session) amount)
        piece))))

(defun emacs-jupyter-notebook-helper--schedule-decode (session)
  "Schedule one bounded decoder continuation when raw bytes remain."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (timerp (emacs-jupyter-notebook-helper-session-decode-timer session)))
    (setf (emacs-jupyter-notebook-helper-session-decode-timer session)
          (run-at-time 0 nil #'emacs-jupyter-notebook-helper--decode-continuation session))))

(defun emacs-jupyter-notebook-helper--decode-continuation (session)
  "Continue bounded decode work outside a process-filter invocation."
  (setf (emacs-jupyter-notebook-helper-session-decode-timer session) nil)
  (when (and (not (emacs-jupyter-notebook-helper-session-disposed session))
             (emacs-jupyter-notebook-helper-session-raw-chunks session))
    (emacs-jupyter-notebook-helper--decode-raw session)))

(defun emacs-jupyter-notebook-helper--decode-raw (session)
  "Decode no more than ET3's frame and payload work budget for SESSION."
  (let ((frames 0) (payload-bytes 0) (decoder (emacs-jupyter-notebook-helper-session-decoder session)))
    (condition-case err
        (while (and (emacs-jupyter-notebook-helper-session-raw-chunks session)
                    (< frames emacs-jupyter-notebook-helper--filter-max-frames)
                    (not (emacs-jupyter-notebook-helper-session-pending-failure session))
                    (or (emacs-jupyter-notebook-helper-session-decode-remaining session)
                        (< payload-bytes emacs-jupyter-notebook-helper--filter-max-payload-bytes)))
          (if (null (emacs-jupyter-notebook-helper-session-decode-remaining session))
              (let* ((prefix (or (emacs-jupyter-notebook-helper-session-decode-prefix session) ""))
                     (piece (emacs-jupyter-notebook-helper--raw-take session (- 4 (length prefix))))
                     (new-prefix (concat prefix piece)))
                (setf (emacs-jupyter-notebook-helper-session-decode-prefix session) new-prefix)
                (ejn-helper-protocol-decoder-feed decoder piece)
                (when (= (length new-prefix) 4)
                  (let ((payload (+ (ash (aref new-prefix 0) 24)
                                    (ash (aref new-prefix 1) 16)
                                    (ash (aref new-prefix 2) 8)
                                    (aref new-prefix 3))))
                    (when (> (+ payload 4) (emacs-jupyter-notebook-helper--frame-limit))
                      (error "helper frame exceeds limit"))
                    (setf (emacs-jupyter-notebook-helper-session-decode-remaining session) payload
                          (emacs-jupyter-notebook-helper-session-decode-wire-size session) (+ payload 4)))))
            (let* ((remaining (emacs-jupyter-notebook-helper-session-decode-remaining session))
                   (room (- emacs-jupyter-notebook-helper--filter-max-payload-bytes payload-bytes)))
              (when (<= room 0) (cl-return))
              (let* ((piece (emacs-jupyter-notebook-helper--raw-take session (min remaining room)))
                     (amount (length piece))
                     (objects (ejn-helper-protocol-decoder-feed decoder piece)))
                (cl-incf payload-bytes amount)
                (cl-decf (emacs-jupyter-notebook-helper-session-decode-remaining session) amount)
                (when (= (emacs-jupyter-notebook-helper-session-decode-remaining session) 0)
                  (unless (= (length objects) 1) (error "helper decoder framing mismatch"))
                  (emacs-jupyter-notebook-helper--enqueue-object
                   session (car objects) (emacs-jupyter-notebook-helper-session-decode-wire-size session))
                  (setq frames (1+ frames))
                  (setf (emacs-jupyter-notebook-helper-session-decode-prefix session) nil
                        (emacs-jupyter-notebook-helper-session-decode-remaining session) nil
                        (emacs-jupyter-notebook-helper-session-decode-wire-size session) nil))))))
      (error
       (emacs-jupyter-notebook-helper--queue-failure
        session (format "helper protocol error: %s" (error-message-string err)))))
    (unless (emacs-jupyter-notebook-helper-session-disposed session)
      (emacs-jupyter-notebook-helper--update-partial-deadline session)
      (when (or (emacs-jupyter-notebook-helper-session-priority-queue session)
                (emacs-jupyter-notebook-helper-session-event-queue session))
        (emacs-jupyter-notebook-helper--schedule-drain session))
      (when (and (emacs-jupyter-notebook-helper-session-raw-chunks session)
                 (not (emacs-jupyter-notebook-helper-session-pending-failure session)))
        (emacs-jupyter-notebook-helper--schedule-decode session)))))

(defun emacs-jupyter-notebook-helper--filter (process bytes)
  "Boundedly accumulate and decode PROCESS stdout without user callbacks."
  (let ((session (process-get process 'emacs-jupyter-notebook-helper-session)))
    (when (and session (emacs-jupyter-notebook-helper--owned-p session process)
               (not (emacs-jupyter-notebook-helper-session-pending-failure session)))
      (emacs-jupyter-notebook-helper--raw-append
       session (if (multibyte-string-p bytes) (encode-coding-string bytes 'binary t) bytes))
      (unless (emacs-jupyter-notebook-helper-session-pending-failure session)
        (emacs-jupyter-notebook-helper--decode-raw session)))))

(defun emacs-jupyter-notebook-helper--dispatch-response (session object)
  "Correlate OBJECT with one pending request, or retain a bounded late note."
  (let ((id (gethash "id" object)))
    (if (string-match "\\`ejn-control-\\([0-9]+\\)-\\([0-9]+\\)\\'" id)
        (let ((sid (string-to-number (match-string 1 id)))
              (sequence (string-to-number (match-string 2 id))))
          (if (and (= sid (emacs-jupyter-notebook-helper-session-id session))
                   (= sequence (1+ (emacs-jupyter-notebook-helper-session-control-acked session)))
                   (<= sequence (emacs-jupyter-notebook-helper-session-control-sent session))
                   (eq (gethash "ok" object) t)
                   (hash-table-p (gethash "result" object)))
              (setf (emacs-jupyter-notebook-helper-session-control-acked session) sequence)
              (emacs-jupyter-notebook-helper--schedule-control-deadline session)
            (emacs-jupyter-notebook-helper--fail session "invalid helper credit acknowledgement")))
      (let ((request (gethash id (emacs-jupyter-notebook-helper-session-requests session))))
        (if request
            (emacs-jupyter-notebook-helper--finish-request session request object nil)
          (emacs-jupyter-notebook-helper--late-response session object))))))

(defun emacs-jupyter-notebook-helper--dispatch-event (session object bytes ordinary)
  "Run SESSION's event callback and replenish ORDINARY event credit afterward.
Return the callback's explicit admission result after the bounded drain work
has completed; replenishing credit never precedes that decision.
"
  (unless (and ordinary (emacs-jupyter-notebook-helper-session-disposed session))
    (let ((accepted
           (emacs-jupyter-notebook-helper--run-callback
            (emacs-jupyter-notebook-helper-session-event-callback session) session object)))
      (when ordinary
        (condition-case err
            (emacs-jupyter-notebook-helper--send-credit session bytes)
          (error
           (emacs-jupyter-notebook-helper--fail
            session (format "cannot replenish helper credit: %s" (error-message-string err))))))
      accepted)))

(defun emacs-jupyter-notebook-helper--drain (session)
  "Dispatch a finite batch of decoded messages outside the process filter."
  (setf (emacs-jupyter-notebook-helper-session-drain-timer session) nil)
  (when (not (emacs-jupyter-notebook-helper-session-disposed session))
    (if (emacs-jupyter-notebook-helper-session-pending-failure session)
        (let ((reason (emacs-jupyter-notebook-helper-session-pending-failure session)))
          (setf (emacs-jupyter-notebook-helper-session-pending-failure session) nil)
          (emacs-jupyter-notebook-helper--fail session reason))
      (let ((frames 0) (bytes 0))
        (while (and (not (emacs-jupyter-notebook-helper-session-disposed session))
                    (< frames emacs-jupyter-notebook-helper--filter-max-frames)
                    (< bytes emacs-jupyter-notebook-helper--filter-max-payload-bytes)
                    (or (emacs-jupyter-notebook-helper-session-priority-queue session)
                        (emacs-jupyter-notebook-helper-session-event-queue session)))
          ;; Priority frames bypass credit admission, but wire order is still
          ;; global across the two finite lanes.
          (let* ((item (emacs-jupyter-notebook-helper--queue-next session))
                 (object (aref item 0))
                 (wire-bytes (aref item 1))
                 (kind (aref item 2)))
            (setq frames (1+ frames) bytes (+ bytes wire-bytes))
            (condition-case err
                (pcase kind
                  ('response
                   (if (eq (emacs-jupyter-notebook-helper-session-state session) 'starting)
                       (emacs-jupyter-notebook-helper--handle-startup-object session object)
                     (emacs-jupyter-notebook-helper--dispatch-response session object)))
                  ('event (emacs-jupyter-notebook-helper--dispatch-event session object wire-bytes t))
                  ('priority-event (emacs-jupyter-notebook-helper--dispatch-event session object wire-bytes nil)))
              (error
               (emacs-jupyter-notebook-helper--fail
                session (format "helper dispatch error: %s" (error-message-string err)))))))
        (when (and (not (emacs-jupyter-notebook-helper-session-disposed session))
                   (or (emacs-jupyter-notebook-helper-session-priority-queue session)
                       (emacs-jupyter-notebook-helper-session-event-queue session)))
          (emacs-jupyter-notebook-helper--schedule-drain session))))))

(defun emacs-jupyter-notebook-helper--schedule-ping (session)
  "Schedule SESSION's next correlated helper liveness ping."
  (unless (or (emacs-jupyter-notebook-helper-session-disposed session)
              (timerp (emacs-jupyter-notebook-helper-session-ping-timer session)))
    (setf (emacs-jupyter-notebook-helper-session-ping-timer session)
          (run-at-time
           (emacs-jupyter-notebook-helper--bounded-positive-number
            emacs-jupyter-notebook-helper--ping-interval 5)
           nil #'emacs-jupyter-notebook-helper--ping-tick session))))

(defun emacs-jupyter-notebook-helper--ping-tick (session)
  "Issue one correlated local ping, unless SESSION is stale or disposed."
  (setf (emacs-jupyter-notebook-helper-session-ping-timer session) nil)
  (when (and (not (emacs-jupyter-notebook-helper-session-disposed session))
             (eq (emacs-jupyter-notebook-helper-session-state session) 'ready)
             (not (emacs-jupyter-notebook-helper-session-ping-id session)))
    (let ((params (make-hash-table :test 'equal)))
      (let ((id (emacs-jupyter-notebook-helper-request
             session "ping" params
             (lambda (current _response error)
               (setf (emacs-jupyter-notebook-helper-session-ping-id current) nil)
               (if error
                   (emacs-jupyter-notebook-helper--fail current "helper ping timed out")
                 (emacs-jupyter-notebook-helper--schedule-ping current)))
             :timeout (emacs-jupyter-notebook-helper--bounded-positive-number
                       emacs-jupyter-notebook-helper--ping-timeout 2)
             :internal t)))
        (unless (emacs-jupyter-notebook-helper-session-disposed session)
          (setf (emacs-jupyter-notebook-helper-session-ping-id session) id))))))

(defun emacs-jupyter-notebook-helper--sentinel (process event)
  "Observe a helper exit only while PROCESS is still the session's process."
  (let ((session (process-get process 'emacs-jupyter-notebook-helper-session)))
    (when (and session (emacs-jupyter-notebook-helper--owned-p session process))
      (emacs-jupyter-notebook-helper--fail
       session (format "helper exited: %s" (string-trim event))))))

(defun emacs-jupyter-notebook-helper-dispose (session &optional reason)
  "Release SESSION's local process, timers, pipe, and stderr buffer.
This never sends a protocol operation and never affects any durable state."
  (when (and session (not (emacs-jupyter-notebook-helper-session-disposed session)))
    (let ((closed-callback
           (emacs-jupyter-notebook-helper-session-closed-callback session))
          (hello-timer (emacs-jupyter-notebook-helper-session-hello-timer session))
          (partial-timer (emacs-jupyter-notebook-helper-session-partial-timer session))
          (decode-timer (emacs-jupyter-notebook-helper-session-decode-timer session))
          (drain-timer (emacs-jupyter-notebook-helper-session-drain-timer session))
          (ping-timer (emacs-jupyter-notebook-helper-session-ping-timer session))
          (control-timer (emacs-jupyter-notebook-helper-session-control-timer session))
          (process (emacs-jupyter-notebook-helper-session-process session))
          (stderr-process (emacs-jupyter-notebook-helper-session-stderr-process session))
          (stderr-buffer (emacs-jupyter-notebook-helper-session-stderr-buffer session))
          (owner (emacs-jupyter-notebook-helper-session-owner-buffer session)))
      (setf (emacs-jupyter-notebook-helper-session-disposed session) t
            (emacs-jupyter-notebook-helper-session-state session) 'disposed
            (emacs-jupyter-notebook-helper-session-hello-timer session) nil
            (emacs-jupyter-notebook-helper-session-partial-timer session) nil
            (emacs-jupyter-notebook-helper-session-decode-timer session) nil
            (emacs-jupyter-notebook-helper-session-drain-timer session) nil
            (emacs-jupyter-notebook-helper-session-ping-timer session) nil
            (emacs-jupyter-notebook-helper-session-control-timer session) nil
            (emacs-jupyter-notebook-helper-session-ping-id session) nil
            (emacs-jupyter-notebook-helper-session-process session) nil
            (emacs-jupyter-notebook-helper-session-stderr-process session) nil
            (emacs-jupyter-notebook-helper-session-stderr-buffer session) nil
            (emacs-jupyter-notebook-helper-session-decoder session) nil
            (emacs-jupyter-notebook-helper-session-event-callback session) nil
            (emacs-jupyter-notebook-helper-session-ready-callback session) nil
            (emacs-jupyter-notebook-helper-session-failure-callback session) nil
            (emacs-jupyter-notebook-helper-session-closed-callback session) nil)
      (emacs-jupyter-notebook-helper--cancel-timer hello-timer)
      (emacs-jupyter-notebook-helper--cancel-timer partial-timer)
      (emacs-jupyter-notebook-helper--cancel-timer decode-timer)
      (emacs-jupyter-notebook-helper--cancel-timer drain-timer)
      (emacs-jupyter-notebook-helper--cancel-timer ping-timer)
      (emacs-jupyter-notebook-helper--cancel-timer control-timer)
      (emacs-jupyter-notebook-helper--fail-pending-requests session reason)
      (setf (emacs-jupyter-notebook-helper-session-requests session) nil
            (emacs-jupyter-notebook-helper-session-raw-chunks session) nil
            (emacs-jupyter-notebook-helper-session-raw-tail session) nil
            (emacs-jupyter-notebook-helper-session-raw-bytes session) 0
            (emacs-jupyter-notebook-helper-session-decode-prefix session) nil
            (emacs-jupyter-notebook-helper-session-decode-remaining session) nil
            (emacs-jupyter-notebook-helper-session-decode-wire-size session) nil
            (emacs-jupyter-notebook-helper-session-event-queue session) nil
            (emacs-jupyter-notebook-helper-session-event-tail session) nil
            (emacs-jupyter-notebook-helper-session-event-queue-bytes session) 0
            (emacs-jupyter-notebook-helper-session-priority-queue session) nil
            (emacs-jupyter-notebook-helper-session-priority-tail session) nil
            (emacs-jupyter-notebook-helper-session-priority-queue-bytes session) 0
            (emacs-jupyter-notebook-helper-session-pending-failure session) nil
            (emacs-jupyter-notebook-helper-session-late-responses session) nil)
      (when (processp process)
        (process-put process 'emacs-jupyter-notebook-helper-session nil)
        (when (process-live-p process) (delete-process process)))
      (when (processp stderr-process)
        (process-put stderr-process 'emacs-jupyter-notebook-helper-session nil)
        (when (process-live-p stderr-process) (delete-process stderr-process)))
      (when (and (buffer-live-p owner)
                 (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner) session))
        (with-current-buffer owner (setq emacs-jupyter-notebook--helper-session nil)))
      (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
      (setf (emacs-jupyter-notebook-helper-session-owner-buffer session) nil)
      (setq emacs-jupyter-notebook-helper--sessions
            (delq session emacs-jupyter-notebook-helper--sessions))
      (emacs-jupyter-notebook-helper--run-callback closed-callback session reason))))

(defun emacs-jupyter-notebook-helper--owner-killed ()
  (when emacs-jupyter-notebook--helper-session
    (emacs-jupyter-notebook-helper-dispose emacs-jupyter-notebook--helper-session "owner buffer killed")))

(defun emacs-jupyter-notebook-helper--mode-hook ()
  "Release a buffer-owned helper when the notebook mode is disabled."
  (when (and (boundp 'emacs-jupyter-notebook-mode)
             (not emacs-jupyter-notebook-mode)
             emacs-jupyter-notebook--helper-session)
    (emacs-jupyter-notebook-helper-dispose emacs-jupyter-notebook--helper-session "mode disabled")))

(defun emacs-jupyter-notebook-helper--kill-emacs ()
  "Dispose every local helper; no kernel operation is involved."
  (dolist (session (copy-sequence emacs-jupyter-notebook-helper--sessions))
    (emacs-jupyter-notebook-helper-dispose session "Emacs exiting")))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-helper--kill-emacs)

;;;###autoload
(cl-defun emacs-jupyter-notebook-helper-start
    (&key buffer command ready-callback failure-callback closed-callback event-callback)
  "Start one local helper and asynchronously perform its v1 hello exchange.
BUFFER owns the session when non-nil.  Starting a replacement for the same
buffer disposes the prior local session before the new process is created."
  (let ((owner (or buffer (current-buffer))))
    (unless (buffer-live-p owner)
      (error "Cannot start helper for a dead owner buffer"))
    (let* ((id (cl-incf emacs-jupyter-notebook-helper--next-id))
           (frame-limit (emacs-jupyter-notebook-helper--frame-limit))
           (stderr-buffer (generate-new-buffer (format " *ejn-helper-stderr-%d*" id)))
           (session (emacs-jupyter-notebook-helper--make-session
                     :id id :owner-buffer owner :stderr-buffer stderr-buffer
                     :decoder (ejn-helper-protocol-make-decoder
                               frame-limit
                               (emacs-jupyter-notebook-helper--accumulator-limit frame-limit))
                     :state 'starting :hello-id (format "ejn-hello-%d" id)
                     :event-credit 0 :request-sequence 0 :control-sequence 0 :wire-sequence 0
                     :control-sent 0 :control-acked 0 :last-event-seq -1
                     :raw-bytes 0 :event-queue-bytes 0 :priority-queue-bytes 0
                     :ready-callback ready-callback :failure-callback failure-callback
                     :closed-callback closed-callback :event-callback event-callback
                     :requests (make-hash-table :test 'equal))))
      (with-current-buffer stderr-buffer (set-buffer-multibyte nil))
      (with-current-buffer owner
        (let ((previous emacs-jupyter-notebook--helper-session))
        ;; Claim ownership before the old close callback can reenter and start
        ;; another session.  A reentrant replacement then supersedes this one.
        (setq emacs-jupyter-notebook--helper-session session)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-helper--owner-killed nil t)
        (when (boundp 'emacs-jupyter-notebook-mode)
          (add-hook 'emacs-jupyter-notebook-mode-hook
                    #'emacs-jupyter-notebook-helper--mode-hook nil t))
          (when previous
            (emacs-jupyter-notebook-helper-dispose previous "superseded"))))
      (when (and (buffer-live-p owner)
                 (not (emacs-jupyter-notebook-helper-session-disposed session))
               (eq (buffer-local-value 'emacs-jupyter-notebook--helper-session owner)
                   session))
        (push session emacs-jupyter-notebook-helper--sessions)
        (condition-case err
        (let* ((argv (emacs-jupyter-notebook-helper-resolve-argv command))
               (stderr-process
                (make-pipe-process :name (format "ejn-helper-stderr-%d" id)
                                   :buffer stderr-buffer :coding 'binary :noquery t
                                   :filter #'emacs-jupyter-notebook-helper--stderr-filter)))
          ;; The pipe is a local resource as soon as it exists.  Record it
          ;; before `make-process' so its failure path can dispose the pipe.
          (setf (emacs-jupyter-notebook-helper-session-stderr-process session) stderr-process)
          (process-put stderr-process 'emacs-jupyter-notebook-helper-session session)
          (let ((process
                 (make-process :name (format "ejn-helper-%d" id)
                               :command argv :connection-type 'pipe :coding 'binary :noquery t
                               :stderr stderr-process
                               :filter #'emacs-jupyter-notebook-helper--filter
                               :sentinel #'emacs-jupyter-notebook-helper--sentinel)))
            (setf (emacs-jupyter-notebook-helper-session-process session) process)
            (process-put process 'emacs-jupyter-notebook-helper-session session)
            (setf (emacs-jupyter-notebook-helper-session-hello-timer session)
                  (run-at-time
                   (emacs-jupyter-notebook-helper--bounded-positive-number
                    emacs-jupyter-notebook-helper-hello-timeout 5)
                   nil #'emacs-jupyter-notebook-helper--hello-deadline session))
            (let ((params (make-hash-table :test 'equal))
                  (hello (make-hash-table :test 'equal)))
              (puthash "versions" (vector ejn-helper-protocol-version) params)
              (puthash "v" ejn-helper-protocol-version hello)
              (puthash "kind" "request" hello)
              (puthash "id" (emacs-jupyter-notebook-helper-session-hello-id session) hello)
              (puthash "op" "hello" hello)
              (puthash "params" params hello)
              (process-send-string process
                                   (ejn-helper-protocol-encode
                                    hello ejn-helper-protocol-max-to-helper-frame)))))
          (error
           (emacs-jupyter-notebook-helper--fail
            session (format "cannot start helper: %s" (error-message-string err))))))
      session)))

(provide 'emacs-jupyter-notebook-helper)
;;; emacs-jupyter-notebook-helper.el ends here
