;;; emacs-jupyter-notebook-ui-hang-tests.el --- Async UI regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(ert-deftest ejn-ui-completion-reply-does-not-enter-an-active-minibuffer ()
  (with-temp-buffer
    (let (opened)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
                ((symbol-function 'emacs-jupyter-notebook--completion-result)
                 (lambda () '(1 1 ("candidate"))))
                ((symbol-function 'completion-in-region)
                 (lambda (&rest _) (setq opened t))))
        (emacs-jupyter-notebook--completion-refresh-ui)
        (should-not opened)))))

(ert-deftest ejn-ui-completion-reply-does-not-open-ui-in-another-buffer ()
  (with-temp-buffer
    (let (opened)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--completion-result)
                 (lambda () '(1 1 ("candidate"))))
                ((symbol-function 'completion-in-region)
                 (lambda (&rest _) (setq opened t))))
        (emacs-jupyter-notebook--completion-refresh-ui)
        (should-not opened)))))

(defun ejn-ui-test--tick (source)
  "Run SOURCE's next owned prompt once, without leaving an old timer armed."
  (with-current-buffer source
    (let ((record (car emacs-jupyter-notebook-ui--pending)))
      (should record)
      (cancel-timer (plist-get (cdr record) :timer))
      (emacs-jupyter-notebook-ui--run source record))))

(ert-deftest ejn-ui-prompts-yield-and-wait-for-minibuffer-without-repeating ()
  (save-window-excursion
    (with-temp-buffer
      (let ((source (current-buffer)) (busy t) (calls 0))
        (set-window-buffer (selected-window) source)
        (cl-letf (((symbol-function 'active-minibuffer-window)
                   (lambda () busy)))
          (emacs-jupyter-notebook-ui-defer
           source (lambda () t) (lambda () (cl-incf calls)))
          (should (= calls 0))
          (let ((record (car emacs-jupyter-notebook-ui--pending)))
            (ejn-ui-test--tick source)
            (should (= calls 0))
            (should (= (length emacs-jupyter-notebook-ui--pending) 1))
            (setq busy nil)
            (ejn-ui-test--tick source)
            (should (= calls 1))
            (should-not emacs-jupyter-notebook-ui--pending)
            (emacs-jupyter-notebook-ui--run source record)
            (should (= calls 1))))))))

(ert-deftest ejn-ui-prompts-cancel-on-stale-owner-replacement-and-buffer-kill ()
  (let ((source (generate-new-buffer " *ejn-ui-lifetime*"))
        (live t) calls timer)
    (unwind-protect
        (with-current-buffer source
          (emacs-jupyter-notebook-ui-defer
           source (lambda () live) (lambda () (push 'old calls)) nil 'pick)
          (setq timer (plist-get (cdar emacs-jupyter-notebook-ui--pending) :timer))
          (emacs-jupyter-notebook-ui-defer
           source (lambda () live) (lambda () (push 'new calls)) nil 'pick)
          (should-not (memq timer timer-list))
          (should (= (length emacs-jupyter-notebook-ui--pending) 1))
          (setq live nil)
          (ejn-ui-test--tick source)
          (should-not calls)
          (should-not emacs-jupyter-notebook-ui--pending)
          (emacs-jupyter-notebook-ui-defer source (lambda () t) #'ignore)
          (setq timer (plist-get (cdar emacs-jupyter-notebook-ui--pending) :timer)))
      (when (buffer-live-p source) (kill-buffer source)))
    (should-not (memq timer timer-list))))

(ert-deftest ejn-ui-registry-picker-unwinds-worker-and-retires-after-quit ()
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (let ((token (gensym)) prompted called)
        (setq emacs-jupyter-notebook--management-operation (list :token token))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--choose-registry-entry)
                   (lambda (_) (setq prompted t) (signal 'quit nil))))
          (emacs-jupyter-notebook--registry-picker-finish
           token (lambda (_) (setq called t)) '((:session-id "dead")))
          (should-not prompted)
          (ejn-ui-test--tick (current-buffer))
          (should prompted)
          (should-not called)
          (should-not emacs-jupyter-notebook--management-operation)
          (should-not emacs-jupyter-notebook-ui--pending))))))

(ert-deftest ejn-ui-explicit-completion-caches-without-interrupting-m-x ()
  (save-window-excursion
    (with-temp-buffer
      (insert "pri")
      (set-window-buffer (selected-window) (current-buffer))
      (let ((emacs-jupyter-notebook--client 'client) reply opened)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-aux)
                   (lambda (_client _op _params success _failure)
                     (setq reply success)))
                  ((symbol-function 'active-minibuffer-window) (lambda () t))
                  ((symbol-function 'completion-in-region)
                   (lambda (&rest _) (setq opened t))))
          (emacs-jupyter-notebook--complete-explicit-now)
          (funcall reply 1 '(:matches ("print") :cursor_start 0 :cursor_end 3))
          (should (emacs-jupyter-notebook--completion-result))
          (should-not opened)
          (should-not emacs-jupyter-notebook-ui--pending))))))

(ert-deftest ejn-ui-stdin-waits-for-source-and-drops-retired-execution ()
  (with-temp-buffer
    (let ((live t) prompted replied)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-input-current-p)
                 (lambda (_) live))
                ((symbol-function 'read-string)
                 (lambda (_) (setq prompted t) "answer")))
        (emacs-jupyter-notebook-events--schedule-input
         (list :buffer (current-buffer) :request-id 1
               :input-reply (lambda (_) (setq replied t))) "Input: " nil)
        (ejn-ui-test--tick (current-buffer))
        (should-not prompted)
        (setq live nil)
        (ejn-ui-test--tick (current-buffer))
        (should-not emacs-jupyter-notebook-ui--pending)
        (should-not replied)))))

(provide 'emacs-jupyter-notebook-ui-hang-tests)
