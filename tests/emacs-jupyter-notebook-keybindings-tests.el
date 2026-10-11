;;; emacs-jupyter-notebook-keybindings-tests.el --- Optional leader bindings -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defvar doom-localleader-key)
(defvar doom-localleader-alt-key)

(ert-deftest ejn-keybindings-vanilla-does-not-acquire-a-leader ()
  "Without Doom prefixes, setup leaves the ordinary minor-mode map alone."
  (let* ((emacs-jupyter-notebook-mode-map
          (copy-keymap emacs-jupyter-notebook-mode-map))
         (before (copy-tree emacs-jupyter-notebook-mode-map))
         (doom-localleader-key nil)
         (doom-localleader-alt-key nil))
    (cl-letf (((symbol-function 'evil-define-minor-mode-key)
               (lambda (&rest _) (ert-fail "Vanilla setup called Evil"))))
      (emacs-jupyter-notebook--setup-doom-keybindings))
    (should (equal before emacs-jupyter-notebook-mode-map))))

(ert-deftest ejn-keybindings-doom-uses-configured-prefixes-and-evil-states ()
  "Both local leaders refer to the shared map, including its cell submenu."
  (let ((doom-localleader-key ",")
        (doom-localleader-alt-key (kbd "C-c m"))
        (real-featurep (symbol-function 'featurep))
        calls)
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional subfeature)
                 (or (eq feature 'evil)
                     (funcall real-featurep feature subfeature))))
              ((symbol-function 'evil-define-minor-mode-key)
               (lambda (states mode key map &rest _)
                 (push (list states mode key map) calls))))
      (emacs-jupyter-notebook--setup-doom-keybindings))
    (should (= (length calls) 2))
    (dolist (state '(normal visual motion insert emacs))
      (let* ((binding (cl-find-if (lambda (call) (memq state (car call))) calls))
             (map (nth 3 binding)))
        (should (eq (nth 1 binding) 'emacs-jupyter-notebook-mode))
        (should (equal (nth 2 binding)
                       (kbd (if (memq state '(insert emacs)) "C-c m" ","))))
        (should (eq map emacs-jupyter-notebook-prefix-map))
        (should (eq (lookup-key map (kbd "TAB"))
                    #'emacs-jupyter-notebook-complete-at-point))
        (should (eq (lookup-key map (kbd "A"))
                    #'emacs-jupyter-notebook-view))
        (should (eq (lookup-key map (kbd "% i"))
                    #'emacs-jupyter-notebook-insert-cell-below))))))

(ert-deftest ejn-keybindings-doom-without-evil-is-scoped-to-notebook-mode ()
  "The alternate prefix preserves other commands and restores collisions."
  (let* ((emacs-jupyter-notebook-mode-map (make-sparse-keymap))
         (minor-mode-map-alist
          `((emacs-jupyter-notebook-mode . ,emacs-jupyter-notebook-mode-map)))
         (doom-localleader-key "SPC m")
         (doom-localleader-alt-key "C-c m")
         (real-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional subfeature)
                 (and (not (eq feature 'evil))
                      (funcall real-featurep feature subfeature)))))
      (emacs-jupyter-notebook--setup-doom-keybindings))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (local-set-key (kbd "C-c m A") #'backward-char)
      (local-set-key (kbd "C-c m e a") #'forward-char)
      (dolist (enabled '(nil t nil t))
        (setq-local emacs-jupyter-notebook-mode enabled)
        (should (eq (key-binding (kbd "C-c m A"))
                    (if enabled #'emacs-jupyter-notebook-view
                      #'backward-char)))
        (should (eq (key-binding (kbd "C-c m e a")) #'forward-char)))
      ;; Never consume the space key in a non-Evil buffer.
      (should-not (lookup-key emacs-jupyter-notebook-mode-map (kbd "SPC"))))))

(ert-deftest ejn-keybindings-command-labels-keep-original-bindings ()
  "Which-key sees short labels without a dependency on which-key itself."
  (let ((map (emacs-jupyter-notebook--build-prefix-map)))
    (dolist (key '("TAB" "A" "I" "J" "V" "%"))
      (let ((raw (cdr (assq (aref (vconcat (kbd key)) 0) (cdr map)))))
        (should (stringp (car-safe raw)))
        (should-not (string-match-p "emacs-jupyter-notebook" (car raw)))))
    (should (eq (lookup-key map (kbd "J"))
                #'emacs-jupyter-notebook-evaluate-and-inspect))))

(provide 'emacs-jupyter-notebook-keybindings-tests)
;;; emacs-jupyter-notebook-keybindings-tests.el ends here
