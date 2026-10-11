;;; emacs-jupyter-notebook-variables.el --- Async variable metadata -*- lexical-binding: t; -*-

;;; Commentary:
;; Array shape and dtype appear through Eldoc; an explicit table lists the
;; kernel's public variables.  Queries use the supervised backend and never
;; create a source evaluation, fetch array samples, or modify source text.

;;; Code:

(require 'cl-lib)
(require 'eldoc)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-ui)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook--client)
(defvar emacs-jupyter-notebook--kernel-status)
(defvar emacs-jupyter-notebook--execution-active-id)
(defvar emacs-jupyter-notebook--execution-queue)
(defvar emacs-jupyter-notebook--execution-setup-pending)
(declare-function emacs-jupyter-notebook--async-in-progress-p "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-inspect-at-point "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-inspect-evaluate "emacs-jupyter-notebook" (code title))
(declare-function emacs-jupyter-notebook-inspect "emacs-jupyter-notebook-actions")
(declare-function emacs-jupyter-notebook-actions "emacs-jupyter-notebook-actions")

(defcustom emacs-jupyter-notebook-variable-eldoc t
  "Show Python variable type, shape and dtype at point through Eldoc.
Only simple variable names are queried, and busy kernels are skipped.  Values
are never transferred.  Unknown object types expose type metadata only.
Automatic name detection is skipped in buffers larger than 1,048,576
characters; explicit commands still accept a variable name at their prompt."
  :type 'boolean :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-variable-cache-seconds 5
  "Seconds to reuse variable metadata between kernel executions.
Starting a new source execution invalidates this cache immediately."
  :type 'number :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-variable-list-limit 200
  "Maximum public variables to show in the variable table, at most 200."
  :type 'integer :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-variable-favorites nil
  "Favorite variable names, shown first in the variable table.
The f command changes this option buffer-locally for the current notebook.
Use Customize or directory-local settings for persistent defaults."
  :type '(repeat string) :group 'emacs-jupyter-notebook)
(make-variable-buffer-local 'emacs-jupyter-notebook-variable-favorites)

(defface emacs-jupyter-notebook-variable-changed
  '((t :inherit warning :weight bold))
  "Face for a variable's shape or dtype changed by the latest execution."
  :group 'emacs-jupyter-notebook)

(defvar-local emacs-jupyter-notebook-variables--cache nil)
(defvar-local emacs-jupyter-notebook-variables--generation 0)
(defvar-local emacs-jupyter-notebook-variables--pending nil)
(defvar-local emacs-jupyter-notebook-variables--queued nil)
(defvar-local emacs-jupyter-notebook-variables--timer nil)
(defvar-local emacs-jupyter-notebook-variables--table nil)
(defvar-local emacs-jupyter-notebook-variables--source nil)
(defvar-local emacs-jupyter-notebook-variables--enabled-eldoc nil)
(defvar-local emacs-jupyter-notebook-variables--rows nil)
(defvar-local emacs-jupyter-notebook-variables--stale t)
(defvar-local emacs-jupyter-notebook-variables--truncated nil)
(defvar-local emacs-jupyter-notebook-variables--favorites-only nil)
(defvar-local emacs-jupyter-notebook-variables--refresh-pending nil)
(defvar-local emacs-jupyter-notebook-variables--refresh-retry-timer nil)
(defvar-local emacs-jupyter-notebook-variables--refresh-retries 0)
(defvar-local emacs-jupyter-notebook-variables--view-token nil)
(defvar-local emacs-jupyter-notebook-variables--view-selections nil
  "At most 32 recent variable names and validated numerical selectors.")
(defvar-local emacs-jupyter-notebook-variables--view-recent nil
  "Most recently viewed group of at most four variable names.")

(defconst emacs-jupyter-notebook-variables--name-buffer-max-chars (* 1024 1024)
  "Largest source buffer admitted to automatic variable syntax inspection.")

(defun emacs-jupyter-notebook-variables--name-at-point ()
  "Return a bounded Python identifier at point, excluding attributes and text.
Skip large sources before entering the potentially cold syntax parser.  Scan
at most 129 characters each way before copying or parsing a candidate."
  (when (and (derived-mode-p 'python-mode 'python-ts-mode)
             (<= (buffer-size) emacs-jupyter-notebook-variables--name-buffer-max-chars))
    (let* ((origin (point))
           (beg (save-excursion
                  (skip-syntax-backward "w_" (max (point-min) (- origin 129)))
                  (point)))
           (end (save-excursion
                  (skip-syntax-forward "w_" (min (point-max) (+ origin 129)))
                  (point))))
      (when (<= 1 (- end beg) 128)
        (let ((name (buffer-substring-no-properties beg end)))
          (when (and (<= (string-bytes name) 128)
                     (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\'" name)
                     (not (eq (char-before beg) ?.))
                     (not (eq (char-after end) ?.))
                     (not (nth 8 (syntax-ppss))))
            name))))))

(defun emacs-jupyter-notebook-variables--ready-p ()
  "Return non-nil when a metadata request will not overtake user execution."
  (and (bound-and-true-p emacs-jupyter-notebook-mode)
       (derived-mode-p 'python-mode 'python-ts-mode)
       (bound-and-true-p emacs-jupyter-notebook--client)
       (emacs-jupyter-notebook-backend-session-live-p
        emacs-jupyter-notebook--client)
       (not (eq (bound-and-true-p emacs-jupyter-notebook--kernel-status) 'busy))
       (not (bound-and-true-p emacs-jupyter-notebook--execution-active-id))
       (not (bound-and-true-p emacs-jupyter-notebook--execution-queue))
       (not (bound-and-true-p emacs-jupyter-notebook--execution-setup-pending))
       (not (and (fboundp 'emacs-jupyter-notebook--async-in-progress-p)
                 (emacs-jupyter-notebook--async-in-progress-p)))))

(defun emacs-jupyter-notebook-variables--cancel-pending ()
  "Retire this buffer's local metadata delivery and deadline.
The helper owns its own finite request deadline; cancellation never interrupts
or closes the kernel to dispose a metadata lookup."
  (setq emacs-jupyter-notebook-variables--pending nil)
  (when (timerp emacs-jupyter-notebook-variables--timer)
    (cancel-timer emacs-jupyter-notebook-variables--timer))
  (setq emacs-jupyter-notebook-variables--timer nil))

(defun emacs-jupyter-notebook-variables-invalidate ()
  "Mark metadata stale after execution admission or a client transition.
Retain the last known rows and cache while fencing old asynchronous replies."
  (cl-incf emacs-jupyter-notebook-variables--generation)
  (setq emacs-jupyter-notebook-variables--queued nil
        emacs-jupyter-notebook-variables--view-token nil)
  (emacs-jupyter-notebook-ui-cancel 'variable-view)
  (emacs-jupyter-notebook-variables--cancel-pending)
  (emacs-jupyter-notebook-variables--cancel-refresh-retry)
  (setq emacs-jupyter-notebook-variables--stale t
        emacs-jupyter-notebook-variables--refresh-pending nil)
  (emacs-jupyter-notebook-variables--status))

(defun emacs-jupyter-notebook-variables--cancel-refresh-retry ()
  "Cancel this source's bounded dashboard retry sequence."
  (when (timerp emacs-jupyter-notebook-variables--refresh-retry-timer)
    (cancel-timer emacs-jupyter-notebook-variables--refresh-retry-timer))
  (setq emacs-jupyter-notebook-variables--refresh-retry-timer nil
        emacs-jupyter-notebook-variables--refresh-retries 0))

(defun emacs-jupyter-notebook-variables--availability ()
  "Return a truthful short label for unavailable or stale metadata."
  (cond
   ((and (fboundp 'emacs-jupyter-notebook--async-in-progress-p)
         (emacs-jupyter-notebook--async-in-progress-p)) "reconnecting")
   ((or (not (bound-and-true-p emacs-jupyter-notebook-mode))
        (not (bound-and-true-p emacs-jupyter-notebook--client))
        (not (emacs-jupyter-notebook-backend-session-live-p emacs-jupyter-notebook--client)))
    "disconnected")
   ((not (emacs-jupyter-notebook-variables--ready-p)) "kernel busy")
   (t "awaiting refresh")))

(defun emacs-jupyter-notebook-variables--status (&optional message)
  "Update the table status using MESSAGE without removing retained rows."
  (when (buffer-live-p emacs-jupyter-notebook-variables--table)
    (let ((status (or message
                      (if emacs-jupyter-notebook-variables--stale
                          (concat "Stale metadata — " (emacs-jupyter-notebook-variables--availability))
                        (if emacs-jupyter-notebook-variables--truncated
                            "Live variables (list truncated)" "Live variables")))))
      (with-current-buffer emacs-jupyter-notebook-variables--table
        (setq header-line-format
              (concat status " · g refresh · v view array · f favorite · F favorites · i inspect · a actions"))))))

(defun emacs-jupyter-notebook-variables--cached (name)
  "Return the fresh cached metadata envelope for NAME, if any."
  (let* ((cached (and emacs-jupyter-notebook-variables--cache
                      (gethash name emacs-jupyter-notebook-variables--cache)))
         (seconds emacs-jupyter-notebook-variable-cache-seconds)
         (ttl (if (and (numberp seconds) (> seconds 0) (<= seconds 60))
                  seconds 5)))
    (and cached
         (eq (plist-get cached :client) emacs-jupyter-notebook--client)
         (= (or (plist-get cached :generation) -1)
            emacs-jupyter-notebook-variables--generation)
         (< (- (float-time) (plist-get cached :time)) ttl)
         cached)))

(defun emacs-jupyter-notebook-variables--cache-put (name metadata)
  "Cache METADATA for NAME, including a nil result for missing names."
  (unless (hash-table-p emacs-jupyter-notebook-variables--cache)
    (setq emacs-jupyter-notebook-variables--cache (make-hash-table :test #'equal)))
  (when (>= (hash-table-count emacs-jupyter-notebook-variables--cache) 200)
    (clrhash emacs-jupyter-notebook-variables--cache))
  (puthash name (list :metadata metadata :client emacs-jupyter-notebook--client
                      :generation emacs-jupyter-notebook-variables--generation
                      :time (float-time))
           emacs-jupyter-notebook-variables--cache))

(defun emacs-jupyter-notebook-variables--shape-text (shape)
  "Format SHAPE as a Python tuple; nil means unavailable."
  (cond ((null shape) "—")
        ((= (length shape) 0) "()")
        (t (concat "(" (mapconcat #'number-to-string shape ", ")
                   (if (= (length shape) 1) ",)" ")")))))

(defun emacs-jupyter-notebook-variables--describe (metadata)
  "Return concise type, shape and dtype text for METADATA."
  (when metadata
    (concat (plist-get metadata :name) ": " (plist-get metadata :type)
            (when (plist-get metadata :shape)
              (concat "  shape=" (emacs-jupyter-notebook-variables--shape-text
                                  (plist-get metadata :shape))))
            (when (plist-get metadata :dtype)
              (concat "  dtype=" (plist-get metadata :dtype))))))

(defun emacs-jupyter-notebook-variables--request
    (names callback error-callback &optional context)
  "Request metadata for NAMES, calling CALLBACK with the reply.
ERROR-CALLBACK receives no arguments.  Optional CONTEXT is (POINT TICK NAME)
for automatic lookups, whose replies are discarded if editing moved on."
  (if emacs-jupyter-notebook-variables--pending
      ;; An explicit gesture follows the current bounded lookup.  Do not send
      ;; overlapping silent executions merely because Eldoc got there first.
      (unless context
        (when-let ((old emacs-jupyter-notebook-variables--queued))
          (setq emacs-jupyter-notebook-variables--queued nil)
          (funcall (nth 2 old)))
        (setq emacs-jupyter-notebook-variables--queued
              (list names callback error-callback))
        t)
    (when (emacs-jupyter-notebook-variables--ready-p)
      (let* ((source (current-buffer))
             (client emacs-jupyter-notebook--client)
             (generation emacs-jupyter-notebook-variables--generation)
             (token (list 'variables))
             (limit (if names (length names)
                      (let ((value emacs-jupyter-notebook-variable-list-limit))
                        (if (and (integerp value) (> value 0)) (min value 200) 200)))))
        (setq emacs-jupyter-notebook-variables--pending token)
        (cl-labels
            ((current-p ()
               (and (eq token emacs-jupyter-notebook-variables--pending)
                    (= generation emacs-jupyter-notebook-variables--generation)
                    (eq client emacs-jupyter-notebook--client)
                    (bound-and-true-p emacs-jupyter-notebook-mode)
                    (emacs-jupyter-notebook-backend-session-live-p client)))
             (finish (reply failed)
               (when (buffer-live-p source)
                 (with-current-buffer source
                   (when (current-p)
                     (emacs-jupyter-notebook-variables--cancel-pending)
                     (unwind-protect
                         (when (or (null context)
                                   (and (= (point) (nth 0 context))
                                        (= (buffer-chars-modified-tick) (nth 1 context))
                                        (equal (emacs-jupyter-notebook-variables--name-at-point)
                                               (nth 2 context))))
                           (if failed (funcall error-callback)
                             (funcall callback reply)))
                       (when-let ((queued emacs-jupyter-notebook-variables--queued))
                         (setq emacs-jupyter-notebook-variables--queued nil)
                         (unless (apply #'emacs-jupyter-notebook-variables--request queued)
                           (funcall (nth 2 queued))))))))))
          ;; Defer even the adapter invocation out of Eldoc's synchronous path.
          (condition-case nil
              (setq emacs-jupyter-notebook-variables--timer
                    (run-at-time
                     0 nil
                     (lambda ()
                       (when (buffer-live-p source)
                         (with-current-buffer source
                           (when (current-p)
                             (setq emacs-jupyter-notebook-variables--timer nil)
                             (if (not (emacs-jupyter-notebook-variables--ready-p))
                                 (finish nil t)
                               (condition-case nil
                                   (progn
                                     (setq emacs-jupyter-notebook-variables--timer
                                           (run-at-time 6 nil (lambda () (finish nil t))))
                                     (emacs-jupyter-notebook-backend-aux
                                      client 'variables (list :names names :limit limit)
                                      (lambda (_id reply) (finish reply nil))
                                      (lambda (&rest _) (finish nil t))))
                                 (error (finish nil t))))))))))
            (error (finish nil t))))
        t))))

(defun emacs-jupyter-notebook-variables--retained (name)
  "Return retained metadata for NAME, even when its client is unavailable."
  (or (plist-get (and emacs-jupyter-notebook-variables--cache
                      (gethash name emacs-jupyter-notebook-variables--cache)) :metadata)
      (cl-find name emacs-jupyter-notebook-variables--rows
               :key (lambda (row) (plist-get row :name)) :test #'equal)))

(defun emacs-jupyter-notebook-variables-eldoc (callback &rest _ignored)
  "Asynchronously pass metadata for the variable at point to Eldoc CALLBACK."
  (when emacs-jupyter-notebook-variable-eldoc
    (when-let ((name (emacs-jupyter-notebook-variables--name-at-point)))
      (let ((cached (emacs-jupyter-notebook-variables--cached name)))
        (cond
         ((not (emacs-jupyter-notebook-variables--ready-p))
          (when-let ((metadata (emacs-jupyter-notebook-variables--retained name)))
            (funcall callback
                     (concat (emacs-jupyter-notebook-variables--describe metadata)
                             "  [stale: " (emacs-jupyter-notebook-variables--availability) "]")) t))
         (cached
            (when-let ((text (emacs-jupyter-notebook-variables--describe
                              (plist-get cached :metadata))))
              (funcall callback text) t))
         (t
          (emacs-jupyter-notebook-variables--request
           (vector name)
           (lambda (reply)
             (let ((metadata (car (append (plist-get reply :variables) nil))))
               (emacs-jupyter-notebook-variables--cache-put name metadata)
               (funcall callback (emacs-jupyter-notebook-variables--describe metadata))))
           (lambda () (funcall callback nil))
           (list (point) (buffer-chars-modified-tick) name))))))))

(defun emacs-jupyter-notebook-variables--ensure-ready ()
  "Signal a useful user error when a metadata query cannot be admitted."
  (unless (derived-mode-p 'python-mode 'python-ts-mode)
    (user-error "Variable metadata currently supports Python buffers"))
  (unless (and (bound-and-true-p emacs-jupyter-notebook-mode)
               (bound-and-true-p emacs-jupyter-notebook--client)
               (emacs-jupyter-notebook-backend-session-live-p emacs-jupyter-notebook--client))
    (user-error "Connect this notebook to a Jupyter kernel first"))
  (unless (emacs-jupyter-notebook-variables--ready-p)
    (user-error "Kernel is busy; variable metadata is available when it is idle")))

;;;###autoload
(defun emacs-jupyter-notebook-inspect-variable (&optional name)
  "Show NAME's type, shape and dtype without evaluating a source cell.
Interactively use the simple variable at point, or prompt for a name.  Only
metadata is retrieved; custom objects are never printed or traversed."
  (interactive)
  (setq name (or name (emacs-jupyter-notebook-variables--name-at-point)
                 (read-string "Variable name: ")))
  (unless (and (stringp name) (<= (length name) 128) (<= (string-bytes name) 128)
               (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\'" name))
    (user-error "Use a simple Python variable name"))
  (if (not (emacs-jupyter-notebook-variables--ready-p))
      (if-let ((metadata (emacs-jupyter-notebook-variables--retained name)))
          (message "%s  [stale: %s]" (emacs-jupyter-notebook-variables--describe metadata)
                   (emacs-jupyter-notebook-variables--availability))
        (emacs-jupyter-notebook-variables--ensure-ready))
    (emacs-jupyter-notebook-variables--request
     (vector name)
     (lambda (reply)
       (let ((metadata (car (append (plist-get reply :variables) nil))))
         (emacs-jupyter-notebook-variables--cache-put name metadata)
         (cond
          (metadata (message "%s" (emacs-jupyter-notebook-variables--describe metadata)))
          ((and (equal name (emacs-jupyter-notebook-variables--name-at-point))
                (fboundp 'emacs-jupyter-notebook-inspect-at-point))
           (emacs-jupyter-notebook-inspect-at-point))
          (t (message "%s is not defined in this kernel" name)))))
     (lambda () (message "Variable metadata request failed or timed out")))))

(defvar emacs-jupyter-notebook-variables-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'emacs-jupyter-notebook-variables-refresh)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-variables-inspect-row)
    (define-key map (kbd "i") #'emacs-jupyter-notebook-inspect)
    (define-key map (kbd "a") #'emacs-jupyter-notebook-actions)
    (define-key map (kbd "v") #'emacs-jupyter-notebook-variables-view-row)
    (define-key map (kbd "f") #'emacs-jupyter-notebook-variables-toggle-favorite)
    (define-key map (kbd "F") #'emacs-jupyter-notebook-variables-toggle-favorites-only)
    (define-key map (kbd "q") #'quit-window)
    map))

(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))

(defun emacs-jupyter-notebook-variables--evil-setup ()
  "Keep variable-table commands reachable under Doom and explicit Evil states."
  (evil-set-initial-state 'emacs-jupyter-notebook-variables-mode 'emacs)
  (evil-define-key* '(normal motion) emacs-jupyter-notebook-variables-mode-map
    (kbd "g") #'emacs-jupyter-notebook-variables-refresh
    (kbd "RET") #'emacs-jupyter-notebook-variables-inspect-row
    (kbd "i") #'emacs-jupyter-notebook-inspect
    (kbd "a") #'emacs-jupyter-notebook-actions
    (kbd "v") #'emacs-jupyter-notebook-variables-view-row
    (kbd "f") #'emacs-jupyter-notebook-variables-toggle-favorite
    (kbd "F") #'emacs-jupyter-notebook-variables-toggle-favorites-only
    (kbd "q") #'quit-window))

(with-eval-after-load 'evil
  (emacs-jupyter-notebook-variables--evil-setup))

(define-derived-mode emacs-jupyter-notebook-variables-mode tabulated-list-mode
  "EJN Variables"
  "Kernel variable metadata.  Press g to refresh, RET to inspect, q to close."
  (setq tabulated-list-format [("★" 2 t) ("Name" 24 t) ("Type" 28 t)
                               ("Shape" 24 t) ("Dtype" 16 t)]
        tabulated-list-padding 2
        tabulated-list-sort-key '("★" . t))
  (tabulated-list-init-header))

(defun emacs-jupyter-notebook-variables--render (table reply)
  "Adopt bounded metadata REPLY and render TABLE, highlighting changes."
  (when (buffer-live-p table)
    (let ((previous emacs-jupyter-notebook-variables--rows))
      (setq emacs-jupyter-notebook-variables--cache nil)
      (setq emacs-jupyter-notebook-variables--rows
            (mapcar
             (lambda (metadata)
               (let* ((row (copy-sequence metadata))
                      (name (plist-get row :name))
                      (old (cl-find name previous :test #'equal
                                    :key (lambda (item) (plist-get item :name)))))
                 (dolist (field '(:shape :dtype))
                   (when (and old (not (equal (plist-get old field) (plist-get row field))))
                     (setq row (plist-put row (if (eq field :shape) :shape-changed :dtype-changed) t))))
                 (emacs-jupyter-notebook-variables--cache-put name row)
                 row))
             (append (plist-get reply :variables) nil))
            emacs-jupyter-notebook-variables--stale nil
            emacs-jupyter-notebook-variables--truncated (plist-get reply :truncated))
      (emacs-jupyter-notebook-variables--render-rows)
      (emacs-jupyter-notebook-variables--status))))

(defun emacs-jupyter-notebook-variables--render-rows ()
  "Render retained rows and favorite state into the current source's table."
  (when (buffer-live-p emacs-jupyter-notebook-variables--table)
    (let ((rows emacs-jupyter-notebook-variables--rows)
          (favorites emacs-jupyter-notebook-variable-favorites)
          (only emacs-jupyter-notebook-variables--favorites-only))
      (with-current-buffer emacs-jupyter-notebook-variables--table
        (setq tabulated-list-entries
              (cl-loop for row in rows
                       for name = (plist-get row :name)
                       for favorite = (member name favorites)
                       when (or (not only) favorite)
                       collect
                       (list name
                             (vector (if favorite "★" "") name (plist-get row :type)
                                     (propertize
                                      (emacs-jupyter-notebook-variables--shape-text (plist-get row :shape))
                                      'face (when (plist-get row :shape-changed)
                                              'emacs-jupyter-notebook-variable-changed))
                                     (propertize
                                      (or (plist-get row :dtype) "—")
                                      'face (when (plist-get row :dtype-changed)
                                              'emacs-jupyter-notebook-variable-changed))))))
        (tabulated-list-print t)))))

(defun emacs-jupyter-notebook-variables--refresh-table ()
  "Refresh a live table once without selecting or displaying its window."
  (if (not (emacs-jupyter-notebook-variables--ready-p))
      (progn (setq emacs-jupyter-notebook-variables--stale t)
             (emacs-jupyter-notebook-variables--status))
    (when (and (buffer-live-p emacs-jupyter-notebook-variables--table)
               (not emacs-jupyter-notebook-variables--refresh-pending)
               (not emacs-jupyter-notebook-variables--refresh-retry-timer))
      (let ((table emacs-jupyter-notebook-variables--table))
        (setq emacs-jupyter-notebook-variables--refresh-pending t)
        (emacs-jupyter-notebook-variables--status "Refreshing metadata; showing last known rows")
        (emacs-jupyter-notebook-variables--request
         nil
         (lambda (reply)
           (setq emacs-jupyter-notebook-variables--refresh-pending nil)
           (emacs-jupyter-notebook-variables--render table reply))
         (lambda ()
           (setq emacs-jupyter-notebook-variables--refresh-pending nil
                 emacs-jupyter-notebook-variables--stale t)
           (emacs-jupyter-notebook-variables--status "Stale metadata — refresh failed; g retries")
           (emacs-jupyter-notebook-variables--retry-refresh)))))))

(defun emacs-jupyter-notebook-variables--retry-refresh ()
  "Retry at most twice when a just-retired helper request races dashboard refresh."
  (when (and (< emacs-jupyter-notebook-variables--refresh-retries 2)
             (emacs-jupyter-notebook-variables--ready-p)
             (buffer-live-p emacs-jupyter-notebook-variables--table))
    (let ((source (current-buffer))
          (client emacs-jupyter-notebook--client)
          (generation emacs-jupyter-notebook-variables--generation))
      (cl-incf emacs-jupyter-notebook-variables--refresh-retries)
      (setq emacs-jupyter-notebook-variables--refresh-retry-timer
            (run-at-time
             (* 0.2 emacs-jupyter-notebook-variables--refresh-retries) nil
             (lambda ()
               (when (buffer-live-p source)
                 (with-current-buffer source
                   (when (and (= generation emacs-jupyter-notebook-variables--generation)
                              (eq client emacs-jupyter-notebook--client))
                     (setq emacs-jupyter-notebook-variables--refresh-retry-timer nil)
                     (emacs-jupyter-notebook-variables--refresh-table))))))))))

(defun emacs-jupyter-notebook-variables-execution-finished (&rest _ignored)
  "Refresh the dashboard after user FIFO execution or reconnect becomes idle."
  (when (buffer-live-p emacs-jupyter-notebook-variables--table)
    (emacs-jupyter-notebook-variables--refresh-table)))

;;;###autoload
(defun emacs-jupyter-notebook-list-variables ()
  "Show an asynchronous table of public variables in this notebook's kernel.
The table contains names, actual types, array shapes and dtypes, never values."
  (interactive)
  (unless (derived-mode-p 'python-mode 'python-ts-mode)
    (user-error "Variable metadata currently supports Python buffers"))
  (let* ((source (current-buffer))
         (table (or (and (buffer-live-p emacs-jupyter-notebook-variables--table)
                         emacs-jupyter-notebook-variables--table)
                    (setq emacs-jupyter-notebook-variables--table
                          (generate-new-buffer (format "*EJN Variables: %s*" (buffer-name)))))))
    (with-current-buffer table
      (unless (derived-mode-p 'emacs-jupyter-notebook-variables-mode)
        (emacs-jupyter-notebook-variables-mode))
      (setq emacs-jupyter-notebook-variables--source source))
    (emacs-jupyter-notebook-variables--render-rows)
    (emacs-jupyter-notebook-variables--refresh-table)
    (display-buffer table)))

(defun emacs-jupyter-notebook-variables-refresh ()
  "Refresh this variable table through its live source buffer."
  (interactive)
  (unless (buffer-live-p emacs-jupyter-notebook-variables--source)
    (user-error "The notebook source buffer is no longer open"))
  (with-current-buffer emacs-jupyter-notebook-variables--source
    (emacs-jupyter-notebook-variables--cancel-refresh-retry)
    (emacs-jupyter-notebook-variables--refresh-table)))

(defun emacs-jupyter-notebook-variables-toggle-favorite ()
  "Toggle whether the current variable is a favorite for this notebook."
  (interactive)
  (let ((name (tabulated-list-get-id))
        (source emacs-jupyter-notebook-variables--source))
    (unless name (user-error "No variable on this row"))
    (unless (buffer-live-p source) (user-error "The notebook source buffer is no longer open"))
    (with-current-buffer source
      (if (member name emacs-jupyter-notebook-variable-favorites)
          (setq emacs-jupyter-notebook-variable-favorites
                (delete name (copy-sequence emacs-jupyter-notebook-variable-favorites)))
        (when (>= (length emacs-jupyter-notebook-variable-favorites) 200)
          (user-error "At most 200 favorite variables are retained"))
        (push name emacs-jupyter-notebook-variable-favorites))
      (emacs-jupyter-notebook-variables--render-rows))))

(defun emacs-jupyter-notebook-variables-toggle-favorites-only ()
  "Toggle between all variables and favorite variables in the dashboard."
  (interactive)
  (unless (buffer-live-p emacs-jupyter-notebook-variables--source)
    (user-error "The notebook source buffer is no longer open"))
  (with-current-buffer emacs-jupyter-notebook-variables--source
    (setq emacs-jupyter-notebook-variables--favorites-only
          (not emacs-jupyter-notebook-variables--favorites-only))
    (emacs-jupyter-notebook-variables--render-rows)))

(defun emacs-jupyter-notebook-variables-inspect-row ()
  "Inspect the variable on the current table row."
  (interactive)
  (let ((name (tabulated-list-get-id))
        (source emacs-jupyter-notebook-variables--source))
    (unless name (user-error "No variable on this row"))
    (unless (buffer-live-p source)
      (user-error "The notebook source buffer is no longer open"))
    (with-current-buffer source
      (emacs-jupyter-notebook-inspect-variable name))))

(defun emacs-jupyter-notebook-variables--select-plane (shape)
  "Choose row/column axes and bounded slice indices for SHAPE.
Return (AXES INDICES), with nil index entries for the displayed axes."
  (let* ((dimensions (length shape))
         (row (if (and (= dimensions 3) (<= (elt shape 2) 4)) 0 (- dimensions 2)))
         (column (1+ row))
         (choices (cl-loop for axis below dimensions
                           collect (cons (format "Axis %d — size %d" axis (elt shape axis)) axis))))
    (when (> dimensions 2)
      (setq row (cdr (assoc (completing-read "Display rows (Y): " choices nil t nil nil
                                           (car (nth row choices))) choices)))
      (let ((remaining (cl-remove row choices :key #'cdr)))
        (when (= column row) (setq column (cdar remaining)))
        (setq column (cdr (assoc (completing-read "Display columns (X): " remaining nil t nil nil
                                                (car (rassq column remaining))) remaining)))))
    (let ((indices (make-vector dimensions nil)))
      (dotimes (axis dimensions)
        (unless (memq axis (list row column))
          (let* ((size (elt shape axis))
                 (index (read-number (format "Axis %d index (size %d, 0–%d): " axis size (1- size))
                                     (if (<= size 4) 0 (/ size 2)))))
            (unless (and (integerp index) (>= index 0) (< index size))
              (user-error "Index for axis %d must be an integer from 0 to %d" axis (1- size)))
            (aset indices axis index))))
      (list (vector row column) indices))))

(defun emacs-jupyter-notebook-variables--plane-code (name axes indices)
  "Build a publisher call for validated NAME, AXES and INDICES.
Only the generated literal selectors cross Emacs; numerical samples do not."
  (format "ejn.view_variable(%s, axes=[%s], indices=[%s])\n"
          (json-encode-string name)
          (mapconcat #'number-to-string axes ",")
          (mapconcat (lambda (index) (if (null index) "None" (number-to-string index))) indices ",")))

(defun emacs-jupyter-notebook-variables--array-p (metadata)
  "Return non-nil when METADATA describes a nonempty numerical array."
  (let ((shape (plist-get metadata :shape)))
    (and (<= 2 (length shape) 32)
         (plist-get metadata :dtype)
         (cl-every (lambda (size) (and (integerp size) (> size 0))) shape))))

(defun emacs-jupyter-notebook-variables--valid-selection-p (selection shape)
  "Return non-nil when remembered SELECTION is still in bounds for SHAPE."
  (let ((axes (car selection)) (indices (cadr selection)) (crop (nth 2 selection)))
    (and selection (= (length indices) (length shape))
         (cl-every (lambda (axis) (< axis (length shape))) axes)
         (cl-loop for axis below (length shape)
                  always (or (memq axis (append axes nil))
                             (and (integerp (aref indices axis))
                                  (< (aref indices axis) (elt shape axis)))))
         (or (null crop)
             (cl-loop for axis across axes for bounds across crop
                      always (<= (aref bounds 1) (elt shape axis)))))))

(defun emacs-jupyter-notebook-variables--select-crop (shape)
  "Choose three display axes and explicit bounded ranges for SHAPE."
  (let ((choices (cl-loop for axis below (length shape)
                          collect (cons (format "Axis %d — size %d" axis (elt shape axis)) axis)))
        axes ranges)
    (dolist (label '("Depth (Z)" "Rows (Y)" "Columns (X)"))
      (let* ((axis (cdr (assoc (completing-read (concat label ": ") choices nil t nil nil
                                              (caar choices)) choices)))
             (size (elt shape axis))
             (start (read-number (format "Axis %d crop start (inclusive): " axis) 0))
             (stop (read-number (format "Axis %d crop end (exclusive, size %d): " axis size)
                                (min size (+ start 64)))))
        (unless (and (integerp start) (integerp stop) (<= 0 start) (< start stop)
                     (<= stop size) (<= (- stop start) 16384))
          (user-error "Choose a nonempty in-bounds crop of at most 16384 samples per axis"))
        (push axis axes)
        (push (vector start stop) ranges)
        (setq choices (cl-remove axis choices :key #'cdr))))
    (setq axes (vconcat (nreverse axes)))
    (let ((indices (make-vector (length shape) nil)))
      (dotimes (axis (length shape))
        (unless (memq axis (append axes nil))
          (let ((index (read-number (format "Axis %d index: " axis) 0)))
            (unless (and (integerp index) (<= 0 index) (< index (elt shape axis)))
              (user-error "Index is outside axis %d" axis))
            (aset indices axis index))))
      (list axes indices (vconcat (nreverse ranges))))))

(defun emacs-jupyter-notebook-variables--selection (name metadata &optional reconfigure)
  "Choose or reuse NAME's selector using fresh METADATA.
RECONFIGURE explicitly offers a plane or bounded 3D crop."
  (let* ((shape (plist-get metadata :shape))
         (saved (cdr (assoc name emacs-jupyter-notebook-variables--view-selections))))
    (unless (emacs-jupyter-notebook-variables--array-p metadata)
      (user-error "%s needs a nonempty numerical array with at least two dimensions" name))
    (if (and (not reconfigure)
             (emacs-jupyter-notebook-variables--valid-selection-p saved shape))
        saved
      (let ((selection
             (if (and reconfigure (>= (length shape) 3)
                      (equal (completing-read "View selection: " '("2D plane" "3D crop") nil t nil nil
                                              (if (= (length (car saved)) 3) "3D crop" "2D plane"))
                             "3D crop"))
                 (emacs-jupyter-notebook-variables--select-crop shape)
               (emacs-jupyter-notebook-variables--select-plane shape))))
        (setq emacs-jupyter-notebook-variables--view-selections
              (cons (cons name selection)
                    (cl-remove name emacs-jupyter-notebook-variables--view-selections
                               :key #'car :test #'equal)))
        (when (> (length emacs-jupyter-notebook-variables--view-selections) 32)
          (setcdr (nthcdr 31 emacs-jupyter-notebook-variables--view-selections) nil))
        selection))))

(defun emacs-jupyter-notebook-variables--selection-code (name selection)
  "Return a bounded literal Python dict for NAME's SELECTION."
  (format "{\"name\":%s,\"axes\":[%s],\"indices\":[%s]%s}"
          (json-encode-string name)
          (mapconcat #'number-to-string (car selection) ",")
          (mapconcat (lambda (index) (if (null index) "None" (number-to-string index)))
                     (cadr selection) ",")
          (if (nth 2 selection) (concat ",\"crop\":" (json-encode (nth 2 selection))) "")))

(defun emacs-jupyter-notebook-variables--view-group (names metadata &optional reconfigure)
  "Select and publish NAMES together using fresh METADATA."
  (unless (<= 1 (length names) 4) (user-error "Choose one to four array variables"))
  (let ((client emacs-jupyter-notebook--client)
        (generation emacs-jupyter-notebook-variables--generation)
        selections)
    (dolist (name names)
      (push (cons name (emacs-jupyter-notebook-variables--selection
                       name (cl-find name metadata :key (lambda (item) (plist-get item :name))
                                     :test #'equal) reconfigure)) selections))
    (unless (and (eq client emacs-jupyter-notebook--client)
                 (= generation emacs-jupyter-notebook-variables--generation))
      (user-error "The kernel changed while selecting arrays; view again"))
    (setq selections (nreverse selections)
          emacs-jupyter-notebook-variables--view-recent names)
    (emacs-jupyter-notebook-inspect-evaluate
     (if (and (= (length names) 1) (null (nth 2 (cdar selections))))
         (emacs-jupyter-notebook-variables--plane-code
          (caar selections) (cadar selections) (nth 2 (car selections)))
       (concat "ejn.view_variables(["
               (mapconcat (lambda (selection)
                            (emacs-jupyter-notebook-variables--selection-code
                             (car selection) (cdr selection))) selections ",") "])\n"))
     (concat "View " (mapconcat #'identity names " + ")))))

(defun emacs-jupyter-notebook-variables--view-metadata (name metadata)
  "Select and publish a plane from NAME using bounded METADATA."
  (let ((shape (plist-get metadata :shape))
        (client emacs-jupyter-notebook--client)
        (generation emacs-jupyter-notebook-variables--generation))
    (unless (and shape (<= 2 (length shape)) (<= (length shape) 32))
      (user-error "%s needs an array with at least two dimensions" name))
    (unless (cl-every (lambda (size) (and (integerp size) (> size 0))) shape)
      (user-error "%s has an empty or unavailable array dimension" name))
    (let* ((selection (emacs-jupyter-notebook-variables--selection name metadata))
           (axes (car selection))
           (indices (cadr selection)))
      (unless (and (eq client emacs-jupyter-notebook--client)
                   (= generation emacs-jupyter-notebook-variables--generation))
        (user-error "The kernel changed while selecting the array slice; inspect again"))
      (emacs-jupyter-notebook-inspect-evaluate
       (if (nth 2 selection)
           (concat "ejn.view_variables(["
                   (emacs-jupyter-notebook-variables--selection-code name selection) "])\n")
         (emacs-jupyter-notebook-variables--plane-code name axes indices))
       (format "View %s · axes %d,%d" name (aref axes 0) (aref axes 1))))))

;;;###autoload
(defun emacs-jupyter-notebook-view-variable (&optional name)
  "View a numerical plane of NumPy array or PyTorch tensor NAME locally.
Use the variable at point or choose live arrays.  Remember valid row/column
axes and slice indices between invocations.  Only selected samples leave the
kernel; GPU tensors are sliced before copying to CPU.  Use the unified
`emacs-jupyter-notebook-view' with a double prefix to configure a 3D crop."
  (interactive)
  (emacs-jupyter-notebook-variables--ensure-ready)
  (setq name (or name (emacs-jupyter-notebook-variables--name-at-point)))
  (if (null name)
      (emacs-jupyter-notebook-view-variables)
    (unless (and (stringp name) (<= (string-bytes name) 128)
                 (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\'" name))
      (user-error "Use a simple Python variable name"))
    ;; Always refresh metadata before picking axes: a previous cell may have
    ;; rebound the variable, including to a differently shaped array.
    (let* ((source (current-buffer))
           (selected (window-buffer (selected-window)))
           (origin (if (eq selected emacs-jupyter-notebook-variables--table) selected source))
           (client emacs-jupyter-notebook--client)
           (generation emacs-jupyter-notebook-variables--generation)
           (token (list 'variable-view)))
      (setq emacs-jupyter-notebook-variables--view-token token)
      (emacs-jupyter-notebook-variables--request
       (vector name)
       (lambda (reply)
         (when (eq token emacs-jupyter-notebook-variables--view-token)
           (let ((metadata (car (append (plist-get reply :variables) nil))))
             (unless metadata (user-error "%s is not defined in this kernel" name))
             (emacs-jupyter-notebook-variables--cache-put name metadata)
             (if (> (length (plist-get metadata :shape)) 2)
                 ;; Never enter recursive minibuffer input from a helper drain.
                 ;; Keep the explicit request pending until its source/table is
                 ;; selected and another minibuffer interaction has finished.
                 (emacs-jupyter-notebook-ui-defer
                  source
                  (lambda ()
                    (and (bound-and-true-p emacs-jupyter-notebook-mode)
                         (eq token emacs-jupyter-notebook-variables--view-token)
                         (eq client emacs-jupyter-notebook--client)
                         (= generation emacs-jupyter-notebook-variables--generation)))
                  (lambda () (emacs-jupyter-notebook-variables--view-metadata name metadata))
                  origin 'variable-view)
               (emacs-jupyter-notebook-variables--view-metadata name metadata)))))
       (lambda () (message "Array metadata unavailable; try again when the kernel is idle"))))))

;;;###autoload
(defun emacs-jupyter-notebook-view-variables (&optional reconfigure preferred)
  "Choose up to four live arrays and view their remembered planes together.
With RECONFIGURE, ask again for selectors and offer bounded 3D crops.
PREFERRED, when non-nil, views that array without a chooser if it exists.
All metadata lookup is asynchronous; no source cell is evaluated."
  (interactive "P")
  (emacs-jupyter-notebook-variables--ensure-ready)
  (let* ((source (current-buffer))
         (selected (window-buffer (selected-window)))
         (origin (if (eq selected emacs-jupyter-notebook-variables--table) selected source))
         (client emacs-jupyter-notebook--client)
         (generation emacs-jupyter-notebook-variables--generation)
         (token (list 'variable-view)))
    (setq emacs-jupyter-notebook-variables--view-token token)
    (emacs-jupyter-notebook-variables--request
     (and preferred (vector preferred))
     (lambda (reply)
       (when (eq token emacs-jupyter-notebook-variables--view-token)
         (let* ((metadata (cl-remove-if-not #'emacs-jupyter-notebook-variables--array-p
                                            (append (plist-get reply :variables) nil)))
                (names (mapcar (lambda (item) (plist-get item :name)) metadata)))
           (if (and preferred (not (member preferred names)))
               (emacs-jupyter-notebook-view-variables reconfigure)
             (unless names (user-error "No nonempty numerical arrays are available in this kernel"))
             (dolist (item metadata)
               (emacs-jupyter-notebook-variables--cache-put (plist-get item :name) item))
             (emacs-jupyter-notebook-ui-defer
              source
              (lambda ()
                (and (bound-and-true-p emacs-jupyter-notebook-mode)
                     (eq token emacs-jupyter-notebook-variables--view-token)
                     (eq client emacs-jupyter-notebook--client)
                     (= generation emacs-jupyter-notebook-variables--generation)))
              (lambda ()
                (let* ((recent (cl-remove-if-not (lambda (name) (member name names))
                                                 emacs-jupyter-notebook-variables--view-recent))
                       (completion-extra-properties
                        (list :annotation-function
                              (lambda (name)
                                (let ((item (cl-find name metadata :test #'equal
                                                     :key (lambda (entry) (plist-get entry :name)))))
                                  (format "  %s %s"
                                          (emacs-jupyter-notebook-variables--shape-text (plist-get item :shape))
                                          (plist-get item :dtype))))))
                       (chosen
                        (if preferred (list preferred)
                          (delete-dups
                           (completing-read-multiple
                            (if (plist-get reply :truncated)
                                "View arrays (comma-separated; list truncated): "
                              "View arrays (comma-separated): ")
                            names nil t nil nil (and recent (mapconcat #'identity recent ",")))))))
                  (emacs-jupyter-notebook-variables--view-group chosen metadata reconfigure)))
              origin 'variable-view)))))
     (lambda () (message "Array metadata unavailable; try again when the kernel is idle")))))

(defun emacs-jupyter-notebook-variables-view-row ()
  "Open the current table variable in the array viewer."
  (interactive)
  (let ((name (tabulated-list-get-id))
        (source emacs-jupyter-notebook-variables--source))
    (unless name (user-error "No variable on this row"))
    (unless (buffer-live-p source)
      (user-error "The notebook source buffer is no longer open"))
    (with-current-buffer source
      (emacs-jupyter-notebook-view-variable name))))

(defun emacs-jupyter-notebook-variables-setup ()
  "Install buffer-local metadata Eldoc and lifetime hooks."
  (add-hook 'eldoc-documentation-functions
            #'emacs-jupyter-notebook-variables-eldoc nil t)
  (unless (bound-and-true-p eldoc-mode)
    (eldoc-mode 1)
    (setq emacs-jupyter-notebook-variables--enabled-eldoc t))
  (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-variables-teardown nil t))

(defun emacs-jupyter-notebook-variables-teardown ()
  "Cancel metadata delivery and remove this source buffer's local hooks."
  (when emacs-jupyter-notebook-variables--enabled-eldoc
    (eldoc-mode -1))
  (setq emacs-jupyter-notebook-variables--enabled-eldoc nil)
  (emacs-jupyter-notebook-variables-invalidate)
  (emacs-jupyter-notebook-variables--status "Stale metadata — notebook disconnected")
  (remove-hook 'eldoc-documentation-functions
               #'emacs-jupyter-notebook-variables-eldoc t)
  (remove-hook 'kill-buffer-hook #'emacs-jupyter-notebook-variables-teardown t))

(provide 'emacs-jupyter-notebook-variables)
;;; emacs-jupyter-notebook-variables.el ends here
