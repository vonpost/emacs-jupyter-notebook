;;; emacs-jupyter-notebook-variables.el --- Async variable metadata -*- lexical-binding: t; -*-

;;; Commentary:
;; Array shape and dtype appear through Eldoc; an explicit table lists the
;; kernel's public variables.  Queries use the supervised backend and never
;; create a source evaluation, fetch array samples, or modify source text.

;;; Code:

(require 'cl-lib)
(require 'eldoc)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)
(require 'emacs-jupyter-notebook-backend)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook--client)
(defvar emacs-jupyter-notebook--kernel-status)
(defvar emacs-jupyter-notebook--execution-active-id)
(defvar emacs-jupyter-notebook--execution-queue)
(defvar emacs-jupyter-notebook--execution-setup-pending)
(declare-function emacs-jupyter-notebook--async-in-progress-p "emacs-jupyter-notebook")

(defcustom emacs-jupyter-notebook-variable-eldoc t
  "Show Python variable type, shape and dtype at point through Eldoc.
Only simple variable names are queried, and busy kernels are skipped.  Values
are never transferred.  Unknown object types expose type metadata only."
  :type 'boolean :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-variable-cache-seconds 5
  "Seconds to reuse variable metadata between kernel executions.
Starting a new source execution invalidates this cache immediately."
  :type 'number :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-variable-list-limit 200
  "Maximum public variables to show in the variable table, at most 200."
  :type 'integer :group 'emacs-jupyter-notebook)

(defvar-local emacs-jupyter-notebook-variables--cache nil)
(defvar-local emacs-jupyter-notebook-variables--generation 0)
(defvar-local emacs-jupyter-notebook-variables--pending nil)
(defvar-local emacs-jupyter-notebook-variables--queued nil)
(defvar-local emacs-jupyter-notebook-variables--timer nil)
(defvar-local emacs-jupyter-notebook-variables--table nil)
(defvar-local emacs-jupyter-notebook-variables--source nil)
(defvar-local emacs-jupyter-notebook-variables--enabled-eldoc nil)

(defun emacs-jupyter-notebook-variables--name-at-point ()
  "Return a simple Python identifier at point, excluding attributes and text."
  (when (derived-mode-p 'python-mode 'python-ts-mode)
    (unless (nth 8 (syntax-ppss))
      (when-let ((bounds (bounds-of-thing-at-point 'symbol)))
        (let ((name (buffer-substring-no-properties (car bounds) (cdr bounds))))
          (when (and (<= (length name) 128) (<= (string-bytes name) 128)
                     (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\'" name)
                     (not (eq (char-before (car bounds)) ?.))
                     (not (eq (char-after (cdr bounds)) ?.)))
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
  "Forget metadata after user execution admission or a client transition."
  (cl-incf emacs-jupyter-notebook-variables--generation)
  (setq emacs-jupyter-notebook-variables--queued nil)
  (emacs-jupyter-notebook-variables--cancel-pending)
  (setq emacs-jupyter-notebook-variables--cache nil)
  (when (buffer-live-p emacs-jupyter-notebook-variables--table)
    (with-current-buffer emacs-jupyter-notebook-variables--table
      (setq header-line-format "Variable metadata changed; press g to refresh")
      (setq tabulated-list-entries nil)
      (tabulated-list-print t))))

(defun emacs-jupyter-notebook-variables--cached (name)
  "Return the fresh cached metadata envelope for NAME, if any."
  (let* ((cached (and emacs-jupyter-notebook-variables--cache
                      (gethash name emacs-jupyter-notebook-variables--cache)))
         (seconds emacs-jupyter-notebook-variable-cache-seconds)
         (ttl (if (and (numberp seconds) (> seconds 0) (<= seconds 60))
                  seconds 5)))
    (and cached
         (eq (plist-get cached :client) emacs-jupyter-notebook--client)
         (< (- (float-time) (plist-get cached :time)) ttl)
         cached)))

(defun emacs-jupyter-notebook-variables--cache-put (name metadata)
  "Cache METADATA for NAME, including a nil result for missing names."
  (unless (hash-table-p emacs-jupyter-notebook-variables--cache)
    (setq emacs-jupyter-notebook-variables--cache (make-hash-table :test #'equal)))
  (when (>= (hash-table-count emacs-jupyter-notebook-variables--cache) 200)
    (clrhash emacs-jupyter-notebook-variables--cache))
  (puthash name (list :metadata metadata :client emacs-jupyter-notebook--client
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

(defun emacs-jupyter-notebook-variables-eldoc (callback &rest _ignored)
  "Asynchronously pass metadata for the variable at point to Eldoc CALLBACK."
  (when (and emacs-jupyter-notebook-variable-eldoc
             (emacs-jupyter-notebook-variables--ready-p))
    (when-let ((name (emacs-jupyter-notebook-variables--name-at-point)))
      (let ((cached (emacs-jupyter-notebook-variables--cached name)))
        (if cached
            (when-let ((text (emacs-jupyter-notebook-variables--describe
                              (plist-get cached :metadata))))
              (funcall callback text) t)
          (emacs-jupyter-notebook-variables--request
           (vector name)
           (lambda (reply)
             (let ((metadata (car (append (plist-get reply :variables) nil))))
               (emacs-jupyter-notebook-variables--cache-put name metadata)
               (funcall callback (emacs-jupyter-notebook-variables--describe metadata))))
           (lambda () (funcall callback nil))
           (list (point) (buffer-chars-modified-tick) name)))))))

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
  (emacs-jupyter-notebook-variables--ensure-ready)
  (setq name (or name (emacs-jupyter-notebook-variables--name-at-point)
                 (read-string "Variable name: ")))
  (unless (and (stringp name) (<= (length name) 128) (<= (string-bytes name) 128)
               (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\'" name))
    (user-error "Use a simple Python variable name"))
  (emacs-jupyter-notebook-variables--request
   (vector name)
   (lambda (reply)
     (let ((metadata (car (append (plist-get reply :variables) nil))))
       (emacs-jupyter-notebook-variables--cache-put name metadata)
       (message "%s" (or (emacs-jupyter-notebook-variables--describe metadata)
                         (format "%s is not defined in this kernel" name)))))
   (lambda () (message "Variable metadata request failed or timed out"))))

(defvar emacs-jupyter-notebook-variables-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'emacs-jupyter-notebook-variables-refresh)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-variables-inspect-row)
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
    (kbd "q") #'quit-window))

(with-eval-after-load 'evil
  (emacs-jupyter-notebook-variables--evil-setup))

(define-derived-mode emacs-jupyter-notebook-variables-mode tabulated-list-mode
  "EJN Variables"
  "Kernel variable metadata.  Press g to refresh, RET to inspect, q to close."
  (setq tabulated-list-format [("Name" 26 t) ("Type" 28 t)
                               ("Shape" 24 t) ("Dtype" 16 t)]
        tabulated-list-padding 2
        tabulated-list-sort-key '("Name" . nil))
  (tabulated-list-init-header))

(defun emacs-jupyter-notebook-variables--render (table reply)
  "Render bounded variable metadata REPLY into TABLE."
  (when (buffer-live-p table)
    (with-current-buffer table
      (setq header-line-format
            (if (plist-get reply :truncated)
                "Variable list truncated; g refreshes, RET inspects a name"
              "g refreshes · RET inspects · shapes describe the current kernel"))
      (setq tabulated-list-entries
            (mapcar (lambda (row)
                      (let ((name (plist-get row :name)))
                        (list name
                              (vector name (plist-get row :type)
                                      (emacs-jupyter-notebook-variables--shape-text
                                       (plist-get row :shape))
                                      (or (plist-get row :dtype) "—")))))
                    (append (plist-get reply :variables) nil)))
      (tabulated-list-print t))))

;;;###autoload
(defun emacs-jupyter-notebook-list-variables ()
  "Show an asynchronous table of public variables in this notebook's kernel.
The table contains names, actual types, array shapes and dtypes, never values."
  (interactive)
  (emacs-jupyter-notebook-variables--ensure-ready)
  (let* ((source (current-buffer))
         (table (or (and (buffer-live-p emacs-jupyter-notebook-variables--table)
                         emacs-jupyter-notebook-variables--table)
                    (setq emacs-jupyter-notebook-variables--table
                          (generate-new-buffer (format "*EJN Variables: %s*" (buffer-name)))))))
    (with-current-buffer table
      (unless (derived-mode-p 'emacs-jupyter-notebook-variables-mode)
        (emacs-jupyter-notebook-variables-mode))
      (setq emacs-jupyter-notebook-variables--source source
            header-line-format "Loading variable metadata…"))
    (emacs-jupyter-notebook-variables--request
     nil
     (lambda (reply) (emacs-jupyter-notebook-variables--render table reply))
     (lambda ()
       (when (buffer-live-p table)
         (with-current-buffer table
           (setq header-line-format "Variable metadata unavailable; g retries")))))
    (display-buffer table)))

(defun emacs-jupyter-notebook-variables-refresh ()
  "Refresh this variable table through its live source buffer."
  (interactive)
  (unless (buffer-live-p emacs-jupyter-notebook-variables--source)
    (user-error "The notebook source buffer is no longer open"))
  (with-current-buffer emacs-jupyter-notebook-variables--source
    (emacs-jupyter-notebook-list-variables)))

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
  (remove-hook 'eldoc-documentation-functions
               #'emacs-jupyter-notebook-variables-eldoc t)
  (remove-hook 'kill-buffer-hook #'emacs-jupyter-notebook-variables-teardown t))

(provide 'emacs-jupyter-notebook-variables)
;;; emacs-jupyter-notebook-variables.el ends here
