;;; emacs-jupyter-notebook-panel-window-tests.el --- Ordinary output windows -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline window behavior tests using real Emacs display and window commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

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

(ert-deftest ejn-panel-window-reuses-output-before-consulting-display-rules ()
  (ejn-panel-window-test--with-source
    (let* ((window (emacs-jupyter-notebook-panel--display panel))
           (display-buffer-overriding-action 'display-buffer-same-window))
      (should (eq window (emacs-jupyter-notebook-panel--display panel)))
      (should (eq (selected-window) source-window))
      (should (eq (window-buffer source-window) source)))))

(ert-deftest ejn-panel-window-malformed-display-actions-fall-back-safely ()
  ;; This malformed action reproduces the reported listp error exactly.
  (dolist (setting '(display-buffer-overriding-action
                     display-buffer-base-action display-buffer-alist))
    (ejn-panel-window-test--with-source
      (let* ((value (if (eq setting 'display-buffer-alist)
                        '(("\\`\\*ejn:" . display-buffer-same-window))
                      'display-buffer-same-window))
             (handle (ejn-panel-start-entry panel nil "print(42)"))
             (messages nil))
        (ejn-panel-append-text handle "42\n")
        (ejn-panel-finish-entry handle 'ok 1)
        (ejn-panel-reveal-entry handle)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (cl-progv (list setting) (list value)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (dotimes (_ 2)
              (let ((window (emacs-jupyter-notebook-panel--display panel)))
                (should (window-live-p window))
                (should (eq (window-buffer window) panel))
                (should-not (eq window source-window))
                (should-not (window-dedicated-p window))
                (should-not (window-parameter window 'window-side))
                (should (eq (selected-window) source-window))
                (delete-window window))))
          (should (equal (symbol-value setting) value)))
        (should (= (length messages) 1))
        (should (string-match-p "display-buffer-same-window" (car messages)))
        (with-current-buffer panel
          (should (string-match-p "42" (buffer-string))))))))

(ert-deftest ejn-panel-window-display-failure-keeps-output-usable ()
  (ejn-panel-window-test--with-source
    (let ((handle (ejn-panel-start-entry panel nil "print(42)")))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (&rest _) (error "No usable window"))))
        (should-not (emacs-jupyter-notebook-panel--display panel)))
      (ejn-panel-append-text handle "42\n")
      (ejn-panel-finish-entry handle 'ok 1)
      (ejn-panel-reveal-entry handle)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "42" (buffer-string))))
      (should (eq (selected-window) source-window)))))

(ert-deftest ejn-panel-window-respects-explicit-no-window-rule ()
  (ejn-panel-window-test--with-source
    (let ((display-buffer-alist
           '(("\\`\\*ejn:" display-buffer-no-window (allow-no-window . t)))))
      (should-not (emacs-jupyter-notebook-panel--display panel))
      (should-not (get-buffer-window panel t))
      (should (eq (window-buffer source-window) source)))))

(ert-deftest ejn-panel-window-follow-ignores-hidden-or-killed-panel ()
  (ejn-panel-window-test--with-source
    (let ((display-buffer-overriding-action 'display-buffer-same-window))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (&rest _) (ert-fail "Following tried to display a buffer"))))
        (emacs-jupyter-notebook-panel--source-post-command)
        (emacs-jupyter-notebook-panel--source-post-command t)
        (emacs-jupyter-notebook-panel-resume-follow)
        (should-not (get-buffer-window panel t))
        (kill-buffer panel)
        (emacs-jupyter-notebook-panel--source-post-command)
        (emacs-jupyter-notebook-panel-resume-follow)
        (should-not (emacs-jupyter-notebook-panel--display panel))
        (should-not (emacs-jupyter-notebook-panel-buffer source)))
      (should (eq (window-buffer source-window) source))
      (should (= (length (window-list)) 1)))))

(ert-deftest ejn-panel-window-follow-keeps-hidden-source-hidden ()
  (ejn-panel-window-test--with-source
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (handle (ejn-panel-start-entry panel key "print(42)"))
           (window (emacs-jupyter-notebook-panel--display panel)))
      (ejn-panel-finish-entry handle 'ok 1)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-selected-window window
        (delete-other-windows)
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (&rest _) (ert-fail "Following reopened the source"))))
          (emacs-jupyter-notebook-panel-resume-follow))
        (should (eq (selected-window) window))
        (should-not (get-buffer-window source t))
        (should (= (length (window-list)) 1))
        (should (= (window-start window)
                   (car (emacs-jupyter-notebook-panel--entry-bounds
                         (plist-get handle :id)))))))))

(ert-deftest ejn-panel-window-follow-updates-visible-panel-without-displaying ()
  (ejn-panel-window-test--with-source
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (handle (ejn-panel-start-entry panel key "print(42)"))
           (window (emacs-jupyter-notebook-panel--display panel)))
      (ejn-panel-append-text handle "42\n")
      (ejn-panel-finish-entry handle 'ok 1)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel (goto-char (point-max)))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (&rest _) (ert-fail "Following invoked display rules"))))
        (emacs-jupyter-notebook-panel--source-post-command))
      (should (eq (selected-window) source-window))
      (with-current-buffer panel
        (should (= (window-start window)
                   (car (emacs-jupyter-notebook-panel--entry-bounds
                         (plist-get handle :id)))))))))

(ert-deftest ejn-panel-window-explicit-visit-opens-hidden-source ()
  (ejn-panel-window-test--with-source
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (handle (ejn-panel-start-entry panel key "print(42)"))
           (window (emacs-jupyter-notebook-panel--display panel)))
      (ejn-panel-finish-entry handle 'ok 1)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-selected-window window
        (delete-other-windows)
        (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds
                         (plist-get handle :id))))
        (should-not (get-buffer-window source t))
        (emacs-jupyter-notebook-panel-visit-source)
        (should (eq (window-buffer (selected-window)) source))
        (should (= (point) (point-min)))))))

(ert-deftest ejn-panel-window-source-visit-survives-malformed-display-action ()
  (dolist (hidden '(nil t))
    (ejn-panel-window-test--with-source
      (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
             (handle (ejn-panel-start-entry panel key "print(42)"))
             (window (emacs-jupyter-notebook-panel--display panel)))
        (ejn-panel-finish-entry handle 'ok 1)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-selected-window window
          (when hidden (delete-other-windows))
          (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds
                           (plist-get handle :id))))
          (let ((display-buffer-overriding-action 'display-buffer-same-window))
            (emacs-jupyter-notebook-panel-visit-source))
          (should (eq (window-buffer (selected-window)) source))
          (should (= (point) (point-min))))))))

(ert-deftest ejn-panel-window-display-errors-do-not-block-execution-dispatch ()
  (dolist (failure '(malformed unavailable))
    (ejn-panel-window-test--with-source
      (let ((emacs-jupyter-notebook-check-code-completeness nil)
            (display-buffer-overriding-action 'display-buffer-same-window)
            (original-display (symbol-function 'display-buffer))
            (original-timers (copy-sequence timer-list))
            (original-processes (process-list))
            executions)
        (setq emacs-jupyter-notebook--client
              (emacs-jupyter-notebook-backend-session-create nil source))
        (cl-letf (((symbol-function 'display-buffer)
                   (if (eq failure 'unavailable)
                       (lambda (&rest _) (error "No usable window"))
                     original-display))
                  ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                   (lambda (success _failure &optional _profile _announce)
                     (funcall success nil)))
                  ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                   (lambda (_client code _options _success _failure)
                     (push code executions)
                     123)))
          (unwind-protect
              (let* ((id (emacs-jupyter-notebook--evaluate-code "print(42)" nil))
                     (record (emacs-jupyter-notebook--execution-record id))
                     (handle (plist-get record :panel-entry))
                     (context (list :buffer source :entry-handle handle
                                    :request-id id :backend-request-id 123
                                    :panel-generation (plist-get record :generation))))
                (should (equal executions '("print(42)")))
                (should (eq (plist-get record :state) 'dispatched))
                (should (equal emacs-jupyter-notebook--execution-active-id id))
                (ejn-panel-append-text handle "42\n")
                (emacs-jupyter-notebook--execution-note-event
                 context '(:type execute-reply :status "ok" :execution-count 1))
                (emacs-jupyter-notebook--execution-note-event
                 context '(:type status :execution-state "idle"))
                (should-not emacs-jupyter-notebook--execution-active-id)
                (should-not emacs-jupyter-notebook--execution-queue)
                (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status) 'ok))
                (emacs-jupyter-notebook-panel-flush-now panel)
                (with-current-buffer panel
                  (should (string-match-p "42" (buffer-string))))
                (should (eq (selected-window) source-window)))
            ;; The fake backend owns no transport, while the real FIFO and
            ;; panel still own timers that must be disposed on assertion failure.
            (setq emacs-jupyter-notebook--client nil)
            (emacs-jupyter-notebook--release-local-resources)
            (emacs-jupyter-notebook--kill-panel)
            (should-not (cl-set-difference (process-list) original-processes))
            (should-not (cl-remove-if
                         (lambda (timer)
                           (eq (timer--function timer) #'undo-auto--boundary-timer))
                         (cl-set-difference timer-list original-timers)))))))))

(provide 'emacs-jupyter-notebook-panel-window-tests)
;;; emacs-jupyter-notebook-panel-window-tests.el ends here
