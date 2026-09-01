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
(require 'emacs-jupyter-notebook-vars)

(defconst emacs-jupyter-notebook-helper-backend--connect-timeout 30)
(defconst emacs-jupyter-notebook-helper-backend--hard-image-pixels 4194304)
(defconst emacs-jupyter-notebook-helper-backend--verify-timeout 180
  "Hard local deadline for helper `kernel_info' readiness verification.

This stays above the helper runtime's 150s backend deadline and 160s
dispatcher deadline.  Core busy arbitration caps at 45s, so it always decides
whether an attached reconnect is usable before this terminal request expiry.")

(defun emacs-jupyter-notebook-helper-backend-ensure ()
  "Resolve the helper executable before any remote launch is admitted."
  (emacs-jupyter-notebook-helper-resolve-argv))

(defun emacs-jupyter-notebook-helper-backend--image-pixel-budget ()
  "Return the configured preview budget clamped to the protocol ceiling."
  (let ((value emacs-jupyter-notebook-helper-inline-image-max-pixels))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook-helper-backend--hard-image-pixels)
      0)))

(cl-defstruct (emacs-jupyter-notebook-helper-backend-state
               (:constructor emacs-jupyter-notebook-helper-backend--make-state))
  "Local resources owned by one helper backend session."
  helper artifact-dir artifact-identity request-map pending-events pending-event-sequence
  retired-request-ids retired-request-order pending-flush-timer emit closing retired close-timer
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
  "Remove only STATE's staging files, never panel-transferred publications."
  (let ((directory (emacs-jupyter-notebook-helper-backend-state-artifact-dir state)))
    (unwind-protect
        (condition-case nil
            (let* ((symlink (and (stringp directory) (file-symlink-p directory)))
                   (attributes (and (stringp directory) (not symlink)
                                    (file-attributes directory 'integer)))
                   (identity (and attributes (file-attribute-file-identifier attributes))))
              (cond
               (symlink (delete-file directory))
               ((and attributes (file-directory-p directory)
                     (equal identity (emacs-jupyter-notebook-helper-backend-state-artifact-identity state))
                     (equal (file-attribute-user-id attributes) (user-uid))
                     (= (logand (file-modes directory) #o7777) #o700))
                ;; Python atomically renames completed publications to
                ;; `ejn-artifact-*'.  Never enumerate or retain those: their
                ;; panel/crash lifetime is independent of this adapter.  The
                ;; only local staging names are direct `.ejn-partial-*' files.
                (dolist (file (directory-files directory t "\\`\\.ejn-partial-"))
                  (ignore-errors (delete-file file)))
                (when (null (directory-files directory nil "\\`[^.]"))
                  (delete-directory directory)))))
          (error nil))
      (setf (emacs-jupyter-notebook-helper-backend-state-artifact-dir state) nil))))

(defun emacs-jupyter-notebook-helper-backend--dispose (state &optional reason)
  "Retire STATE's local helper and temporary artifacts exactly once."
  (when state
    (setf (emacs-jupyter-notebook-helper-backend-state-retired state) t)
    (when (timerp (emacs-jupyter-notebook-helper-backend-state-close-timer state))
      (cancel-timer (emacs-jupyter-notebook-helper-backend-state-close-timer state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-close-timer state) nil)
    (when (timerp (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state))
      (cancel-timer (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state) nil)
    (setf (emacs-jupyter-notebook-helper-backend-state-transport-failure state) nil)
    (when (hash-table-p (emacs-jupyter-notebook-helper-backend-state-request-map state))
      (clrhash (emacs-jupyter-notebook-helper-backend-state-request-map state)))
    (when (hash-table-p (emacs-jupyter-notebook-helper-backend-state-pending-events state))
      (clrhash (emacs-jupyter-notebook-helper-backend-state-pending-events state)))
    (when (hash-table-p (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state))
      (clrhash (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state)))
    (setf (emacs-jupyter-notebook-helper-backend-state-retired-request-order state) nil)
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
  (let (created directory complete)
    (unwind-protect
        (progn
          (setq created (make-temp-file "ejn-helper-artifacts-" t))
          ;; `make-temp-file' honours umask, but artifacts can contain code
          ;; output; force the contract even under a permissive umask.
          (set-file-modes created #o700)
          ;; Python resolves ordinary ancestor aliases (notably Darwin's
          ;; /var -> /private/var) before reporting publication paths.  Pin and
          ;; advertise that same canonical spelling while the freshly-created
          ;; final component is still known not to be a symlink.
          (when (file-symlink-p created)
            (error "helper artifact directory became a symlink"))
          (setq directory (file-truename created))
          (let* ((attributes (or (file-attributes directory 'integer)
                                 (error "cannot stat helper artifact directory")))
                 (identity (file-attribute-file-identifier attributes)))
            (unless identity
              (error "cannot identify helper artifact directory"))
            (setq complete t)
            (cons directory identity)))
      (unless complete
        (when created
          (ignore-errors (delete-directory created t)))))))

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

(defun emacs-jupyter-notebook-helper-backend--event-data (event)
  "Return EVENT's protocol data object, or nil."
  (let ((data (and (hash-table-p event) (gethash "data" event))))
    (and (hash-table-p data) data)))

(defun emacs-jupyter-notebook-helper-backend--required-field (object field)
  "Return required FIELD from OBJECT, rejecting absent JSON keys explicitly."
  (let ((missing (make-symbol "missing")))
    (let ((value (gethash field object missing)))
      (when (eq value missing)
        (error "helper artifact lacks required %s" field))
      value)))

(defun emacs-jupyter-notebook-helper-backend--artifact-leaf (object)
  "Validate one required path/bytes/SHA256 artifact leaf from OBJECT."
  (unless (hash-table-p object)
    (error "malformed helper artifact leaf"))
  (let ((path (emacs-jupyter-notebook-helper-backend--required-field object "path"))
        (bytes (emacs-jupyter-notebook-helper-backend--required-field object "bytes"))
        (sha256 (emacs-jupyter-notebook-helper-backend--required-field object "sha256")))
    (unless (and (stringp path) (file-name-absolute-p path)
                 (integerp bytes) (>= bytes 0)
                 (stringp sha256)
                 (string-equal sha256 (downcase sha256))
                 (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256))
      (error "malformed helper artifact leaf"))
    (list :path path :size bytes :sha256 sha256)))

(defun emacs-jupyter-notebook-helper-backend--image-publication
    (state mime descriptor display-id)
  "Validate nested image DESCRIPTOR and attach STATE's pinned root metadata."
  (unless (hash-table-p descriptor)
    (error "malformed helper image descriptor"))
  (let* ((original
          (emacs-jupyter-notebook-helper-backend--artifact-leaf
           (emacs-jupyter-notebook-helper-backend--required-field
            descriptor "original")))
         (missing (make-symbol "missing"))
         (preview-value (gethash "preview" descriptor missing))
         (preview
          (unless (eq preview-value missing)
            (let* ((leaf (emacs-jupyter-notebook-helper-backend--artifact-leaf
                          preview-value))
                   (preview-mime
                    (emacs-jupyter-notebook-helper-backend--required-field
                     preview-value "mime"))
                   (width (emacs-jupyter-notebook-helper-backend--required-field
                           preview-value "width"))
                   (height (emacs-jupyter-notebook-helper-backend--required-field
                            preview-value "height")))
              (unless (and (equal preview-mime "image/x-portable-pixmap")
                           (integerp width) (integerp height)
                           (<= 1 width 1024) (<= 1 height 1024))
                (error "malformed helper PPM preview"))
              (append leaf (list :mime preview-mime :width width :height height))))))
    (list :root (emacs-jupyter-notebook-helper-backend-state-artifact-dir state)
          :root-identity
          (emacs-jupyter-notebook-helper-backend-state-artifact-identity state)
          :mime mime :original original :preview preview :display-id display-id)))

(defun emacs-jupyter-notebook-helper-backend--normalize-event (state event)
  "Translate one bounded helper EVENT into an EI1R event plist, or signal.
No generic reducer is called here: the core validates the ledger/backend/
generation tuple before any presentation mutation.
"
  (let* ((name (gethash "event" event)) (data (emacs-jupyter-notebook-helper-backend--event-data event)))
    (unless data (error "helper event lacks an object payload"))
    (pcase name
      ("stream" (let ((text (gethash "text" data)) (stream (gethash "name" data)))
                  (unless (and (stringp text) (member stream '("stdout" "stderr")))
                    (error "malformed helper stream"))
                  (list :type 'stream :text text :name stream)))
      ("clear_output" (let ((wait (gethash "wait" data)))
                         (unless (or (eq wait t) (eq wait :false))
                           (error "malformed helper clear"))
                         (list :type 'clear :wait (eq wait t))))
      ("status" (let ((value (gethash "execution_state" data)))
                   (unless (stringp value) (error "malformed helper status"))
                   (list :type 'status :execution-state value)))
      ("execute_reply" (let ((status (gethash "status" data)) (count (gethash "execution_count" data)))
                           (unless (and (member status '("ok" "error" "aborted"))
                                        (or (null count) (and (integerp count) (>= count 0))))
                             (error "malformed helper execute reply"))
                           (list :type 'execute-reply :status status :execution-count count)))
      ;; EI5 owns stdin request/reply correlation.  Do not create a prompt
      ;; with no bounded reply route in EI4.
      ("input_request" (error "helper stdin is unavailable until EI5"))
      ("output_truncated" (list :type 'truncation :text "[output truncated]\n"))
      ((or "display_data" "execute_result" "update_display_data")
       (let* ((payload (gethash "data" data))
              (metadata (gethash "metadata" data))
              (transient (gethash "transient" data))
              (display-id (and (hash-table-p transient) (gethash "display_id" transient)))
              ;; HT9 keeps the protocol event name `display_data' and marks
              ;; Jupyter's `update_display_data' with this bounded boolean.
              (update-value (gethash "update" data))
              (update-p (or (equal name "update_display_data")
                            (eq update-value t)))
              (pickle-artifact (and (hash-table-p payload)
                                    (gethash "application/x-ejn-mpl-pickle" payload)))
              (image-mime (and (hash-table-p payload)
                               (cl-find-if (lambda (key) (gethash key payload))
                                           '("image/png" "image/jpeg" "image/gif" "image/webp"))))
              (image-artifact (and image-mime (gethash image-mime payload)))
              (text (and (hash-table-p payload) (gethash "text/plain" payload)))
              (type (if (equal name "execute_result") 'result
                      (if update-p 'update-display 'display))))
         (unless (hash-table-p payload)
           (error "malformed helper rich output data"))
         (unless (hash-table-p metadata)
           (error "malformed helper rich output metadata"))
         (unless (or (null transient) (hash-table-p transient))
           (error "malformed helper transient data"))
         (unless (memq update-value '(nil t :false))
           (error "malformed helper update flag"))
         (when (and (equal name "execute_result") update-p)
           (error "malformed helper execute result update"))
         (unless (or (null display-id)
                     (and (stringp display-id) (<= (string-bytes display-id) 256)))
           (error "malformed helper display id"))
         (when (or (and pickle-artifact (not (hash-table-p pickle-artifact)))
                   (and image-mime (not (hash-table-p image-artifact))))
           (error "malformed helper artifact descriptor"))
         (cond
          ((or pickle-artifact image-artifact)
           (let ((publication-data nil))
             (when image-artifact
               (setq publication-data
                     (append publication-data
                             (list :ejn-published-image
                                   (emacs-jupyter-notebook-helper-backend--image-publication
                                    state image-mime image-artifact display-id)))))
             (when pickle-artifact
               (let ((pickle (emacs-jupyter-notebook-helper-backend--artifact-leaf
                              pickle-artifact)))
                 (setq publication-data
                       (append publication-data
                               (list :ejn-published-pickle
                                     (append pickle
                                             (list :root (emacs-jupyter-notebook-helper-backend-state-artifact-dir state)
                                                   :root-identity (emacs-jupyter-notebook-helper-backend-state-artifact-identity state)
                                                   :display-id display-id)))))))
             (list :type type :data publication-data
                   :metadata metadata
                   :transient transient :display-id display-id
                   :require-display-id update-p)))
          ((stringp text) (list :type type :data (list :text/plain text)
                                :metadata metadata
                                :transient transient :display-id display-id
                                :require-display-id update-p))
          (t (error "malformed helper rich output")))))
      ("transport_error" (list :type 'transport-error))
      (_ (error "unsupported helper event")))))

(defun emacs-jupyter-notebook-helper-backend--emit-event (state helper-id mapping-value event)
  "Emit one normalized EI4 event tied to MAPPING-VALUE."
  (when-let ((emit (emacs-jupyter-notebook-helper-backend-state-emit state)))
    (funcall emit (list :type 'helper-event :event event :helper-request-id helper-id
                        :ledger-id (plist-get mapping-value :ledger-id)
                        :backend-request-id (plist-get mapping-value :backend-request-id)
                        :panel-generation (plist-get mapping-value :panel-generation)))))

(defun emacs-jupyter-notebook-helper-backend--raw-publication-paths (event)
  "Return every helper artifact path advertised by raw EVENT."
  (let* ((data (emacs-jupyter-notebook-helper-backend--event-data event))
         (payload (and data (gethash "data" data))))
    (when (hash-table-p payload)
      (let (paths)
        (dolist (mime '("application/x-ejn-mpl-pickle"
                        "image/png" "image/jpeg" "image/gif" "image/webp"))
          (let ((artifact (gethash mime payload)))
            (when (hash-table-p artifact)
              (if (string-prefix-p "image/" mime)
                  (dolist (part '("original" "preview"))
                    (let ((leaf (gethash part artifact)))
                      (when (hash-table-p leaf)
                        (let ((path (gethash "path" leaf)))
                          (when (stringp path) (push path paths))))))
                (let ((path (gethash "path" artifact)))
                  (when (stringp path) (push path paths)))))))
        (nreverse paths)))))

(defun emacs-jupyter-notebook-helper-backend--discard-publication (state path)
  "Unlink unaccepted helper publication PATH if its pinned identity is intact."
  (let ((file-name-handler-alist nil)
        (root (emacs-jupyter-notebook-helper-backend-state-artifact-dir state))
        (root-identity
         (emacs-jupyter-notebook-helper-backend-state-artifact-identity state)))
    (condition-case nil
        (when (and (stringp root) (file-name-absolute-p root)
                   (stringp path) (file-name-absolute-p path)
                   (string-match-p "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'"
                                   (file-name-nondirectory path)))
          (let* ((root-name (directory-file-name (expand-file-name root)))
                 (path-name (expand-file-name path))
                 (root-attrs (and (not (file-symlink-p root-name))
                                  (file-attributes root-name 'integer)))
                 (attrs (and (not (file-symlink-p path-name))
                             (file-attributes path-name 'integer)))
                 (identity (and attrs (file-attribute-file-identifier attrs))))
            (when (and root-attrs attrs identity
                       (file-directory-p root-name)
                       (eq (file-attribute-type root-attrs) t)
                       (equal (file-attribute-user-id root-attrs) (user-uid))
                       (= (logand (file-modes root-name) #o7777) #o700)
                       (equal root-identity
                              (file-attribute-file-identifier root-attrs))
                       (equal (file-name-directory (directory-file-name path-name))
                              (file-name-as-directory root-name))
                       (file-regular-p path-name)
                       (null (file-attribute-type attrs))
                       (equal (file-attribute-user-id attrs) (user-uid))
                       (= (logand (file-modes path-name) #o7777) #o600)
                       (let ((post-root (and (not (file-symlink-p root-name))
                                             (file-attributes root-name 'integer)))
                             (post (and (not (file-symlink-p path-name))
                                        (file-attributes path-name 'integer))))
                         (and post-root post
                              (equal root-identity
                                     (file-attribute-file-identifier post-root))
                              (equal identity (file-attribute-file-identifier post)))))
              (delete-file path-name)
              t)))
      (error nil))))

(defun emacs-jupyter-notebook-helper-backend--deliver-mapped-event
    (state helper-id mapping-value raw-event)
  "Normalize and synchronously deliver RAW-EVENT for MAPPING-VALUE.
Return the core's explicit admission result.  An accepted publication becomes
panel-owned; an individually rejected publication is securely discarded.
Crash-orphaned publications remain for EI9's confined stale-artifact pruning.
"
  (let ((paths (emacs-jupyter-notebook-helper-backend--raw-publication-paths raw-event))
        accepted)
    (unwind-protect
        (let ((event (emacs-jupyter-notebook-helper-backend--normalize-event state raw-event)))
          (setq accepted (emacs-jupyter-notebook-helper-backend--emit-event
                          state helper-id mapping-value event)))
      (unless accepted
        (dolist (path paths)
          (emacs-jupyter-notebook-helper-backend--discard-publication state path))))
    accepted))

(defun emacs-jupyter-notebook-helper-backend--flush-pending-events (session state)
  "Deliver every now-mapped bounded early-event FIFO in arrival order.
This runs once after a reentrant public backend call returns, so generic
backend deferral cannot be mistaken for panel acceptance.
"
  (when (emacs-jupyter-notebook-helper-backend--state-live-p session state)
    (let ((pending (emacs-jupyter-notebook-helper-backend-state-pending-events state))
          (mapping (emacs-jupyter-notebook-helper-backend-state-request-map state))
          ready)
      (when (and (hash-table-p pending) (hash-table-p mapping))
        (maphash (lambda (helper-id events)
                   (when-let ((mapped (gethash helper-id mapping)))
                     (dolist (sequenced-event events)
                       (push (vector (car sequenced-event) helper-id mapped
                                     (cdr sequenced-event))
                             ready))
                     (remhash helper-id pending)))
                 pending)
        ;; Hash iteration is unspecified.  Restore the original global arrival
        ;; order before delivering entries from multiple now-mapped ids.
        (setq ready (sort ready (lambda (left right)
                                  (< (aref left 0) (aref right 0)))))
        (dolist (item ready)
          ;; Admission belongs only to this event's artifact lease.  A rejected
          ;; or malformed output must never suppress later terminal evidence.
          (condition-case err
              (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
               state (aref item 1) (aref item 2) (aref item 3))
            (error
             (message "emacs-jupyter-notebook rejected early helper event: %s"
                      (error-message-string err)))))))))

(defun emacs-jupyter-notebook-helper-backend--schedule-pending-flush (session state)
  "Flush early events now, or in one post-dispatch callback when required."
  (if (> (or (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0) 0)
      (unless (timerp (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state))
        (setf (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state)
              (run-at-time
               0 nil
               (lambda ()
                 (setf (emacs-jupyter-notebook-helper-backend-state-pending-flush-timer state) nil)
                 (emacs-jupyter-notebook-helper-backend--flush-pending-events session state)))))
    (emacs-jupyter-notebook-helper-backend--flush-pending-events session state)))

(defun emacs-jupyter-notebook-helper-backend--retain-early-event
    (session state helper-id event)
  "Boundedly retain reentrant EVENT until HELPER-ID receives its mapping."
  (let ((publications
         (emacs-jupyter-notebook-helper-backend--raw-publication-paths event)))
    (cond
     (publications
      ;; Never hold an uncorrelated disk artifact merely to support a
      ;; synchronous test fake.
      (dolist (publication publications)
        (emacs-jupyter-notebook-helper-backend--discard-publication
         state publication)))
     ((<= (or (emacs-jupyter-notebook-backend-session-dispatch-depth session) 0) 0)
      ;; A real process callback cannot run before `helper-request' installs
      ;; the mapping.  An asynchronous unknown id is late or invalid, not early.
      nil)
     (t
      (let* ((pending
              (or (emacs-jupyter-notebook-helper-backend-state-pending-events state)
                  (setf (emacs-jupyter-notebook-helper-backend-state-pending-events state)
                        (make-hash-table :test #'equal))))
             (events (gethash helper-id pending)))
        (when (and (or events (< (hash-table-count pending) 128))
                   (< (length events) 8))
          (let ((sequence
                 (1+ (or (emacs-jupyter-notebook-helper-backend-state-pending-event-sequence
                          state)
                         0))))
            (setf (emacs-jupyter-notebook-helper-backend-state-pending-event-sequence
                   state)
                  sequence)
            (puthash helper-id (append events (list (cons sequence event))) pending))
          t))))))

(defun emacs-jupyter-notebook-helper-backend--event (session state event)
  "Normalize helper EVENT and deliver it only through the EI1R admission path."
  (when (emacs-jupyter-notebook-helper-backend--state-live-p session state)
    (let ((kind (and (hash-table-p event) (gethash "event" event))))
      (if (equal kind "transport_error")
          (when-let* ((failure
                       (emacs-jupyter-notebook-helper-backend-state-transport-failure
                        state)))
            (funcall failure
                     (emacs-jupyter-notebook-helper-backend--safe-message
                      (gethash "data" event))))
        (let ((helper-id (gethash "request_id" event)))
          ;; A production helper cannot emit before `helper-request' returns,
          ;; but a synchronous fake can.  Keep its bounded FIFO intact until
          ;; the mapping is installed; one post-dispatch flush handles all ids.
          (when (stringp helper-id)
            (let* ((mapping (emacs-jupyter-notebook-helper-backend-state-request-map state))
                   (retired (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state))
                   (mapping-value (and (hash-table-p mapping)
                                       (gethash helper-id mapping))))
              (cond
               ;; A terminal ledger retirement tombstones its helper wire id.
               ;; Late output must not masquerade as a reentrant early event
               ;; and consume the pending-id budget.
               ((and (hash-table-p retired) (gethash helper-id retired))
                (dolist (publication (emacs-jupyter-notebook-helper-backend--raw-publication-paths event))
                  (emacs-jupyter-notebook-helper-backend--discard-publication
                   state publication))
                nil)
               (mapping-value
                (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
                 state helper-id mapping-value event))
               (t
                (emacs-jupyter-notebook-helper-backend--retain-early-event
                 session state helper-id event))))))))))

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
      (emacs-jupyter-notebook-helper-backend--schedule-pending-flush session state))
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
        (dolist (wire-id ids)
          (remhash wire-id mapping)
          (let ((retired
                 (or (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state)
                     (setf (emacs-jupyter-notebook-helper-backend-state-retired-request-ids state)
                           (make-hash-table :test #'equal))))
                (order (emacs-jupyter-notebook-helper-backend-state-retired-request-order state)))
            (unless (gethash wire-id retired)
              (puthash wire-id t retired)
              (setq order (append order (list wire-id)))
              (when (> (length order) 128)
                (remhash (car order) retired)
                (setq order (cdr order)))
              (setf (emacs-jupyter-notebook-helper-backend-state-retired-request-order state)
                    order))))))))

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
                    "artifact_dir" (emacs-jupyter-notebook-helper-backend-state-artifact-dir state)
                    "image_max_pixels"
                    (emacs-jupyter-notebook-helper-backend--image-pixel-budget))
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
