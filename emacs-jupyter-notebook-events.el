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

(defvar emacs-jupyter-notebook--kernel-status nil)
(defvar emacs-jupyter-notebook--evaluation-timer nil)
(defvar emacs-jupyter-notebook--evaluation-request nil)

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
               (equal request-id
                      (plist-get emacs-jupyter-notebook--evaluation-request
                                 :request-id)))))))

(defun emacs-jupyter-notebook-events--entry-live-p (context)
  "Return non-nil when CONTEXT's presentation entry has not been retired."
  (ejn-panel-entry-live-p (plist-get context :entry-handle)))

(defun emacs-jupyter-notebook-events--current-request (context)
  "Return CONTEXT's source buffer current request, without mutating it."
  (let ((buffer (plist-get context :buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer emacs-jupyter-notebook--evaluation-request))))

(defun emacs-jupyter-notebook-events--error-text (event)
  "Return display text for normalized error EVENT."
  (let ((traceback (plist-get event :traceback)))
    (if (and (listp traceback) traceback)
        (string-join traceback "\n")
      (format "%s: %s" (or (plist-get event :ename) "Error")
              (or (plist-get event :evalue) "")))))

(defun emacs-jupyter-notebook-events--reply-status (event)
  "Return the panel status symbol encoded by execute-reply EVENT."
  (if (equal (plist-get event :status) "error") 'error 'ok))

(defun emacs-jupyter-notebook-events-reduce (context event)
  "Reduce normalized EVENT with CONTEXT to declarative EJN actions.

CONTEXT contains `:buffer', `:entry-handle', optional `:request-id', and the
request-local `:had-result' flag.  This function performs no prompting,
replying, panel mutation, timer cancellation, or transport I/O.  Late and
retired presentation events reduce to `:ignore', while status and matching
request bookkeeping remain meaningful after a panel clear.

The normalized schema is backend-neutral: stream has `:text' and `:name';
clear has `:wait'; result/display/update-display have `:data'; error has
`:traceback'/`:ename'/`:evalue'; execute-reply has `:status',
`:execution-count', and optional `:watch-text'; status has
`:execution-state'; input-request has `:prompt' and `:password'; and
truncation has optional `:text'."
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
       ;; EI1R preserves the legacy adapter's MIME plist (`:data') intact.
       ;; EI4 owns the one helper-v1 envelope -> plist translation, including
       ;; nested data/metadata/transient fields; reducers never invent another
       ;; wire shape here.
       (if (not (and live current))
           '((:action ignore))
         (unless (and (plist-member event :data) (plist-get event :data)
                      (listp (plist-get event :data)))
           (error "Malformed %s event :data" type))
         (list (list :action type :data (plist-get event :data) :result-seen t))))
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
              (snapshot (and live (ejn-panel-entry-snapshot handle)))
              (cell-key (plist-get handle :cell-key))
              (current-request (emacs-jupyter-notebook-events--current-request context))
              (same-cell (and (not current)
                              (plist-get current-request :cell-key)
                              (equal (plist-get current-request :cell-key) cell-key))))
         (append (when current '((:action settle-request)))
                 (when (and snapshot (eq (plist-get snapshot :status) 'running)
                            (not same-cell))
                   (let ((watch (plist-get event :watch-text))
                         (status (emacs-jupyter-notebook-events--reply-status event)))
                     (append
                      (when (and (stringp watch) (not (string-empty-p watch)))
                        (list (list :action 'append :text watch :result-seen t)))
                      (when (and (not (plist-get context :had-result))
                                 (not (and (stringp watch)
                                           (not (string-empty-p watch))))
                                 (eq status 'error))
                        (list (list :action 'append
                                    :text (format "%s: %s"
                                                  (or (plist-get event :ename) "Error")
                                                  (or (plist-get event :evalue) ""))
                                    :face 'emacs-jupyter-notebook-result-error-face
                                    :result-seen t)))
                      (list (list :action 'finish :status status
                                  :execution-count (plist-get event :execution-count)
                                  :cell-key cell-key))))))))
      ('status
       (let ((state (plist-get event :execution-state)))
         (unless (stringp state)
           (error "Malformed status event :execution-state"))
         (list (list :action 'status :state state
                     :settle-idle (and (equal state "idle") current)))))
      ('input-request
       (if current
           (list (list :action 'input-request
                       :prompt (or (plist-get event :prompt) "")
                       :password (and (plist-get event :password) t)))
         '((:action ignore)))))))

(defun emacs-jupyter-notebook-events--render-display (context data mode)
  "Apply normalized MIME DATA for CONTEXT using result/display MODE semantics."
  (let ((handle (plist-get context :entry-handle))
        (buffer (plist-get context :buffer)))
    (when (ejn-panel-entry-live-p handle)
      (emacs-jupyter-notebook--maybe-stash-pickle buffer handle data)
      (let ((rendered (emacs-jupyter-notebook--render-mime-result data)))
        (cond
         ((null rendered)
          (if (eq mode 'update-display)
              (ejn-panel-replace-text handle "[unsupported output format]")
            (ejn-panel-append-text handle "[unsupported output format]")))
         ((get-text-property 0 'display rendered)
          (funcall (if (eq mode 'update-display)
                       #'ejn-panel-update-image #'ejn-panel-set-image)
                   handle (get-text-property 0 'display rendered)))
         ((memq mode '(result update-display))
          (ejn-panel-replace-text handle (ansi-color-apply rendered)))
         (t
          (ejn-panel-append-text handle (ansi-color-apply rendered))))))))

(defun emacs-jupyter-notebook-events--schedule-input (context prompt password)
  "Schedule, rather than perform, the minibuffer input requested by EVENT.
The timer rechecks request identity before prompt/reply so a retired source
buffer or superseded execution cannot receive an input reply."
  (let ((thunk
         (lambda ()
           (when (emacs-jupyter-notebook-events--request-current-p context)
             (let ((value (condition-case nil
                              (if password (read-passwd prompt) (read-string prompt))
                            (quit ""))))
               (unwind-protect
                   (when-let ((reply (plist-get context :input-reply)))
                     (funcall reply value))
                 (when password (clear-string value))))))))
    (run-at-time 0 nil thunk)))

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
        context (plist-get action :data) (plist-get action :action)))
      ('settle-request
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (timerp emacs-jupyter-notebook--evaluation-timer)
             (cancel-timer emacs-jupyter-notebook--evaluation-timer))
           (setq emacs-jupyter-notebook--evaluation-timer nil
                 emacs-jupyter-notebook--evaluation-request nil))))
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
           (when (plist-get action :settle-idle)
             (when (timerp emacs-jupyter-notebook--evaluation-timer)
               (cancel-timer emacs-jupyter-notebook--evaluation-timer))
             (setq emacs-jupyter-notebook--evaluation-timer nil))
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
      (let ((actions (emacs-jupyter-notebook-events-reduce context event)))
        (dolist (action actions)
          (emacs-jupyter-notebook-events--apply context action)
          (when (plist-get action :result-seen)
            (when-let ((setter (plist-get context :set-had-result)))
              (funcall setter t))))
        actions)
    (error
     (message "emacs-jupyter-notebook event reducer failed for %S: %s"
              (plist-get event :type) (error-message-string err))
     nil)))

(provide 'emacs-jupyter-notebook-events)

;;; emacs-jupyter-notebook-events.el ends here
