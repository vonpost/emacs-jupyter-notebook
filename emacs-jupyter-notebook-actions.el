;;; emacs-jupyter-notebook-actions.el --- Contextual notebook actions -*- lexical-binding: t; -*-

(require 'cl-lib)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook-prefix-key)
(declare-function emacs-jupyter-notebook-variables--name-at-point "emacs-jupyter-notebook-variables")
(declare-function emacs-jupyter-notebook-inspect-variable "emacs-jupyter-notebook-variables")
(declare-function emacs-jupyter-notebook-variables-inspect-row "emacs-jupyter-notebook-variables")
(declare-function emacs-jupyter-notebook-inspect-at-point "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-inspect-images "emacs-jupyter-notebook-inspect")
(declare-function emacs-jupyter-notebook-panel--entry-id-at-point "emacs-jupyter-notebook-result")
(declare-function emacs-jupyter-notebook-panel--entry "emacs-jupyter-notebook-result" (panel id))
(declare-function emacs-jupyter-notebook-panel--image-at-point "emacs-jupyter-notebook-result")
(declare-function emacs-jupyter-notebook-panel-open-image-externally "emacs-jupyter-notebook-result")
(declare-function emacs-jupyter-notebook-panel-visit-source "emacs-jupyter-notebook-result")

(defun emacs-jupyter-notebook-actions--panel-array-p ()
  "Return non-nil when the selected panel entry has a numerical publication."
  (when-let ((id (emacs-jupyter-notebook-panel--entry-id-at-point)))
    (cl-some (lambda (segment) (eq (car segment) 'array))
             (plist-get (emacs-jupyter-notebook-panel--entry (current-buffer) id)
                        :outputs))))

(defun emacs-jupyter-notebook-actions--panel-segment ()
  "Return the selected output kind; nil denotes a header or separator."
  (when-let ((id (emacs-jupyter-notebook-panel--entry-id-at-point)))
    (let ((index (or (get-text-property (point) 'emacs-jupyter-notebook-segment-index)
                     (get-text-property (point) 'emacs-jupyter-notebook-text-segment-index))))
      (when (integerp index)
        (car (nth index (plist-get (emacs-jupyter-notebook-panel--entry (current-buffer) id)
                                  :outputs)))))))

;;;###autoload
(defun emacs-jupyter-notebook-inspect ()
  "Inspect the variable, documentation, or output at point.
In a panel, open numerical images or the selected raster; text entries jump
to their source.  In source, identifiers show live metadata (including shape)
and other contexts use kernel documentation.  No cell is evaluated."
  (interactive)
  (cond
   ((derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (pcase (emacs-jupyter-notebook-actions--panel-segment)
      ('array (emacs-jupyter-notebook-inspect-images))
      ('image (emacs-jupyter-notebook-panel-open-image-externally))
      ('nil
       (cond
        ((emacs-jupyter-notebook-actions--panel-array-p)
         (emacs-jupyter-notebook-inspect-images))
        ((emacs-jupyter-notebook-panel--image-at-point)
         (emacs-jupyter-notebook-panel-open-image-externally))
        (t (emacs-jupyter-notebook-panel-visit-source))))
      (_ (emacs-jupyter-notebook-panel-visit-source))))
   ((derived-mode-p 'emacs-jupyter-notebook-variables-mode)
    (call-interactively #'emacs-jupyter-notebook-variables-inspect-row))
   ((and (bound-and-true-p emacs-jupyter-notebook-mode)
         (emacs-jupyter-notebook-variables--name-at-point))
    (call-interactively #'emacs-jupyter-notebook-inspect-variable))
   ((bound-and-true-p emacs-jupyter-notebook-mode)
    (call-interactively #'emacs-jupyter-notebook-inspect-at-point))
   (t (user-error "Inspect requires a notebook, output, or variable buffer"))))

(defun emacs-jupyter-notebook-actions--choices ()
  "Return contextual (LABEL COMMAND SHORTCUT) actions without kernel I/O."
  (cond
   ((derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    '(("Inspect output" emacs-jupyter-notebook-inspect "i")
      ("Hide/show outputs" emacs-jupyter-notebook-toggle-cell-output "TAB")
      ("Go to source cell" emacs-jupyter-notebook-panel-visit-source "RET")
      ("Resume following source" emacs-jupyter-notebook-panel-resume-follow "f")
      ("Switch latest/history" emacs-jupyter-notebook-panel-toggle-view "H")
      ("Next output" emacs-jupyter-notebook-panel-next-entry "n")
      ("Previous output" emacs-jupyter-notebook-panel-previous-entry "p")))
   ((derived-mode-p 'emacs-jupyter-notebook-variables-mode)
    '(("Inspect variable" emacs-jupyter-notebook-inspect "i / RET")
      ("View array plane" emacs-jupyter-notebook-variables-view-row "v")
      ("Refresh variables" emacs-jupyter-notebook-variables-refresh "g")
      ("Favorite variable" emacs-jupyter-notebook-variables-toggle-favorite "f")
      ("Show favorites/all" emacs-jupyter-notebook-variables-toggle-favorites-only "F")))
   ((bound-and-true-p emacs-jupyter-notebook-mode)
    '(("Inspect at point" emacs-jupyter-notebook-inspect "i")
      ("View array variable" emacs-jupyter-notebook-view-variable "A")
      ("Browse variables" emacs-jupyter-notebook-list-variables "V")
      ("Inspect cell images" emacs-jupyter-notebook-inspect-images "I")
      ("Evaluate cell and inspect" emacs-jupyter-notebook-evaluate-and-inspect "J")
      ("Evaluate cell" emacs-jupyter-notebook-send-cell "c")
      ("Evaluate and advance" emacs-jupyter-notebook-send-cell-and-advance "j")
      ("Hide/show cell outputs" emacs-jupyter-notebook-toggle-cell-output "h / normal TAB")
      ("Show output panel" emacs-jupyter-notebook-show-output-panel "o")
      ("Kernel documentation" emacs-jupyter-notebook-inspect-at-point ".")
      ("Interrupt kernel" emacs-jupyter-notebook-interrupt-kernel "k")
      ("Notebook status" emacs-jupyter-notebook-status "?")))
   (t (user-error "Actions require a notebook, output, or variable buffer"))))

;;;###autoload
(defun emacs-jupyter-notebook-actions ()
  "Choose an action relevant to this buffer, with its keyboard shortcut.
Completion integrates with the user's usual minibuffer UI, including Doom."
  (interactive)
  (let* ((prefix (if (bound-and-true-p emacs-jupyter-notebook-mode)
                     (concat emacs-jupyter-notebook-prefix-key " ") ""))
         (choices (mapcar (lambda (choice)
                            (cons (format "%-28s  %s%s" (car choice) prefix (nth 2 choice))
                                  (nth 1 choice)))
                          (cl-remove-if-not
                           (lambda (choice) (commandp (nth 1 choice)))
                           (emacs-jupyter-notebook-actions--choices))))
         (selected (completing-read "Notebook action: " choices nil t)))
    (when-let ((command (cdr (assoc selected choices))))
      (call-interactively command))))

(provide 'emacs-jupyter-notebook-actions)
;;; emacs-jupyter-notebook-actions.el ends here
