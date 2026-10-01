;;; emacs-jupyter-notebook-completion-tests.el --- Remote completion latency -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defmacro ejn-completion-test-with-source (text &rest body)
  "Create an attached source with real edit tracking and deterministic cleanup."
  (declare (indent 1))
  `(save-window-excursion
     (with-temp-buffer
       (python-mode)
       (insert ,text)
       (set-window-buffer (selected-window) (current-buffer))
       (setq-local emacs-jupyter-notebook-mode t
                   emacs-jupyter-notebook--client 'completion-test-client
                   emacs-jupyter-notebook--kernel-status 'idle)
       (add-hook 'after-change-functions
                 #'emacs-jupyter-notebook--completion-after-change nil t)
       (unwind-protect (progn ,@body)
         (emacs-jupyter-notebook--completion-cancel-idle-timer)
         (emacs-jupyter-notebook-ui-cancel)))))

(defun ejn-completion-test-tick (timer)
  "Run and disarm an owned TIMER without waiting for wall time."
  (should (timerp timer))
  (let ((function (timer--function timer))
        (args (timer--args timer)))
    (cancel-timer timer)
    (apply function args)))

(ert-deftest ejn-completion-remote-path-reply-survives-typing-and-backspace ()
  "One directory reply supports several prefix edits without another request."
  (ejn-completion-test-with-source "open('/remote/"
    (let (success (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no)
                   (cl-incf calls) (setq success yes))))
        (emacs-jupyter-notebook--request-completion t)
        (insert "s")
        (let ((this-command 'self-insert-command))
          (emacs-jupyter-notebook-completion-at-point)
          (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer))
        (should (= calls 1))
        (funcall success 1 '(:matches ("scans/" "scripts/" "images/")
                            :cursor_start 14 :cursor_end 14))
        (should (equal (nth 2 (emacs-jupyter-notebook--completion-result))
                       '("scans/" "scripts/")))
        (insert "ca")
        (should (equal (nth 2 (emacs-jupyter-notebook--completion-result))
                       '("scans/")))
        (delete-char -2)
        (should (equal (nth 2 (emacs-jupyter-notebook--completion-result))
                       '("scans/" "scripts/")))
        (should (= calls 1))))))

(ert-deftest ejn-completion-repeated-capf-keeps-request-owner ()
  "CAPF retries and manual completion promote one outstanding request."
  (ejn-completion-test-with-source "obj.pr"
    (let (success (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no)
                   (cl-incf calls) (setq success yes))))
        (emacs-jupyter-notebook--request-completion)
        (let ((owner emacs-jupyter-notebook--completion-pending-id)
              (this-command 'self-insert-command))
          (dotimes (_ 4)
            (emacs-jupyter-notebook-completion-at-point)
            (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer))
          (emacs-jupyter-notebook--complete-explicit-now)
          (should (= calls 1))
          (should (= owner emacs-jupyter-notebook--completion-pending-id))
          (should (eq (plist-get emacs-jupyter-notebook--completion-flight :show)
                      'explicit))
          (funcall success 1 '(:matches ("print") :cursor_start 4 :cursor_end 6))
          (should (emacs-jupyter-notebook--completion-result)))))))

(ert-deftest ejn-completion-changed-context-coalesces-latest-demand ()
  "Changed directories serialize behind the old request, then request only latest."
  (ejn-completion-test-with-source "open('/remote/"
    (let (callbacks codes)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op payload yes _no)
                   (push (plist-get payload :code) codes)
                   (push yes callbacks))))
        (emacs-jupyter-notebook--request-completion t)
        (insert "sub/")
        (emacs-jupyter-notebook--request-completion t)
        (insert "nested/")
        (emacs-jupyter-notebook--request-completion t)
        (should (= 1 (length codes)))
        (funcall (car callbacks) 1
                 '(:matches ("obsolete/") :cursor_start 14 :cursor_end 14))
        (should-not (emacs-jupyter-notebook--completion-result))
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer)
        (should (= 2 (length codes)))
        (should (equal (car codes) "open('/remote/sub/nested/"))))))

(ert-deftest ejn-completion-unrelated-edit-invalidates-same-line-key ()
  "Editing another cell line must not revive a reply with the same prefix."
  (ejn-completion-test-with-source "a = 1\nobj.pr"
    (let (success)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no) (setq success yes))))
        (emacs-jupyter-notebook--request-completion)
        (save-excursion (goto-char (point-min)) (delete-char 1) (insert "b"))
        (funcall success 1 '(:matches ("print") :cursor_start 10 :cursor_end 12))
        (should-not (emacs-jupyter-notebook--completion-result))))))

(ert-deftest ejn-completion-explicit-capf-skips-debounce-and-transport ()
  "Explicit CAPF returns immediately and defers transport by zero seconds."
  (ejn-completion-test-with-source "obj."
    (let ((this-command 'completion-at-point) delay called)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (seconds _repeat _callback &rest _)
                   (setq delay seconds) (timer-create)))
                ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (&rest _) (setq called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should (= delay 0))
        (should-not called)))))

(ert-deftest ejn-completion-reply-refreshes-open-popup-without-retyping ()
  "An async reply replaces an active frontend's stale collection automatically."
  (ejn-completion-test-with-source "obj.pr"
    (let ((completion-in-region-mode t) success shown)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no) (setq success yes)))
                ((symbol-function 'completion-in-region)
                 (lambda (beg end table &optional _predicate)
                   (setq shown (list beg end (all-completions "pr" table))))))
        (emacs-jupyter-notebook--request-completion t)
        (funcall success 1 '(:matches ("print" "private") :cursor_start 4 :cursor_end 6))
        (should-not shown)
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-ui-timer)
        (should (equal shown '(5 7 ("print" "private"))))))))

(ert-deftest ejn-completion-refresh-replaces-an-active-collection ()
  "A current popup must not suppress new cached candidates."
  (ejn-completion-test-with-source "pr"
    (let ((completion-in-region-mode t) shown)
      (emacs-jupyter-notebook--completion-cache-put
       (emacs-jupyter-notebook--completion-key)
       '(:matches ("print") :cursor_start 0 :cursor_end 2))
      (cl-letf (((symbol-function 'completion-in-region)
                 (lambda (_beg _end table &optional _)
                   (setq shown (all-completions "pr" table)))))
        (emacs-jupyter-notebook--completion-refresh-ui)
        (should (equal shown '("print")))))))

(ert-deftest ejn-completion-automatic-ui-does-not-expand-source ()
  "A background reply presents candidates without inserting their common prefix."
  (ejn-completion-test-with-source "pr"
    (let ((before (buffer-string)) success collection)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no) (setq success yes)))
                ((symbol-function 'completion-in-region)
                 (lambda (_beg _end table &optional _predicate)
                   (setq collection table)
                   (should (equal (try-completion "pr" table) "pr"))
                   (should (equal (all-completions "pr" table) '("print"))))))
        (emacs-jupyter-notebook--request-completion t)
        (funcall success 1 '(:matches ("print") :cursor_start 0 :cursor_end 2))
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-ui-timer)
        (should (equal before (buffer-string)))
        ;; A subsequent user invocation can expand normally.
        (should (equal (try-completion "pr" collection) "print"))))))

(ert-deftest ejn-completion-company-replaces-its-cached-miss ()
  "Company gets a fresh backend backed directly by remote cached candidates."
  (ejn-completion-test-with-source "obj.pr"
    (let ((company-mode t) backend aborted)
      (emacs-jupyter-notebook--completion-cache-put
       (emacs-jupyter-notebook--completion-key)
       '(:matches ("print" "private") :cursor_start 4 :cursor_end 6))
      (cl-letf (((symbol-function 'company-abort) (lambda () (setq aborted t)))
                ((symbol-function 'company-begin-backend)
                 (lambda (value &rest _) (setq backend value))))
        (emacs-jupyter-notebook--completion-refresh-ui)
        (should aborted)
        (should (equal (funcall backend 'prefix) "pr"))
        (should (equal (funcall backend 'candidates "pri") '("print" "private")))))))

(ert-deftest ejn-completion-ui-drops-moved-buffer-minibuffer-and-retired-session ()
  "Deferred UI cannot take input after a lifecycle or focus change."
  (dolist (change '(move minibuffer client cleanup))
    (ejn-completion-test-with-source "pr"
      (let (success shown busy)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _op _payload yes _no) (setq success yes)))
                  ((symbol-function 'completion-in-region)
                   (lambda (&rest _) (setq shown t)))
                  ((symbol-function 'active-minibuffer-window) (lambda () busy)))
          (emacs-jupyter-notebook--request-completion t)
          (funcall success 1 '(:matches ("print") :cursor_start 0 :cursor_end 2))
          (let ((timer emacs-jupyter-notebook--completion-ui-timer))
            (pcase change
              ('move (backward-char))
              ('minibuffer (setq busy t))
              ('client (setq emacs-jupyter-notebook--client 'replacement))
              ('cleanup (emacs-jupyter-notebook--completion-cancel-idle-timer)))
            (ejn-completion-test-tick timer)
            (should-not shown)))))))

(ert-deftest ejn-completion-reply-winning-debounce-race-does-not-request-again ()
  "A reply arriving before a scheduled CAPF fill can satisfy that demand."
  (ejn-completion-test-with-source "pr"
    (let (success shown (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no)
                   (cl-incf calls) (setq success yes)))
                ((symbol-function 'completion-in-region)
                 (lambda (&rest _) (setq shown t))))
        (emacs-jupyter-notebook--request-completion)
        (emacs-jupyter-notebook--completion-schedule-request t)
        (funcall success 1 '(:matches ("print") :cursor_start 0 :cursor_end 2))
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer)
        (should shown)
        (should (= calls 1))))))

(ert-deftest ejn-completion-unrelated-edit-with-identical-key-is-queued ()
  "A still-pending reply must not suppress a changed cell's identical line key."
  (ejn-completion-test-with-source "a = 1\nobj.pr"
    (let (callbacks (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no)
                   (cl-incf calls) (push yes callbacks))))
        (emacs-jupyter-notebook--request-completion)
        (save-excursion (goto-char (point-min)) (delete-char 1) (insert "b"))
        (emacs-jupyter-notebook--request-completion t)
        (should (= calls 1))
        (funcall (car callbacks) 1
                 '(:matches ("obsolete") :cursor_start 10 :cursor_end 12))
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer)
        (should (= calls 2))))))

(ert-deftest ejn-completion-stale-request-cannot-clear-new-owner ()
  "A late callback with a reused numeric id cannot retire a replacement request."
  (ejn-completion-test-with-source "pr"
    (let (callbacks)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no) (push yes callbacks))))
        (emacs-jupyter-notebook--request-completion)
        (emacs-jupyter-notebook--completion-cancel-idle-timer)
        ;; Local teardown resets the counter; exact context identity still fences it.
        (setq emacs-jupyter-notebook--completion-request-counter 0)
        (emacs-jupyter-notebook--request-completion)
        (funcall (cadr callbacks) 1
                 '(:matches ("obsolete") :cursor_start 0 :cursor_end 2))
        (should emacs-jupyter-notebook--completion-flight)
        (funcall (car callbacks) 2
                 '(:matches ("print") :cursor_start 0 :cursor_end 2))
        (should (equal (nth 2 (emacs-jupyter-notebook--completion-result))
                       '("print")))))))

(ert-deftest ejn-completion-separator-invalidates-prefix-reuse ()
  "Directory, attribute, quote and whitespace boundaries require fresh data."
  (dolist (separator '("/" "." "'" " "))
    (ejn-completion-test-with-source "pr"
      (let (success)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _op _payload yes _no) (setq success yes))))
          (emacs-jupyter-notebook--request-completion)
          (funcall success 1 '(:matches ("print") :cursor_start 0 :cursor_end 2))
          (insert separator)
          (should-not (emacs-jupyter-notebook--completion-result))
          (should-not emacs-jupyter-notebook--completion-reusable))))))

(ert-deftest ejn-completion-empty-vector-does-not-start-an-empty-popup ()
  "An empty JSON matches array is a cacheable miss, never a CAPF result."
  (ejn-completion-test-with-source "pr"
    (should-not (emacs-jupyter-notebook--completion-result-from-reply
                 '(:matches [] :cursor_start 0 :cursor_end 2)))))

(ert-deftest ejn-completion-truncated-reply-requeries-narrower-prefix ()
  "A broad reply capped at 256 entries cannot hide omitted narrower matches."
  (ejn-completion-test-with-source "open('/remote/"
    (let (success (calls 0)
          (wire (make-hash-table :test #'equal)))
      (puthash "matches" (cl-loop for i below 256 collect (format "scan%03d/" i)) wire)
      (puthash "cursor_start" 14 wire)
      (puthash "cursor_end" 14 wire)
      (puthash "status" "ok" wire)
      (puthash "_ejn_truncated" t wire)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes _no)
                   (cl-incf calls) (setq success yes))))
        (emacs-jupyter-notebook--request-completion)
        (funcall success 1
                 (emacs-jupyter-notebook-helper-backend--complete-result wire))
        (should (= (length (nth 2 (emacs-jupyter-notebook--completion-result))) 256))
        (insert "scan")
        ;; All 256 cached entries still match, but later scan names were omitted.
        (should-not (emacs-jupyter-notebook--completion-result))
        (emacs-jupyter-notebook--complete-explicit-now)
        (should (= calls 2))))))

(ert-deftest ejn-completion-error-releases-owner-and-drains-latest-demand ()
  "Timeout/error of an old prefix cannot strand the newer queued request."
  (ejn-completion-test-with-source "pr"
    (let (failure success (calls 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client _op _payload yes no)
                   (cl-incf calls) (setq success yes failure no))))
        (emacs-jupyter-notebook--request-completion)
        (insert "i")
        (emacs-jupyter-notebook--request-completion t)
        (funcall failure 1 "timeout")
        (should-not emacs-jupyter-notebook--completion-flight)
        (ejn-completion-test-tick emacs-jupyter-notebook--completion-idle-timer)
        (should (= calls 2))
        (funcall success 2 '(:matches ("print") :cursor_start 0 :cursor_end 3))
        (should (equal (nth 2 (emacs-jupyter-notebook--completion-result))
                       '("print")))))))

(ert-deftest ejn-completion-corfu-paints-refreshed-data-on-reply ()
  "Timer delivery must paint Corfu now, without waiting for another command."
  (dolist (candidates '(("print") ("print" "private")))
    (ejn-completion-test-with-source "pr"
      (let ((corfu-mode t)
            (completion-in-region-mode t)
            (before (buffer-string))
            success table painted)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _op _payload yes _no) (setq success yes)))
                  ((symbol-function 'completion-in-region)
                   (lambda (_beg _end collection &optional _predicate)
                     (setq table collection)))
                  ((symbol-function 'corfu--exhibit)
                   (lambda ()
                     (should (equal (all-completions "pr" table) candidates))
                     ;; Painting a singleton may query try-completion again;
                     ;; it must still see the non-expanding presentation table.
                     (should (equal (try-completion "pr" table) "pr"))
                     (setq painted t))))
          (emacs-jupyter-notebook--request-completion t)
          (funcall success 1 (list :matches candidates :cursor_start 0 :cursor_end 2))
          (should-not painted)
          (ejn-completion-test-tick emacs-jupyter-notebook--completion-ui-timer)
          (should painted)
          (should (equal before (buffer-string))))))))

(provide 'emacs-jupyter-notebook-completion-tests)
;;; emacs-jupyter-notebook-completion-tests.el ends here
