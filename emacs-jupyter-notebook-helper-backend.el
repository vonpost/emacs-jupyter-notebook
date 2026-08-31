;;; emacs-jupyter-notebook-helper-backend.el --- Helper backend adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; This is the deliberately narrow EI2 bridge between the generic backend
;; contract and the local helper supervisor.  It owns local helper state and
;; its artifact directory only; it never owns a kernel or durable connection
;; metadata.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-helper)

(defconst emacs-jupyter-notebook-helper-backend--connect-timeout 30)
(defconst emacs-jupyter-notebook-helper-backend--verify-timeout 180
  "Hard local deadline for helper `kernel_info' readiness verification.

This stays above the helper runtime's 150s backend deadline and 160s
dispatcher deadline.  Core busy arbitration caps at 45s, so it always decides
whether an attached reconnect is usable before this terminal request expiry.")

(defun emacs-jupyter-notebook-helper-backend-ensure ()
  "Resolve the helper executable before any remote launch is admitted."
  (emacs-jupyter-notebook-helper-resolve-argv))

(cl-defstruct (emacs-jupyter-notebook-helper-backend-state
               (:constructor emacs-jupyter-notebook-helper-backend--make-state))
  "Local resources owned by one helper backend session."
  helper artifact-dir artifact-identity request-map pending-events emit closing retired close-timer
  close-success close-failure transport-failure)

(defun emacs-jupyter-notebook-helper-backend--make-object (&rest pairs)
  "Build a protocol object from string/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) object))
    object))

(defun emacs-jupyter-notebook-helper-backend--safe-message (value)
  "Return a bounded diagnostic string for helper VALUE."
  (let ((text (cond ((stringp value) value)
                    ((and (hash-table-p value) (stringp (gethash "message" value)))
                     (gethash "message" value))
                    (t "helper request failed"))))
    (substring text 0 (min (length text) 512))))

(defun emacs-jupyter-notebook-helper-backend--state-live-p (session state)
  "Return non-nil when STATE is still the local state of SESSION."
  (and (eq state (emacs-jupyter-notebook-backend-session-data session))
       (not (emacs-jupyter-notebook-helper-backend-state-retired state))
       (not (emacs-jupyter-notebook-backend-session-closed session))))

(defun emacs-jupyter-notebook-helper-backend--close-live-p (session state)
  "Return non-nil only for STATE's in-progress local close completion."
  (and (eq state (emacs-jupyter-notebook-backend-session-data session))
       (emacs-jupyter-notebook-helper-backend-state-closing state)
       (not (emacs-jupyter-notebook-helper-backend-state-retired state))))

(defun emacs-jupyter-notebook-helper-backend--remove-artifacts (state)
  "Remove only STATE's private local artifact directory."
  (let ((directory (emacs-jupyter-notebook-helper-backend-state-artifact-dir state)))
    (unwind-protect
        (condition-case nil
            (let* ((symlink (and (stringp directory) (file-symlink-p directory)))
                   (attributes (and (stringp directory)
                                    (not symlink)
                                    (file-attributes directory)))
                   (identity (and attributes
                                  (file-attribute-file-identifier attributes))))
              ;; A stale pathname must never recursively delete a replacement
              ;; supplied by another process.  Only our unchanged private
              ;; directory, or a replacement link itself, is eligible.
              (cond
               (symlink (delete-file directory))
               ((and attributes
                     (file-directory-p directory)
                     (equal identity
                            (emacs-jupyter-notebook-helper-backend-state-artifact-identity
                             state))
                     (equal (file-attribute-user-id attributes) (user-uid))
                     (= (logand (file-modes directory) #o777) #o700))
                (delete-directory directory t))))
          (error nil))
      (setf (emacs-jupyter-notebook-helper-backend-state-artifact-dir state) nil))))

(defun emacs-jupyter-notebook-helper-backend--dispose (state &optional reason)
  "Retire STATE's local helper and temporary artifacts exactly once."
  (when state
    (setf (emacs-jupyter-notebook-helper-backend-state-retired state) t)
    (when (timerp (emacs-jupyter-notebook-helper-backend-state-close-timer state))
      (cancel-timer (emacs-jupyter-notebook-helper-backend-state-close-timer state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-close-timer state) nil)
    (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state) nil)
    (when (hash-table-p (emacs-jupyter-notebook-helper-backend-state-request-map state))
      (clrhash (emacs-jupyter-notebook-helper-backend-state-request-map state)))
    (when (hash-table-p (emacs-jupyter-notebook-helper-backend-state-pending-events state))
      (clrhash (emacs-jupyter-notebook-helper-backend-state-pending-events state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-emit state) nil)
    (let ((helper (emacs-jupyter-notebook-helper-backend-state-helper state)))
      (setf (emacs-jupyter-notebook-helper-backend-state-helper state) nil)
      (when helper
        (ignore-errors (emacs-jupyter-notebook-helper-dispose helper reason))))
    (emacs-jupyter-notebook-helper-backend--remove-artifacts state)))

(defun emacs-jupyter-notebook-helper-backend--make-artifact-directory ()
  "Atomically create and identify one private helper artifact directory.

Return `(DIRECTORY . IDENTITY)'.  No caller receives DIRECTORY until its mode
has been forced to 0700 and its identity is available for replacement-safe
cleanup.  A failure after creation removes that just-created directory.
"
  (let (directory complete)
    (unwind-protect
        (progn
          (setq directory (make-temp-file "ejn-helper-artifacts-" t))
          ;; `make-temp-file' honours umask, but artifacts can contain code
          ;; output; force the contract even under a permissive umask.
          (set-file-modes directory #o700)
          (let* ((attributes (or (file-attributes directory)
                                 (error "cannot stat helper artifact directory")))
                 (identity (file-attribute-file-identifier attributes)))
            (unless identity
              (error "cannot identify helper artifact directory"))
            (setq complete t)
            (cons directory identity)))
      (unless complete
        (when directory
          (ignore-errors (delete-directory directory t)))))))

(defun emacs-jupyter-notebook-helper-backend--close-deadline ()
  "Return a close deadline which fires before the generic close deadline."
  ;; A fraction stays strictly earlier even when callers configure a very
  ;; short valid generic close deadline; subtraction can collapse to equality.
  (* 0.5 (emacs-jupyter-notebook-backend--close-timeout)))

(defun emacs-jupyter-notebook-helper-backend--finish-close
    (session state reason failed)
  "Complete STATE's local close once, even after generic session retirement."
  (when (emacs-jupyter-notebook-helper-backend--close-live-p session state)
    (let ((success (emacs-jupyter-notebook-helper-backend-state-close-success state))
          (failure (emacs-jupyter-notebook-helper-backend-state-close-failure state)))
      (emacs-jupyter-notebook-helper-backend--dispose state reason)
      (if failed
          (funcall failure reason)
        (funcall success nil)))))

(defun emacs-jupyter-notebook-helper-backend--response-result (response)
  "Extract RESPONSE's successful result or signal its bounded error."
  (if (and (hash-table-p response) (eq (gethash "ok" response) t))
      (gethash "result" response)
    (let ((error-object (and (hash-table-p response) (gethash "error" response))))
      (error "%s" (emacs-jupyter-notebook-helper-backend--safe-message error-object)))))

(defun emacs-jupyter-notebook-helper-backend--attached-result-p (result)
  "Return non-nil only for the exact successful helper connect result."
  (and (hash-table-p result)
       (= (hash-table-count result) 1)
       (eq (gethash "attached" result) t)))

(defun emacs-jupyter-notebook-helper-backend--closed-result-p (result)
  "Return non-nil only for the exact successful helper local-close result."
  (and (hash-table-p result)
       (= (hash-table-count result) 1)
       (eq (gethash "closed" result) t)))

(defun emacs-jupyter-notebook-helper-backend--emit-correlated
    (state helper-id mapping-value)
  "Synchronously emit one bounded EI3 correlation envelope.
The envelope is intentionally not an EI4 normalized output event."
  (when-let ((emit (emacs-jupyter-notebook-helper-backend-state-emit state)))
    (funcall emit (list :type 'helper-correlated
                        :ledger-id (plist-get mapping-value :ledger-id)
                        :backend-request-id
                        (plist-get mapping-value :backend-request-id)
                        :panel-generation
                        (plist-get mapping-value :panel-generation)
                        :helper-request-id helper-id))))

(defun emacs-jupyter-notebook-helper-backend--event (session state event)
  "Handle helper EVENT locally until EI4 owns normalized event delivery."
  (when (emacs-jupyter-notebook-helper-backend--state-live-p session state)
    (let ((kind (and (hash-table-p event) (gethash "event" event))))
      ;; A helper transport error is meaningful before output/event routing is
      ;; implemented.  Other raw protocol events are intentionally not fed to
      ;; EI1R's reducer: they are not normalized EI1R events yet.
      (if (equal kind "transport_error")
          (when-let* ((failure
                       (emacs-jupyter-notebook-helper-backend-state-transport-failure
                        state)))
            (funcall failure
                     (emacs-jupyter-notebook-helper-backend--safe-message
                      (gethash "data" event))))
        ;; EI3 only proves request/session correlation.  EI4 will normalize
        ;; output; raw payload is deliberately never handed to its reducer.
        (let ((helper-id (gethash "request_id" event)))
          ;; A production helper cannot emit before `helper-request' returns,
          ;; but a synchronous fake can.  Keep only one inert descriptor per
          ;; bounded inflight id rather than creating a timer per raw event.
          (when (stringp helper-id)
            (let* ((mapping (emacs-jupyter-notebook-helper-backend-state-request-map state))
                   (mapping-value (and (hash-table-p mapping)
                                       (gethash helper-id mapping))))
              (if mapping-value
                  (emacs-jupyter-notebook-helper-backend--emit-correlated
                   state helper-id mapping-value)
                (let ((pending
                       (or (emacs-jupyter-notebook-helper-backend-state-pending-events state)
                           (setf (emacs-jupyter-notebook-helper-backend-state-pending-events state)
                                 (make-hash-table :test #'equal)))))
                  (when (or (gethash helper-id pending)
                            (< (hash-table-count pending) 128))
                    (puthash helper-id t pending)))))))))))

(defun emacs-jupyter-notebook-helper-backend--request
    (session state op params timeout success failure
             &optional ledger-id backend-request-id panel-generation)
  "Send helper OP, while gating every terminal callback on SESSION and STATE."
  (let ((helper (emacs-jupyter-notebook-helper-backend-state-helper state))
        helper-id)
    (unless helper (error "helper is not available"))
    (when ledger-id
      (unless (and (integerp ledger-id) (> ledger-id 0))
        (error "Helper execution lacks a valid ledger id"))
      (let ((mapping (emacs-jupyter-notebook-helper-backend-state-request-map state)))
        (when (and (hash-table-p mapping) (>= (hash-table-count mapping) 128))
          (error "Too many correlated helper executions"))))
    ;; `helper-request' returns its string wire id only after it has installed
    ;; its own request slot.  A test helper may invoke CALLBACK re-entrantly,
    ;; but the generic backend dispatch boundary already defers the resulting
    ;; consumer callback until this function returns and installs the mapping.
    ;; Adding another timer here changes connect/close ordering and is not
    ;; needed for reentrancy safety.
    (setq helper-id
          (emacs-jupyter-notebook-helper-request
           helper op params
           (lambda (_current response error-data)
             (when (emacs-jupyter-notebook-helper-backend--state-live-p session state)
               ;; The core removes this mapping only when its ledger record
               ;; becomes terminal.  Removing it at helper response time races
               ;; already queued output/status events.
               (if error-data
                   (funcall failure
                            (emacs-jupyter-notebook-helper-backend--safe-message error-data))
                 (condition-case err
                     (funcall success
                              (emacs-jupyter-notebook-helper-backend--response-result response))
                   (error
                    (funcall failure (error-message-string err)))))))
           :timeout timeout))
    (when ledger-id
      (unless (and (stringp helper-id)
                   (> (length helper-id) 0))
        (error "Helper returned an invalid request id"))
      (unless (hash-table-p
               (emacs-jupyter-notebook-helper-backend-state-request-map state))
        (setf (emacs-jupyter-notebook-helper-backend-state-request-map state)
              (make-hash-table :test #'equal)))
      (puthash helper-id (list :ledger-id ledger-id
                               :backend-request-id backend-request-id
                               :panel-generation panel-generation)
               (emacs-jupyter-notebook-helper-backend-state-request-map state))
      (when-let ((pending (emacs-jupyter-notebook-helper-backend-state-pending-events state)))
        (when (gethash helper-id pending)
          (remhash helper-id pending)
          (emacs-jupyter-notebook-helper-backend--emit-correlated
           state helper-id
           (gethash helper-id
                    (emacs-jupyter-notebook-helper-backend-state-request-map state))))))
    helper-id))

(defun emacs-jupyter-notebook-helper-backend--execute-result (result)
  "Validate and normalize the bounded helper execute RESULT.
Only Jupyter's two terminal statuses and a nonnegative integer execution
count are admitted.  The core must never manufacture a successful reply from
an arbitrary helper object."
  (let ((status (and (hash-table-p result) (gethash "status" result)))
        (count (and (hash-table-p result) (gethash "execution_count" result))))
    (unless (and (member status '("ok" "error" "aborted"))
                 (integerp count) (>= count 0))
      (error "helper execute returned an invalid terminal result"))
    (list :status (if (equal status "ok") "ok" "error")
          :execution-count count)))

(defun emacs-jupyter-notebook-helper-backend-retire-ledger-id (session ledger-id)
  "Retire SESSION's bounded helper wire ids for terminal LEDGER-ID."
  (let ((state (and (emacs-jupyter-notebook-backend-session-p session)
                    (emacs-jupyter-notebook-backend-session-data session))))
    (when-let ((mapping (and (emacs-jupyter-notebook-helper-backend-state-p state)
                             (emacs-jupyter-notebook-helper-backend-state-request-map state))))
      (let (ids)
        (maphash (lambda (wire-id mapped)
                   (when (equal (plist-get mapped :ledger-id) ledger-id)
                     (push wire-id ids))) mapping)
        (dolist (wire-id ids) (remhash wire-id mapping))))))

(defun emacs-jupyter-notebook-helper-backend--verification-failure
    (session request reason failure)
  "Handle a bounded readiness failure for SESSION's connect REQUEST.

Before installation this is an ordinary connect failure.  After the core has
adopted an attached session for a PID-proven busy kernel, only retire the
obsolete generic readiness request.  Helper transport/process failure takes
the normal FAILURE path and remains fatal to local resources.
"
  (if (emacs-jupyter-notebook-backend-session-installed-p session)
      (emacs-jupyter-notebook-backend-request-fail request reason)
    (funcall failure reason)))

(defun emacs-jupyter-notebook-helper-backend--connect
    (session state request connection-file success failure)
  "Start/hello helper STATE, attach it, then verify CONNECTION-FILE.
The verification deadline intentionally exceeds the core connect timeout: the
core can retain an attached helper for the existing PID busy arbitration.
"
  (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state)
        (lambda (reason)
          (emacs-jupyter-notebook-backend-session-notify-transport-failure
           session reason)
          (funcall failure reason)))
  (condition-case err
      (let ((helper
             (emacs-jupyter-notebook-helper-start
              :buffer (emacs-jupyter-notebook-backend-session-owner-buffer session)
              :event-callback
              (lambda (_helper event)
                (emacs-jupyter-notebook-helper-backend--event session state event))
              :failure-callback
              (lambda (_helper reason)
                (let ((reason (emacs-jupyter-notebook-helper-backend--safe-message reason)))
                  (cond
                   ((emacs-jupyter-notebook-helper-backend--state-live-p session state)
                    (funcall
                     (emacs-jupyter-notebook-helper-backend-state-transport-failure
                      state)
                     reason))
                   ((emacs-jupyter-notebook-helper-backend--close-live-p session state)
                    (emacs-jupyter-notebook-helper-backend--finish-close
                     session state reason t)))))
              :closed-callback #'ignore
              :ready-callback
              (lambda (ready-helper _reason)
                (when (emacs-jupyter-notebook-helper-backend--state-live-p session state)
                  (setf (emacs-jupyter-notebook-helper-backend-state-helper state) ready-helper)
                  (emacs-jupyter-notebook-helper-backend--request
                   session state "connect"
                   (emacs-jupyter-notebook-helper-backend--make-object
                    "connection_file" connection-file
                    "artifact_dir" (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
                   emacs-jupyter-notebook-helper-backend--connect-timeout
                   (lambda (result)
                     (cond
                      ((not (emacs-jupyter-notebook-helper-backend--state-live-p session state)) nil)
                      ((not (emacs-jupyter-notebook-helper-backend--attached-result-p result))
                       (funcall failure "helper connect returned an invalid attachment result"))
                      (t
                       (emacs-jupyter-notebook-backend-session-mark-attached session)
                       (emacs-jupyter-notebook-helper-backend--request
                        session state "kernel_info"
                        (emacs-jupyter-notebook-helper-backend--make-object)
                        emacs-jupyter-notebook-helper-backend--verify-timeout
                        (lambda (verified) (funcall success verified))
                        (lambda (reason)
                          (emacs-jupyter-notebook-helper-backend--verification-failure
                           session request reason failure))))))
                   failure))))))
        (unless (emacs-jupyter-notebook-helper-backend-state-retired state)
          (setf (emacs-jupyter-notebook-helper-backend-state-helper state) helper)))
    (error (funcall failure (error-message-string err)))))

(defun emacs-jupyter-notebook-helper-backend--is-complete-operation-p (operation)
  "Return non-nil when OPERATION is the generic is-complete auxiliary call."
  (and (consp operation)
       (eq (car operation) 'aux)
       (eq (cdr operation) 'is-complete)))

(defun emacs-jupyter-notebook-helper-backend--kernel-info-operation-p (operation)
  "Return non-nil for EI3's bounded post-restart readiness probe."
  (and (consp operation)
       (eq (car operation) 'aux)
       (eq (cdr operation) 'kernel-info)))

(defun emacs-jupyter-notebook-helper-backend--payload-object (operation payload)
  "Translate EI3's admitted operations to a v1 params object."
  (cond
   ((or (eq operation 'execute)
        (emacs-jupyter-notebook-helper-backend--is-complete-operation-p operation))
    (emacs-jupyter-notebook-helper-backend--make-object
     "code" (plist-get payload :code)))
   ((emacs-jupyter-notebook-helper-backend--kernel-info-operation-p operation)
    (emacs-jupyter-notebook-helper-backend--make-object))
   (t (error "Unsupported helper operation: %S" operation))))

(defun emacs-jupyter-notebook-helper-backend-dispatch
    (session request operation payload success failure emit)
  "Implement the generic backend dispatch contract using the local helper."
  (pcase operation
    ('connect
     (let* ((artifact (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
            (artifact-dir (car artifact))
            (state (emacs-jupyter-notebook-helper-backend--make-state
                    :artifact-dir artifact-dir
                    :artifact-identity (cdr artifact))))
       (setf (emacs-jupyter-notebook-backend-session-data session) state)
       (emacs-jupyter-notebook-helper-backend--connect
        session state request payload
        (lambda (_result) (funcall success session))
        (lambda (reason)
          (emacs-jupyter-notebook-helper-backend--dispose state reason)
          (funcall failure reason)))))
    ('close-local
     (let ((state (emacs-jupyter-notebook-backend-session-data session)))
       ;; A failed connect can leave a generic session whose adapter state was
       ;; already retired.  Generic close must complete immediately there;
       ;; scheduling a helper request would only strand its own timeout.
       (if (or (not (emacs-jupyter-notebook-helper-backend-state-p state))
               (emacs-jupyter-notebook-helper-backend-state-retired state)
               (not (emacs-jupyter-notebook-helper-backend-state-helper state)))
           (funcall success nil)
         (progn
           (setf (emacs-jupyter-notebook-helper-backend-state-closing state) t)
           (setf (emacs-jupyter-notebook-helper-backend-state-close-success state) success
                 (emacs-jupyter-notebook-helper-backend-state-close-failure state) failure
                 (emacs-jupyter-notebook-helper-backend-state-close-timer state)
                 (run-at-time (emacs-jupyter-notebook-helper-backend--close-deadline)
                              nil
                              (lambda ()
                                (emacs-jupyter-notebook-helper-backend--finish-close
                                 session state "helper local close timed out" t))))
           ;; `close' is helper-local, not Jupyter shutdown.  Its outcome is
           ;; bounded separately from generic backend retirement.
           (condition-case err
               (emacs-jupyter-notebook-helper-request
                (emacs-jupyter-notebook-helper-backend-state-helper state)
                "close" (emacs-jupyter-notebook-helper-backend--make-object)
                (lambda (_helper response error-data)
                  (when (emacs-jupyter-notebook-helper-backend--close-live-p session state)
                    (if error-data
                        (emacs-jupyter-notebook-helper-backend--finish-close
                         session state
                         (emacs-jupyter-notebook-helper-backend--safe-message error-data) t)
                      (condition-case response-error
                          (let ((result
                                 (emacs-jupyter-notebook-helper-backend--response-result response)))
                            (if (emacs-jupyter-notebook-helper-backend--closed-result-p result)
                                (emacs-jupyter-notebook-helper-backend--finish-close
                                 session state "local close" nil)
                              (emacs-jupyter-notebook-helper-backend--finish-close
                               session state "helper close returned an invalid result" t)))
                        (error
                         (emacs-jupyter-notebook-helper-backend--finish-close
                          session state (error-message-string response-error) t))))))
                :timeout (emacs-jupyter-notebook-helper-backend--close-deadline))
             (error
              (emacs-jupyter-notebook-helper-backend--finish-close
               session state (error-message-string err) t)))))))
    (_
     (let ((state (emacs-jupyter-notebook-backend-session-data session)))
       (unless (and (emacs-jupyter-notebook-helper-backend-state-p state)
                    (emacs-jupyter-notebook-helper-backend--state-live-p session state))
         (error "Helper backend is not attached"))
       (unless (or (eq operation 'execute)
                   (emacs-jupyter-notebook-helper-backend--is-complete-operation-p operation)
                   (emacs-jupyter-notebook-helper-backend--kernel-info-operation-p operation))
         (error "Helper backend operation is unavailable until EI5"))
       (setf (emacs-jupyter-notebook-helper-backend-state-emit state) emit)
       (let* ((options (plist-get payload :options))
              (ledger-id (and (eq operation 'execute)
                              (plist-get options :ledger-id)))
              (panel-generation (and (eq operation 'execute)
                                     (plist-get (plist-get options :entry-handle)
                                                :generation))))
         (emacs-jupyter-notebook-helper-backend--request
          session state
          (cond ((eq operation 'execute) "execute")
                ((emacs-jupyter-notebook-helper-backend--is-complete-operation-p operation)
                 "is_complete")
                (t "kernel_info"))
          (emacs-jupyter-notebook-helper-backend--payload-object operation payload)
          30
          (cond
           ((eq operation 'execute)
            (lambda (result)
              (condition-case err
                  (funcall success
                           (emacs-jupyter-notebook-helper-backend--execute-result result))
                (error (funcall failure (error-message-string err))))))
           ((emacs-jupyter-notebook-helper-backend--is-complete-operation-p operation)
            (lambda (result)
              (let ((status (and (hash-table-p result) (gethash "status" result))))
                (if (stringp status)
                    (funcall success (list :status status))
                  (funcall failure "helper is_complete returned an invalid result")))))
           (t success))
          failure ledger-id
          (and (eq operation 'execute)
               (emacs-jupyter-notebook-backend-request-id request))
          panel-generation))))))

(add-to-list 'emacs-jupyter-notebook-backend-implementations
             (cons 'helper #'emacs-jupyter-notebook-helper-backend-dispatch))

(provide 'emacs-jupyter-notebook-helper-backend)

;;; emacs-jupyter-notebook-helper-backend.el ends here
