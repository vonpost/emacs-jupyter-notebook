;;; emacs-jupyter-notebook-registry.el --- Async durable registry bridge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; The registry is owned by a one-shot local JSON worker.  This module never
;; reads or writes registry files: every operation is a bounded child process
;; with exact-revision CAS supplied by the worker.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-process)

(defconst emacs-jupyter-notebook-registry--protocol-version 1)
(defconst emacs-jupyter-notebook-registry--hard-request-bytes (* 64 1024))
(defconst emacs-jupyter-notebook-registry--hard-output-bytes (* 384 1024))
(defconst emacs-jupyter-notebook-registry--hard-stderr-bytes (* 64 1024))
(defconst emacs-jupyter-notebook-registry--hard-deadline 120)
(defconst emacs-jupyter-notebook-registry--hard-min-retry-delay 0.001)
(defconst emacs-jupyter-notebook-registry--retry-safety-margin 0.001)
(defconst emacs-jupyter-notebook-registry--hard-json-depth 21)
(defconst emacs-jupyter-notebook-registry--hard-json-object-items 128)
(defconst emacs-jupyter-notebook-registry--hard-json-array-items 256)
(defconst emacs-jupyter-notebook-registry--hard-json-number-chars 32)
(defconst emacs-jupyter-notebook-registry--module-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory))))

(cl-defstruct (emacs-jupyter-notebook-registry-owner
               (:constructor emacs-jupyter-notebook-registry--make-owner))
  "Local callback ownership for asynchronous registry operations."
  token buffer guard operations cancelled)

(cl-defstruct (emacs-jupyter-notebook-registry-operation
               (:constructor emacs-jupyter-notebook-registry--make-operation))
  "One local registry worker request.
Cancellation affects only local processes and timers.  A worker may have
committed before cancellation, so no cancellation path compensates durably."
  token owner request success failure process stderr-process stdout stderr
  deadline attempt-timer retry-timer deadline-timer retry-count finished
  cancelled result)

(defvar-local emacs-jupyter-notebook-registry--owners nil
  "Registry worker owners associated with the current source buffer.")

(defun emacs-jupyter-notebook-registry--entry-key (entry)
  "Return durable identity key for in-memory ENTRY."
  (or (plist-get entry :session-id)
      (plist-get entry :profile)
      (error "Registry entry has no :session-id or :profile")))

(defun emacs-jupyter-notebook-registry-find (key entries)
  "Return in-memory registry entry identified by KEY in ENTRIES."
  (cl-find-if (lambda (entry)
                (equal key (emacs-jupyter-notebook-registry--entry-key entry)))
              entries))

(defun emacs-jupyter-notebook-registry-latest-for-profile (profile entries)
  "Return newest in-memory registry entry for PROFILE in ENTRIES."
  (car (sort (cl-remove-if-not
              (lambda (entry) (equal profile (plist-get entry :profile)))
              (copy-sequence entries))
             (lambda (a b)
               (string> (or (plist-get a :created-at) "")
                        (or (plist-get b :created-at) ""))))))

(defun emacs-jupyter-notebook-registry-latest-for-file (file entries)
  "Return newest in-memory registry entry associated with local FILE."
  (let ((file (and file (expand-file-name file))))
    (car (sort (cl-remove-if-not
                (lambda (entry)
                  (equal file
                         (and (plist-get entry :local-file)
                              (expand-file-name (plist-get entry :local-file)))))
                (copy-sequence entries))
               (lambda (a b)
                 (string> (or (plist-get a :created-at) "")
                          (or (plist-get b :created-at) "")))))))

(defun emacs-jupyter-notebook-registry--finite-number-p (value)
  "Return non-nil when VALUE is a finite Emacs number."
  (and (numberp value)
       (or (not (floatp value))
           (and (not (isnan value)) (< (abs value) 1.0e+INF)))))

(defun emacs-jupyter-notebook-registry--positive-number (value fallback)
  "Return finite positive VALUE capped by the bridge hard deadline.
FALLBACK is normalized too, so this boundary never leaks an unsafe default
into a timer or deadline calculation."
  (let ((safe-fallback
         (if (and (emacs-jupyter-notebook-registry--finite-number-p fallback)
                  (> fallback 0))
             (min fallback emacs-jupyter-notebook-registry--hard-deadline)
           emacs-jupyter-notebook-registry--hard-deadline)))
    (if (and (emacs-jupyter-notebook-registry--finite-number-p value)
             (> value 0))
        (min value emacs-jupyter-notebook-registry--hard-deadline)
      safe-fallback)))

(defun emacs-jupyter-notebook-registry--request-timeout ()
  "Return timeout for one worker attempt."
  (emacs-jupyter-notebook-registry--positive-number
   emacs-jupyter-notebook-registry-worker-request-timeout 5))

(defun emacs-jupyter-notebook-registry--retry-deadline ()
  "Return total deadline for one logical worker request."
  (emacs-jupyter-notebook-registry--positive-number
   emacs-jupyter-notebook-registry-worker-retry-deadline 15))

(defun emacs-jupyter-notebook-registry--deadline-at (deadline)
  "Normalize DEADLINE to an absolute `float-time' deadline.
An absolute value is recognized by its epoch-scale magnitude.  Smaller
positive values are relative seconds, which keeps the public API convenient
for callers without an enclosing lifecycle deadline.  A stale absolute value
is retained so the caller fails immediately rather than silently receiving a
fresh, longer transaction budget."
  (let* ((now (float-time))
         (hard-deadline (+ now emacs-jupyter-notebook-registry--hard-deadline)))
    (cond
     ;; Preserve stale and nearer finite absolute deadlines.  A distant one
     ;; is still bounded by the immutable transaction ceiling.
     ((and (numberp deadline) (> deadline 1000000))
      (if (emacs-jupyter-notebook-registry--finite-number-p deadline)
          (min deadline hard-deadline)
        hard-deadline))
     (t
      (min (+ now
             (emacs-jupyter-notebook-registry--positive-number
              deadline (emacs-jupyter-notebook-registry--retry-deadline)))
           hard-deadline)))))

(defun emacs-jupyter-notebook-registry--output-limit ()
  "Return bounded stdout retention limit."
  (let ((value emacs-jupyter-notebook-registry-worker-output-max-bytes))
    (if (and (integerp value) (> value 0)
             (<= value emacs-jupyter-notebook-registry--hard-output-bytes))
        value
      emacs-jupyter-notebook-registry--hard-output-bytes)))

(defun emacs-jupyter-notebook-registry--stderr-limit ()
  "Return bounded stderr retention limit."
  (let ((value emacs-jupyter-notebook-registry-worker-stderr-max-bytes))
    (if (and (integerp value) (> value 0)
             (<= value emacs-jupyter-notebook-registry--hard-stderr-bytes))
        value
      emacs-jupyter-notebook-registry--hard-stderr-bytes)))

(defun emacs-jupyter-notebook-registry--resolve-program (program)
  "Resolve registry worker PROGRAM without depending on `default-directory'."
  (cond
   ((not (and (stringp program) (not (string-empty-p program)))) nil)
   ;; Reject remote syntax before any file predicate can invoke a handler.
   ((file-remote-p program) nil)
   ((file-name-absolute-p program)
    (and (file-executable-p program) program))
   ((file-name-directory program)
    (let ((candidate (expand-file-name program
                                       emacs-jupyter-notebook-registry--module-directory)))
      (and (not (file-remote-p candidate))
           (file-executable-p candidate)
           candidate)))
   ((cl-loop for directory in exec-path
             when (and (stringp directory)
                       (file-name-absolute-p directory)
                       (not (file-remote-p directory)))
             for candidate = (expand-file-name program directory)
             when (file-executable-p candidate)
             return candidate))
   (t
    (let ((root emacs-jupyter-notebook-registry--module-directory))
      (cl-loop for candidate in
               (delq nil
                     (list
                      (and (stringp emacs-jupyter-notebook--runtime-directory)
                           (expand-file-name
                            (concat "bin/" program)
                            emacs-jupyter-notebook--runtime-directory))
                      (expand-file-name (concat "result/bin/" program) root)
                      (expand-file-name (concat "../result/bin/" program) root)
                      (expand-file-name (concat "registry_worker/bin/" program) root)))
               when (file-executable-p candidate)
               return candidate)))))

(defun emacs-jupyter-notebook-registry-worker-resolve-argv (&optional command)
  "Return executable argv for one local transactional registry worker.
PATH is preferred, followed by the auto-built closure, a Nix `result/bin'
link, and the checkout wrapper.  This performs command discovery only, never
registry I/O."
  (let ((argv (or command emacs-jupyter-notebook-registry-worker-command)))
    (unless (and (listp argv) (stringp (car argv))
                 (cl-every #'stringp argv))
      (error "Registry worker command must be a non-empty argv list of strings"))
    (let ((program (emacs-jupyter-notebook-registry--resolve-program (car argv))))
      (unless program
        (error (concat "Cannot resolve EJN registry worker. Retry the automatic "
                       "Nix build or set "
                       "emacs-jupyter-notebook-registry-worker-command.")))
      (cons program (cdr argv)))))

(defun emacs-jupyter-notebook-registry--cancel-timer (timer)
  "Cancel TIMER when live."
  (when (timerp timer) (cancel-timer timer)))

(defun emacs-jupyter-notebook-registry--delete-process (process)
  "Stop local PROCESS without letting its sentinel continue ownership state."
  (when (processp process)
    (set-process-sentinel process #'ignore)
    (when (process-live-p process) (delete-process process))))

(defun emacs-jupyter-notebook-registry--kill-buffer-owners ()
  "Cancel only local registry activity for a dying source buffer."
  (dolist (owner (copy-sequence emacs-jupyter-notebook-registry--owners))
    (emacs-jupyter-notebook-registry-owner-cancel owner))
  (setq emacs-jupyter-notebook-registry--owners nil))

(defun emacs-jupyter-notebook-registry--register-owner (owner)
  "Arrange for OWNER to be cancelled if its source buffer is killed."
  (let ((buffer (emacs-jupyter-notebook-registry-owner-buffer owner)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless emacs-jupyter-notebook-registry--owners
          (add-hook 'kill-buffer-hook
                    #'emacs-jupyter-notebook-registry--kill-buffer-owners nil t))
        (cl-pushnew owner emacs-jupyter-notebook-registry--owners :test #'eq)))))

(cl-defun emacs-jupyter-notebook-registry-owner-create (&key buffer guard)
  "Create callback ownership for registry operations.
BUFFER defaults to the current buffer.  GUARD is a no-argument predicate
checked before callbacks, normally closing over the caller's context and
generation token.  Killing BUFFER cancels local workers and timers only."
  (let* ((buffer (or buffer (current-buffer)))
         (owner (emacs-jupyter-notebook-registry--make-owner
                 :token (gensym "ejn-registry-owner-") :buffer buffer
                 :guard guard :operations nil :cancelled nil)))
    (emacs-jupyter-notebook-registry--register-owner owner)
    owner))

(defun emacs-jupyter-notebook-registry-owner-live-p (owner)
  "Return non-nil when OWNER may receive local continuation callbacks."
  (and (emacs-jupyter-notebook-registry-owner-p owner)
       (not (emacs-jupyter-notebook-registry-owner-cancelled owner))
       (let ((buffer (emacs-jupyter-notebook-registry-owner-buffer owner)))
         (or (null buffer) (buffer-live-p buffer)))
       (let ((guard (emacs-jupyter-notebook-registry-owner-guard owner)))
         (or (null guard)
             (condition-case nil (funcall guard) (error nil))))))

(defun emacs-jupyter-notebook-registry-owner-cancel (owner)
  "Cancel OWNER's local workers/timers without any durable mutation."
  (when (and (emacs-jupyter-notebook-registry-owner-p owner)
             (not (emacs-jupyter-notebook-registry-owner-cancelled owner)))
    (setf (emacs-jupyter-notebook-registry-owner-cancelled owner) t)
    (dolist (operation
             (copy-sequence (emacs-jupyter-notebook-registry-owner-operations owner)))
      (emacs-jupyter-notebook-registry-operation-cancel operation))
    (let ((buffer (emacs-jupyter-notebook-registry-owner-buffer owner)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq emacs-jupyter-notebook-registry--owners
                (delq owner emacs-jupyter-notebook-registry--owners)))))))

(defun emacs-jupyter-notebook-registry-operation-live-p (operation)
  "Return non-nil when OPERATION still owns local continuation state."
  (and (emacs-jupyter-notebook-registry--operation-active-p operation)
       (emacs-jupyter-notebook-registry-owner-live-p
        (emacs-jupyter-notebook-registry-operation-owner operation))))

(defun emacs-jupyter-notebook-registry--operation-active-p (operation)
  "Return non-nil when OPERATION still needs local resource disposal.
Unlike `emacs-jupyter-notebook-registry-operation-live-p', this deliberately
ignores a stale guard: stale completions must still reap their child process
and timers, but must never run a continuation."
  (and (emacs-jupyter-notebook-registry-operation-p operation)
       (not (emacs-jupyter-notebook-registry-operation-finished operation))
       (not (emacs-jupyter-notebook-registry-operation-cancelled operation))))

(defun emacs-jupyter-notebook-registry--detach-operation (operation)
  "Remove terminal OPERATION from its owner."
  (let ((owner (emacs-jupyter-notebook-registry-operation-owner operation)))
    (setf (emacs-jupyter-notebook-registry-owner-operations owner)
          (delq operation
                (emacs-jupyter-notebook-registry-owner-operations owner)))
    (when (null (emacs-jupyter-notebook-registry-owner-operations owner))
      (let ((buffer (emacs-jupyter-notebook-registry-owner-buffer owner)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq emacs-jupyter-notebook-registry--owners
                  (delq owner emacs-jupyter-notebook-registry--owners))))))))

(defun emacs-jupyter-notebook-registry--finish (operation callback value)
  "Finish OPERATION and invoke CALLBACK with VALUE only while still guarded."
  (unless (emacs-jupyter-notebook-registry-operation-finished operation)
    (let ((live (emacs-jupyter-notebook-registry-operation-live-p operation)))
      (setf (emacs-jupyter-notebook-registry-operation-finished operation) t
            (emacs-jupyter-notebook-registry-operation-result operation) value)
      (emacs-jupyter-notebook-registry--cancel-timer
       (emacs-jupyter-notebook-registry-operation-deadline-timer operation))
      (emacs-jupyter-notebook-registry--cancel-timer
       (emacs-jupyter-notebook-registry-operation-attempt-timer operation))
      (emacs-jupyter-notebook-registry--cancel-timer
       (emacs-jupyter-notebook-registry-operation-retry-timer operation))
      (emacs-jupyter-notebook-registry--delete-process
       (emacs-jupyter-notebook-registry-operation-process operation))
      (emacs-jupyter-notebook-registry--delete-process
       (emacs-jupyter-notebook-registry-operation-stderr-process operation))
      (setf (emacs-jupyter-notebook-registry-operation-process operation) nil
            (emacs-jupyter-notebook-registry-operation-stderr-process operation) nil)
      (emacs-jupyter-notebook-registry--detach-operation operation)
      (when (and live callback)
        (let ((owner (emacs-jupyter-notebook-registry-operation-owner operation)))
          (condition-case err
              (let ((buffer (emacs-jupyter-notebook-registry-owner-buffer owner)))
                (if (buffer-live-p buffer)
                    (with-current-buffer buffer (funcall callback value operation))
                  (funcall callback value operation)))
            (error
             ;; Do not leave the owning connection state permanently in
             ;; progress when a success continuation itself fails.
             (let ((failure
                    (emacs-jupyter-notebook-registry-operation-failure operation)))
               (if (and failure (not (eq callback failure)))
                   (condition-case failure-error
                       (let ((failure-value
                              (emacs-jupyter-notebook-registry--failure
                               'callback "callback"
                               (format "registry continuation failed: %s"
                                       (error-message-string err)))))
                         (if (buffer-live-p
                              (emacs-jupyter-notebook-registry-owner-buffer owner))
                             (with-current-buffer
                                 (emacs-jupyter-notebook-registry-owner-buffer owner)
                               (funcall failure failure-value operation))
                           (funcall failure failure-value operation)))
                     (error
                      (message "emacs-jupyter-notebook registry failure callback failed: %s"
                               (error-message-string failure-error))))
                 (message "emacs-jupyter-notebook registry callback failed: %s"
                          (error-message-string err)))))))))))

(defun emacs-jupyter-notebook-registry-operation-cancel (operation)
  "Cancel OPERATION locally, retaining every possible durable worker outcome."
  (when (and (emacs-jupyter-notebook-registry-operation-p operation)
             (not (emacs-jupyter-notebook-registry-operation-finished operation)))
    (setf (emacs-jupyter-notebook-registry-operation-cancelled operation) t)
    (emacs-jupyter-notebook-registry--finish operation nil (list :kind 'cancelled))))

(defun emacs-jupyter-notebook-registry--failure
    (kind code message &optional durability-uncertain diagnostics)
  "Build fixed-shape worker failure data."
  (list :kind kind :code code :message message
        :durability-uncertain (and durability-uncertain t)
        :diagnostics diagnostics))

(defun emacs-jupyter-notebook-registry--mutation-p (operation)
  "Return non-nil when OPERATION may change durable registry state."
  (member (cdr (assoc "op"
                      (emacs-jupyter-notebook-registry-operation-request
                       operation)))
          '("create-if-absent"
            "replace-if-revision"
            "upsert-if-current"
            "remove-if-revision"
            "prune-if-revision")))

(defun emacs-jupyter-notebook-registry--bounded-binary-append
    (current text limit)
  "Return (COMBINED . OVERFLOW) for binary CURRENT, TEXT, and byte LIMIT.
COMBINED never exceeds LIMIT bytes, and an oversized TEXT is sliced before it
is concatenated.  Registry worker pipes use binary coding, so a multibyte
chunk indicates a violated process-boundary invariant and is treated as an
overflow without copying it."
  (let* ((current (or current ""))
         (current-bytes (string-bytes current))
         (remaining (max 0 (- limit current-bytes))))
    (if (multibyte-string-p text)
        (cons current t)
      (let* ((text-length (length text))
             (take (min remaining text-length))
             (combined
              (cond
               ((zerop take) current)
               ((= take text-length) (concat current text))
               (t (concat current (substring text 0 take))))))
        (cons combined (< take text-length))))))

(defun emacs-jupyter-notebook-registry--append-stdout (operation text)
  "Append bounded binary TEXT to OPERATION stdout, returning overflow state."
  (let* ((result
          (emacs-jupyter-notebook-registry--bounded-binary-append
           (emacs-jupyter-notebook-registry-operation-stdout operation)
           text (emacs-jupyter-notebook-registry--output-limit))))
    (setf (emacs-jupyter-notebook-registry-operation-stdout operation)
          (car result))
    (cdr result)))

(defun emacs-jupyter-notebook-registry--append-stderr (operation text)
  "Append bounded binary TEXT to OPERATION stderr."
  (let ((result
         (emacs-jupyter-notebook-registry--bounded-binary-append
          (emacs-jupyter-notebook-registry-operation-stderr operation)
          text (emacs-jupyter-notebook-registry--stderr-limit))))
    (setf (emacs-jupyter-notebook-registry-operation-stderr operation)
          (car result))))

(defun emacs-jupyter-notebook-registry--diagnostics (operation)
  "Return printable, bounded worker stderr for OPERATION."
  (let ((raw (or (emacs-jupyter-notebook-registry-operation-stderr operation) "")))
    (replace-regexp-in-string
     "[^[:print:]\n\t]" "?"
     (condition-case nil
         (decode-coding-string raw 'utf-8)
       (error (decode-coding-string raw 'binary))) t t)))

(defconst emacs-jupyter-notebook-registry--absent
  (make-symbol "emacs-jupyter-notebook-registry-absent"))

(defun emacs-jupyter-notebook-registry--json-get (object key)
  "Return string KEY from JSON object OBJECT or an internal absent marker."
  (if (hash-table-p object)
      (gethash key object emacs-jupyter-notebook-registry--absent)
    emacs-jupyter-notebook-registry--absent))

(defun emacs-jupyter-notebook-registry--json-object-p (value)
  "Return non-nil for JSON object VALUE."
  (hash-table-p value))

(defun emacs-jupyter-notebook-registry--json-keys (object)
  "Return sorted string keys from JSON OBJECT."
  (and (hash-table-p object) (sort (hash-table-keys object) #'string<)))

(defun emacs-jupyter-notebook-registry--assert-safe-json-structure (text)
  "Reject hostile JSON structure before the general JSON parser sees TEXT.
The worker protocol permits at most 128 object fields, 256 array items, and
21 levels after its response envelope is included.  This scanner is linear,
tracks decoded object keys in hash tables, and leaves value decoding to
`json-read' only after these resource bounds have been established."
  (let ((length (length text)))
    (cl-labels
        ((space-p (character)
           (memq character '(?\s ?\t ?\r ?\n)))
         (skip-space (index)
           (while (and (< index length) (space-p (aref text index)))
             (setq index (1+ index)))
           index)
         (hex-value (character)
           (cond ((and (>= character ?0) (<= character ?9)) (- character ?0))
                 ((and (>= character ?a) (<= character ?f)) (+ 10 (- character ?a)))
                 ((and (>= character ?A) (<= character ?F)) (+ 10 (- character ?A)))
                 (t nil)))
         (string-at (index decode)
           (unless (and (< index length) (= (aref text index) ?\"))
             (error "registry response expected a JSON string"))
           (setq index (1+ index))
           (let (characters)
             (while (and (< index length) (/= (aref text index) ?\"))
               (let ((character (aref text index)))
                 (cond
                  ((< character ?\x20) (error "registry response has a control character"))
                  ((/= character ?\\)
                   (when decode (push character characters))
                   (setq index (1+ index)))
                  (t
                   (setq index (1+ index))
                   (unless (< index length) (error "registry response has a short escape"))
                   (setq character (aref text index))
                   (cond
                    ((memq character '(?\" ?\\ ?/))
                     (when decode (push character characters))
                     (setq index (1+ index)))
                    ((memq character '(?b ?f ?n ?r ?t))
                     (when decode
                       (push (cdr (assq character '((?b . ?\b) (?f . ?\f) (?n . ?\n)
                                                    (?r . ?\r) (?t . ?\t)))) characters))
                     (setq index (1+ index)))
                    ((= character ?u)
                     (unless (<= (+ index 5) length) (error "registry response has a short unicode escape"))
                     (let ((code 0))
                       (dotimes (offset 4)
                         (let ((digit (hex-value (aref text (+ index 1 offset)))))
                           (unless digit (error "registry response has an invalid unicode escape"))
                           (setq code (+ (* code 16) digit))))
                       (setq index (+ index 5))
                       (when (and (>= code #xD800) (<= code #xDBFF))
                         (unless (and (<= (+ index 6) length) (= (aref text index) ?\\)
                                      (= (aref text (1+ index)) ?u))
                           (error "registry response has an unpaired surrogate"))
                         (let ((low 0))
                           (dotimes (offset 4)
                             (let ((digit (hex-value (aref text (+ index 2 offset)))))
                               (unless digit (error "registry response has an invalid unicode escape"))
                               (setq low (+ (* low 16) digit))))
                           (unless (and (>= low #xDC00) (<= low #xDFFF))
                             (error "registry response has an unpaired surrogate"))
                           (setq code (+ #x10000 (* (- code #xD800) #x400) (- low #xDC00))
                                 index (+ index 6))))
                       (when (and (>= code #xDC00) (<= code #xDFFF))
                         (error "registry response has an unpaired surrogate"))
                       (when decode (push (decode-char 'ucs code) characters))))
                    (t (error "registry response has an invalid escape")))))))
             (unless (< index length) (error "registry response has an unterminated string"))
             (cons (and decode (apply #'string (nreverse characters))) (1+ index))))
         (value-at (index depth)
           (setq index (skip-space index))
           (when (> depth emacs-jupyter-notebook-registry--hard-json-depth)
             (error "registry response nesting is too deep"))
           (unless (< index length) (error "registry response ends mid-value"))
           (let ((character (aref text index)))
             (cond
              ((= character ?{) (object-at index depth))
              ((= character ?\[) (array-at index depth))
              ((= character ?\") (cdr (string-at index nil)))
              ((memq character '(?t ?f ?n))
              (let ((word (cond ((= character ?t) "true")
                                ((= character ?f) "false")
                                (t "null"))))
                (unless (and (<= (+ index (length word)) length)
                             (string= word (substring text index (+ index (length word)))))
                  (error "registry response has an invalid literal"))
                (+ index (length word))))
              (t
              (let ((start index))
                (while (and (< index length)
                            (memq (aref text index) '(?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9 ?+ ?- ?. ?e ?E)))
                  (setq index (1+ index)))
                (unless (> index start) (error "registry response has an invalid value"))
                (when (> (- index start) emacs-jupyter-notebook-registry--hard-json-number-chars)
                  (error "registry response number is too large"))
                index)))))
         (object-at (index depth)
           (setq index (skip-space (1+ index)))
           (let ((seen (make-hash-table :test #'equal)) (count 0) done)
             (if (and (< index length) (= (aref text index) ?}))
                 (setq index (1+ index))
               (while (not done)
                 (let ((key (car (string-at index t)))
                       (after-key (cdr (string-at index t))))
                   (when (gethash key seen) (error "registry response has duplicate object keys"))
                   (puthash key t seen)
                   (setq count (1+ count))
                   (when (> count emacs-jupyter-notebook-registry--hard-json-object-items)
                     (error "registry response object has too many fields"))
                   (setq index (skip-space after-key))
                   (unless (and (< index length) (= (aref text index) ?:))
                     (error "registry response object lacks a colon"))
                   (setq index (value-at (1+ index) (1+ depth)))
                   (setq index (skip-space index)))
                 (cond ((and (< index length) (= (aref text index) ?}))
                        (setq index (1+ index) done t))
                       ((and (< index length) (= (aref text index) ?,)) (setq index (skip-space (1+ index))))
                       (t (error "registry response object is malformed")))))
             index))
         (array-at (index depth)
           (setq index (skip-space (1+ index)))
           (let ((count 0) done)
             (if (and (< index length) (= (aref text index) ?\]))
                 (setq index (1+ index))
               (while (not done)
                 (setq count (1+ count))
                 (when (> count emacs-jupyter-notebook-registry--hard-json-array-items)
                   (error "registry response array has too many items"))
                 (setq index (skip-space (value-at index (1+ depth))))
                 (cond ((and (< index length) (= (aref text index) ?\]))
                        (setq index (1+ index) done t))
                       ((and (< index length) (= (aref text index) ?,)) (setq index (skip-space (1+ index))))
                       (t (error "registry response array is malformed")))))
             index)))
      (let ((end (skip-space (value-at 0 1))))
        (unless (= end length) (error "trailing content after registry response"))))))

(defun emacs-jupyter-notebook-registry--json-depth-valid-p (text)
  "Return non-nil when TEXT meets the worker response structure limits."
  (condition-case nil
      (progn (emacs-jupyter-notebook-registry--assert-safe-json-structure text) t)
    (error nil)))

(defun emacs-jupyter-notebook-registry--assert-one-response-object (text)
  "Reject trailing data and duplicate top-level keys in worker response TEXT.
`json-parse-string' correctly rejects trailing content, but its hash-table
representation intentionally coalesces duplicate keys.  Parse the bounded
top-level envelope once as a string-keyed alist first so a hostile replacement
worker cannot smuggle a second `ok', `v', or `result' field past schema checks."
  (emacs-jupyter-notebook-registry--assert-safe-json-structure text)
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((json-object-type 'alist)
          (json-key-type 'string)
          (json-array-type 'vector)
          (json-false :false)
          (json-null nil))
      (let ((envelope (json-read)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp) (error "trailing content after registry response"))
        (unless (and (listp envelope)
                     (cl-every (lambda (pair)
                                 (and (consp pair) (stringp (car pair))))
                               envelope))
          (error "registry response root is not an object"))
        envelope))))

(defun emacs-jupyter-notebook-registry--parse-response (raw)
  "Strictly parse binary one-response worker RAW."
  (condition-case err
      (let* ((_ (when (string-match-p "[^\0-\177]" raw)
                  (error "response is not canonical ASCII JSON")))
             (text (decode-coding-string raw 'utf-8))
             (_ (emacs-jupyter-notebook-registry--assert-one-response-object text))
             (value (json-parse-string
                     text
                     :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object :false))
             (version (emacs-jupyter-notebook-registry--json-get value "v"))
             (ok (emacs-jupyter-notebook-registry--json-get value "ok"))
             (keys (emacs-jupyter-notebook-registry--json-keys value)))
        (unless (and (integerp version)
                     (= version emacs-jupyter-notebook-registry--protocol-version)
                     (memq ok '(t :false)))
          (error "response version or ok flag is invalid"))
        (if (eq ok t)
            (let ((result (emacs-jupyter-notebook-registry--json-get value "result")))
              (unless (and (equal keys '("ok" "result" "v"))
                           (emacs-jupyter-notebook-registry--json-object-p result))
                (error "success response schema is invalid"))
              (list :ok t :result result))
          (let* ((error-object (emacs-jupyter-notebook-registry--json-get value "error"))
                 (code (and (emacs-jupyter-notebook-registry--json-object-p error-object)
                            (emacs-jupyter-notebook-registry--json-get error-object "code")))
                 (message (and (emacs-jupyter-notebook-registry--json-object-p error-object)
                               (emacs-jupyter-notebook-registry--json-get error-object "message")))
                 (committed (emacs-jupyter-notebook-registry--json-get value "committed")))
            (unless (and (member keys '(("error" "ok" "v")
                                        ("committed" "error" "ok" "v")))
                         (equal (emacs-jupyter-notebook-registry--json-keys error-object)
                                '("code" "message"))
                         (stringp code) (stringp message)
                         (or (eq committed emacs-jupyter-notebook-registry--absent)
                             (memq committed '(t :false))))
              (error "failure response schema is invalid"))
            (list :ok nil :code code :message message :committed (eq committed t)))))
    (error
     (list :ok nil :code "protocol"
           :message "registry worker returned malformed JSON"
           :detail (error-message-string err)))))

(defun emacs-jupyter-notebook-registry--plist-p (value)
  "Return non-nil for a proper keyword plist VALUE."
  (and (listp value) (zerop (% (length value) 2))
       (cl-loop for tail on value by #'cddr always (keywordp (car tail)))))

(defun emacs-jupyter-notebook-registry--value-to-wire (value)
  "Encode current registry plist VALUE without evaluating deserialized data."
  (cond
   ((null value) nil)
   ((eq value t) t)
   ((stringp value) value)
   ((integerp value) value)
   ((symbolp value)
   (list (cons "@ejn" "symbol") (cons "name" (symbol-name value))))
   ((emacs-jupyter-notebook-registry--plist-p value)
    (let ((fields
           (cl-loop for (key field) on value by #'cddr
                    collect (vector (substring (symbol-name key) 1)
                                    (emacs-jupyter-notebook-registry--value-to-wire field)))))
      (list (cons "@ejn" "plist") (cons "fields" (vconcat fields)))))
   ((listp value)
    (list (cons "@ejn" "list")
          (cons "items" (vconcat (mapcar #'emacs-jupyter-notebook-registry--value-to-wire value)))))
   ((vectorp value)
    (list (cons "@ejn" "vector")
          (cons "items" (vconcat (mapcar #'emacs-jupyter-notebook-registry--value-to-wire value)))))
   (t (error "Registry value has unsupported type: %S" (type-of value)))))

(defun emacs-jupyter-notebook-registry--wire-fields-to-plist (fields)
  "Decode tagged JSON FIELDS into a keyword plist without reader evaluation."
  (unless (and (listp fields)
               (cl-every
                (lambda (pair)
                  (and (listp pair) (= (length pair) 2) (stringp (nth 0 pair))
                       (not (string-empty-p (nth 0 pair)))
                       (not (string-match-p "[:[:space:]\\0]" (nth 0 pair)))))
                fields))
    (error "registry plist fields are invalid"))
  (let (result seen)
    (dolist (pair fields (nreverse result))
      (when (member (nth 0 pair) seen)
        (error "registry plist field is duplicated"))
      (push (nth 0 pair) seen)
      (let ((keyword (intern-soft (concat ":" (nth 0 pair)))))
        (unless (keywordp keyword)
          (error "registry plist field is unknown"))
        (push keyword result))
      (push (emacs-jupyter-notebook-registry--wire-to-value (nth 1 pair)) result))))

(defun emacs-jupyter-notebook-registry--wire-to-value (value)
  "Decode tagged JSON VALUE without evaluating symbols or forms."
  (cond
   ((or (null value) (eq value t) (stringp value) (integerp value)) value)
   ((emacs-jupyter-notebook-registry--json-object-p value)
    (let ((tag (emacs-jupyter-notebook-registry--json-get value "@ejn"))
          (items (emacs-jupyter-notebook-registry--json-get value "items"))
          (fields (emacs-jupyter-notebook-registry--json-get value "fields"))
          (name (emacs-jupyter-notebook-registry--json-get value "name"))
          (keys (emacs-jupyter-notebook-registry--json-keys value)))
      (cond
       ((and (equal tag "symbol") (equal keys '("@ejn" "name"))
             (stringp name) (not (string-empty-p name))
             (not (string-match-p "[[:space:]\\0]" name)))
        (or (intern-soft name)
            (error "registry symbol is unknown")))
       ((and (equal tag "plist") (equal keys '("@ejn" "fields")))
        (emacs-jupyter-notebook-registry--wire-fields-to-plist fields))
       ((and (member tag '("list" "vector")) (equal keys '("@ejn" "items"))
             (listp items))
        (let ((decoded (mapcar #'emacs-jupyter-notebook-registry--wire-to-value items)))
          (if (equal tag "vector") (vconcat decoded) decoded)))
       (t (error "registry tagged value is invalid")))))
   (t (error "registry JSON value is invalid"))))

(defun emacs-jupyter-notebook-registry--entry-to-wire (entry)
  "Encode in-memory ENTRY to worker `{key,data}' object.
`:registry-revision' is worker metadata and never appears in user data."
  (unless (emacs-jupyter-notebook-registry--plist-p entry)
    (error "Registry entry must be a keyword plist"))
  (let ((key (emacs-jupyter-notebook-registry--entry-key entry)) fields)
    (unless (stringp key) (error "Registry entry identity key must be a string"))
    (cl-loop for (field value) on entry by #'cddr
             unless (eq field :registry-revision)
             do (push (vector (substring (symbol-name field) 1)
                              (emacs-jupyter-notebook-registry--value-to-wire value)) fields))
    (list (cons "key" key)
          (cons "data" (list (cons "@ejn" "entry")
                              (cons "fields" (vconcat (nreverse fields))))))))

(defun emacs-jupyter-notebook-registry--entry-from-wire (wire)
  "Decode worker WIRE entry and attach its opaque `:registry-revision'."
  (let ((key (emacs-jupyter-notebook-registry--json-get wire "key"))
        (revision (emacs-jupyter-notebook-registry--json-get wire "revision"))
        (data (emacs-jupyter-notebook-registry--json-get wire "data")))
    (unless (and (emacs-jupyter-notebook-registry--json-object-p wire)
                 (equal (emacs-jupyter-notebook-registry--json-keys wire) '("data" "key" "revision"))
                 (stringp key) (stringp revision)
                 (string-match-p "\\`[[:xdigit:]]\\{32\\}\\'" revision)
                 (emacs-jupyter-notebook-registry--json-object-p data)
                 (equal (emacs-jupyter-notebook-registry--json-keys data) '("@ejn" "fields"))
                 (equal (emacs-jupyter-notebook-registry--json-get data "@ejn") "entry"))
      (error "registry worker entry schema is invalid"))
    (let ((entry (emacs-jupyter-notebook-registry--wire-fields-to-plist
                  (emacs-jupyter-notebook-registry--json-get data "fields"))))
      (unless (equal key (emacs-jupyter-notebook-registry--entry-key entry))
        (error "registry worker entry key does not match data"))
      (plist-put entry :registry-revision revision))))

(defun emacs-jupyter-notebook-registry--request-json (request)
  "Serialize bounded REQUEST to worker JSON."
  ;; `json-serialize' requires symbol alist keys while worker protocol keys
  ;; are deliberately strings.  `json-encode' preserves those keys without
  ;; consulting the Lisp reader or touching the filesystem.
  (let ((json (json-encode request)))
    (unless (<= (string-bytes json) emacs-jupyter-notebook-registry--hard-request-bytes)
      (error "Registry worker request exceeds its byte limit"))
    json))

(defun emacs-jupyter-notebook-registry--remaining (operation)
  "Return seconds remaining before OPERATION's total deadline."
  (- (emacs-jupyter-notebook-registry-operation-deadline operation) (float-time)))

(defun emacs-jupyter-notebook-registry--retry-delay (operation)
  "Return timer delay for OPERATION's next known-uncommitted busy retry."
  (let* ((initial emacs-jupyter-notebook-registry-worker-retry-initial-delay)
         (maximum emacs-jupyter-notebook-registry-worker-retry-max-delay)
         (initial (min emacs-jupyter-notebook-registry--hard-deadline
                       (max emacs-jupyter-notebook-registry--hard-min-retry-delay
                            (if (emacs-jupyter-notebook-registry--finite-number-p initial)
                                initial 0.05))))
         (maximum (min emacs-jupyter-notebook-registry--hard-deadline
                       (max emacs-jupyter-notebook-registry--hard-min-retry-delay
                            (if (emacs-jupyter-notebook-registry--finite-number-p maximum)
                                maximum 1.0))))
         ;; A maximum below the initial delay would make the configuration
         ;; internally contradictory; retain the invariant max >= initial.
         (maximum (max maximum initial))
         (count (emacs-jupyter-notebook-registry-operation-retry-count operation)))
    (min maximum
         (if (and (integerp count) (>= count 0) (< count 32))
             (* initial (expt 2 count))
           maximum))))

(defun emacs-jupyter-notebook-registry--deadline-expired (operation)
  "Finish OPERATION when its complete busy-retry deadline expires."
  (when (emacs-jupyter-notebook-registry--operation-active-p operation)
    (emacs-jupyter-notebook-registry--finish
     operation (emacs-jupyter-notebook-registry-operation-failure operation)
     (if (and (emacs-jupyter-notebook-registry-operation-process operation)
              (emacs-jupyter-notebook-registry--mutation-p operation))
         (emacs-jupyter-notebook-registry--failure
          'durability-uncertain "deadline"
          "registry mutation deadline elapsed after the request was sent" t
          (emacs-jupyter-notebook-registry--diagnostics operation))
       (emacs-jupyter-notebook-registry--failure
        'deadline "deadline" "registry worker operation deadline elapsed")))))

(defun emacs-jupyter-notebook-registry--schedule-retry (operation)
  "Retry busy OPERATION from a timer under its original deadline."
  (let ((remaining (emacs-jupyter-notebook-registry--remaining operation)))
    (if (<= remaining emacs-jupyter-notebook-registry--retry-safety-margin)
      (emacs-jupyter-notebook-registry--deadline-expired operation)
      (let ((delay (min (emacs-jupyter-notebook-registry--retry-delay operation)
                        (- remaining
                           emacs-jupyter-notebook-registry--retry-safety-margin))))
        (setf (emacs-jupyter-notebook-registry-operation-retry-count operation)
              (1+ (emacs-jupyter-notebook-registry-operation-retry-count operation)))
        (setf (emacs-jupyter-notebook-registry-operation-retry-timer operation)
              (run-at-time delay nil
                           (lambda ()
                             (when (emacs-jupyter-notebook-registry--operation-active-p operation)
                               (setf (emacs-jupyter-notebook-registry-operation-retry-timer operation) nil)
                               (if (emacs-jupyter-notebook-registry-operation-live-p operation)
                                   (emacs-jupyter-notebook-registry--start-attempt operation)
                                 (emacs-jupyter-notebook-registry--finish
                                  operation nil (list :kind 'stale)))))))))))

(defun emacs-jupyter-notebook-registry--attempt-timeout (operation process)
  "Fail conservatively after PROCESS was sent a request but did not respond."
  (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
             (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
    ;; A filter can append the final frame in the same event turn that made the
    ;; timeout ready.  Consume already-delivered bytes once more before
    ;; classifying an otherwise trustworthy mutation reply as lost.
    (unless (emacs-jupyter-notebook-registry--consume-framed-response
             operation process)
      (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
                 (eq process
                     (emacs-jupyter-notebook-registry-operation-process operation)))
      (if (emacs-jupyter-notebook-registry--mutation-p operation)
          ;; A mutation worker might have committed just before stdout was lost.
          (emacs-jupyter-notebook-registry--finish
           operation (emacs-jupyter-notebook-registry-operation-failure operation)
           (emacs-jupyter-notebook-registry--failure
            'durability-uncertain "worker-timeout"
            "registry worker timed out after receiving a mutation" t
            (emacs-jupyter-notebook-registry--diagnostics operation)))
        ;; Reads cannot commit.  Kill the wedged child and retry by timer under
        ;; the original finite logical deadline.
        (let ((stderr
               (emacs-jupyter-notebook-registry-operation-stderr-process operation)))
          (setf (emacs-jupyter-notebook-registry-operation-process operation) nil
                (emacs-jupyter-notebook-registry-operation-stderr-process operation) nil
                (emacs-jupyter-notebook-registry-operation-attempt-timer operation) nil)
          (emacs-jupyter-notebook-registry--delete-process process)
          (emacs-jupyter-notebook-registry--delete-process stderr)
            (emacs-jupyter-notebook-registry--schedule-retry operation)))))))

(defun emacs-jupyter-notebook-registry--handle-response (operation response)
  "Handle parsed worker RESPONSE for OPERATION."
  (if (not (emacs-jupyter-notebook-registry-operation-live-p operation))
      (emacs-jupyter-notebook-registry--finish operation nil (list :kind 'stale))
    (if (plist-get response :ok)
        (emacs-jupyter-notebook-registry--finish
         operation (emacs-jupyter-notebook-registry-operation-success operation)
         (plist-get response :result))
      (let ((code (plist-get response :code)) (message (plist-get response :message)))
        (cond
       ((equal code "busy")
        (emacs-jupyter-notebook-registry--schedule-retry operation))
       ((plist-get response :committed)
        (emacs-jupyter-notebook-registry--finish
         operation (emacs-jupyter-notebook-registry-operation-failure operation)
         (emacs-jupyter-notebook-registry--failure
          'durability-uncertain code message t
          (emacs-jupyter-notebook-registry--diagnostics operation))))
       ((equal code "conflict")
        (emacs-jupyter-notebook-registry--finish
         operation (emacs-jupyter-notebook-registry-operation-failure operation)
         (emacs-jupyter-notebook-registry--failure 'conflict code message)))
       ((equal code "protocol")
        (emacs-jupyter-notebook-registry--finish
         operation (emacs-jupyter-notebook-registry-operation-failure operation)
         (if (emacs-jupyter-notebook-registry--mutation-p operation)
             (emacs-jupyter-notebook-registry--failure
              'durability-uncertain code
              "registry mutation returned an untrustworthy response" t
              (emacs-jupyter-notebook-registry--diagnostics operation))
           (emacs-jupyter-notebook-registry--failure
            'protocol code message nil
            (emacs-jupyter-notebook-registry--diagnostics operation)))))
         (t
          (emacs-jupyter-notebook-registry--finish
           operation (emacs-jupyter-notebook-registry-operation-failure operation)
           (emacs-jupyter-notebook-registry--failure
            'worker code message nil (emacs-jupyter-notebook-registry--diagnostics operation)))))))))

(defun emacs-jupyter-notebook-registry--stdout-filter (operation process text)
  "Collect bounded worker stdout TEXT and consume one framed response."
  (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
             (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
    (if (emacs-jupyter-notebook-registry--append-stdout operation text)
        (emacs-jupyter-notebook-registry--finish
         operation (emacs-jupyter-notebook-registry-operation-failure operation)
         (if (emacs-jupyter-notebook-registry--mutation-p operation)
             (emacs-jupyter-notebook-registry--failure
              'durability-uncertain "output-overflow"
              "registry mutation response exceeded its stdout limit" t
              (emacs-jupyter-notebook-registry--diagnostics operation))
           (emacs-jupyter-notebook-registry--failure
            'protocol "output-overflow" "registry worker exceeded its stdout limit" nil
            (emacs-jupyter-notebook-registry--diagnostics operation))))
      (emacs-jupyter-notebook-registry--consume-framed-response
       operation process))))

(defun emacs-jupyter-notebook-registry--consume-framed-response
    (operation process)
  "Consume OPERATION's newline-framed worker response when complete.
Return non-nil only when PROCESS still owned OPERATION and a frame was
consumed.  The validated response, not delivery of a later exit sentinel, is
the transaction completion boundary."
  (let ((stdout (or (emacs-jupyter-notebook-registry-operation-stdout operation)
                    "")))
    (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
               (eq process
                   (emacs-jupyter-notebook-registry-operation-process operation))
               (string-suffix-p "\n" stdout))
      (let ((stderr
             (emacs-jupyter-notebook-registry-operation-stderr-process operation)))
        (emacs-jupyter-notebook-registry--cancel-timer
         (emacs-jupyter-notebook-registry-operation-attempt-timer operation))
        (setf (emacs-jupyter-notebook-registry-operation-attempt-timer operation) nil
              (emacs-jupyter-notebook-registry-operation-process operation) nil
              (emacs-jupyter-notebook-registry-operation-stderr-process operation) nil)
        (emacs-jupyter-notebook-registry--delete-process process)
        (emacs-jupyter-notebook-registry--delete-process stderr)
        (emacs-jupyter-notebook-registry--handle-response
         operation (emacs-jupyter-notebook-registry--parse-response stdout))
        t))))

(defun emacs-jupyter-notebook-registry--stderr-filter (operation process text)
  "Collect bounded stderr TEXT; stderr never controls transaction semantics."
  (when (and (emacs-jupyter-notebook-registry-operation-live-p operation)
             (eq process (emacs-jupyter-notebook-registry-operation-stderr-process operation)))
    (emacs-jupyter-notebook-registry--append-stderr operation text)))

(defun emacs-jupyter-notebook-registry--sentinel (operation process _event)
  "Finish OPERATION from PROCESS exit with strict response and ambiguity rules."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook-registry--operation-active-p operation)
             (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
    (let ((status (process-status process)) (exit-status (process-exit-status process))
          (stdout (or (emacs-jupyter-notebook-registry-operation-stdout operation) ""))
          (stderr
           (emacs-jupyter-notebook-registry-operation-stderr-process operation)))
      (emacs-jupyter-notebook-registry--cancel-timer
       (emacs-jupyter-notebook-registry-operation-attempt-timer operation))
      (setf (emacs-jupyter-notebook-registry-operation-attempt-timer operation) nil
            (emacs-jupyter-notebook-registry-operation-process operation) nil
            (emacs-jupyter-notebook-registry-operation-stderr-process operation) nil)
      (emacs-jupyter-notebook-registry--delete-process process)
      ;; A BUSY response keeps the logical operation alive for a retry; retire
      ;; this attempt's separate stderr pipe now so retries cannot accumulate
      ;; closed process objects.
      (emacs-jupyter-notebook-registry--delete-process stderr)
      (if (and (eq status 'exit) (= exit-status 0))
          (emacs-jupyter-notebook-registry--handle-response
           operation (emacs-jupyter-notebook-registry--parse-response stdout))
        (if (emacs-jupyter-notebook-registry--mutation-p operation)
            (emacs-jupyter-notebook-registry--finish
             operation (emacs-jupyter-notebook-registry-operation-failure operation)
             (emacs-jupyter-notebook-registry--failure
              'durability-uncertain "worker-exit"
              "registry mutation worker exited without a trustworthy response" t
              (emacs-jupyter-notebook-registry--diagnostics operation)))
          (emacs-jupyter-notebook-registry--schedule-retry operation))))))

(defun emacs-jupyter-notebook-registry--start-attempt (operation)
  "Start one nonblocking child worker attempt for OPERATION."
(when (emacs-jupyter-notebook-registry--operation-active-p operation)
  (if (not (emacs-jupyter-notebook-registry-operation-live-p operation))
      (emacs-jupyter-notebook-registry--finish operation nil (list :kind 'stale))
    (let ((remaining (emacs-jupyter-notebook-registry--remaining operation)))
      (if (<= remaining 0)
          (emacs-jupyter-notebook-registry--deadline-expired operation)
        (condition-case err
            (let* ((argv (emacs-jupyter-notebook-registry-worker-resolve-argv))
                   (payload (emacs-jupyter-notebook-registry--request-json
                             (emacs-jupyter-notebook-registry-operation-request operation)))
                   process stderr
                   (setup-complete nil)
                   (pending-terminal nil))
              (setf (emacs-jupyter-notebook-registry-operation-stdout operation) ""
                    (emacs-jupyter-notebook-registry-operation-stderr operation) "")
              (setq stderr
                    (make-pipe-process
                     :name "emacs-jupyter-notebook-registry-stderr" :buffer nil
                     :coding 'binary :noquery t
                     :filter (lambda (pipe text)
                               (emacs-jupyter-notebook-registry--stderr-filter operation pipe text))))
              ;; Attach the pipe immediately.  If worker creation signals,
              ;; `--finish' must still be able to reap this lexical process.
              (setf (emacs-jupyter-notebook-registry-operation-stderr-process operation)
                    stderr)
              (setq process
                    (make-process
                     :name "emacs-jupyter-notebook-registry-worker" :buffer nil
                     :command argv :coding 'binary :connection-type 'pipe :noquery t
                     :stderr stderr
                     :filter (lambda (worker text)
                               (emacs-jupyter-notebook-registry--stdout-filter operation worker text))
                     :sentinel
                     (lambda (worker event)
                       (if setup-complete
                           (emacs-jupyter-notebook-registry--sentinel
                            operation worker event)
                         (when (and (memq (process-status worker) '(exit signal))
                                    (not pending-terminal))
                           (setq pending-terminal (cons worker event)))))))
              (setf (emacs-jupyter-notebook-registry-operation-process operation) process
                    (emacs-jupyter-notebook-registry-operation-stderr-process operation) stderr)
              ;; The deadline must exist before a possibly blocked pipe write.
              (let ((timer (run-at-time
                            (min remaining (emacs-jupyter-notebook-registry--request-timeout))
                            nil #'emacs-jupyter-notebook-registry--attempt-timeout
                            operation process)))
                (if (and (emacs-jupyter-notebook-registry--operation-active-p operation)
                         (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
                    (setf (emacs-jupyter-notebook-registry-operation-attempt-timer operation) timer)
                  (emacs-jupyter-notebook-registry--cancel-timer timer)))
              (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
                         (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
                (emacs-jupyter-notebook-process-send process payload)
                (when (and (emacs-jupyter-notebook-registry--operation-active-p operation)
                           (eq process (emacs-jupyter-notebook-registry-operation-process operation)))
                  (process-send-eof process)))
              (setq setup-complete t)
              (cond
               (pending-terminal
                (emacs-jupyter-notebook-registry--sentinel
                 operation (car pending-terminal) (cdr pending-terminal)))
               ((and (emacs-jupyter-notebook-registry--operation-active-p operation)
                     (eq process
                         (emacs-jupyter-notebook-registry-operation-process operation))
                     (not (process-live-p process)))
                (emacs-jupyter-notebook-registry--sentinel
                 operation process "terminated during registry worker startup"))))
          (error
           (let ((sent-p
                  (emacs-jupyter-notebook-registry-operation-process operation)))
             (emacs-jupyter-notebook-registry--finish
              operation (emacs-jupyter-notebook-registry-operation-failure operation)
              (if (and sent-p
                       (emacs-jupyter-notebook-registry--mutation-p operation))
                  (emacs-jupyter-notebook-registry--failure
                   'durability-uncertain "local-send"
                   (format "registry mutation request delivery failed: %s"
                           (error-message-string err))
                   t (emacs-jupyter-notebook-registry--diagnostics operation))
                (emacs-jupyter-notebook-registry--failure
                 'local-start "local-start"
                 (format "could not start registry worker: %s"
                         (error-message-string err)))))))))))))

(cl-defun emacs-jupyter-notebook-registry-request-async
    (request success failure &key owner deadline)
  "Run worker REQUEST asynchronously and return an operation handle.
SUCCESS receives `(RESULT OPERATION)'.  FAILURE receives `(FAILURE OPERATION)'
where FAILURE has `:kind', `:code', `:message', `:durability-uncertain', and
bounded `:diagnostics'.  OWNER is a handle from
`emacs-jupyter-notebook-registry-owner-create'; otherwise a current-buffer
owner is created.  DEADLINE accepts either relative seconds or an absolute
`float-time' deadline.  BUSY retries use timers under that one finite budget.

Timeout, early exit, and worker `committed: true' replies are
durability-uncertain and never trigger a compensating mutation or retry."
  (let* ((owner (or owner (emacs-jupyter-notebook-registry-owner-create)))
         (deadline-at (emacs-jupyter-notebook-registry--deadline-at deadline))
         (seconds (max 0 (- deadline-at (float-time))))
         (operation (emacs-jupyter-notebook-registry--make-operation
                     :token (gensym "ejn-registry-operation-") :owner owner
                     :request request :success success :failure failure
                     :deadline deadline-at :retry-count 0)))
    (unless (emacs-jupyter-notebook-registry-owner-live-p owner)
      (error "Registry owner is no longer live"))
    (emacs-jupyter-notebook-registry--register-owner owner)
    (push operation (emacs-jupyter-notebook-registry-owner-operations owner))
    (condition-case err
        (progn
          (setf (emacs-jupyter-notebook-registry-operation-deadline-timer operation)
                (run-at-time seconds nil #'emacs-jupyter-notebook-registry--deadline-expired operation))
          ;; A timer mock may settle the operation during allocation.  Do not
          ;; start a child after that terminal local outcome.
          (when (emacs-jupyter-notebook-registry--operation-active-p operation)
            (emacs-jupyter-notebook-registry--start-attempt operation))
          operation)
      (error
       (emacs-jupyter-notebook-registry--finish
        operation (emacs-jupyter-notebook-registry-operation-failure operation)
        (emacs-jupyter-notebook-registry--failure
         'local-start "deadline-timer"
         (format "could not allocate registry deadline timer: %s" (error-message-string err))))
       operation))))

(defun emacs-jupyter-notebook-registry--request (operation &rest fields)
  "Build protocol-v1 OPERATION request from JSON FIELDS."
  (let ((path (expand-file-name emacs-jupyter-notebook-registry-file
                                user-emacs-directory)))
    (when (file-remote-p path)
      (error "Registry path must be local; remote file handlers are unsupported"))
    (append (list (cons "v" emacs-jupyter-notebook-registry--protocol-version)
                  (cons "op" operation)
                  (cons "path" path))
            fields)))

(cl-defun emacs-jupyter-notebook-registry-read-async
    (success failure &key owner deadline local-file)
  "Read registry entries asynchronously.
SUCCESS receives `(ENTRIES OPERATION)' where every entry has
`:registry-revision'.  With LOCAL-FILE, the worker also resolves symlink and
hardlink aliases and SUCCESS receives the matching entry as a third argument.
FAILURE receives `(FAILURE OPERATION)'."
  (emacs-jupyter-notebook-registry-request-async
   (if local-file
       (emacs-jupyter-notebook-registry--request
        "read-for-local-file" (cons "local_file" local-file))
     (emacs-jupyter-notebook-registry--request "read"))
   (lambda (result operation)
     (condition-case err
         (let ((entries (emacs-jupyter-notebook-registry--json-get result "entries"))
               (generation (emacs-jupyter-notebook-registry--json-get result "generation"))
               (matching (and local-file
                              (emacs-jupyter-notebook-registry--json-get
                               result "matching_entry"))))
           (unless (and (equal (emacs-jupyter-notebook-registry--json-keys result)
                               (if local-file
                                   '("entries" "generation" "matching_entry")
                                 '("entries" "generation")))
                        (integerp generation) (listp entries))
             (error "registry read schema is invalid"))
           (let ((decoded
                  (mapcar #'emacs-jupyter-notebook-registry--entry-from-wire entries)))
             (if local-file
                 (funcall success decoded operation
                          (and matching
                               (emacs-jupyter-notebook-registry--entry-from-wire matching)))
               (funcall success decoded operation))))
       (error
        (funcall failure
                 (emacs-jupyter-notebook-registry--failure
                  'protocol "protocol" "registry worker returned invalid entries" nil
                  (error-message-string err)) operation))))
   failure :owner owner :deadline deadline))

(defun emacs-jupyter-notebook-registry--mutation-success
    (success failure result operation)
  "Decode mutation RESULT to an entry, or route invalid response to FAILURE."
  (condition-case err
      (let ((entry (emacs-jupyter-notebook-registry--json-get result "entry"))
            (generation (emacs-jupyter-notebook-registry--json-get result "generation")))
        (unless (and (equal (emacs-jupyter-notebook-registry--json-keys result)
                            '("entry" "generation"))
                     (integerp generation)
                     (emacs-jupyter-notebook-registry--json-object-p entry))
          (error "mutation result lacks entry"))
        (funcall success (emacs-jupyter-notebook-registry--entry-from-wire entry) operation))
    (error
     (funcall failure
              (emacs-jupyter-notebook-registry--failure
               'durability-uncertain "protocol"
               "registry mutation may have committed but returned an invalid entry" t
               (format "%s%s"
                       (error-message-string err)
                       (let ((diagnostics
                              (emacs-jupyter-notebook-registry--diagnostics operation)))
                         (if (string-empty-p diagnostics)
                             ""
                           (format "; stderr: %s" diagnostics)))))
              operation))))

(cl-defun emacs-jupyter-notebook-registry-create-async
    (entry success failure &key owner deadline)
  "Create ENTRY only if its identity key is absent.
SUCCESS receives `(PERSISTED-ENTRY OPERATION)' with a worker revision."
  (emacs-jupyter-notebook-registry-request-async
   (emacs-jupyter-notebook-registry--request
    "create-if-absent" (cons "entry" (emacs-jupyter-notebook-registry--entry-to-wire entry)))
   (lambda (result operation)
     (emacs-jupyter-notebook-registry--mutation-success success failure result operation))
   failure :owner owner :deadline deadline))

(cl-defun emacs-jupyter-notebook-registry-replace-async
    (entry expected-revision success failure &key owner deadline)
  "CAS replace ENTRY only at EXPECTED-REVISION.
SUCCESS receives `(PERSISTED-ENTRY OPERATION)' with a new worker revision."
  (unless (stringp expected-revision) (error "Registry replacement needs exact revision"))
  (emacs-jupyter-notebook-registry-request-async
   (emacs-jupyter-notebook-registry--request
    "replace-if-revision" (cons "entry" (emacs-jupyter-notebook-registry--entry-to-wire entry))
    (cons "expected_revision" expected-revision))
   (lambda (result operation)
     (emacs-jupyter-notebook-registry--mutation-success success failure result operation))
   failure :owner owner :deadline deadline))

(cl-defun emacs-jupyter-notebook-registry-remove-async
    (key expected-revision success failure &key owner deadline)
  "CAS remove KEY only at EXPECTED-REVISION.
SUCCESS receives `(KEY OPERATION)'.  Conflicts never retry against new data."
  (unless (and (stringp key) (stringp expected-revision))
    (error "Registry removal needs string key and exact revision"))
  (emacs-jupyter-notebook-registry-request-async
   (emacs-jupyter-notebook-registry--request
    "remove-if-revision" (cons "key" key) (cons "expected_revision" expected-revision))
   (lambda (result operation)
     (let ((removed (emacs-jupyter-notebook-registry--json-get result "removed"))
           (generation (emacs-jupyter-notebook-registry--json-get result "generation")))
       (if (and (equal (emacs-jupyter-notebook-registry--json-keys result)
                       '("generation" "removed"))
                (integerp generation) (equal removed key))
           (funcall success key operation)
         (funcall failure
                  (emacs-jupyter-notebook-registry--failure
                   'durability-uncertain "protocol"
                   "registry removal may have committed but returned an invalid result" t
                   (emacs-jupyter-notebook-registry--diagnostics operation))
                  operation))))
   failure :owner owner :deadline deadline))

(cl-defun emacs-jupyter-notebook-registry-prune-async
    (entries success failure &key owner deadline)
  "Remove ENTRIES only at their attached exact worker revisions.
SUCCESS receives `(REMOVED-KEYS RETAINED-KEYS OPERATION)'."
  (let ((targets
         (mapcar
          (lambda (entry)
            (let ((revision (plist-get entry :registry-revision)))
              (unless (stringp revision)
                (error "Prune target lacks exact registry revision"))
              (list (cons "key" (emacs-jupyter-notebook-registry--entry-key entry))
                    (cons "expected_revision" revision))))
          entries)))
    (unless targets (error "Prune requires at least one target"))
    (emacs-jupyter-notebook-registry-request-async
     (emacs-jupyter-notebook-registry--request "prune-if-revision"
                                                (cons "targets" targets))
     (lambda (result operation)
       (let ((removed (emacs-jupyter-notebook-registry--json-get result "removed"))
             (retained (emacs-jupyter-notebook-registry--json-get result "retained"))
             (generation (emacs-jupyter-notebook-registry--json-get result "generation")))
         (if (and (equal (emacs-jupyter-notebook-registry--json-keys result)
                         '("generation" "removed" "retained"))
                  (integerp generation) (listp removed) (listp retained)
                  (cl-every #'stringp removed) (cl-every #'stringp retained))
             (funcall success removed retained operation)
           (funcall failure
                    (emacs-jupyter-notebook-registry--failure
                     'durability-uncertain "protocol"
                     "registry prune may have committed but returned an invalid result" t
                     (emacs-jupyter-notebook-registry--diagnostics operation))
                    operation))))
     failure :owner owner :deadline deadline)))

(provide 'emacs-jupyter-notebook-registry)

;;; emacs-jupyter-notebook-registry.el ends here
