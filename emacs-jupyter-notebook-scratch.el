;;; emacs-jupyter-notebook-scratch.el --- Disposable notebook input -*- lexical-binding: t; -*-

;;; Commentary:
;; A Python input surface, subordinate to one source's existing queue/client.
;; It never enables notebook mode, owns a connection, or edits the source.

;;; Code:

(require 'cl-lib)
(require 'python)
(require 'subr-x)
(require 'emacs-jupyter-notebook-history)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook--max-code-bytes)
(defvar python-base-mode-hook)
(defvar doom-localleader-key)
(defvar doom-localleader-alt-key)
(declare-function evil-define-minor-mode-key "evil-core"
                  (state mode key def &rest bindings))
(declare-function emacs-jupyter-notebook--evaluate-code "emacs-jupyter-notebook"
                  (code cell-key &optional start-profile announce-start options))
(declare-function emacs-jupyter-notebook--bounded-buffer-substring "emacs-jupyter-notebook"
                  (beg end max-bytes &optional quiet))
(declare-function emacs-jupyter-notebook-show-output-panel "emacs-jupyter-notebook-result")
(declare-function emacs-jupyter-notebook--region-bounds "emacs-jupyter-notebook")

(defvar-local emacs-jupyter-notebook-scratch--owner nil)
(defvar-local emacs-jupyter-notebook-scratch--buffer nil)

(defvar emacs-jupyter-notebook-scratch-prefix-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("c" "Send scratch input" emacs-jupyter-notebook-scratch-send)
                       ("r" "Send scratch selection" emacs-jupyter-notebook-scratch-send-region)
                       ("o" "Show notebook output" emacs-jupyter-notebook-scratch-output)
                       ("H" "Execution trail" emacs-jupyter-notebook-history)
                       ("~" "Return to notebook" emacs-jupyter-notebook-scratch-source)))
      (define-key map (kbd (car binding)) (cons (nth 1 binding) (nth 2 binding))))
    map))

(defvar emacs-jupyter-notebook-scratch-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c j") emacs-jupyter-notebook-scratch-prefix-map)
    map))

(defun emacs-jupyter-notebook-scratch--setup-doom-keybindings ()
  "Give scratch's subordinate input map Doom's configured local leaders."
  (when (and (bound-and-true-p doom-localleader-key)
             (bound-and-true-p doom-localleader-alt-key))
    (let ((leader (if (stringp doom-localleader-key)
                      (kbd doom-localleader-key) doom-localleader-key))
          (alternate (if (stringp doom-localleader-alt-key)
                         (kbd doom-localleader-alt-key) doom-localleader-alt-key)))
      (if (featurep 'evil)
          (progn
            (evil-define-minor-mode-key
             '(normal visual motion) 'emacs-jupyter-notebook-scratch-input-mode
             leader emacs-jupyter-notebook-scratch-prefix-map)
            (evil-define-minor-mode-key
             '(insert emacs) 'emacs-jupyter-notebook-scratch-input-mode
             alternate emacs-jupyter-notebook-scratch-prefix-map))
        (define-key emacs-jupyter-notebook-scratch-input-mode-map
                    alternate emacs-jupyter-notebook-scratch-prefix-map)))))

(define-minor-mode emacs-jupyter-notebook-scratch-input-mode
  "Keybindings for subordinate scratch input; owns no kernel resources."
  :lighter nil :keymap emacs-jupyter-notebook-scratch-input-mode-map
  (when emacs-jupyter-notebook-scratch-input-mode
    (emacs-jupyter-notebook-scratch--setup-doom-keybindings)))

(with-eval-after-load 'evil (emacs-jupyter-notebook-scratch--setup-doom-keybindings))

(defvar emacs-jupyter-notebook-scratch-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map python-mode-map)
    (define-key map (kbd "C-c C-c") #'emacs-jupyter-notebook-scratch-send)
    (define-key map (kbd "C-c j c") #'emacs-jupyter-notebook-scratch-send)
    (define-key map (kbd "C-c j o") #'emacs-jupyter-notebook-scratch-output)
    (define-key map (kbd "C-c j H") #'emacs-jupyter-notebook-history)
    (define-key map (kbd "C-c C-z") #'emacs-jupyter-notebook-scratch-source)
    map))

(define-derived-mode emacs-jupyter-notebook-scratch-mode python-mode "EJN Scratch"
  "Disposable input; C-c C-c sends then clears, C-c C-z returns to source."
  (setq-local header-line-format
              "Disposable input   C-c C-c send and clear   C-c C-z source   C-c j H trail")
  (setq-local buffer-offer-save nil)
  (setq-local buffer-save-without-query nil)
  (emacs-jupyter-notebook-scratch-input-mode 1))

(defun emacs-jupyter-notebook-scratch--source ()
  "Return the scratch's live, enabled owner."
  (unless (and (buffer-live-p emacs-jupyter-notebook-scratch--owner)
               (buffer-local-value 'emacs-jupyter-notebook-mode
                                   emacs-jupyter-notebook-scratch--owner))
    (user-error "Scratch's source notebook is closed or disabled"))
  emacs-jupyter-notebook-scratch--owner)

(defun emacs-jupyter-notebook-scratch--cleanup ()
  "Kill subordinate disposable input when its source is killed."
  (when (buffer-live-p emacs-jupyter-notebook-scratch--buffer)
    (with-current-buffer emacs-jupyter-notebook-scratch--buffer
      (set-buffer-modified-p nil)
      (let ((kill-buffer-query-functions nil)) (kill-buffer (current-buffer)))))
  (setq emacs-jupyter-notebook-scratch--buffer nil))

;;;###autoload
(defun emacs-jupyter-notebook-scratch (&optional code)
  "Open disposable Python input attached to the current notebook source.
Optional CODE is appended for recall, preserving any existing draft.  Input
is submitted through the source's single queue and recorded in its trail."
  (interactive)
  (let* ((owner (emacs-jupyter-notebook-history--source))
         (scratch (buffer-local-value 'emacs-jupyter-notebook-scratch--buffer owner)))
    (unless (buffer-local-value 'emacs-jupyter-notebook-mode owner)
      (user-error "Enable notebook mode in the source first"))
    (unless (buffer-live-p scratch)
      (setq scratch (generate-new-buffer (format "*EJN scratch: %s*" (buffer-name owner))))
      (with-current-buffer owner
        (setq emacs-jupyter-notebook-scratch--buffer scratch)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-scratch--cleanup nil t))
      (with-current-buffer scratch
        ;; Standard Python hooks often auto-enable EJN.  This subordinate
        ;; input must not acquire a second session or source lifecycle.
        (let ((python-mode-hook nil) (python-base-mode-hook nil) (prog-mode-hook nil)
              (emacs-jupyter-notebook-scratch--owner owner))
          (emacs-jupyter-notebook-scratch-mode))
        (setq emacs-jupyter-notebook-scratch--owner owner)
        (setq default-directory (buffer-local-value 'default-directory owner))))
    (when code
      (with-current-buffer scratch
        (goto-char (point-max))
        (unless (= (point-min) (point-max)) (insert "\n\n"))
        (insert code)))
    (pop-to-buffer scratch)
    scratch))

(defun emacs-jupyter-notebook-scratch-send ()
  "Submit this input to its source's queue, then clear the accepted input.
An active region submits only that region.  A rejected reservation leaves
the draft intact.  Exact accepted code remains available in the trail."
  (interactive)
  (emacs-jupyter-notebook-scratch--submit-region
   (if (use-region-p) (region-beginning) (point-min))
   (if (use-region-p) (region-end) (point-max))))

(defun emacs-jupyter-notebook-scratch-send-region (beg end)
  "Submit only scratch's selected region BEG to END, including Evil visual."
  (interactive (emacs-jupyter-notebook--region-bounds))
  (emacs-jupyter-notebook-scratch--submit-region beg end))

(defun emacs-jupyter-notebook-scratch--submit-region (beg end)
  "Queue scratch input BEG to END and remove only accepted text."
  (let* ((owner (emacs-jupyter-notebook-scratch--source))
         (code (emacs-jupyter-notebook--bounded-buffer-substring
                beg end emacs-jupyter-notebook--max-code-bytes))
         id)
    (when (string-empty-p (string-trim code)) (user-error "Scratch input is empty"))
    (setq id (with-current-buffer owner
               (emacs-jupyter-notebook--evaluate-code
                code nil nil nil '(:title "Scratch" :origin scratch))))
    (delete-region beg end)
    (deactivate-mark)
    (when (= (point-min) (point-max)) (set-buffer-modified-p nil))
    (message "Scratch queued as execution #%s" id)
    id))

(defun emacs-jupyter-notebook-scratch-source ()
  "Return to the source notebook owning this scratch input."
  (interactive)
  (pop-to-buffer (emacs-jupyter-notebook-scratch--source)))

(defun emacs-jupyter-notebook-scratch-output ()
  "Show the owning notebook's result panel."
  (interactive)
  (with-current-buffer (emacs-jupyter-notebook-scratch--source)
    (emacs-jupyter-notebook-show-output-panel)))

(provide 'emacs-jupyter-notebook-scratch)
;;; emacs-jupyter-notebook-scratch.el ends here
