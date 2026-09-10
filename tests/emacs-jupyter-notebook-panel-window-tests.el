;;; emacs-jupyter-notebook-panel-window-tests.el --- Ordinary output windows -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline window behavior tests using real Emacs display and window commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-result)

(defmacro ejn-panel-window-test--with-source (&rest body)
  "Run BODY with a source, panel and selected source-window; release the panel."
  (declare (indent 0))
  `(let ((display-buffer-alist nil)
         (display-buffer-overriding-action nil)
         (display-buffer-base-action nil)
         (display-buffer-mark-dedicated nil)
         (display-buffer-reuse-frames nil)
         (pop-up-frames nil)
         (pop-up-windows t)
         (emacs-jupyter-notebook-panel-side 'right)
         (emacs-jupyter-notebook-panel-width 30))
     (save-window-excursion
       (delete-other-windows)
       (with-temp-buffer
         (insert "# %% Result\nprint(42)\n")
         (set-buffer-modified-p nil)
         (let* ((source (current-buffer))
                (source-window (selected-window))
                (panel (ejn-panel-ensure source)))
           (set-window-buffer source-window source)
           (unwind-protect
               (progn
                 ,@body
                 (with-current-buffer source
                   (should (equal (buffer-string) "# %% Result\nprint(42)\n"))
                   (should-not (buffer-modified-p))))
             (with-current-buffer source
               (emacs-jupyter-notebook--kill-panel))))))))

(ert-deftest ejn-panel-window-allows-ordinary-window-commands ()
  (ejn-panel-window-test--with-source
    (let* ((handle (ejn-panel-start-entry panel nil "print(42)"))
           (window (emacs-jupyter-notebook-panel--display panel)))
      (ejn-panel-append-text handle "42\n")
      (ejn-panel-finish-entry handle 'ok 1)
      (ejn-panel-reveal-entry handle)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (should (eq (selected-window) source-window))
      (should (eq (window-buffer source-window) source))
      (should-not (window-parameter window 'window-side))
      (should-not (window-dedicated-p window))
      (with-current-buffer panel
        (should buffer-read-only)
        (should (string-match-p "42" (buffer-string))))
      (should (window-live-p (split-window window nil 'below)))
      (with-selected-window window
        (switch-to-buffer source)
        (should (eq (window-buffer window) source))
        (switch-to-buffer panel)
        (delete-other-windows)
        (should (= (length (window-list)) 1))
        (should (eq (window-buffer (selected-window)) panel))))))

(ert-deftest ejn-panel-window-default-is-not-dedicated ()
  (ejn-panel-window-test--with-source
    (let* ((display-buffer-mark-dedicated t)
           (window (emacs-jupyter-notebook-panel--display panel)))
      (should-not (window-dedicated-p window)))))

(ert-deftest ejn-panel-window-reuses-manually-placed-output ()
  (ejn-panel-window-test--with-source
    ;; The user places output left of the source despite the right-side default.
    (let ((window (split-window source-window -30 'left)))
      (set-window-buffer window panel)
      (window-resize window 5 t)
      (let ((edges (window-edges window))
            (source-edges (window-edges source-window)))
        (should (eq window (emacs-jupyter-notebook-panel--display panel)))
        (should (eq (selected-window) source-window))
        (should (= (length (window-list)) 2))
        (should (equal (window-edges window) edges))
        (should (equal (window-edges source-window) source-edges))
        (should-not (window-parameter window 'window-side))))))

(ert-deftest ejn-panel-window-reuses-resized-and-selected-output ()
  (ejn-panel-window-test--with-source
    (let ((window (emacs-jupyter-notebook-panel--display panel)))
      (window-resize window 5 t)
      (let ((edges (window-edges window))
            (source-edges (window-edges source-window)))
        (should (eq window (emacs-jupyter-notebook-panel--display panel)))
        (should (equal (window-edges window) edges))
        (should (equal (window-edges source-window) source-edges))
        (with-selected-window window
          (should (eq window (emacs-jupyter-notebook-panel--display panel)))
          (should (eq (selected-window) window))
          (should (= (length (window-list)) 2))
          (should (equal (window-edges window) edges))
          (should (equal (window-edges source-window) source-edges)))))))

(ert-deftest ejn-panel-window-honors-initial-direction ()
  (dolist (side '(right left top bottom))
    (ejn-panel-window-test--with-source
      (let* ((emacs-jupyter-notebook-panel-side side)
             (window (emacs-jupyter-notebook-panel--display panel))
             (output (window-edges window))
             (input (window-edges source-window)))
        (should-not (window-parameter window 'window-side))
        (should-not (window-dedicated-p window))
        (should (eq (selected-window) source-window))
        (pcase side
          ('right (should (>= (nth 0 output) (nth 2 input))))
          ('left (should (<= (nth 2 output) (nth 0 input))))
          ('top (should (<= (nth 3 output) (nth 1 input))))
          ('bottom (should (>= (nth 1 output) (nth 3 input)))))))))

(ert-deftest ejn-panel-window-honors-user-display-rule ()
  (ejn-panel-window-test--with-source
    (let ((display-buffer-alist
           '(("\\`\\*ejn:" (display-buffer-same-window)))))
      (should (eq source-window (emacs-jupyter-notebook-panel--display panel)))
      (should (eq (window-buffer source-window) panel))
      (should (eq (selected-window) source-window))
      (should (= (length (window-list)) 1)))))

(ert-deftest ejn-panel-window-falls-back-when-direction-cannot-split ()
  (ejn-panel-window-test--with-source
    ;; Prevent a horizontal split while leaving room for an ordinary lower window.
    (let* ((window-min-width (window-total-width source-window))
           (window (emacs-jupyter-notebook-panel--display panel)))
      (should (window-live-p window))
      (should-not (eq window source-window))
      (should-not (window-parameter window 'window-side))
      (should-not (window-dedicated-p window))
      (should (eq (window-buffer source-window) source))
      (should (eq (selected-window) source-window))
      (should (>= (nth 1 (window-edges window))
                  (nth 3 (window-edges source-window)))))))

(provide 'emacs-jupyter-notebook-panel-window-tests)
;;; emacs-jupyter-notebook-panel-window-tests.el ends here
