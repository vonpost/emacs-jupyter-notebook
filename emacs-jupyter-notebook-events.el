;;; emacs-jupyter-notebook-events.el --- Normalized notebook event reducer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Backends translate their transport messages into the small event schema in
;; this file.  `emacs-jupyter-notebook-events-reduce' is deliberately free of
;; Jupyter objects and returns declarative actions; the dispatcher applies
;; those actions in the source buffer which owns the request.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-ui)

(defvar emacs-jupyter-notebook--kernel-status nil)
(declare-function emacs-jupyter-notebook--execution-current-p
                  "emacs-jupyter-notebook" (id))
(declare-function emacs-jupyter-notebook--execution-input-current-p
                  "emacs-jupyter-notebook" (id))
(declare-function emacs-jupyter-notebook--execution-record
                  "emacs-jupyter-notebook" (id))
(declare-function emacs-jupyter-notebook--execution-note-event
                  "emacs-jupyter-notebook" (context event))

(defconst emacs-jupyter-notebook-events--types
  '(stream clear result display update-display error execute-reply status
           input-request truncation)
  "Normalized event types understood by the reducer.")

(defun emacs-jupyter-notebook-events--request-current-p (context)
  "Return non-nil when CONTEXT still names the source buffer's request."
  (let ((buffer (plist-get context :buffer))
        (request-id (plist-get context :request-id)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (or (null request-id)
               (emacs-jupyter-notebook--execution-current-p request-id))))))

(defun emacs-jupyter-notebook-events--execution-event-admitted-p (context event)
  "Return non-nil when EVENT may mutate the request named by CONTEXT.

Lifecycle events without a request id are transport-wide and remain admitted.
Per-execution events require the active ledger record, its captured panel
generation, and the execute request id admitted by the helper.  A terminal
event can arrive while `backend-execute' is still returning that id; stage
only its terminal evidence until the core has validated admission."
  (let ((buffer (plist-get context :buffer))
        (request-id (plist-get context :request-id)))
    (or (null request-id)
        (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (let* ((record (emacs-jupyter-notebook--execution-record request-id))
                      (backend-id (plist-get context :backend-request-id))
                      (generation (plist-get context :panel-generation))
                      (type (plist-get event :type)))
                 (and record
                      (emacs-jupyter-notebook--execution-current-p request-id)
                      (memq (plist-get record :state) '(dispatched cancelling))
                      (or (not (eq type 'input-request))
                          (emacs-jupyter-notebook--execution-input-current-p
                           request-id))
                      (equal generation (plist-get record :generation))
                      (cond
                       ((and backend-id
                             (plist-get record :backend-request-id)
                             (equal backend-id
                                    (plist-get record :backend-request-id)))
                        t)
                       ;; Pre-admission terminal evidence is retained by the
                       ;; core but never reaches panel/status reduction first.
                       ((and backend-id
                             (null (plist-get record :backend-request-id))
                             (eq (plist-get record :state) 'dispatched)
                             (memq type '(execute-reply status)))
                        (emacs-jupyter-notebook--execution-note-event context event)
                        nil)
                       (t nil)))))))))

(defun emacs-jupyter-notebook-events--entry-live-p (context)
  "Return non-nil when CONTEXT's presentation entry has not been retired."
  (ejn-panel-entry-live-p (plist-get context :entry-handle)))

(defun emacs-jupyter-notebook-events--error-text (event)
  "Return display text for normalized error EVENT."
  (let ((traceback (plist-get event :traceback)))
    (if (and (listp traceback) traceback)
        (string-join traceback "\n")
      (format "%s: %s" (or (plist-get event :ename) "Error")
              (or (plist-get event :evalue) "")))))

(defun emacs-jupyter-notebook-events--reply-status (event)
  "Return the panel status symbol encoded by execute-reply EVENT."
  (if (equal (plist-get event :status) "ok") 'ok 'error))

(defun emacs-jupyter-notebook-events-reduce (context event)
  "Reduce normalized EVENT with CONTEXT to declarative EJN actions.

CONTEXT contains `:buffer', `:entry-handle', optional `:request-id', and the
request-local `:had-result' flag.  This function performs no prompting,
replying, panel mutation, timer cancellation, or transport I/O.  Late and
retired presentation events reduce to `:ignore', while status and matching
request bookkeeping remain meaningful after a panel clear.

The normalized schema is helper-neutral: stream has `:text' and `:name';
clear has `:wait'; result/display/update-display have `:data'; error has
`:traceback'/`:ename'/`:evalue'; execute-reply has `:status',
`:execution-count'; status has `:execution-state'; input-request has `:prompt'
and `:password'; and truncation has optional `:text'."
  (let ((type (plist-get event :type))
        (live (emacs-jupyter-notebook-events--entry-live-p context))
        (current (emacs-jupyter-notebook-events--request-current-p context)))
    (unless (memq type emacs-jupyter-notebook-events--types)
      (error "Unsupported normalized notebook event: %S" type))
    (pcase type
      ('stream
       (if (and live current (stringp (plist-get event :text))
                (not (string-empty-p (plist-get event :text))))
           (list (list :action 'append :text (plist-get event :text)
                       :face (and (equal (plist-get event :name) "stderr")
                                  'emacs-jupyter-notebook-result-error-face)
                       :result-seen t))
         '((:action ignore))))
      ('clear
       (unless (memq (plist-get event :wait) '(nil t))
         (error "Malformed clear event :wait"))
       (if (and live current)
           (list (list :action 'clear :wait (and (plist-get event :wait) t)))
         '((:action ignore))))
      ((or 'result 'display 'update-display)
       ;; EI4 owns the one helper-v1 envelope -> plist translation, including
       ;; nested data/metadata/transient fields; reducers never invent another
       ;; wire shape here.
       (if (not (and live current))
           '((:action ignore))
         (unless (and (plist-member event :data) (plist-get event :data)
                      (listp (plist-get event :data)))
           (error "Malformed %s event :data" type))
         (list (list :action type :data (plist-get event :data)
                     :display-id (plist-get event :display-id)
                     :require-display-id (plist-get event :require-display-id)
                     :metadata (plist-get event :metadata)
                     :transient (plist-get event :transient)
                     :result-seen t))))
      ('error
       (if (and live current)
           (list (list :action 'append
                       :text (emacs-jupyter-notebook-events--error-text event)
                       :face 'emacs-jupyter-notebook-result-error-face
                       :result-seen t))
         '((:action ignore))))
      ('truncation
       (if (and live current)
           (list (list :action 'append
                       :text (or (plist-get event :text) "[output truncated]\n")
                       :face 'emacs-jupyter-notebook-result-error-face
                       :result-seen t))
         '((:action ignore))))
      ('execute-reply
       (let* ((handle (plist-get context :entry-handle))
              (snapshot (and live (ejn-panel-entry-snapshot handle))))
         (when (and current snapshot
                    (memq (plist-get snapshot :status) '(running queued))
                    (not (plist-get context :had-result))
                    (eq (emacs-jupyter-notebook-events--reply-status event) 'error))
           (list (list :action 'append
                       :text (format "%s: %s"
                                     (or (plist-get event :ename) "Error")
                                     (or (plist-get event :evalue) ""))
                       :face 'emacs-jupyter-notebook-result-error-face
                       :result-seen t)))))
      ('status
       (let ((state (plist-get event :execution-state)))
         (unless (stringp state)
           (error "Malformed status event :execution-state"))
         (list (list :action 'status :state state))))
      ('input-request
       (if current
           (list (list :action 'input-request
                       :prompt (or (plist-get event :prompt) "")
                       :password (and (plist-get event :password) t)))
         '((:action ignore)))))))

(defun emacs-jupyter-notebook-events--render-display
    (context data mode &optional display-id require-display-id)
  "Apply normalized MIME DATA for CONTEXT using result/display MODE semantics."
  (let ((handle (plist-get context :entry-handle)))
    ;; HT9 deliberately omits an oversized display id instead of truncating it.
    ;; Such an update has no safe identity and must not fall back to replacing
    ;; the last unrelated image or all text in the entry.
    (when (and (ejn-panel-entry-live-p handle)
               (not (and (eq mode 'update-display)
                         require-display-id
                         (null display-id))))
      (if-let ((array (plist-get data :ejn-published-array)))
          (condition-case nil
              (ejn-panel-set-published-array handle array (eq mode 'update-display))
            (error nil))
        (let ((publication (plist-get data :ejn-published-image))
            (pickle (plist-get data :ejn-published-pickle)))
        (if (or publication pickle)
            (when-let ((effective-handle
                        (condition-case nil
                            (ejn-panel-set-published-bundle
                             handle publication pickle (eq mode 'update-display))
                          (error nil))))
              (when pickle
                (when (and (bound-and-true-p emacs-jupyter-notebook-enable-pickle-viewer)
                           (bound-and-true-p emacs-jupyter-notebook-viewer-auto-open)
                           (fboundp 'emacs-jupyter-notebook-open-figure-pickle-lease))
                  (ejn-panel-schedule-pickle-open
                   effective-handle #'emacs-jupyter-notebook-open-figure-pickle-lease)))
              t))
          (let ((rendered (plist-get data :text/plain)))
            (cond
             ((null rendered)
              (if (eq mode 'update-display)
                  (if display-id
                      (ejn-panel-update-display-text handle "[unsupported output format]" display-id)
                    (ejn-panel-replace-text handle "[unsupported output format]"))
                (if display-id
                    (ejn-panel-set-display-text handle "[unsupported output format]" display-id)
                  (ejn-panel-append-text handle "[unsupported output format]"))))
             ((memq mode '(result update-display))
              (let ((text (ansi-color-apply rendered)))
                (if display-id
                    (ejn-panel-update-display-text handle text display-id)
                  (if (and (eq mode 'result)
                           (cl-find 'array
                                    (plist-get (ejn-panel-entry-snapshot handle) :outputs)
                                    :key #'car))
                      (ejn-panel-append-text handle text)
                    (ejn-panel-replace-text handle text)))))
             (t
              (let ((text (ansi-color-apply rendered)))
                (if display-id
                    (ejn-panel-set-display-text handle text display-id)
                  (ejn-panel-append-text handle text))))))
          ;; Non-publication rendering has no transfer lease to acknowledge.
          t)))))

(defun emacs-jupyter-notebook-events--schedule-input (context prompt password)
  "Read kernel input only when the originating buffer owns the minibuffer."
  (let* ((source (plist-get context :buffer))
         (request-id (plist-get context :request-id))
         (current-p
          (lambda ()
            (or (null request-id)
                (emacs-jupyter-notebook--execution-input-current-p request-id)))))
    (emacs-jupyter-notebook-ui-defer
     source current-p
     (lambda ()
       (let ((value (condition-case nil
                        (if password (read-passwd prompt) (read-string prompt))
                      (quit ""))))
         (unwind-protect
             (when (funcall current-p)
               (when-let ((reply (plist-get context :input-reply)))
                 (funcall reply value)))
           (when password (clear-string value)))))
     nil 'kernel-input)))

(defun emacs-jupyter-notebook-events--apply (context action)
  "Apply one reduced ACTION for CONTEXT in its owner buffer."
  (let ((handle (plist-get context :entry-handle))
        (buffer (plist-get context :buffer)))
    (pcase (plist-get action :action)
      ('ignore nil)
      ('append
       (when (ejn-panel-entry-live-p handle)
         (ejn-panel-append-text handle (ansi-color-apply (plist-get action :text))
                                (plist-get action :face))))
      ('clear (when (ejn-panel-entry-live-p handle)
                (ejn-panel-clear-entry handle (plist-get action :wait))))
      ((or 'result 'display 'update-display)
       (emacs-jupyter-notebook-events--render-display
        context (plist-get action :data) (plist-get action :action)
        (plist-get action :display-id)
        (plist-get action :require-display-id)))
      ('finish
       (when (ejn-panel-entry-live-p handle)
         (ejn-panel-finish-entry handle (plist-get action :status)
                                 (plist-get action :execution-count))
         (when (and (plist-get action :cell-key) (buffer-live-p buffer))
           (with-current-buffer buffer
             (emacs-jupyter-notebook-fringe-set
              (plist-get action :cell-key) (plist-get action :status)
              (plist-get action :execution-count))))))
      ('status
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq emacs-jupyter-notebook--kernel-status
                 (pcase (plist-get action :state) ("busy" 'busy) ("idle" 'idle) (_ nil)))
           (force-mode-line-update t))))
      ('input-request
       ;; Showing the prompt is presentation, but reading and replying happen
       ;; later outside the transport callback and outside this reducer.
       (when (ejn-panel-entry-live-p handle)
         (ejn-panel-append-text handle (plist-get action :prompt)))
       (emacs-jupyter-notebook-events--schedule-input
        context (plist-get action :prompt) (plist-get action :password))))))

(defun emacs-jupyter-notebook-events-dispatch (context event)
  "Reduce and apply normalized EVENT, logging reducer failures visibly.
No event error is swallowed: malformed events, stale shape regressions, and
presentation exceptions produce one bounded `message' diagnostic while the
transport callback itself remains safe."
  (condition-case err
      (if (not (emacs-jupyter-notebook-events--execution-event-admitted-p
                context event))
          '((:action ignore))
        (let ((actions (emacs-jupyter-notebook-events-reduce context event))
              (publication-admitted t))
          (dolist (action actions)
            (let ((applied (emacs-jupyter-notebook-events--apply context action)))
              ;; A publication is not panel-owned until this exact call
              ;; accepts it.  Do not turn an unknown display-id or stale handle
              ;; into successful local admission.
              (when (or (plist-get (plist-get action :data) :ejn-published-image)
                        (plist-get (plist-get action :data) :ejn-published-array)
                        (plist-get (plist-get action :data) :ejn-published-pickle))
                (setq publication-admitted (and publication-admitted applied))))
            (when (plist-get action :result-seen)
              (when-let ((setter (plist-get context :set-had-result)))
                (funcall setter t))))
          (when (and (not (plist-get context :skip-execution-note))
                     (memq (plist-get event :type) '(execute-reply status)))
            (when (buffer-live-p (plist-get context :buffer))
              (with-current-buffer (plist-get context :buffer)
                (emacs-jupyter-notebook--execution-note-event context event))))
          (and publication-admitted actions)))
    (error
     (message "emacs-jupyter-notebook event reducer failed for %S: %s"
              (plist-get event :type) (error-message-string err))
     nil)))

(provide 'emacs-jupyter-notebook-events)

;;; emacs-jupyter-notebook-events.el ends here
