;;; emacs-jupyter-notebook-array-panel-tests.el --- Numerical panel ownership -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-events)
(require 'emacs-jupyter-notebook-helper-backend)

(defvar ejn-array-test--leases nil)

(defmacro ejn-array-test--with-panel (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((source (generate-new-buffer " *ejn-array-source*"))
          (panel (ejn-panel-ensure source))
          (cap (emacs-jupyter-notebook-artifacts-create 'helper))
          (root (emacs-jupyter-notebook-artifacts-capability-root cap))
          (key '("test.py" . 1))
          (handle (ejn-panel-start-entry panel key "ejn.view(planes)"))
          (ejn-array-test--leases nil))
     (unwind-protect
         (progn
           (with-current-buffer source
             (insert "# %%\nejn.view(planes)\n")
             (set-buffer-modified-p nil))
           ,@body)
       (dolist (lease ejn-array-test--leases)
         (when lease (funcall (plist-get lease :release))))
       (when (buffer-live-p panel) (kill-buffer panel))
       (when (buffer-live-p source) (kill-buffer source))
       (emacs-jupyter-notebook-artifacts-retire cap))))

(defun ejn-array-test--publication (root index &optional display-id)
  (let* ((file (expand-file-name (format "ejn-artifact-%032x" index) root))
         (manifest (json-parse-string
                    (format
                     "{\"v\":1,\"key\":\"reconstruction\",\"sample_id\":\"case/slice-2\",\"publication_id\":\"%032x\",\"planes\":[{\"id\":\"0\",\"name\":\"prediction\",\"shape\":[2,3],\"dtype\":\"<u2\",\"offset\":0,\"nbytes\":12,\"units\":\"HU\"}]}"
                     index)))
         (payload "test-owned numerical artifact: never decode in Emacs"))
    ;; The trusted helper validates file contents. This fixture deliberately
    ;; cannot be parsed as an array, proving that the panel uses metadata only.
    (with-temp-file file (insert payload))
    (set-file-modes file #o600)
    (list :root root :root-identity (file-attribute-file-identifier
                                   (file-attributes root 'integer))
          :path file :size (string-bytes payload) :sha256 (secure-hash 'sha256 payload)
          :manifest manifest :display-id display-id)))

(defun ejn-array-test--acquire (handle &optional id)
  (let ((lease (ejn-panel-acquire-array handle id)))
    (when lease (push lease ejn-array-test--leases))
    lease))

(ert-deftest ejn-array-panel-multiple-publications-have-exact-inspect-buttons ()
  (ejn-array-test--with-panel
    (let ((first (ejn-array-test--publication root 1))
          (second (ejn-array-test--publication root 2)) inspected)
      (should (ejn-panel-set-published-array handle first))
      (ejn-panel-append-text handle "between\n")
      (should (ejn-panel-set-published-array handle second))
      (should (equal (mapcar #'car (plist-get (ejn-panel-entry-snapshot handle) :outputs))
                     '(array text array)))
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (goto-char (point-min))
        (should (search-forward "2 × 3  <u2  HU" nil t))
        (should (search-forward "[Inspect]" nil t))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-publication)
                   (lambda (lease) (setq inspected lease)
                     (push lease ejn-array-test--leases))))
          (button-activate (button-at (1- (point)))))
        (should (equal (plist-get inspected :file) (plist-get first :path)))
        (goto-char (point-min))
        (search-forward "prediction")
        (let ((lease (emacs-jupyter-notebook-panel-acquire-array-at-point)))
          (push lease ejn-array-test--leases)
          (should (equal (plist-get lease :file) (plist-get first :path)))))
      (should (equal (plist-get (ejn-array-test--acquire handle) :file)
                     (plist-get second :path))))))

(ert-deftest ejn-array-panel-admission-render-acquire-never-read-array-or-change-source ()
  (ejn-array-test--with-panel
    (let* ((publication (ejn-array-test--publication root 3))
           (file (plist-get publication :path))
           (reader (symbol-function 'insert-file-contents))
           (literal (symbol-function 'insert-file-contents-literally))
           (before (with-current-buffer source (buffer-string))))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (path &rest args)
                   (should-not (equal path file)) (apply reader path args)))
                ((symbol-function 'insert-file-contents-literally)
                 (lambda (path &rest args)
                   (should-not (equal path file)) (apply literal path args))))
        (should (ejn-panel-set-published-array handle publication))
        (emacs-jupyter-notebook-panel-flush-now panel)
        (should (ejn-array-test--acquire handle)))
      (with-current-buffer source
        (should (equal before (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-deftest ejn-array-panel-current-cell-never-falls-back-to-previous-evaluation ()
  (ejn-array-test--with-panel
    (ejn-panel-set-published-array handle (ejn-array-test--publication root 4))
    (let ((lease (emacs-jupyter-notebook-panel-acquire-array-for-cell source key)))
      (should lease) (push lease ejn-array-test--leases))
    (let ((new (ejn-panel-start-entry panel key "new evaluation")))
      (should-not (emacs-jupyter-notebook-panel-acquire-array-for-cell source key))
      (ejn-panel-append-text new "no image\n")
      (should-not (emacs-jupyter-notebook-panel-acquire-array-for-cell source key))
      (ejn-panel-set-published-array new (ejn-array-test--publication root 5))
      (let ((lease (emacs-jupyter-notebook-panel-acquire-array-for-cell source key)))
        (push lease ejn-array-test--leases)
        (should (equal (plist-get lease :publication-id) (format "%032x" 5)))))))

(ert-deftest ejn-array-panel-display-update-replaces-only-matched-publication ()
  (ejn-array-test--with-panel
    (let* ((first (ejn-array-test--publication root 6 "left"))
           (second (ejn-array-test--publication root 7 "right")))
      (ejn-panel-set-published-array handle first)
      (let ((old (ejn-array-test--acquire handle)))
        (ejn-panel-set-published-array handle second)
        (let* ((next (ejn-panel-start-entry panel nil "update"))
               (update (ejn-array-test--publication root 8 "left")))
          (should (equal (ejn-panel-set-published-array next update t) handle))
          (should (= 2 (length (plist-get (ejn-panel-entry-snapshot handle) :outputs))))
          (should-not (plist-get (ejn-panel-entry-snapshot next) :outputs))
          (should (file-exists-p (plist-get first :path)))
          (funcall (plist-get old :release))
          (should-not (file-exists-p (plist-get first :path)))
          (should (file-exists-p (plist-get second :path)))
          (should (file-exists-p (plist-get update :path))))))))

(ert-deftest ejn-array-panel-clear-wait-preserves-until-next-publication ()
  (ejn-array-test--with-panel
    (let ((first (ejn-array-test--publication root 9 "image")))
      (ejn-panel-set-published-array handle first)
      (ejn-panel-clear-entry handle t)
      (should (file-exists-p (plist-get first :path)))
      (ejn-panel-set-published-array handle (ejn-array-test--publication root 10 "image") t)
      (should-not (file-exists-p (plist-get first :path)))
      (should (= 1 (length (plist-get (ejn-panel-entry-snapshot handle) :outputs))))
      (ejn-panel-clear-entry handle t)
      (ejn-panel-append-text handle "replacement")
      (should-not (ejn-array-test--acquire handle)))))

(ert-deftest ejn-array-panel-handoff-survives-panel-kill-and-helper-retirement ()
  (ejn-array-test--with-panel
    (let ((publication (ejn-array-test--publication root 11)))
      (ejn-panel-set-published-array handle publication)
      (let ((lease (ejn-array-test--acquire handle)))
        (emacs-jupyter-notebook-artifacts-retire cap)
        (kill-buffer panel)
        (should (file-exists-p (plist-get publication :path)))
        (funcall (plist-get lease :release))
        (funcall (plist-get lease :release))
        (should-not (file-exists-p (plist-get publication :path)))))))

(ert-deftest ejn-array-panel-retention-counts-numerical-bytes-and-deferred-leases ()
  (ejn-array-test--with-panel
    (let ((publication (ejn-array-test--publication root 12)))
      (ejn-panel-set-published-array handle publication)
      (let ((lease (ejn-array-test--acquire handle))
            (emacs-jupyter-notebook-panel-max-total-artifact-bytes 1))
        (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
        (should-not (ejn-panel-entry-live-p handle))
        (should (file-exists-p (plist-get publication :path)))
        (with-current-buffer panel
          (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes 0))
          (should (= emacs-jupyter-notebook-panel--retained-output-segments 0)))
        (funcall (plist-get lease :release))
        (should-not (file-exists-p (plist-get publication :path)))))))

(ert-deftest ejn-array-panel-evicted-handoff-survives-later-panel-kill ()
  (ejn-array-test--with-panel
    (let ((publication (ejn-array-test--publication root 18)))
      (ejn-panel-set-published-array handle publication)
      (let ((first (ejn-array-test--acquire handle))
            (second (ejn-array-test--acquire handle))
            (emacs-jupyter-notebook-panel-max-total-artifact-bytes 1))
        (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
        (kill-buffer panel)
        (emacs-jupyter-notebook-artifacts-retire cap)
        (should (file-exists-p (plist-get publication :path)))
        (funcall (plist-get first :release))
        (should (file-exists-p (plist-get publication :path)))
        (funcall (plist-get second :release))
        (should-not (file-exists-p (plist-get publication :path)))))))

(ert-deftest ejn-array-panel-raster-after-pending-clear-retires-array ()
  (ejn-array-test--with-panel
    (let* ((publication (ejn-array-test--publication root 19))
           (image-file (ejn-array-test--publication root 20))
           (image (list :root root :root-identity (plist-get image-file :root-identity)
                        :mime "image/png" :preview nil
                        :original (list :path (plist-get image-file :path)
                                        :size (plist-get image-file :size)
                                        :sha256 (plist-get image-file :sha256)))))
      (ejn-panel-set-published-array handle publication)
      (ejn-panel-clear-entry handle t)
      (should (ejn-panel-set-published-bundle handle image nil nil))
      (should-not (file-exists-p (plist-get publication :path)))
      (should (equal (mapcar #'car (plist-get (ejn-panel-entry-snapshot handle) :outputs))
                     '(image))))))

(ert-deftest ejn-array-panel-sliced-render-includes-card-with-bounded-text-work ()
  (ejn-array-test--with-panel
    (ejn-panel-set-published-array handle (ejn-array-test--publication root 21))
    (emacs-jupyter-notebook-panel--start-sliced-render panel)
    (with-current-buffer panel
      (let ((steps 0))
        (while (and emacs-jupyter-notebook-panel--sliced-render-job (< steps 10))
          (cl-incf steps)
          (when (timerp emacs-jupyter-notebook-panel--sliced-render-timer)
            (cancel-timer emacs-jupyter-notebook-panel--sliced-render-timer))
          (emacs-jupyter-notebook-panel--sliced-render-tick
           panel emacs-jupyter-notebook-panel--sliced-render-generation))
        (should-not emacs-jupyter-notebook-panel--sliced-render-job)
        (should (string-match-p "full source resolution" (buffer-string)))))))

(ert-deftest ejn-array-panel-segment-budget-discards-extra-publication ()
  (ejn-array-test--with-panel
    (let ((emacs-jupyter-notebook-panel--hard-entry-output-segments 2)
          (first (ejn-array-test--publication root 13))
          (second (ejn-array-test--publication root 14)))
      (ejn-panel-set-published-array handle first)
      (ejn-panel-set-published-array handle second)
      (should (file-exists-p (plist-get first :path)))
      (should-not (file-exists-p (plist-get second :path)))
      (should (equal (mapcar #'car (plist-get (ejn-panel-entry-snapshot handle) :outputs))
                     '(array text))))))

(ert-deftest ejn-array-panel-bounded-handoffs-and-idempotent-release ()
  (ejn-array-test--with-panel
    (ejn-panel-set-published-array handle (ejn-array-test--publication root 15))
    (let* ((emacs-jupyter-notebook-panel--max-array-handoffs 2)
           (first (ejn-array-test--acquire handle))
           (second (ejn-array-test--acquire handle)))
      (should-error (ejn-array-test--acquire handle) :type 'user-error)
      (funcall (plist-get first :release))
      (funcall (plist-get first :release))
      (should (= emacs-jupyter-notebook-panel--array-handoff-count 1))
      (funcall (plist-get second :release))
      (should (= emacs-jupyter-notebook-panel--array-handoff-count 0)))))

(ert-deftest ejn-array-panel-late-publication-is-not-admitted-after-clear ()
  (ejn-array-test--with-panel
    (let ((publication (ejn-array-test--publication root 16)))
      (ejn-panel-clear-all panel)
      (should-not (ejn-panel-set-published-array handle publication))
      (should (file-exists-p (plist-get publication :path)))
      (should-not (ejn-array-test--acquire handle)))))

(ert-deftest ejn-array-panel-events-admit-arrays-and-retain-interleaved-result-text ()
  (ejn-array-test--with-panel
    (let ((publication (ejn-array-test--publication root 17)))
      (should (emacs-jupyter-notebook-events--render-display
               (list :entry-handle handle) (list :ejn-published-array publication) 'display))
      (emacs-jupyter-notebook-events--render-display
       (list :entry-handle handle) '(:text/plain "scores") 'result)
      (should (equal (mapcar #'car (plist-get (ejn-panel-entry-snapshot handle) :outputs))
                     '(array text)))
      (should (ejn-array-test--acquire handle)))))

(ert-deftest ejn-array-panel-dispatch-rejection-discards-unowned-helper-publication ()
  (ejn-array-test--with-panel
    (let* ((publication (ejn-array-test--publication root 26 "unknown-display"))
           (path (plist-get publication :path))
           (context (list :buffer source :entry-handle handle))
           (emit-count 0)
           (dispatch-result 'not-called)
           before-outputs
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :artifact-dir root :artifact-capability cap
                   :artifact-identity (plist-get publication :root-identity)
                   :emit (lambda (envelope)
                           (cl-incf emit-count)
                           (setq dispatch-result
                                 (emacs-jupyter-notebook-events-dispatch
                                  context (plist-get envelope :event))))))
           (raw (emacs-jupyter-notebook-helper-backend--make-object
                 "event" "update_display_data"
                 "data" (emacs-jupyter-notebook-helper-backend--make-object
                         "data" (emacs-jupyter-notebook-helper-backend--make-object
                                 "application/x-ejn-array-group"
                                 (emacs-jupyter-notebook-helper-backend--make-object
                                  "path" path "bytes" (plist-get publication :size)
                                  "sha256" (plist-get publication :sha256)
                                  "manifest" (plist-get publication :manifest)))
                         "metadata" (make-hash-table :test #'equal)
                         "transient" (emacs-jupyter-notebook-helper-backend--make-object
                                      "display_id" "unknown-display")))))
      (ejn-panel-append-text handle "retained text")
      (setq before-outputs (copy-tree (plist-get (ejn-panel-entry-snapshot handle) :outputs)))
      ;; The entry is live, so reduction produces a display action. Its
      ;; unknown display id is rejected only during application. Dispatch
      ;; must propagate that nil admission instead of accepting the action
      ;; list as ordinary text; only then can helper delivery retire the file.
      (should-not (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
                   state "helper-test-id" nil raw))
      (should (= emit-count 1))
      (should-not dispatch-result)
      (should-not (file-exists-p path))
      (should-not (ejn-array-test--acquire handle))
      (should (equal (plist-get (ejn-panel-entry-snapshot handle) :outputs)
                     before-outputs)))))

(ert-deftest ejn-array-panel-publication-hook-observes-only-committed-retained-output ()
  (ejn-array-test--with-panel
    (let ((calls nil)
          (ejn-panel-array-published-hook nil))
      (add-hook 'ejn-panel-array-published-hook
                (lambda (effective output-id)
                  (let ((lease (ejn-array-test--acquire effective output-id)))
                    (should lease)
                    (push (list effective output-id) calls))))
      (ejn-panel-set-published-array handle (ejn-array-test--publication root 22))
      (should (= (length calls) 1))
      (should (equal (caar calls) handle))
      (let ((emacs-jupyter-notebook-panel--hard-entry-output-segments 2))
        (ejn-panel-set-published-array handle (ejn-array-test--publication root 23)))
      (should (= (length calls) 1))
      (ejn-panel-clear-all panel)
      (should-not (ejn-panel-set-published-array handle (ejn-array-test--publication root 24)))
      (should (= (length calls) 1)))))

(ert-deftest ejn-array-panel-publication-hook-error-does-not-reject-owned-artifact ()
  (ejn-array-test--with-panel
    (let ((ejn-panel-array-published-hook (list (lambda (&rest _) (error "consumer failed"))))
          (publication (ejn-array-test--publication root 25)))
      (should (ejn-panel-set-published-array handle publication))
      (should (file-exists-p (plist-get publication :path)))
      (should (ejn-array-test--acquire handle)))))

(provide 'emacs-jupyter-notebook-array-panel-tests)
;;; emacs-jupyter-notebook-array-panel-tests.el ends here
