;;; emacs-jupyter-notebook-history-tests.el --- Trail regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-history)

(defun ejn-history-test--record (id code &optional cell handle)
  (list :id id :code code :cell-key cell :panel-entry handle :started-at (+ 1000.0 id)))

(defun ejn-history-test--run (id code &optional cell handle status)
  (let ((record (ejn-history-test--record id code cell handle)))
    (emacs-jupyter-notebook-history-record-created record)
    (emacs-jupyter-notebook-history-record-dispatched record)
    (emacs-jupyter-notebook-history-record-finished record (or status 'ok) id)
    record))

(ert-deftest ejn-history-retains-exact-code-and-outcomes-independently ()
  (with-temp-buffer
    (insert "# %%\ncurrent_edit = 9\n")
    (setq-local emacs-jupyter-notebook--session-entry '(:session-id "kernel-42"))
    (let* ((source (buffer-string))
           (code (copy-sequence "checkpoint = 42\n"))
           (record (ejn-history-test--record 1 code '("source.py" . 8))))
      (emacs-jupyter-notebook-history-record-created record)
      (aset code 0 ?X)
      (emacs-jupyter-notebook-history-record-dispatched record)
      (emacs-jupyter-notebook-history-record-finished record 'error 8)
      (let ((entry (car emacs-jupyter-notebook-history--entries)))
        (should (equal (plist-get entry :code) "checkpoint = 42\n"))
        (should (eq (plist-get entry :status) 'error))
        (should (equal (plist-get entry :session-id) "kernel-42"))
        (should (numberp (plist-get entry :submitted-at)))
        (should (numberp (plist-get entry :finished-at)))
        (should (= (plist-get entry :execution-count) 8)))
      ;; Neither disposable rendering state nor subsequent edits own the trail.
      (setq emacs-jupyter-notebook--execution-ledger nil)
      (should (equal (buffer-string) source))
      (should (= (length emacs-jupyter-notebook-history--entries) 1)))))

(ert-deftest ejn-history-unsent-work-is-never-described-as-submitted ()
  (with-temp-buffer
    (let ((record (ejn-history-test--record 1 "dangerous()")))
      (emacs-jupyter-notebook-history-record-created record)
      (emacs-jupyter-notebook-history-record-finished record 'cancelled)
      (let ((entry (aref (gethash "entries" (emacs-jupyter-notebook-history-provenance)) 0)))
        (should (eq (gethash "submitted_at" entry) :null))
        (should (equal (gethash "status" entry) "cancelled"))))))

(ert-deftest ejn-history-retention-is-bounded-by-count-and-code-bytes ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-history-limit 2)
          (emacs-jupyter-notebook-history-code-bytes 9))
      (ejn-history-test--run 1 "aaaa")
      (ejn-history-test--run 2 "bbbb")
      (ejn-history-test--run 3 "ccccc")
      (should (equal (mapcar (lambda (e) (plist-get e :id))
                            emacs-jupyter-notebook-history--entries) '(2 3)))
      (should (= emacs-jupyter-notebook-history--bytes 9))
      (should emacs-jupyter-notebook-history--evicted)
      (ejn-history-test--run 4 "more than the whole budget")
      (should-not emacs-jupyter-notebook-history--entries)
      (should (= emacs-jupyter-notebook-history--bytes 0)))))

(ert-deftest ejn-history-provenance-fences-target-handle-and-copies-context ()
  (with-temp-buffer
    (let ((one (list :panel (current-buffer) :generation 1 :id 1))
          (two (list :panel (current-buffer) :generation 2 :id 1)))
      (ejn-history-test--run 1 "model = 'A'" '("source.py" . 1) one)
      (ejn-history-test--run 2 "model = 'B'" '("source.py" . 1) two)
      (let* ((context (emacs-jupyter-notebook-history-provenance one))
             (entries (gethash "entries" context)))
        (should (= (length entries) 1))
        (should (= (gethash "target_id" context) 1))
        (aset (gethash "code" (aref entries 0)) 0 ?X)
        (should (equal (plist-get (car emacs-jupyter-notebook-history--entries) :code)
                       "model = 'A'")))
      (let ((missing (emacs-jupyter-notebook-history-provenance
                      (list :panel (current-buffer) :generation 3 :id 1))))
        (should (eq (gethash "target_missing" missing) t))
        (should (= (length (gethash "entries" missing)) 0))))))

(ert-deftest ejn-history-provenance-is-bounded-json-with-explicit-code-omission ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook--session-entry '(:session-id "test-session"))
    (dotimes (i 8)
      (ejn-history-test--run (1+ i) (concat "# " (make-string 2000 ?界)) '("x.py" . 1)))
    (ejn-history-test--run 9 (make-string 25000 ?界) '("x.py" . 1))
    (let* ((context (emacs-jupyter-notebook-history-provenance))
           (entries (gethash "entries" context))
           (target (aref entries (1- (length entries)))))
      (should (<= (emacs-jupyter-notebook-history--json-bytes context) 24576))
      (should (eq (gethash "truncated" context) t))
      (should (= (gethash "id" target) 9))
      (should (eq (gethash "code" target) :null))
      (should (eq (gethash "code_omitted" target) t))
      (should (= (length (gethash "code_sha256" target)) 64))
      (should (cl-some (lambda (e) (stringp (gethash "code" e))) entries)))))

(ert-deftest ejn-history-diff-shows-intervening-executions-with-unchanged-cell ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--session-entry '(:session-id "session"))
    (let ((key '("source.py" . 8)) shown)
      (ejn-history-test--run 1 "predict()" key)
      (ejn-history-test--run 2 "load_checkpoint(57)")
      (ejn-history-test--run 3 "sigma = .5")
      (ejn-history-test--run 4 "predict()" key)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key) (lambda () key))
                ((symbol-function 'emacs-jupyter-notebook-history--detail)
                 (lambda (_owner _entry text &optional _diff) (setq shown text))))
        (emacs-jupyter-notebook-history-diff))
      (should (string-match-p "Cell code is unchanged" shown))
      (should (string-match-p "load_checkpoint(57)" shown))
      (should (string-match-p "sigma = .5" shown))
      (should (< (string-match "Run #2" shown) (string-match "Run #3" shown))))))

(ert-deftest ejn-history-diff-does-not-cross-kernel-session ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--session-entry '(:session-id "A"))
    (let ((key '("source.py" . 8)))
      (ejn-history-test--run 1 "predict()" key)
      (setq emacs-jupyter-notebook--session-entry '(:session-id "B"))
      (ejn-history-test--run 2 "predict()" key)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key) (lambda () key)))
        (should-error (emacs-jupyter-notebook-history-diff) :type 'user-error)))))

(ert-deftest ejn-history-diff-does-not-cross-restarted-kernel-with-reused-session-id ()
  (dolist (changed '((:session-id "same" :remote-pid 23 :docker-container-id "a")
                     (:session-id "same" :remote-pid 22 :docker-container-id "b")))
    (with-temp-buffer
      (setq-local emacs-jupyter-notebook-mode t
                  emacs-jupyter-notebook--session-entry
                  '(:session-id "same" :remote-pid 22 :docker-container-id "a"))
      (let ((key '("source.py" . 8)))
        (ejn-history-test--run 1 "predict()" key)
        (setq emacs-jupyter-notebook--session-entry changed)
        (ejn-history-test--run 2 "predict()" key)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key) (lambda () key)))
          (should-error (emacs-jupyter-notebook-history-diff) :type 'user-error))
        (let ((identities (mapcar (lambda (entry) (gethash "kernel_identity" entry))
                                 (append (gethash "entries" (emacs-jupyter-notebook-history-provenance)) nil))))
          (should (equal (gethash "session_id" (car identities)) "same"))
          (should (= (gethash "remote_pid" (car identities)) 22))
          (should (equal (gethash "docker_container_id" (cadr identities))
                         (plist-get changed :docker-container-id))))))))

(ert-deftest ejn-history-reconnect-same-kernel-keeps-diff-but-confirmed-restart-does-not ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--session-entry
                '(:session-id "same" :remote-pid 22))
    (let ((key '("source.py" . 8)) shown)
      (ejn-history-test--run 1 "predict()" key)
      ;; A fresh local attachment to the same durable process retains identity.
      (setq emacs-jupyter-notebook--session-entry
            (copy-tree emacs-jupyter-notebook--session-entry))
      (ejn-history-test--run 2 "predict()" key)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-cell-key) (lambda () key))
                ((symbol-function 'emacs-jupyter-notebook-history--detail)
                 (lambda (_owner _entry text &optional _diff) (setq shown text))))
        (emacs-jupyter-notebook-history-diff)
        (should (string-match-p "Changes from run #1 to #2" shown))
        ;; Explicit restart remains distinct even if the remote PID is reused.
        (emacs-jupyter-notebook-history-kernel-restarted)
        (ejn-history-test--run 3 "predict()" key)
        (should-error (emacs-jupyter-notebook-history-diff) :type 'user-error)))))

(ert-deftest ejn-history-local-line-diff-preserves-change-and-context ()
  (let ((text (emacs-jupyter-notebook-history--line-diff
               "a\nmodel = 'A'\nz\n" "a\nmodel = 'B'\nz\n")))
    (should (string-match-p "^-model = 'A'$" text))
    (should (string-match-p "^+model = 'B'$" text))
    (should (string-match-p "^ a$" text))
    (should (string-match-p "^ z$" text))))

(ert-deftest ejn-history-admission-is-idempotent-across-transport-loss ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook--session-entry '(:session-id "original"))
    (let ((record (ejn-history-test--run 1 "predict()")))
      (let ((time (plist-get (car emacs-jupyter-notebook-history--entries) :submitted-at)))
        (setq emacs-jupyter-notebook--session-entry '(:session-id "other"))
        (emacs-jupyter-notebook-history-record-dispatched record)
        (should (equal time (plist-get (car emacs-jupyter-notebook-history--entries) :submitted-at)))
        (should (equal "original" (plist-get (car emacs-jupyter-notebook-history--entries) :session-id)))))))

(ert-deftest ejn-history-core-lifecycle-retains-context-after-panel-clear ()
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook-mode t
                emacs-jupyter-notebook--session-entry '(:session-id "actual"))
    (insert "# %%\nsource_stays = 1\n")
    (let ((original (buffer-string))
          (timers (copy-sequence timer-list)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-panel--display) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-variables-invalidate) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-variables-execution-finished) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (&rest _) 123)))
        (unwind-protect
            (let* ((id (emacs-jupyter-notebook--evaluate-code "submitted = 7" nil))
                   (record (emacs-jupyter-notebook--execution-record id))
                   (handle (plist-get record :panel-entry)))
              (setq emacs-jupyter-notebook--client 'test-client
                    emacs-jupyter-notebook--execution-active-id id)
              (setf (plist-get record :state) 'checking)
              (emacs-jupyter-notebook--execution-dispatch record)
              (should (plist-get (emacs-jupyter-notebook-history--record id) :submitted-at))
              (ejn-panel-clear-all (plist-get handle :panel))
              (emacs-jupyter-notebook--execution-finish
               (emacs-jupyter-notebook--execution-record id) 'ok 7)
              (let* ((context (emacs-jupyter-notebook-history-provenance handle))
                     (entry (aref (gethash "entries" context) 0)))
                (should (equal (gethash "code" entry) "submitted = 7"))
                (should (equal (gethash "status" entry) "ok"))
                (should (= (gethash "execution_count" entry) 7)))
              (should (equal (buffer-string) original)))
          (emacs-jupyter-notebook--clear-buffer-timers)
          (emacs-jupyter-notebook--kill-panel)
          (should-not (cl-set-difference timer-list timers)))))))

(ert-deftest ejn-history-evil-actions-cover-the-trail-table ()
  (let (bindings initial)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state) (setq initial (cons mode state))))
              ((symbol-function 'evil-define-key*)
               (lambda (states map &rest keys) (setq bindings (list states map keys)))))
      (emacs-jupyter-notebook-history--evil-setup))
    (should (equal initial '(emacs-jupyter-notebook-history-mode . emacs)))
    (should (equal (car bindings) '(normal motion visual)))
    (should (eq (nth 1 bindings) emacs-jupyter-notebook-history-mode-map))
    (dolist (command '(emacs-jupyter-notebook-history-show
                       emacs-jupyter-notebook-history-diff
                       emacs-jupyter-notebook-history-copy-code
                       emacs-jupyter-notebook-history-recall next-line previous-line))
      (should (memq command (nth 2 bindings))))))

(ert-deftest ejn-history-detail-views-are-reused-and-cleaned-on-owner-kill ()
  (let ((owner (generate-new-buffer " *ejn-history-owner*")) code-view diff-view)
    (unwind-protect
        (with-current-buffer owner
          (setq-local emacs-jupyter-notebook-mode t)
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (dotimes (i 12)
              (emacs-jupyter-notebook-history--detail owner (list :id i) "code")
              (emacs-jupyter-notebook-history--detail owner (list :id i) "changes" t)
              (if code-view
                  (progn
                    (should (eq code-view emacs-jupyter-notebook-history--code-view))
                    (should (eq diff-view emacs-jupyter-notebook-history--diff-view)))
                (setq code-view emacs-jupyter-notebook-history--code-view
                      diff-view emacs-jupyter-notebook-history--diff-view))))
          (kill-buffer owner)
          (should-not (buffer-live-p code-view))
          (should-not (buffer-live-p diff-view)))
      (dolist (buffer (list owner code-view diff-view))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'emacs-jupyter-notebook-history-tests)
