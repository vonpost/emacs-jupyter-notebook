;;; emacs-jupyter-notebook-workflow-integration-tests.el --- Exploration integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-array-panel-tests)

(ert-deftest ejn-workflow-capture-addresses-existing-view-without-evaluation ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook-mode t)
    (let* ((source (current-buffer))
           (workspaces (list (list :workspace "source/other" :source source :cell-key '(source . 2))
                             (list :workspace "source/input-and-prediction" :source source
                                   :cell-key '(source . 1))))
           called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key)
                 (lambda () '(source . 1)))
                ((symbol-function 'emacs-jupyter-notebook-inspect-workspaces)
                 (lambda () workspaces))
                ((symbol-function 'emacs-jupyter-notebook-inspect-control)
                 (lambda (op params &optional existing-only &rest _)
                   (setq called (list op (gethash "workspace" params) existing-only))))
                ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) (ert-fail "Capture must not execute code")))
                ((symbol-function 'ejn-panel-acquire-array)
                 (lambda (&rest _) (ert-fail "Capture must use the displayed samples"))))
        (emacs-jupyter-notebook-capture-finding))
      (should (equal called '("capture" "source/input-and-prediction" t))))))

(ert-deftest ejn-workflow-capture-never-falls-back-to-another-notebook ()
  (let ((other (generate-new-buffer " *other-notebook*")))
    (unwind-protect
        (with-temp-buffer
          (setq-local emacs-jupyter-notebook-mode t)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key)
                     (lambda () '(source . 1)))
                    ((symbol-function 'emacs-jupyter-notebook-inspect-workspaces)
                     (lambda () (list (list :source other :workspace "other/images"))))
                    ((symbol-function 'emacs-jupyter-notebook-inspect-control)
                     (lambda (&rest _) (ert-fail "No viewer action should be sent"))))
            (should-error (emacs-jupyter-notebook-capture-finding) :type 'user-error)))
      (kill-buffer other))))

(ert-deftest ejn-workflow-findings-review-does-not-require-source-or-kernel ()
  (with-temp-buffer
    (let (called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-control)
                 (lambda (op params &optional existing-only &rest _)
                   (setq called (list op (hash-table-count params) existing-only))))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (&rest _) (ert-fail "Review must not connect to a kernel"))))
        (emacs-jupyter-notebook-review-findings))
      (should (equal called '("findings" 0 nil))))))

(ert-deftest ejn-workflow-display-update-keeps-producing-execution-context ()
  "Updating an old output uses the new producer's code for saved context."
  (ejn-array-test--with-panel
    (let* ((next (ejn-panel-start-entry panel nil "prediction = model_b(volume)"))
           (original (list :id 1 :code "prediction = model_a(volume)"
                           :cell-key key :panel-entry handle))
           (updated (list :id 2 :code "prediction = model_b(volume)"
                          :cell-key nil :panel-entry next)))
      (with-current-buffer source
        (setq-local emacs-jupyter-notebook--session-entry '(:session-id "kernel-1"))
        (dolist (record (list original updated))
          (emacs-jupyter-notebook-history-record-created record)
          (emacs-jupyter-notebook-history-record-dispatched record)))
      (ejn-panel-set-published-array handle (ejn-array-test--publication root 901 "image"))
      (ejn-panel-set-published-array next (ejn-array-test--publication root 902 "image") t)
      (let* ((lease (ejn-array-test--acquire handle))
             (params (emacs-jupyter-notebook-inspect--params lease t))
             (context (gethash "context" params))
             (entries (gethash "entries" context)))
        (should (equal (plist-get lease :entry-handle) handle))
        (should (equal (plist-get lease :execution-handle) next))
        (should (= (gethash "target_id" context) 2))
        (should (equal (gethash "code" (aref entries (1- (length entries))))
                       "prediction = model_b(volume)"))))))

(ert-deftest ejn-workflow-queue-records-exact-code-and-admission-before-terminal ()
  "The real reservation/dispatch path survives edits and settled outputs."
  (with-temp-buffer
    (python-mode)
    (insert "# %%\ncheckpoint = 'A'\n")
    (emacs-jupyter-notebook-mode 1)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                   (lambda (_client code _context _success _failure)
                     (should (equal code "checkpoint = 'A'")) "wire-1")))
          (let* ((id (emacs-jupyter-notebook--evaluate-code
                      "checkpoint = 'A'" (emacs-jupyter-notebook--current-cell-key)))
                 (entry (emacs-jupyter-notebook-history--record id)))
            (erase-buffer)
            (insert "checkpoint = 'B'\n")
            (should-not (plist-get entry :submitted-at))
            (setq emacs-jupyter-notebook--execution-active-id id
                  emacs-jupyter-notebook--client 'test-client
                  emacs-jupyter-notebook--session-entry '(:session-id "test-kernel"))
            (emacs-jupyter-notebook--execution-put
             (plist-put (emacs-jupyter-notebook--execution-record id) :state 'checking))
            (emacs-jupyter-notebook--execution-dispatch
             (emacs-jupyter-notebook--execution-record id))
            (should (numberp (plist-get entry :submitted-at)))
            (should (equal (plist-get entry :session-id) "test-kernel"))
            (emacs-jupyter-notebook--execution-finish
             (emacs-jupyter-notebook--execution-record id) 'error 7)
            (should (equal (plist-get entry :code) "checkpoint = 'A'"))
            (should (eq (plist-get entry :status) 'error))
            (should (= (plist-get entry :execution-count) 7))
            (should (equal (buffer-string) "checkpoint = 'B'\n"))))
      (setq emacs-jupyter-notebook--client nil)
      (emacs-jupyter-notebook-mode -1)
      (emacs-jupyter-notebook--kill-panel))))

(ert-deftest ejn-workflow-confirmed-restart-advances-history-identity-exactly-once ()
  "A confirmed terminal boundary advances history even if replacement fails."
  (with-temp-buffer
    (let* ((client 'workflow-client)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'restart-shutdown :origin-buffer (current-buffer)
                     :entry '(:session-id "same-session" :remote-pid 1234
                              :registry-revision "current-revision"
                              :transition-token "workflow-transition"
                              :remote-connection-file "/cache/kernel.json")
                     :restart-client client :restart-epoch 7
                     :restart-shutdown-sent t))
           (retired 0) failure)
      (setq emacs-jupyter-notebook--async-context context
            emacs-jupyter-notebook--client client
            emacs-jupyter-notebook--execution-setup-pending t
            emacs-jupyter-notebook--execution-setup-epoch 7)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--lifecycle-retire-local-transport)
                 (lambda (_client)
                   ;; History identity changes before old transport is retired.
                   (should (= emacs-jupyter-notebook-history--kernel-epoch 1))
                   (cl-incf retired)))
                ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                 (lambda (&rest _) (error "simulated persistence failure")))
                ((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (_context reason) (setq failure reason))))
        (emacs-jupyter-notebook--restart-shutdown-confirmed context client 7)
        (should (string-match-p "simulated persistence failure" failure))
        (should (= emacs-jupyter-notebook-history--kernel-epoch 1))
        (should (= retired 1))
        ;; Keep the same transport and context live to exercise the explicit
        ;; duplicate guard, rather than relying on teardown to fence the call.
        (emacs-jupyter-notebook--restart-shutdown-confirmed context client 7)
        (should (= emacs-jupyter-notebook-history--kernel-epoch 1))
        (should (= retired 1))))))

(ert-deftest ejn-workflow-unconfirmed-and-stale-restarts-preserve-history-identity ()
  "Failed preflight, ambiguous shutdown, and stale confirmations cannot reset history."
  (with-temp-buffer
    (let* ((client 'workflow-client)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'restart-preflight :origin-buffer (current-buffer)
                     :entry '(:session-id "same-session" :remote-pid 1234)
                     :restart-client client :restart-epoch 7))
           (new (emacs-jupyter-notebook--async-new-context
                 :phase 'retrieve :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context
            emacs-jupyter-notebook--client client
            emacs-jupyter-notebook--execution-setup-pending t
            emacs-jupyter-notebook--execution-setup-epoch 7)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-setup-finish) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--lifecycle-retire-local-transport) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--log-append) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                 (lambda (&rest _) (ert-fail "Stale confirmation attempted a registry write"))))
        (emacs-jupyter-notebook--restart-failed context "preflight failed")
        (should (= emacs-jupyter-notebook-history--kernel-epoch 0))
        (setq context (emacs-jupyter-notebook--async-put context :restart-shutdown-sent t))
        (emacs-jupyter-notebook--restart-failed context "shutdown reply lost")
        (should (= emacs-jupyter-notebook-history--kernel-epoch 0))
        ;; Mismatched client/epoch and a superseded or terminal context are
        ;; all inert even if an old shutdown callback eventually arrives.
        (emacs-jupyter-notebook--restart-shutdown-confirmed context 'other-client 7)
        (emacs-jupyter-notebook--restart-shutdown-confirmed context client 6)
        (setq emacs-jupyter-notebook--async-context new)
        (emacs-jupyter-notebook--restart-shutdown-confirmed context client 7)
        (setq emacs-jupyter-notebook--async-context context)
        (setf (plist-get context :phase) 'error)
        (emacs-jupyter-notebook--restart-shutdown-confirmed context client 7)
        (should (= emacs-jupyter-notebook-history--kernel-epoch 0))))))

(defmacro ejn-workflow--with-org-overview (&rest body)
  "Provide a private local overview path and reclaim its buffers after BODY."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "ejn-org-overview-" t))
          (path (expand-file-name "findings.org" directory))
          (result (emacs-jupyter-notebook-inspect--object "path" path)))
     (unwind-protect
         (progn
           (with-temp-file path
             (insert "#+title: Saved findings\n\n* First observation\nCaptured: yesterday\n"
                     "[[file:0123456789abcdef0123456789abcdef/overview.png]]\n\n"
                     "** Context\n#+begin_example\nmodel = A\n#+end_example\n"
                     "* Second observation\nCaptured: today\n** Context\nmodel = B\n"))
           (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil))
                     ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
             ,@body))
       (dolist (buffer (buffer-list))
         (when-let ((file (buffer-local-value 'buffer-file-name buffer)))
           (when (string-prefix-p (file-name-as-directory directory) file)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (delete-directory directory t))))

(ert-deftest ejn-workflow-org-generation-defers-opening-and-never-contacts-kernel ()
  "A completed local generation opens only after its original UI context is free."
  (let ((origin (generate-new-buffer " *overview-origin*"))
        (other (generate-new-buffer " *overview-other*")) callback opened)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer origin)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-control)
                     (lambda (operation params &optional existing-only ready)
                       (should (equal operation "findings_org"))
                       (should (= (hash-table-count params) 0))
                       (should-not existing-only)
                       (setq callback ready)))
                    ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (&rest _) (ert-fail "An overview must not connect to a kernel")))
                    ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                     (lambda (&rest _) (ert-fail "An overview must not execute code")))
                    ((symbol-function 'emacs-jupyter-notebook-findings--open-overview)
                     (lambda (value) (setq opened value))))
            (emacs-jupyter-notebook-findings-overview)
            (should (functionp callback))
            ;; A slow generation must not steal whichever buffer was selected
            ;; while the worker ran; presentation remains owned by ORIGIN.
            (switch-to-buffer other)
            (funcall callback 'overview-result)
            (should-not opened)
            (should-not (buffer-local-value 'emacs-jupyter-notebook-ui--pending other))
            (let ((pending (car (buffer-local-value 'emacs-jupyter-notebook-ui--pending origin))))
              (should pending)
              (should (timerp (plist-get (cdr pending) :timer)))
              (switch-to-buffer origin)
              (emacs-jupyter-notebook-ui--run origin pending)
              (should (eq opened 'overview-result))
              (should-not emacs-jupyter-notebook-ui--pending))))
      (dolist (buffer (list origin other))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (emacs-jupyter-notebook-ui-cancel))
          (kill-buffer buffer))))))

(ert-deftest ejn-workflow-org-opens-readonly-with-observations-visible-and-context-folded ()
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)))
      (with-current-buffer buffer
        (should (derived-mode-p 'org-mode))
        (should buffer-read-only)
        (should-not (buffer-modified-p))
        (goto-char (point-min))
        (search-forward "Captured: yesterday")
        (should-not (outline-invisible-p (1- (point))))
        (search-forward "model = A")
        (should (outline-invisible-p (1- (point))))
        (search-forward "Captured: today")
        (should-not (outline-invisible-p (1- (point))))
        (search-forward "model = B")
        (should (outline-invisible-p (1- (point))))))))

(ert-deftest ejn-workflow-org-rejects-remote-input-without-invoking-file-handlers ()
  "Even probing a remote-looking result must not call TRAMP or file handlers."
  (let ((file-name-handler-alist
         (list (cons "/ssh:" (lambda (&rest _) (ert-fail "A remote handler was invoked"))))))
    (cl-letf (((symbol-function 'find-file-noselect)
               (lambda (&rest _) (ert-fail "A rejected path was visited"))))
      (should-error
       (emacs-jupyter-notebook-findings--open-overview
        (emacs-jupyter-notebook-inspect--object "path" "/ssh:example.invalid:/tmp/findings.org"))
       :type 'user-error))))

(ert-deftest ejn-workflow-org-rejects-symlinks-special-files-and-oversized-documents ()
  (ejn-workflow--with-org-overview
    (let ((target (expand-file-name "actual.org" directory)))
      (rename-file path target)
      (make-symbolic-link target path)
      (should-error (emacs-jupyter-notebook-findings--open-overview result) :type 'user-error)
      (delete-file path)
      (rename-file target path))
    (let* ((attributes (file-attributes path))
           (special (copy-sequence attributes))
           (oversized (copy-sequence attributes)))
      ;; Emacs reports nil type for a FIFO as well as a regular file.  Such
      ;; a path must be rejected before visiting can block on its reader.
      (setf (nth 8 special) "prw-------")
      (setf (nth 7 oversized) (1+ (* 8 1024 1024)))
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest _) (ert-fail "An inadmissible overview was opened"))))
        (cl-letf (((symbol-function 'file-attributes) (lambda (&rest _) special))
                  ((symbol-function 'file-regular-p) (lambda (&rest _) nil)))
          (should-error (emacs-jupyter-notebook-findings--open-overview result) :type 'user-error))
        (cl-letf (((symbol-function 'file-attributes) (lambda (&rest _) oversized)))
          (should-error (emacs-jupyter-notebook-findings--open-overview result) :type 'user-error))))))

(ert-deftest ejn-workflow-org-refreshes-an-unmodified-overview-in-place ()
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)))
      (with-temp-file path (insert "* Newly captured finding\nChanged note\n** Context\nnew_model()\n"))
      (should (eq buffer (emacs-jupyter-notebook-findings--open-overview result)))
      (with-current-buffer buffer
        (should (string-match-p "Newly captured finding" (buffer-string)))
        (should-not (string-match-p "First observation" (buffer-string)))
        (should buffer-read-only)
        (should-not (buffer-modified-p))))))

(ert-deftest ejn-workflow-org-unsaved-edits-block-generation-and-late-replacement ()
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)) draft)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "My unsaved observation\n"))
        (setq draft (buffer-string)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-control)
                 (lambda (&rest _) (ert-fail "Generation would overwrite an unsaved overview"))))
        (with-temp-buffer
          (should-error (emacs-jupyter-notebook-findings-overview) :type 'user-error)))
      ;; This models a generation already in flight when the user edited the
      ;; overview: the ACK must not revert the newly modified buffer.
      (with-temp-file path (insert "* Generated replacement\n"))
      (should-error (emacs-jupyter-notebook-findings--open-overview result) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) draft))
        (should (buffer-modified-p))))))

(ert-deftest ejn-workflow-org-save-copy-becomes-editable-and-allows-regeneration ()
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result))
          (copy (expand-file-name "report.org" directory)) called)
      (with-current-buffer buffer
        (write-file copy)
        (should (equal buffer-file-name copy))
        (should (derived-mode-p 'org-mode))
        (should-not buffer-read-only)
        (should-not emacs-jupyter-notebook-findings--overview)
        (goto-char (point-max))
        (insert "Report draft\n"))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-inspect-control)
                 (lambda (&rest _) (setq called t))))
        (with-temp-buffer (emacs-jupyter-notebook-findings-overview)))
      (should called)
      (let ((generated (emacs-jupyter-notebook-findings--open-overview result)))
        (should-not (eq generated buffer))
        (with-current-buffer generated
          (should buffer-read-only)
          (should-not (string-match-p "Report draft" (buffer-string))))))))

(ert-deftest ejn-workflow-org-previews-decode-only-visible-images-and-release-offscreen ()
  "A large collection retains one bounded set of real Org image overlays."
  (ejn-workflow--with-org-overview
    (with-temp-file path
      (dotimes (i 1000)
        (insert (format "* Finding %d\n[[file:%032x/overview.png]]\n" i i))))
    (let* ((buffer (emacs-jupyter-notebook-findings--open-overview result))
           (file-exists (symbol-function 'file-exists-p))
           start end decoded flushed)
      (save-window-excursion
        (switch-to-buffer buffer)
        (let ((window (selected-window)))
          (with-current-buffer buffer
            (setq start (point-min)
                  end (save-excursion (goto-char start) (forward-line 40) (point))))
          ;; Keep Org's link parser and image overlay creation real.  Only
          ;; the image decoder and the viewport geometry need a GUI stand-in.
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                    ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'window-start)
                     (lambda (target) (should (eq target window)) start))
                    ((symbol-function 'window-end)
                     (lambda (target &optional _) (should (eq target window)) end))
                    ((symbol-function 'file-exists-p)
                     (lambda (file)
                       (or (string-suffix-p "/overview.png" file) (funcall file-exists file))))
                    ((symbol-function 'org--create-inline-image)
                     (lambda (file _width)
                       (push file decoded)
                       (list 'image :type 'png :file file)))
                    ((symbol-function 'image-flush)
                     (lambda (image &rest _) (push image flushed))))
            (emacs-jupyter-notebook-findings--render-previews buffer)
            (should (= (length decoded) 8))
            (should (= (length org-inline-image-overlays) 8))
            (let ((initial (copy-sequence org-inline-image-overlays)))
              ;; Ordinary commands in the same viewport must not accumulate
              ;; duplicate overlays or repeatedly decode the same previews.
              (dotimes (_ 3) (emacs-jupyter-notebook-findings--render-previews buffer))
              (should (= (length decoded) 8))
              (should (equal initial org-inline-image-overlays))
              (setq start (save-excursion
                            (goto-char (point-min)) (forward-line 1000) (point))
                    end (save-excursion (goto-char start) (forward-line 40) (point))
                    flushed nil)
              (emacs-jupyter-notebook-findings--render-previews buffer)
              (should (= (length decoded) 16))
              (should (= (length org-inline-image-overlays) 8))
              (dolist (overlay initial)
                (should-not (overlay-buffer overlay))
                (should (member (overlay-get overlay 'display) flushed)))
              (dolist (overlay org-inline-image-overlays)
                (should (<= start (overlay-start overlay)))
                (should (< (overlay-start overlay) end))))
            ;; A late update after leaving the overview frees its remaining
            ;; images without moving focus back or changing the active buffer.
            (with-temp-buffer
              (insert "Keep editing here")
              (switch-to-buffer (current-buffer))
              (let ((origin (current-buffer)) (position (point)))
                (emacs-jupyter-notebook-findings--render-previews buffer)
                (should (eq (current-buffer) origin))
                (should (eq (window-buffer) origin))
                (should (= (point) position))))
            (should-not (buffer-local-value 'org-inline-image-overlays buffer))
            (should (= (length decoded) 16))))))))

(ert-deftest ejn-workflow-org-preview-scroll-updates-coalesce-and-cancel-on-kill ()
  "Scrolling and commands arm one bounded update and buffer death cancels it."
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)) pending)
      (with-current-buffer buffer
        (should (memq #'emacs-jupyter-notebook-findings--schedule-previews post-command-hook))
        (should (memq #'emacs-jupyter-notebook-findings--schedule-previews window-scroll-functions))
        (emacs-jupyter-notebook-findings--schedule-previews (selected-window) (point-min))
        (setq pending emacs-jupyter-notebook-findings--preview-timer)
        (should (timerp pending))
        (should (memq pending timer-list))
        (dotimes (_ 5) (emacs-jupyter-notebook-findings--schedule-previews))
        (should (eq pending emacs-jupyter-notebook-findings--preview-timer)))
      (kill-buffer buffer)
      (should-not (memq pending timer-list))
      ;; A callback already queued at destruction must be inert.
      (cl-letf (((symbol-function 'org-display-inline-images)
                 (lambda (&rest _) (ert-fail "A dead overview rendered images"))))
        (emacs-jupyter-notebook-findings--render-previews buffer)))))

(ert-deftest ejn-workflow-org-fontified-links-render-but-folded-findings-do-not ()
  "Link bracket fontification must not be mistaken for a folded observation."
  (ejn-workflow--with-org-overview
    (with-temp-file path
      (insert "* Visible observation\n[[file:aa/overview.png]]\n"
              "** Context\n[[file:bb/overview.png]]\n"
              "* Folded observation\n[[file:cc/overview.png]]\n"))
    (dolist (id '("aa" "bb" "cc"))
      (let ((asset-directory (expand-file-name id directory)))
        (make-directory asset-directory)
        (with-temp-file (expand-file-name "overview.png" asset-directory)
          (insert "The test replaces only image decoding."))))
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result))
          visible folded decoded)
      (save-window-excursion
        (switch-to-buffer buffer)
        (goto-char (point-min))
        (search-forward "[[file:aa")
        (setq visible (match-beginning 0))
        (search-forward "* Folded observation")
        (org-fold-hide-subtree)
        (search-forward "[[file:cc")
        (setq folded (match-beginning 0))
        (font-lock-ensure)
        ;; The real Org fontifier conceals opening brackets even though the
        ;; link itself is visible.  The folded sibling remains concealed by
        ;; outline folding, independently of these link text properties.
        (should (get-text-property visible 'invisible))
        (should (org-invisible-p visible))
        (should-not (org-invisible-p visible t))
        (should (org-invisible-p folded t))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'window-start) (lambda (&rest _) (point-min)))
                  ((symbol-function 'window-end) (lambda (&rest _) (point-max)))
                  ((symbol-function 'org--create-inline-image)
                   (lambda (file _width)
                     (push file decoded)
                     (list 'image :type 'png :file file)))
                  ((symbol-function 'image-flush) (lambda (&rest _))))
          (emacs-jupyter-notebook-findings--render-previews buffer)
          (should (equal decoded (list (expand-file-name "aa/overview.png" directory))))
          (should (= (length org-inline-image-overlays) 1))
          (should (= (overlay-start (car org-inline-image-overlays)) visible)))))))

(ert-deftest ejn-workflow-org-preview-update-uses-owner-window-without-changing-selection ()
  "A timer renders the overview's viewport while input stays in another window."
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)) rendered)
      (save-window-excursion
        (switch-to-buffer buffer)
        (let ((overview-window (selected-window)))
          (with-temp-buffer
            (let ((origin (current-buffer)))
              (select-window (split-window-right))
              (switch-to-buffer origin))
            (insert "An unrelated edit")
            (let ((origin (current-buffer)) (window (selected-window)) (position (point)))
              (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                        ((symbol-function 'window-end)
                         (lambda (target &optional _)
                           (should (eq target overview-window))
                           (with-current-buffer buffer (point-max))))
                        ((symbol-function 'org-display-inline-images)
                         (lambda (_linked _refresh beg end)
                           (should (eq (current-buffer) buffer))
                           (push (buffer-substring-no-properties beg end) rendered))))
                (emacs-jupyter-notebook-findings--render-previews buffer)
                (should (= (length rendered) 1))
                (should (string-suffix-p "/overview.png]]" (car rendered)))
                (should (eq (current-buffer) origin))
                (should (eq (selected-window) window))
                (should (= (point) position))))))))))

(ert-deftest ejn-workflow-org-saving-report-copy-releases-preview-scheduler ()
  "An editable report copy no longer runs the generated overview's scheduler."
  (ejn-workflow--with-org-overview
    (let ((buffer (emacs-jupyter-notebook-findings--open-overview result)) pending)
      (with-current-buffer buffer
        (emacs-jupyter-notebook-findings--schedule-previews)
        (setq pending emacs-jupyter-notebook-findings--preview-timer)
        (write-file (expand-file-name "report.org" directory))
        (should-not (memq pending timer-list))
        (should-not emacs-jupyter-notebook-findings--preview-timer)
        (should-not (memq #'emacs-jupyter-notebook-findings--schedule-previews post-command-hook))
        (should-not (memq #'emacs-jupyter-notebook-findings--schedule-previews window-scroll-functions))
        (emacs-jupyter-notebook-findings--schedule-previews)
        (should-not emacs-jupyter-notebook-findings--preview-timer)))))

(provide 'emacs-jupyter-notebook-workflow-integration-tests)
;;; emacs-jupyter-notebook-workflow-integration-tests.el ends here
