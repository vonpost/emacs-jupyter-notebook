;;; emacs-jupyter-notebook-output-cells-tests.el --- Cell output lifetime tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Local source edits, late panel events and visibility require no kernel.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-cell)
(require 'emacs-jupyter-notebook-result)

(defmacro ejn-output-cells-test--with-source (text &rest body)
  "Run BODY in a tracked Python source containing TEXT; dispose its panel."
  (declare (indent 1))
  `(with-temp-buffer
     (python-mode)
     (insert ,text)
     (goto-char (point-min))
     (emacs-jupyter-notebook-cell-tracking-enable)
     (unwind-protect (progn ,@body)
       (emacs-jupyter-notebook-cell-tracking-disable)
       (emacs-jupyter-notebook--kill-panel))))

(defun ejn-output-cells-test--key (text)
  "Return the identity of the source marker containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (emacs-jupyter-notebook--cell-key-for (line-beginning-position)))

(ert-deftest ejn-output-cells-delete-preserves-adjacent-cell-and-rejects-late-events ()
  (ejn-output-cells-test--with-source "# %% first\n1\n# %% second\n2\n"
    (let* ((first (ejn-output-cells-test--key "first"))
           (second (ejn-output-cells-test--key "second"))
           (panel (ejn-panel-ensure (current-buffer)))
           (one (ejn-panel-start-entry panel first "first"))
           (older (ejn-panel-start-entry panel first "old first"))
           (two (ejn-panel-start-entry panel second "second")))
      (ejn-panel-append-text one "deleted output")
      (ejn-panel-append-text two "surviving output")
      (emacs-jupyter-notebook-fringe-set first 'running)
      (emacs-jupyter-notebook-fringe-set second 'ok)
      (delete-region (point-min)
                     (marker-position
                      (gethash (cdr second) emacs-jupyter-notebook--cell-key-markers)))
      (should-not (ejn-panel-entry-live-p one))
      (should-not (ejn-panel-entry-live-p older))
      (should (ejn-panel-entry-live-p two))
      (should (equal second (emacs-jupyter-notebook--cell-key-for (point-min))))
      (ejn-panel-append-text one "late stream")
      (ejn-panel-finish-entry one 'ok 1)
      (should-not (emacs-jupyter-notebook-fringe-set first 'ok 1))
      (should-not (emacs-jupyter-notebook-fringe-overlay first))
      (should-not (ejn-panel-entry-live-p
                   (ejn-panel-start-entry panel first "late queued dispatch")))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (= (length emacs-jupyter-notebook-panel--entries) 1))
        (should-not (string-match-p (regexp-opt '("deleted output" "late stream"))
                                    (buffer-string)))
        (should (string-match-p "surviving output" (buffer-string)))))))

(ert-deftest ejn-output-cells-identity-survives-insertion-and-body-edit ()
  (ejn-output-cells-test--with-source "# %% first\n1\n# %% second\n2\n"
    (let* ((key (ejn-output-cells-test--key "second"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "second")))
      (goto-char (point-min))
      (insert "# %% new\n0\n")
      (should (equal key (ejn-output-cells-test--key "second")))
      (forward-line 1)
      (delete-region (point) (point-max))
      (insert "replacement body\n")
      (should (ejn-panel-entry-live-p handle))
      (should (equal key (ejn-output-cells-test--key "second"))))))

(ert-deftest ejn-output-cells-delete-implicit-first-cell ()
  (ejn-output-cells-test--with-source "initial = 1\n# %% next\n2\n"
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (next (ejn-output-cells-test--key "next"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "initial")))
      (delete-region (point-min) (line-beginning-position))
      (should-not (ejn-panel-entry-live-p handle))
      (should (equal next (emacs-jupyter-notebook--cell-key-for (point-min)))))))

(ert-deftest ejn-output-cells-marker-edit-and-newline-collapse-retire-only-lost-cell ()
  (ejn-output-cells-test--with-source "# %% first\n# %% second\n2\n"
    (let* ((first (ejn-output-cells-test--key "first"))
           (second (ejn-output-cells-test--key "second"))
           (panel (ejn-panel-ensure (current-buffer)))
           (one (ejn-panel-start-entry panel first "first"))
           (two (ejn-panel-start-entry panel second "second")))
      (beginning-of-line)
      (delete-char -1)
      (should (ejn-panel-entry-live-p one))
      (should-not (ejn-panel-entry-live-p two))
      (should (equal first (emacs-jupyter-notebook--cell-key-for (point-min))))
      (goto-char (point-min))
      (delete-char 1)
      (should-not (ejn-panel-entry-live-p one)))))

(ert-deftest ejn-output-cells-partial-boundary-collapse-does-not-alias-identities ()
  (ejn-output-cells-test--with-source "# %%\n# %%\n"
    (let* ((first (emacs-jupyter-notebook--cell-key-for (point-min)))
           (second (emacs-jupyter-notebook--cell-key-for 6))
           (panel (ejn-panel-ensure (current-buffer)))
           (one (ejn-panel-start-entry panel first "first"))
           (two (ejn-panel-start-entry panel second "second")))
      ;; Combine the first header's # and second header's %% into one valid
      ;; boundary.  Both original marker anchors now occupy that boundary.
      (delete-region 2 7)
      (should (equal (buffer-string) "# %%\n"))
      (should-not (ejn-panel-entry-live-p one))
      (should-not (ejn-panel-entry-live-p two))
      (let ((new (emacs-jupyter-notebook--cell-key-for (point-min))))
        (should-not (equal new first))
        (should-not (equal new second))))))

(ert-deftest ejn-output-cells-explicit-move-preserves-identities ()
  (ejn-output-cells-test--with-source "# %% first\n1\n# %% second\n2\n"
    (let* ((first (ejn-output-cells-test--key "first"))
           (second (ejn-output-cells-test--key "second"))
           (panel (ejn-panel-ensure (current-buffer)))
           (one (ejn-panel-start-entry panel first "first"))
           (two (ejn-panel-start-entry panel second "second")))
      (let ((emacs-jupyter-notebook--cell-moving-p t))
        (code-cells-move-cell-up 1))
      (should (ejn-panel-entry-live-p one))
      (should (ejn-panel-entry-live-p two))
      (should (equal first (ejn-output-cells-test--key "first")))
      (should (equal second (ejn-output-cells-test--key "second"))))))

(ert-deftest ejn-output-cells-toggle-source-and-panel-preserves-source-and-retention ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let* ((key (ejn-output-cells-test--key "first"))
           (source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel key "first"))
           (original (buffer-string)))
      (ejn-panel-append-text handle "visible output")
      (set-buffer-modified-p nil)
      (emacs-jupyter-notebook-toggle-cell-output)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (should (equal original (buffer-string)))
      (should-not (buffer-modified-p))
      (should (equal "visible output" (ejn-panel-entry-text handle)))
      (with-current-buffer panel
        (should (string-match-p "outputs hidden" (buffer-string)))
        (should-not (string-match-p "visible output" (buffer-string)))
        (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds
                         (plist-get handle :id))))
        (emacs-jupyter-notebook-toggle-cell-output))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "visible output" (buffer-string)))
        (should (= (emacs-jupyter-notebook-panel--entry-id-at-point)
                   (plist-get handle :id))))
      (should (equal original (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest ejn-output-cells-hidden-cell-stays-hidden-during-stream-and-reevaluation ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let* ((key (ejn-output-cells-test--key "first"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "first")))
      (ejn-panel-append-text handle "first stream")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (emacs-jupyter-notebook-toggle-cell-output)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (ejn-panel-append-text handle " later stream")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should-not (string-match-p "stream" (buffer-string))))
      (let ((new (ejn-panel-start-entry panel key "again")))
        (should (plist-get (ejn-panel-entry-snapshot new) :hidden))
        (ejn-panel-append-text new "new output")
        (with-current-buffer panel (emacs-jupyter-notebook-panel-toggle-view))
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-current-buffer panel
          (should-not (string-match-p (regexp-opt '("stream" "new output"))
                                      (buffer-string))))))))

(ert-deftest ejn-output-cells-panel-tab-bindings ()
  (dolist (key '("TAB" "<tab>"))
    (should (eq (lookup-key emacs-jupyter-notebook-panel-mode-map (kbd key))
                #'emacs-jupyter-notebook-toggle-cell-output))))

(ert-deftest ejn-output-cells-deletion-releases-artifacts-and-retention-counters ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let* ((key (ejn-output-cells-test--key "first"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "first"))
           timer file)
      (ejn-panel-append-text handle "retained text")
      (ejn-panel-set-image handle '(image :type png :data "image bytes"))
      (setq file (plist-get (cdr (car (ejn-panel-entry-images handle))) :file))
      (should (file-exists-p file))
      (setq timer (run-at-time 100 nil #'ignore))
      (unwind-protect
          (progn
            (emacs-jupyter-notebook-panel--mutate-live-entry
             handle (lambda (entry) (plist-put entry :pickle-open-timer timer)))
            (erase-buffer)
            (should-not (file-exists-p file))
            (should-not (memq timer timer-list))
            (ejn-panel-set-image handle '(image :type png :data "late image"))
            (with-current-buffer panel
              (should-not emacs-jupyter-notebook-panel--entries)
              (should (= emacs-jupyter-notebook-panel--retained-text-bytes 0))
              (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes 0))
              (should (= emacs-jupyter-notebook-panel--retained-output-segments 0))))
        (cancel-timer timer)))))

(ert-deftest ejn-output-cells-implicit-edit-survives-but-whole-replacement-does-not ()
  (ejn-output-cells-test--with-source "value = 1\n"
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "value")))
      (goto-char (point-min))
      (insert "# comment\n")
      (should (equal key (emacs-jupyter-notebook--cell-key-for (point-min))))
      (should (ejn-panel-entry-live-p handle))
      (erase-buffer)
      (insert "# %% replacement\n2\n")
      (should-not (ejn-panel-entry-live-p handle))
      (should-not (equal key (ejn-output-cells-test--key "replacement"))))))

(ert-deftest ejn-output-cells-new-boundary-retires-implicit-identity ()
  (ejn-output-cells-test--with-source "value = 1\n"
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point-min)))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "value")))
      (insert "# %% named\n")
      (should-not (ejn-panel-entry-live-p handle))
      (should-not (equal key (ejn-output-cells-test--key "named"))))))

(ert-deftest ejn-output-cells-disable-removes-hooks-and-never-reuses-ids ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let ((key (ejn-output-cells-test--key "first")))
      (emacs-jupyter-notebook-cell-tracking-disable)
      (should-not (memq #'emacs-jupyter-notebook--cell-before-change before-change-functions))
      (should-not (memq #'emacs-jupyter-notebook--cell-after-change after-change-functions))
      (should (emacs-jupyter-notebook--cell-key-retired-p key))
      (erase-buffer)
      (insert "# %% new\n2\n")
      (emacs-jupyter-notebook-cell-tracking-enable)
      (should-not (equal key (ejn-output-cells-test--key "new"))))))

(defun ejn-output-cells-test--drain-render (panel)
  "Drive PANEL's bounded renderer deterministically, cancelling every timer."
  (with-current-buffer panel
    (when (timerp emacs-jupyter-notebook-panel--flush-timer)
      (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
    (setq emacs-jupyter-notebook-panel--flush-timer nil)
    (emacs-jupyter-notebook-panel--flush panel)
    (let ((remaining 100))
      (while emacs-jupyter-notebook-panel--sliced-render-job
        (should (> remaining 0))
        (cl-decf remaining)
        (when (timerp emacs-jupyter-notebook-panel--sliced-render-timer)
          (cancel-timer emacs-jupyter-notebook-panel--sliced-render-timer))
        (emacs-jupyter-notebook-panel--sliced-render-tick
         panel emacs-jupyter-notebook-panel--sliced-render-generation)))))

(ert-deftest ejn-output-cells-sliced-render-hidden-body-and-retired-token ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let* ((key (ejn-output-cells-test--key "first"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel key "first"))
           (emacs-jupyter-notebook-panel--sliced-render-max-work-items 2)
           old-token)
      (ejn-panel-append-text handle "sliced body")
      (ejn-panel-set-image handle '(image :type png :data "image bytes"))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds
                         (plist-get handle :id))))
        (emacs-jupyter-notebook-toggle-cell-output))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--insert-image)
                 (lambda (&rest _) (ert-fail "Hidden image was rendered"))))
        (ejn-output-cells-test--drain-render panel))
      (with-current-buffer panel
        (should-not (string-match-p "sliced body" (buffer-string)))
        (should (= (emacs-jupyter-notebook-panel--entry-id-at-point)
                   (plist-get handle :id)))
        (emacs-jupyter-notebook-toggle-cell-output)
        (when (timerp emacs-jupyter-notebook-panel--flush-timer)
          (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
        (emacs-jupyter-notebook-panel--flush panel)
        (setq old-token emacs-jupyter-notebook-panel--sliced-render-generation)
        (should emacs-jupyter-notebook-panel--sliced-render-job))
      (erase-buffer)
      (emacs-jupyter-notebook-panel--sliced-render-tick panel old-token)
      (ejn-output-cells-test--drain-render panel)
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--entries)
        (should-not (string-match-p (regexp-opt '("sliced body" "first"))
                                    (buffer-string)))))))

(ert-deftest ejn-output-cells-region-output-toggle-is-independent ()
  (ejn-output-cells-test--with-source "# %% first\n1\n"
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (one (ejn-panel-start-entry panel nil "region one"))
           (two (ejn-panel-start-entry panel nil "region two")))
      (ejn-panel-append-text one "one body")
      (ejn-panel-append-text two "two body")
      (with-current-buffer panel (emacs-jupyter-notebook-panel-toggle-view))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (goto-char (car (emacs-jupyter-notebook-panel--entry-bounds (plist-get one :id))))
        (forward-line 1)
        (emacs-jupyter-notebook-toggle-cell-output))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should-not (string-match-p "one body" (buffer-string)))
        (should (string-match-p "two body" (buffer-string)))))))

(provide 'emacs-jupyter-notebook-output-cells-tests)
;;; emacs-jupyter-notebook-output-cells-tests.el ends here
