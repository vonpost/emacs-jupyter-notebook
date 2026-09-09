;;; emacs-jupyter-notebook-panel-ux-tests.el --- Output navigation and headers -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline tests for source-following windows and bounded presentation metadata.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-result)

(defmacro ejn-panel-ux-test--source (text &rest body)
  "Run BODY in a tracked source containing TEXT, disposing every panel timer."
  (declare (indent 1))
  `(with-temp-buffer
     (python-mode)
     (insert ,text)
     (goto-char (point-min))
     (emacs-jupyter-notebook-cell-tracking-enable)
     (unwind-protect (progn ,@body)
       (emacs-jupyter-notebook-cell-tracking-disable)
       (emacs-jupyter-notebook--kill-panel))))

(defun ejn-panel-ux-test--entry (label code)
  "Start an entry for the source cell with LABEL, executing CODE."
  (goto-char (point-min))
  (search-forward label)
  (let ((key (emacs-jupyter-notebook--cell-key-for (line-beginning-position))))
    (ejn-panel-start-entry (ejn-panel-ensure (current-buffer)) key code)))

(ert-deftest ejn-panel-ux-header-uses-cell-title-and-explicit-title ()
  (ejn-panel-ux-test--source "# %% Fit model\nmodel.fit(data)\n"
    (let* ((handle (ejn-panel-ux-test--entry "Fit model" "model.fit(data)"))
           (panel (plist-get handle :panel)))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "Fit model" (buffer-string)))
        (should-not (string-match-p "model.fit(data)" (buffer-string))))
      (let ((named (ejn-panel-start-entry panel nil "generated implementation" "Inspect image\nextra")))
        (ejn-panel-reveal-entry named)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-current-buffer panel
          (should (string-match-p "Inspect image" (buffer-string)))
          (should-not (string-match-p "generated implementation" (buffer-string)))
          (should-not (string-match-p "extra" (buffer-string))))))))

(ert-deftest ejn-panel-ux-edited-since-run-is-cell-local-and-source-stays-clean ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n# %% B\ny=2\n"
    (let* ((one (ejn-panel-ux-test--entry "A" "x=1\n"))
           (two (ejn-panel-ux-test--entry "B" "y=2\n"))
           (panel (plist-get one :panel)))
      (goto-char (point-min))
      (insert "# leading comment\n")
      (should-not (plist-get (ejn-panel-entry-snapshot one) :edited-since-run))
      (search-forward "x=1")
      (insert "+3")
      (should (plist-get (ejn-panel-entry-snapshot one) :edited-since-run))
      (should-not (plist-get (ejn-panel-entry-snapshot two) :edited-since-run))
      (let ((source (buffer-string)))
        (set-buffer-modified-p nil)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (should (equal (buffer-string) source))
        (should-not (buffer-modified-p)))
      (with-current-buffer panel
        (should (string-match-p "edited since run" (buffer-string))))
      (let ((new (ejn-panel-ux-test--entry "A" "x=1+3\n")))
        (should-not (plist-get (ejn-panel-entry-snapshot new) :edited-since-run))))))

(ert-deftest ejn-panel-ux-duration-excludes-queue-time-and-freezes-on-finish ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n"
    (let* ((now 10.0)
           (handle (ejn-panel-ux-test--entry "A" "x=1")))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now)))
        (ejn-panel-set-entry-status handle 'queued)
        (setq now 30.0)
        (ejn-panel-set-entry-status handle 'running)
        (setq now 32.5)
        (ejn-panel-finish-entry handle 'ok 1)
        (should (= 2.5 (plist-get (ejn-panel-entry-snapshot handle) :duration)))
        (setq now 100.0)
        (ejn-panel-finish-entry handle 'ok 1)
        (should (= 2.5 (plist-get (ejn-panel-entry-snapshot handle) :duration)))))))

(ert-deftest ejn-panel-ux-folded-summary-counts-retained-lines-and-images ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n"
    (let* ((handle (ejn-panel-ux-test--entry "A" "x=1"))
           (panel (plist-get handle :panel)))
      (ejn-panel-append-text handle "one\ntwo\n")
      (ejn-panel-set-image handle '(image :type png :data "image data"))
      (ejn-panel-append-text handle "three")
      (emacs-jupyter-notebook-toggle-cell-output)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--text-state-value)
                 (lambda (&rest _) (ert-fail "Fold summary materialized retained text"))))
        (emacs-jupyter-notebook-panel-flush-now panel))
      (with-current-buffer panel
        (should (string-match-p "3 lines" (buffer-string)))
        (should (string-match-p "1 image" (buffer-string)))
        (should-not (string-match-p "three" (buffer-string)))))))

(ert-deftest ejn-panel-ux-folded-error-retains-final-message ()
  (ejn-panel-ux-test--source "# %% Broken\nraise ValueError()\n"
    (let* ((handle (ejn-panel-ux-test--entry "Broken" "raise ValueError()"))
           (panel (plist-get handle :panel)))
      (ejn-panel-append-text handle "Traceback (most recent call last):\n  internal frames\nValueError: expected an image\n")
      (ejn-panel-finish-entry handle 'error 1)
      (emacs-jupyter-notebook-toggle-cell-output)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "ValueError: expected an image" (buffer-string)))
        (should-not (string-match-p "internal frames" (buffer-string)))))))

(ert-deftest ejn-panel-ux-nil-cell-evaluation-reveals-history-without-selecting-panel ()
  (save-window-excursion
    (ejn-panel-ux-test--source "print(1)\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((source-window (selected-window))
             (panel (ejn-panel-ensure (current-buffer)))
             (handle (ejn-panel-start-entry panel nil "print(1)"))
             (panel-window (display-buffer-in-side-window panel '((side . right) (window-width . 30)))))
        (ejn-panel-reveal-entry handle)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (should (eq source-window (selected-window)))
        (with-current-buffer panel
          (should (eq emacs-jupyter-notebook-panel--view 'history))
          (should (= (window-start panel-window)
                     (car (emacs-jupyter-notebook-panel--entry-bounds
                           (plist-get handle :id))))))))))

(ert-deftest ejn-panel-ux-source-follow-and-manual-scroll-pause ()
  (save-window-excursion
    (ejn-panel-ux-test--source "# %% A\nx=1\n# %% B\ny=2\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((one (ejn-panel-ux-test--entry "A" "x=1"))
             (two (ejn-panel-ux-test--entry "B" "y=2"))
             (panel (plist-get one :panel))
             (source-window (selected-window))
             (panel-window (display-buffer-in-side-window panel '((side . right) (window-width . 30)))))
        (ejn-panel-append-text one (make-string 100 ?a))
        (emacs-jupyter-notebook-panel-flush-now panel)
        (emacs-jupyter-notebook-panel--source-post-command)
        (with-current-buffer panel
          (should (= (window-start panel-window)
                     (car (emacs-jupyter-notebook-panel--entry-bounds
                           (plist-get two :id)))))
          (let ((this-command 'scroll-up-command))
            (emacs-jupyter-notebook-panel--window-scrolled panel-window (point-min)))
          (should emacs-jupyter-notebook-panel--follow-paused))
        (emacs-jupyter-notebook-panel--source-post-command)
        (with-current-buffer panel (should emacs-jupyter-notebook-panel--follow-paused))
        (goto-char (point-min))
        (emacs-jupyter-notebook-panel--source-post-command)
        (should (eq source-window (selected-window)))
        (with-current-buffer panel
          (should-not emacs-jupyter-notebook-panel--follow-paused)
          (should (= (window-start panel-window)
                     (car (emacs-jupyter-notebook-panel--entry-bounds
                           (plist-get one :id))))))))))

(ert-deftest ejn-panel-ux-region-reveal-survives-evaluation-post-command ()
  (save-window-excursion
    (ejn-panel-ux-test--source "# %% A\nx=1\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((cell (ejn-panel-ux-test--entry "A" "x=1"))
             (panel (plist-get cell :panel))
             (region (ejn-panel-start-entry panel nil "x + 1"))
             (window (display-buffer-in-side-window panel '((side . right)))))
        (ejn-panel-reveal-entry region)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (emacs-jupyter-notebook-panel--source-post-command)
        (with-current-buffer panel
          (should (= (window-start window)
                     (car (emacs-jupyter-notebook-panel--entry-bounds
                           (plist-get region :id))))))))))

(ert-deftest ejn-panel-ux-reading-position-survives-earlier-stream-redraw ()
  (save-window-excursion
    (ejn-panel-ux-test--source "# %% A\nx=1\n# %% B\ny=2\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((one (ejn-panel-ux-test--entry "A" "x=1"))
             (two (ejn-panel-ux-test--entry "B" "y=2"))
             (panel (plist-get one :panel))
             (source-window (selected-window))
             (window (display-buffer-in-side-window panel '((side . right)))))
        (ejn-panel-append-text one "Earlier output\n")
        (ejn-panel-append-text two "Reading this line\nand this line\n")
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-current-buffer panel
          (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds (plist-get two :id))))
          (forward-line 1)
          (set-window-start window (point) t)
          (forward-char 4)
          (set-window-point window (point))
          (emacs-jupyter-notebook-panel--pause-follow))
        (ejn-panel-append-text one "More streaming output before B\n")
        (emacs-jupyter-notebook-panel-flush-now panel)
        (should (eq source-window (selected-window)))
        (with-current-buffer panel
          (should emacs-jupyter-notebook-panel--follow-paused)
          (save-excursion
            (goto-char (window-start window))
            (should (looking-at "Reading this line")))
          (should (= 4 (- (window-point window) (window-start window)))))))))

(ert-deftest ejn-panel-ux-sliced-redraw-preserves-reading-and-render-order ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n# %% B\ny=2\n"
    (let* ((one (ejn-panel-ux-test--entry "A" "x=1"))
           (two (ejn-panel-ux-test--entry "B" "y=2"))
           (panel (plist-get one :panel)))
      (ejn-panel-append-text one (concat (make-string 20000 ?a) "\n"))
      (ejn-panel-append-text two "Reading this\n")
      (ejn-panel-finish-entry one 'ok 1)
      (ejn-panel-finish-entry two 'ok 2)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (let ((expected (buffer-string)) (ticks 0))
          (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds (plist-get two :id))))
          (forward-line 1)
          (emacs-jupyter-notebook-panel--pause-follow)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--sliced-render-arm) #'ignore))
            (emacs-jupyter-notebook-panel--start-sliced-render panel)
            (while (and emacs-jupyter-notebook-panel--sliced-render-job (< ticks 100))
              ;; A reader can move point between any two timer callbacks.
              (goto-char (point-min))
              (emacs-jupyter-notebook-panel--sliced-render-tick
               panel emacs-jupyter-notebook-panel--sliced-render-generation)
              (cl-incf ticks)))
          (should (> ticks 3))
          (should-not emacs-jupyter-notebook-panel--sliced-render-job)
          (should (equal (buffer-string) expected))
          (should (looking-at "Reading this")))))))

(ert-deftest ejn-panel-ux-duration-tick-only-touches-header-and-clear-cancels-it ()
  (save-window-excursion
    (ejn-panel-ux-test--source "# %% A\nx=1\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((handle (ejn-panel-ux-test--entry "A" "x=1"))
             (panel (plist-get handle :panel))
             (now (+ 12.5 (plist-get (ejn-panel-entry-snapshot handle) :started-at))))
        (display-buffer-in-side-window panel '((side . right)))
        (ejn-panel-append-text handle (make-string 20000 ?a))
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-current-buffer panel
          (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds (plist-get handle :id))))
          (forward-line 1)
          (forward-char 7)
          (emacs-jupyter-notebook-panel--pause-follow))
        (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                  ((symbol-function 'emacs-jupyter-notebook-panel--schedule-render)
                   (lambda (&rest _) (ert-fail "Duration scheduled a body redraw")))
                  ((symbol-function 'emacs-jupyter-notebook-panel--text-state-value)
                   (lambda (&rest _) (ert-fail "Duration materialized retained text"))))
          (emacs-jupyter-notebook-panel--duration-tick panel))
        (with-current-buffer panel
          (should (string-match-p "12.5s" (buffer-string)))
          (should (timerp emacs-jupyter-notebook-panel--duration-timer))
          (should-not emacs-jupyter-notebook-panel--sliced-render-job)
          (should (= 7 (current-column)))
          (should (eq ?a (char-after))))
        (ejn-panel-clear-all panel)
        (with-current-buffer panel
          (should-not emacs-jupyter-notebook-panel--duration-timer)
          (should-not emacs-jupyter-notebook-panel--reveal-entry-id))))))

(ert-deftest ejn-panel-ux-fold-summary-counts-after-carriage-return-and-retention ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n"
    (let ((handle (ejn-panel-ux-test--entry "A" "x=1"))
          (emacs-jupyter-notebook-result-max-bytes 200))
      (dolist (text '("old line\nprogress 1" "\rprogress 2\n" "done\n"))
        (ejn-panel-append-text handle text))
      (should (equal "3 lines" (emacs-jupyter-notebook-panel--folded-summary
                                (ejn-panel-entry-snapshot handle))))
      ;; Retention removes old chunks and can split the retained first line.
      (ejn-panel-append-text handle (apply #'concat (make-list 50 "new line\n")))
      (let* ((entry (ejn-panel-entry-snapshot handle))
             (state (cdar (plist-get entry :outputs)))
             (text (emacs-jupyter-notebook-panel--text-state-value
                    (car (plist-get entry :outputs)))))
        (should (= (plist-get state :newlines)
                   (cl-count ?\n text)))
        (should (equal (format "%d lines" (cl-count ?\n text))
                       (emacs-jupyter-notebook-panel--folded-summary entry)))))))

(ert-deftest ejn-panel-ux-stale-header-updates-with-pending-stream ()
  (ejn-panel-ux-test--source "# %% A\nx=1\n"
    (let* ((handle (ejn-panel-ux-test--entry "A" "x=1"))
           (panel (plist-get handle :panel)))
      (ejn-panel-append-text handle "initial\n")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (ejn-panel-append-text handle "pending\n")
      (search-forward "x=1")
      (insert "+1")
      (ejn-panel-append-text handle "later\n")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "edited since run" (buffer-string)))
        (should (string-match-p "initial\npending" (buffer-string)))))))

(provide 'emacs-jupyter-notebook-panel-ux-tests)
;;; emacs-jupyter-notebook-panel-ux-tests.el ends here
