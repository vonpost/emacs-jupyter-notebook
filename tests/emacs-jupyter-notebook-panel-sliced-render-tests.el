;;; emacs-jupyter-notebook-panel-sliced-render-tests.el --- Bounded panel rendering tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Deterministic tests for the timer-sliced full panel renderer.  These tests
;; drive its timer callback directly so they do not depend on GUI redisplay,
;; Jupyter, SSH, or wall-clock timing.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-result)

(defun ejn-sliced-render-test--source ()
  "Create a disposable source buffer for one panel test."
  (generate-new-buffer " *ejn-sliced-render-source*"))

(defun ejn-sliced-render-test--cleanup (source)
  "Kill SOURCE and any panel it owns."
  (when (buffer-live-p source)
    (kill-buffer source)))

(defun ejn-sliced-render-test--cancel-timer (panel)
  "Cancel PANEL's current sliced-render timer without retiring its job."
  (with-current-buffer panel
    (when (timerp emacs-jupyter-notebook-panel--sliced-render-timer)
      (cancel-timer emacs-jupyter-notebook-panel--sliced-render-timer))
    (setq emacs-jupyter-notebook-panel--sliced-render-timer nil)))

(defun ejn-sliced-render-test--start (panel)
  "Run PANEL's pending throttle flush and return its active render token."
  (with-current-buffer panel
    (when (timerp emacs-jupyter-notebook-panel--flush-timer)
      (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
    (setq emacs-jupyter-notebook-panel--flush-timer nil))
  (emacs-jupyter-notebook-panel--flush panel)
  (with-current-buffer panel
    (should emacs-jupyter-notebook-panel--sliced-render-job)
    emacs-jupyter-notebook-panel--sliced-render-generation))

(defun ejn-sliced-render-test--drain (panel &optional limit)
  "Synchronously drive PANEL's live render generation to completion.
LIMIT protects the test suite from an accidental non-progressing state
machine."
  (let ((remaining (or limit 20000)))
    (while (with-current-buffer panel
             emacs-jupyter-notebook-panel--sliced-render-job)
      (should (> remaining 0))
      (cl-decf remaining)
      (let ((token (with-current-buffer panel
                     emacs-jupyter-notebook-panel--sliced-render-generation)))
        (ejn-sliced-render-test--cancel-timer panel)
        (emacs-jupyter-notebook-panel--sliced-render-tick panel token)))))

(defun ejn-sliced-render-test--property-runs (panel property)
  "Return (VALUE . WIDTH) runs for PROPERTY in PANEL."
  (with-current-buffer panel
    (let ((position (point-min))
          (limit (point-max))
          runs)
      (while (< position limit)
        (let ((next (next-single-property-change position property nil limit)))
          (push (cons (get-text-property position property) (- next position)) runs)
          (setq position next)))
      (nreverse runs))))

(defun ejn-sliced-render-test--wait-for-dead-process (process)
  "Run timers briefly until PROCESS exits, or fail after a bounded wait."
  (let ((remaining 100))
    (while (and (process-live-p process) (> remaining 0))
      (cl-decf remaining)
      (sleep-for 0.01))
    (should-not (process-live-p process))))

(ert-deftest ejn-panel-sliced-render-first-tick-is-bounded-and-continuable ()
  "A scheduled full render writes only a bounded prefix in its first idle tick."
  (let ((source (ejn-sliced-render-test--source))
        inserted-bytes)
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel '("source.py" . 1) "cell"))
               (text (make-string (* 24 1024) ?x))
               real-insert token)
          (setq real-insert
                (symbol-function
                 'emacs-jupyter-notebook-panel--sliced-render-insert-text))
          (ejn-panel-append-text handle text)
          (setq token (ejn-sliced-render-test--start panel))
          (ejn-sliced-render-test--cancel-timer panel)
          (cl-letf (((symbol-function
                      'emacs-jupyter-notebook-panel--sliced-render-insert-text)
                     (lambda (piece index)
                       (push (string-bytes piece) inserted-bytes)
                       (funcall real-insert piece index))))
            (emacs-jupyter-notebook-panel--sliced-render-tick panel token))
          (with-current-buffer panel
            (should emacs-jupyter-notebook-panel--sliced-render-job)
            (should (timerp emacs-jupyter-notebook-panel--sliced-render-timer))
            (should (memq emacs-jupyter-notebook-panel--sliced-render-timer
                          timer-list))
            (should-not (memq emacs-jupyter-notebook-panel--sliced-render-timer
                              timer-idle-list))
            (should inserted-bytes)
            (should (<= (apply #'+ inserted-bytes)
                        emacs-jupyter-notebook-panel--sliced-render-max-text-bytes))
            (should (< (length (buffer-string))
                       (+ (length text) 200))))
          (ejn-sliced-render-test--drain panel)
          (with-current-buffer panel
            (should (string-match-p text (buffer-string))))
          ;; A subsequent structural rebuild has an existing large view to
          ;; retire.  Its first tick may only delete the immutable small
          ;; prefix, not call `erase-buffer' on the whole retained history.
          (ejn-panel-start-entry panel '("source.py" . 2) "second")
          (setq token (ejn-sliced-render-test--start panel))
          (let ((before (with-current-buffer panel (buffer-size))))
            (ejn-sliced-render-test--cancel-timer panel)
            (emacs-jupyter-notebook-panel--sliced-render-tick panel token)
            (with-current-buffer panel
              (should (= (buffer-size)
                         (- before
                            (min before
                                 emacs-jupyter-notebook-panel--sliced-render-max-clear-characters)))))))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-sliced-render-ordinary-dirty-work-falls-back-to-slices ()
  "Scheduled non-suffix, coalesced, and oversized dirty work never reinserts sync."
  (let ((source (ejn-sliced-render-test--source)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (first (ejn-panel-start-entry panel '("source.py" . 1) "first"))
               (second (ejn-panel-start-entry panel '("source.py" . 2) "second")))
          (ejn-panel-append-text first "old first")
          (ejn-panel-append-text second "old second")
          (emacs-jupyter-notebook-panel-flush-now panel)
          ;; Header/status replacement is not a suffix patch and must begin a
          ;; regular sliced full render before deleting/reinserting an entry.
          (ejn-panel-set-entry-status first 'ok)
          (ejn-sliced-render-test--start panel)
          (with-current-buffer panel
            (should emacs-jupyter-notebook-panel--sliced-render-job)
            (should (string-match-p "\\[running\\] first" (buffer-string))))
          (with-current-buffer panel
            (emacs-jupyter-notebook-panel--cancel-sliced-render))
          ;; Two dirty ids are coalesced work, never a loop of synchronous
          ;; entry replacements.
          (ejn-panel-set-entry-status first 'running)
          (ejn-panel-set-entry-status second 'ok)
          (ejn-sliced-render-test--start panel)
          (with-current-buffer panel
            (should emacs-jupyter-notebook-panel--sliced-render-job))
          (with-current-buffer panel
            (emacs-jupyter-notebook-panel--cancel-sliced-render))
          ;; The normal stream fast path accepts one small suffix only.  Two
          ;; 64 KiB chunks must decline before `mapconcat' can allocate them.
          (ejn-panel-append-text first
                                 (make-string
                                  emacs-jupyter-notebook-panel--sliced-render-max-text-bytes
                                  ?a))
          (ejn-panel-append-text first
                                 (make-string
                                  emacs-jupyter-notebook-panel--sliced-render-max-text-bytes
                                  ?b))
          (with-current-buffer panel
            (let* ((entry (emacs-jupyter-notebook-panel--entry
                           panel (plist-get first :id)))
                   (bounds (emacs-jupyter-notebook-panel--entry-bounds
                            (plist-get first :id))))
              (should bounds)
              (cl-letf (((symbol-function 'mapconcat)
                         (lambda (&rest _)
                           (error "oversized suffix was materialized"))))
                (should-not
                 (emacs-jupyter-notebook-panel--render-stream-suffix
                  entry bounds
                  emacs-jupyter-notebook-panel--sliced-render-max-text-bytes)))))
          (ejn-sliced-render-test--start panel)
          (with-current-buffer panel
            (should emacs-jupyter-notebook-panel--sliced-render-job)))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-sliced-render-admits-at-most-one-image-per-tick ()
  "A full-render slice never inserts more than one image segment."
  (let ((source (ejn-sliced-render-test--source)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel '("source.py" . 1) "plots"))
               (token nil)
               (calls 0)
               (remaining 20)
               (real-insert
                (symbol-function 'emacs-jupyter-notebook-panel--insert-image)))
          (ejn-panel-set-image handle '(image :type png :data "one"))
          (ejn-panel-set-image handle '(image :type png :data "two"))
          (setq token (ejn-sliced-render-test--start panel))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--insert-image)
                     (lambda (&rest args)
                       (cl-incf calls)
                       (apply real-insert args))))
            ;; Advance through the empty-buffer/header setup until this tick
            ;; reaches the first image.  The same tick must block before the
            ;; second one even though its logical-operation budget remains.
            (while (and (= calls 0) (> remaining 0))
              (cl-decf remaining)
              (ejn-sliced-render-test--cancel-timer panel)
              (emacs-jupyter-notebook-panel--sliced-render-tick panel token))
            (should (= calls 1))
            (with-current-buffer panel
              (should emacs-jupyter-notebook-panel--sliced-render-job)
              (should (timerp emacs-jupyter-notebook-panel--sliced-render-timer)))
            (ejn-sliced-render-test--cancel-timer panel)
            (emacs-jupyter-notebook-panel--sliced-render-tick panel token)
            (should (= calls 2))))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-sliced-render-mutation-retires-stale-generation ()
  "A stream mutation cannot let an older timer callback overwrite new state."
  (let ((source (ejn-sliced-render-test--source)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel '("source.py" . 1) "cell"))
               (old-text (make-string (* 16 1024) ?a))
               (old-token nil)
               before-stale-tick)
          (ejn-panel-append-text handle old-text)
          (setq old-token (ejn-sliced-render-test--start panel))
          (ejn-sliced-render-test--cancel-timer panel)
          (emacs-jupyter-notebook-panel--sliced-render-tick panel old-token)
          (dotimes (index 3)
            (ejn-panel-append-text handle (format "fresh-%d" index)))
          (with-current-buffer panel
            (should (/= old-token emacs-jupyter-notebook-panel--sliced-render-generation))
            (should-not emacs-jupyter-notebook-panel--sliced-render-job)
            (setq before-stale-tick (buffer-string)))
          ;; A callback that escaped `cancel-timer' has no authority after the
          ;; generation change and must be a no-op.
          (emacs-jupyter-notebook-panel--sliced-render-tick panel old-token)
          (with-current-buffer panel
            (should (equal before-stale-tick (buffer-string))))
          (ejn-sliced-render-test--start panel)
          (ejn-sliced-render-test--drain panel)
          (with-current-buffer panel
            (should (string-match-p old-text (buffer-string)))
            (dotimes (index 3)
              (should (string-match-p (format "fresh-%d" index)
                                      (buffer-string))))))
      (ejn-sliced-render-test--cleanup source))))

(defun ejn-sliced-render-test--populate (panel)
  "Create representative interleaved output in PANEL and return its handles."
  (let ((first (ejn-panel-start-entry panel '("source.py" . 10) "first()"))
        (second (ejn-panel-start-entry panel nil "region()")))
    (ejn-panel-append-text first "before image\n")
    ;; Inline previews are disabled by the caller, so this exercises the
    ;; lightweight placeholder path without requiring a graphical display.
    (ejn-panel-set-image first '(image :type png :data "test image bytes"))
    (ejn-panel-append-text first "after image")
    (ejn-panel-append-text second "history text")
    (list first second)))

(ert-deftest ejn-panel-sliced-render-matches-sync-history-placeholder-output ()
  "A completed sliced history render has the same text and properties as sync."
  (let ((source-a (ejn-sliced-render-test--source))
        (source-b (ejn-sliced-render-test--source))
        (emacs-jupyter-notebook-panel-max-inline-images 0))
    (unwind-protect
        (let* ((sync (ejn-panel-ensure source-a))
               (async (ejn-panel-ensure source-b)))
          (with-current-buffer sync
            (setq emacs-jupyter-notebook-panel--view 'history))
          (with-current-buffer async
            (setq emacs-jupyter-notebook-panel--view 'history))
          (ejn-sliced-render-test--populate sync)
          (ejn-sliced-render-test--populate async)
          (emacs-jupyter-notebook-panel-flush-now sync)
          (ejn-sliced-render-test--start async)
          (ejn-sliced-render-test--drain async)
          (should (equal (with-current-buffer sync (buffer-string))
                         (with-current-buffer async (buffer-string))))
          (dolist (property '(emacs-jupyter-notebook-entry-id
                              emacs-jupyter-notebook-cell-key
                              emacs-jupyter-notebook-text-segment-index
                              emacs-jupyter-notebook-segment-index))
            (should (equal (ejn-sliced-render-test--property-runs sync property)
                           (ejn-sliced-render-test--property-runs async property))))
          (with-current-buffer async
            (should (= (length emacs-jupyter-notebook-panel--inline-image-specs) 0))
            (should (string-match-p "\\[png image," (buffer-string)))))
      (ejn-sliced-render-test--cleanup source-a)
      (ejn-sliced-render-test--cleanup source-b))))

(ert-deftest ejn-panel-sliced-render-header-keeps-first-nonempty-code-line ()
  "The bounded header scan retains normal first-nonempty-line semantics."
  (let ((source (ejn-sliced-render-test--source)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel '("source.py" . 1)
                                              "\n\nprint('first')\nprint('second')")))
          (ignore handle)
          (ejn-sliced-render-test--start panel)
          (ejn-sliced-render-test--drain panel)
          (with-current-buffer panel
            (should (string-match-p "print('first')" (buffer-string)))
            (should-not (string-match-p "print('second')" (buffer-string)))))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-sliced-render-header-bounds-leading-newline-scan ()
  "Pathological leading newlines cannot turn a header into a large insertion."
  (let* ((code (concat
                (make-string
                 (1+ emacs-jupyter-notebook-panel--header-scan-max-characters)
                 ?\n)
                "print('unscanned')"))
         (header
          (emacs-jupyter-notebook-panel--format-header
           (list :id 1 :code code :status 'running :exec-count "*" :timestamp ""))))
    (should (= (cl-count ?\n header) 1))
    (should-not (string-match-p "unscanned" header))))

(ert-deftest ejn-panel-sliced-render-kill-cancels-timer-and-retires-artifacts ()
  "Killing a panel cancels its timer slice and releases its owned image files."
  (let ((source (ejn-sliced-render-test--source))
        panel timer directory)
    (unwind-protect
        (progn
          (setq panel (ejn-panel-ensure source))
          (let ((handle (ejn-panel-start-entry panel '("source.py" . 1) "plot")))
            (ejn-panel-set-image handle '(image :type png :data "image payload")))
          (ejn-sliced-render-test--start panel)
          (with-current-buffer panel
            (setq timer emacs-jupyter-notebook-panel--sliced-render-timer
                  directory emacs-jupyter-notebook-panel--image-directory)
            (should (timerp timer))
            (should (file-directory-p directory)))
          (kill-buffer panel)
          (should-not (memq timer timer-idle-list))
          (should-not (memq timer timer-list))
          (should-not (file-exists-p directory)))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-inline-image-data-rejects-before-private-file-write ()
  "Oversized direct image data is rejected before it allocates an artifact."
  (let ((source (ejn-sliced-render-test--source)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure source))
               (handle (ejn-panel-start-entry panel '("source.py" . 1) "plot"))
               (payload
                (make-string
                 (1+ emacs-jupyter-notebook-panel--max-inline-image-data-bytes)
                 ?x)))
          (should-error
           (ejn-panel-set-image handle `(image :type png :data ,payload)))
          (with-current-buffer panel
            (should-not emacs-jupyter-notebook-panel--image-directory)
            (should-not
             (plist-get
              (emacs-jupyter-notebook-panel--entry
               panel (plist-get handle :id))
              :outputs))))
      (ejn-sliced-render-test--cleanup source))))

(ert-deftest ejn-panel-external-opener-watchdog-kills-only-its-hung-child ()
  "A timed-out opener is reaped once without touching a newer opener child."
  (let ((slow-command '("sh" "-c" "sleep 2"))
        (first nil)
        (replacement nil)
        (first-watchdog nil)
        (deletes 0))
    (unwind-protect
        (let ((real-delete-process (symbol-function 'delete-process)))
          (cl-letf (((symbol-function 'delete-process)
                     (lambda (process)
                       (when (eq process first) (cl-incf deletes))
                       (funcall real-delete-process process))))
            (cl-letf (((symbol-value
                        'emacs-jupyter-notebook-panel--external-opener-timeout)
                       0.02))
              (setq first
                    (emacs-jupyter-notebook-panel--spawn-external-opener
                     slow-command "/tmp/ejn-first-image"))
              (setq first-watchdog
                    (process-get
                     first
                     'emacs-jupyter-notebook-panel--external-opener-watchdog)))
            ;; The replacement gets its own token and later watchdog.  The
            ;; expired first timer must not kill it or manipulate any state it
            ;; would share with an independently retained image snapshot.
            (cl-letf (((symbol-value
                        'emacs-jupyter-notebook-panel--external-opener-timeout)
                       0.5))
              (setq replacement
                    (emacs-jupyter-notebook-panel--spawn-external-opener
                     slow-command "/tmp/ejn-replacement-image")))
            (ejn-sliced-render-test--wait-for-dead-process first)
            (should (= deletes 1))
            (should (process-live-p replacement))
            (should-not (memq first-watchdog timer-list))
            (should-not (memq first-watchdog timer-idle-list))))
      (when (and (processp first) (process-live-p first))
        (delete-process first))
      (when (and (processp replacement) (process-live-p replacement))
        (delete-process replacement)))))

(ert-deftest ejn-panel-external-opener-early-exit-cancels-its-watchdog-once ()
  "A normal opener exit cancels its watchdog and disposes its child once."
  (let ((command '("sh" "-c" "exit 0"))
        process watchdog (deletes 0))
    (unwind-protect
        (let ((real-delete-process (symbol-function 'delete-process)))
          (cl-letf (((symbol-function 'delete-process)
                     (lambda (current)
                       (when (eq current process) (cl-incf deletes))
                       (funcall real-delete-process current))))
            (setq process
                  (emacs-jupyter-notebook-panel--spawn-external-opener
                   command "/tmp/ejn-early-exit-image"))
            (setq watchdog
                  (process-get
                   process
                   'emacs-jupyter-notebook-panel--external-opener-watchdog))
            (ejn-sliced-render-test--wait-for-dead-process process)
            (should (= deletes 1))
            (should-not (memq watchdog timer-list))
            (should-not (memq watchdog timer-idle-list))))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))))

(ert-deftest ejn-panel-external-opener-timer-setup-failure-reaps-child ()
  "Failure to arm an opener watchdog kills that exact already-started child."
  (let ((command '("sh" "-c" "sleep 2"))
        process (deletes 0))
    (unwind-protect
        (let ((real-make-process (symbol-function 'make-process))
              (real-delete-process (symbol-function 'delete-process)))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq process (apply real-make-process args))))
                    ((symbol-function 'delete-process)
                     (lambda (current)
                       (when (eq current process) (cl-incf deletes))
                       (funcall real-delete-process current)))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _)
                       (error "injected watchdog setup failure"))))
            (should-error
             (emacs-jupyter-notebook-panel--spawn-external-opener
              command "/tmp/ejn-timer-setup-failure"))
            (should (processp process))
            (ejn-sliced-render-test--wait-for-dead-process process)
            (should (= deletes 1))))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))))

(ert-deftest ejn-panel-original-verifier-timer-setup-failure-reaps-child ()
  "Failure to arm verifier timeout settles callback and reaps its child."
  (let ((process (make-process
                  :name (generate-new-buffer-name "ejn-test-image-verify")
                  :command '("sh" "-c" "sleep 2")
                  :connection-type 'pipe :noquery t))
        (callbacks nil)
        (deletes 0))
    (unwind-protect
        (let ((real-delete-process (symbol-function 'delete-process)))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_program) "/bin/true"))
                    ((symbol-function
                      'emacs-jupyter-notebook-panel--artifact-verifier-script)
                     (lambda () "/tmp/fake-ejn-artifact-verifier.py"))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) process))
                    ((symbol-function 'delete-process)
                     (lambda (current)
                       (when (eq current process) (cl-incf deletes))
                       (funcall real-delete-process current)))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _)
                       (error "injected verifier watchdog setup failure"))))
            (should-error
             (emacs-jupyter-notebook-panel--verify-original-async
              '(:root-identity (2 . 1) :identity (4 . 3)
                :root "/tmp/source" :file "/tmp/source/image.png"
                :size 8 :sha256 "abcd")
              '(:root "/tmp/destination" :file "/tmp/destination/image.png")
              (lambda (valid) (push valid callbacks))))
            (should (equal callbacks '(nil)))
            (should (= deletes 1))
            (ejn-sliced-render-test--wait-for-dead-process process)))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))))

(ert-deftest ejn-panel-snapshot-registration-publishes-only-after-timer ()
  "A failed expiry timer cannot publish an immortal external snapshot."
  (let ((emacs-jupyter-notebook-panel--external-image-snapshots nil)
        (snapshot (list :root "/tmp/snapshot" :file "/tmp/snapshot/image.png"
                        :root-identity '(1 . 2)
                        :artifact-capability 'capability))
        (metadata '(:sha256 "abcd" :size 8)))
    (cl-letf (((symbol-function
                'emacs-jupyter-notebook-panel--published-artifact-metadata)
               (lambda (&rest _) 'verified-artifact))
              ((symbol-function 'run-at-time)
               (lambda (&rest _)
                 (error "injected snapshot expiry setup failure"))))
      (should-error
       (emacs-jupyter-notebook-panel--register-external-image-snapshot
        snapshot metadata))
      (should-not emacs-jupyter-notebook-panel--external-image-snapshots)
      (should (eq (plist-get snapshot :artifact) 'verified-artifact))
      (should-not (plist-get snapshot :timer)))))

(provide 'emacs-jupyter-notebook-panel-sliced-render-tests)
;;; emacs-jupyter-notebook-panel-sliced-render-tests.el ends here
