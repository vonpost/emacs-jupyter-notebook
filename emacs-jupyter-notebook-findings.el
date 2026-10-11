;;; emacs-jupyter-notebook-findings.el --- Saved viewer findings -*- lexical-binding: t; -*-

;;; Commentary:
;; These commands address the local viewer.  Capturing never evaluates source
;; or fetches fresh samples: the viewer freezes its currently displayed panes.

;;; Code:

(require 'cl-lib)
(require 'emacs-jupyter-notebook-inspect)
(require 'emacs-jupyter-notebook-ui)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook-panel--source-buffer)
(defvar emacs-jupyter-notebook-variables--source)
(defvar emacs-jupyter-notebook-scratch--owner)
(defvar emacs-jupyter-notebook-history--owner)
(declare-function emacs-jupyter-notebook--current-cell-key "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-inspect-control "emacs-jupyter-notebook-inspect"
                  (op params &optional existing-only callback))
(declare-function emacs-jupyter-notebook-inspect-workspaces "emacs-jupyter-notebook-inspect" ())
(declare-function org-mode "org")
(declare-function org-overview "org")
(declare-function org-show-entry "org" (&optional hide-drawers))
(declare-function org-fold-show-all "org-fold" (&optional types))
(declare-function org-display-inline-images "org" (&optional include-linked refresh beg end))
(declare-function org-remove-inline-images "org" (&optional beg end))
(declare-function org-invisible-p "org" (&optional pos folding-only))
(defvar org-inhibit-startup)
(defvar org-startup-with-inline-images)
(defvar org-inline-image-overlays)
(defvar-local emacs-jupyter-notebook-findings--overview nil)
(defvar-local emacs-jupyter-notebook-findings--preview-timer nil)

(defun emacs-jupyter-notebook-findings--saved-copy ()
  "Release generated-overview behavior after saving an ordinary report copy."
  (when (and emacs-jupyter-notebook-findings--overview
             (not (equal buffer-file-name emacs-jupyter-notebook-findings--overview)))
    (emacs-jupyter-notebook-findings--cancel-previews)
    (setq emacs-jupyter-notebook-findings--overview nil
          header-line-format nil
          buffer-read-only nil)
    (remove-hook 'post-command-hook #'emacs-jupyter-notebook-findings--schedule-previews t)
    (remove-hook 'window-scroll-functions #'emacs-jupyter-notebook-findings--schedule-previews t)
    (remove-hook 'after-save-hook #'emacs-jupyter-notebook-findings--saved-copy t)))

(defun emacs-jupyter-notebook-findings--cancel-previews ()
  "Cancel this overview's pending thumbnail rendering."
  (when (timerp emacs-jupyter-notebook-findings--preview-timer)
    (cancel-timer emacs-jupyter-notebook-findings--preview-timer))
  (setq emacs-jupyter-notebook-findings--preview-timer nil))

(defun emacs-jupyter-notebook-findings--schedule-previews (&rest _)
  "Schedule one visible-preview update after scrolling or an Org command."
  (when (and emacs-jupyter-notebook-findings--overview
             (not (timerp emacs-jupyter-notebook-findings--preview-timer)))
    (setq emacs-jupyter-notebook-findings--preview-timer
          (run-at-time 0.05 nil #'emacs-jupyter-notebook-findings--render-previews
                       (current-buffer)))))

(defun emacs-jupyter-notebook-findings--render-previews (buffer)
  "Show at most eight visible previews in BUFFER, releasing offscreen images."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacs-jupyter-notebook-findings--preview-timer nil)
      (when (and emacs-jupyter-notebook-findings--overview (display-images-p))
        (let ((window (get-buffer-window buffer t)) ranges)
          (when window
            (save-excursion
              (goto-char (window-start window))
              (beginning-of-line)
              (let ((end (or (window-end window t) (point-max))))
                (while (and (< (length ranges) 8)
                            (re-search-forward
                             "^\\[\\[file:[0-9a-f]+/overview\\.png\\]\\]$" end t))
                  (unless (org-invisible-p (match-beginning 0) t)
                    (push (cons (match-beginning 0) (line-end-position)) ranges))))))
          ;; Org retains image overlays, and Emacs also caches decoded images.
          ;; Release both when scrolling away, keeping large collections cheap.
          (dolist (overlay (copy-sequence org-inline-image-overlays))
            (unless (assq (overlay-start overlay) ranges)
              (when-let ((image (overlay-get overlay 'display))) (image-flush image))
              (delete-overlay overlay)
              (setq org-inline-image-overlays (delq overlay org-inline-image-overlays))))
          (dolist (range (nreverse ranges))
            (unless (cl-find (car range) org-inline-image-overlays
                             :key #'overlay-start :test #'equal)
              (org-display-inline-images nil nil (car range) (cdr range)))))))))

(defun emacs-jupyter-notebook-findings--open-overview (result)
  "Open the bounded local Org document identified by viewer RESULT."
  (let* ((file-name-handler-alist nil)
         (path (and (hash-table-p result) (gethash "path" result)))
         (attributes
          (and (stringp path) (<= (string-bytes path) 4096)
               (file-name-absolute-p path)
               (not (string-match-p "\\`/[^/]*:" path))
               (equal (file-name-nondirectory path) "findings.org")
               (file-attributes path))))
    (unless (and attributes (null (file-attribute-type attributes))
                 (file-regular-p path)
                 (<= (file-attribute-size attributes) (* 8 1024 1024)))
      (user-error "The viewer did not return a readable local findings overview"))
    (let ((existing (get-file-buffer path)))
      (when (and existing (buffer-modified-p existing))
        (user-error "Save your edited overview as a copy before reopening it"))
      (require 'org)
      (let* ((enable-local-variables nil)
             (enable-local-eval nil)
             (org-inhibit-startup t)
             (org-startup-with-inline-images nil)
             (buffer (or existing (find-file-noselect path))))
        (with-current-buffer buffer
          (emacs-jupyter-notebook-findings--cancel-previews)
          (when existing
            (when (derived-mode-p 'org-mode)
              (org-remove-inline-images)
              (org-fold-show-all))
            (revert-buffer t t t))
          (unless (derived-mode-p 'org-mode) (org-mode))
          (setq-local emacs-jupyter-notebook-findings--overview path
                      header-line-format
                      "Saved findings   TAB expand context   C-x C-w save a report copy")
          (org-remove-inline-images)
          (org-overview)
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward "^\\* " nil t) (org-show-entry t)))
          (goto-char (point-min))
          (when (re-search-forward "^\\* " nil t) (beginning-of-line))
          (setq buffer-read-only t)
          (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-findings--cancel-previews nil t)
          (add-hook 'post-command-hook #'emacs-jupyter-notebook-findings--schedule-previews nil t)
          (add-hook 'window-scroll-functions #'emacs-jupyter-notebook-findings--schedule-previews nil t)
          (add-hook 'after-save-hook #'emacs-jupyter-notebook-findings--saved-copy nil t))
        (pop-to-buffer buffer)
        (set-window-start (selected-window) (point))
        (emacs-jupyter-notebook-findings--render-previews buffer)
        buffer))))

(defun emacs-jupyter-notebook-findings--overview-ready (result origin)
  "Defer opening completed RESULT until ORIGIN owns input again."
  (if (buffer-live-p origin)
    (emacs-jupyter-notebook-ui-defer
     origin (lambda () t)
     (lambda () (emacs-jupyter-notebook-findings--open-overview result))
     origin 'findings-overview)
    (message "Findings overview saved: %s" (gethash "path" result))))

(defun emacs-jupyter-notebook-findings--source ()
  "Return the notebook that owns this source, scratch or review buffer."
  (cl-find-if
   #'buffer-live-p
   (list (and (bound-and-true-p emacs-jupyter-notebook-mode) (current-buffer))
         (bound-and-true-p emacs-jupyter-notebook-panel--source-buffer)
         (bound-and-true-p emacs-jupyter-notebook-variables--source)
         (bound-and-true-p emacs-jupyter-notebook-scratch--owner)
         (bound-and-true-p emacs-jupyter-notebook-history--owner))))

(defun emacs-jupyter-notebook-findings--workspace ()
  "Choose an already displayed workspace belonging to this notebook."
  (let* ((source (emacs-jupyter-notebook-findings--source))
         (workspaces
          (cl-remove-if-not
           (lambda (workspace) (eq source (plist-get workspace :source)))
           (and source (emacs-jupyter-notebook-inspect-workspaces))))
         (cell (and (eq source (current-buffer))
                    (emacs-jupyter-notebook--current-cell-key)))
         (matching (and cell
                        (cl-remove-if-not
                         (lambda (workspace) (equal cell (plist-get workspace :cell-key)))
                         workspaces))))
    (when matching (setq workspaces matching))
    (unless workspaces
      (user-error "Open a result in the viewer before capturing a finding"))
    (if (= (length workspaces) 1)
        (plist-get (car workspaces) :workspace)
      (let* ((choices
              (mapcar
               (lambda (workspace)
                 (let* ((id (plist-get workspace :workspace))
                        (label (if (string-match "/" id)
                                   (substring id (match-end 0)) id)))
                   (cons label id)))
               workspaces))
             (choice (completing-read "Capture viewer: " choices nil t)))
        (cdr (assoc choice choices))))))

;;;###autoload
(defun emacs-jupyter-notebook-capture-finding ()
  "Save the displayed viewer image and its recorded execution context.
The local viewer freezes its current panes before an optional note.  This
does not evaluate a cell or capture the kernel's mutable object state."
  (interactive)
  (let ((workspace (emacs-jupyter-notebook-findings--workspace)))
    (emacs-jupyter-notebook-inspect-control
     "capture" (emacs-jupyter-notebook-inspect--object "workspace" workspace) t)))

;;;###autoload
(defun emacs-jupyter-notebook-review-findings ()
  "Browse saved findings, annotate them or copy an image and caption.
Opens the local collection even without a live source buffer or kernel."
  (interactive)
  (emacs-jupyter-notebook-inspect-control
   "findings" (emacs-jupyter-notebook-inspect--object)))

;;;###autoload
(defun emacs-jupyter-notebook-findings-overview ()
  "Generate and open a lightweight Org overview of saved findings.
Images, notes and folded context link to ordinary files beside the document.
The overview is read-only; save a copy to compose a report.  Generation never
evaluates source code and does not require a kernel or notebook buffer."
  (interactive)
  (dolist (buffer (buffer-list))
    (when (and (buffer-local-value 'emacs-jupyter-notebook-findings--overview buffer)
               (buffer-modified-p buffer))
      (user-error "Save your edited overview as a copy before regenerating it")))
  (let ((origin (window-buffer (selected-window))))
    (emacs-jupyter-notebook-inspect-control
     "findings_org" (emacs-jupyter-notebook-inspect--object) nil
     (lambda (result)
       (emacs-jupyter-notebook-findings--overview-ready result origin)))))

(provide 'emacs-jupyter-notebook-findings)
;;; emacs-jupyter-notebook-findings.el ends here
