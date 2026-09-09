;;; emacs-jupyter-notebook-ui.el --- Deferred notebook prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; An asynchronous reply must unwind its process callback before reading input,
;; and must not take over another buffer's minibuffer.  Pending prompts are
;; local, replaceable, and guarded by their originating operation's identity.

;;; Code:

(require 'cl-lib)

(defvar emacs-jupyter-notebook-ui--active nil
  "Non-nil while a deferred notebook interaction is running.")

(defvar-local emacs-jupyter-notebook-ui--pending nil
  "Pending prompt records, keyed by purpose, for this source buffer.")

(defun emacs-jupyter-notebook-ui-available-p (buffer)
  "Return non-nil when BUFFER owns the selected window and input is free."
  (and (buffer-live-p buffer)
       (not (active-minibuffer-window))
       (eq buffer (window-buffer (selected-window)))))

(defun emacs-jupyter-notebook-ui-cancel (&optional key)
  "Cancel current buffer's pending prompts, or only purpose KEY."
  (dolist (record (copy-sequence emacs-jupyter-notebook-ui--pending))
    (when (or (null key) (eq key (car record)))
      (when (timerp (plist-get (cdr record) :timer))
        (cancel-timer (plist-get (cdr record) :timer)))
      (setq emacs-jupyter-notebook-ui--pending
            (delq record emacs-jupyter-notebook-ui--pending))))
  (unless emacs-jupyter-notebook-ui--pending
    (remove-hook 'kill-buffer-hook #'emacs-jupyter-notebook-ui-cancel t)))

(defun emacs-jupyter-notebook-ui--schedule (source record)
  "Schedule one positive-delay attempt to present SOURCE's RECORD."
  (setcdr record
          (plist-put (cdr record) :timer
                     (run-at-time 0.1 nil
                                  #'emacs-jupyter-notebook-ui--run
                                  source record))))

(defun emacs-jupyter-notebook-ui--run (source record)
  "Present a still-owned RECORD only after SOURCE's input context is free."
  (when (buffer-live-p source)
    (with-current-buffer source
      (when (memq record emacs-jupyter-notebook-ui--pending)
        (condition-case err
            (let* ((data (cdr record))
                   (origin (plist-get data :origin)))
              (cond
               ((not (and (buffer-live-p origin)
                          (funcall (plist-get data :guard))))
                (emacs-jupyter-notebook-ui-cancel (car record)))
               ((or emacs-jupyter-notebook-ui--active
                    (not (emacs-jupyter-notebook-ui-available-p origin)))
                (emacs-jupyter-notebook-ui--schedule source record))
               (t
                ;; Remove before invoking: C-g or recursive dispatch cannot
                ;; repeat the same prompt on every later minibuffer entry.
                (emacs-jupyter-notebook-ui-cancel (car record))
                (let ((emacs-jupyter-notebook-ui--active t))
                  (funcall (plist-get data :function))))))
          (quit (emacs-jupyter-notebook-ui-cancel (car record)))
          (error
           (emacs-jupyter-notebook-ui-cancel (car record))
           (message "emacs-jupyter-notebook: deferred prompt failed: %s"
                    (error-message-string err))))))))

(defun emacs-jupyter-notebook-ui-defer (source guard function &optional origin key)
  "Defer FUNCTION until ORIGIN owns input and GUARD holds in SOURCE.
ORIGIN defaults to SOURCE.  KEY replaces any prior prompt for that purpose.
Always yield first, even when input is currently free.  FUNCTION and GUARD
run in SOURCE; FUNCTION is called once, outside the process callback."
  (when (buffer-live-p source)
    (with-current-buffer source
      (let* ((key (or key 'prompt))
             (record (list key :guard guard :function function
                           :origin (or origin source))))
        (emacs-jupyter-notebook-ui-cancel key)
        (push record emacs-jupyter-notebook-ui--pending)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-ui-cancel nil t)
        (condition-case err
            (emacs-jupyter-notebook-ui--schedule source record)
          (error
           (emacs-jupyter-notebook-ui-cancel key)
           (signal (car err) (cdr err))))))))

(provide 'emacs-jupyter-notebook-ui)
;;; emacs-jupyter-notebook-ui.el ends here
