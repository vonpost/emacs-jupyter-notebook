;;; emacs-jupyter-notebook-process.el --- Bounded local process writes -*- lexical-binding: t; -*-

;;; Commentary:
;; `process-send-string' waits when a child's input pipe fills.  Emacs timers
;; still run in that wait, but keyboard commands cannot be dispatched.  Keep
;; this uncommon failure short and retire partial streams before reuse.

;;; Code:

(defconst emacs-jupyter-notebook-process--write-timeout 0.05
  "Maximum seconds a local process write may hold keyboard dispatch.
This is a write deadline, not the child's startup or request deadline.")

(defun emacs-jupyter-notebook-process-send (process string)
  "Send STRING to local PROCESS with a short, non-recursive write deadline.
A full pipe must not block editing for the operation's seconds-long timeout.
On timeout or an interrupted partial write, retire only this local process;
the caller retains ownership of request/session cleanup.  Never retry bytes
whose delivery is ambiguous.  Reentrant writers send no bytes at all."
  (when (process-get process 'ejn-write-owner)
    (error "Reentrant local process write refused"))
  (let ((token (list 'ejn-write)) timer started complete expired)
    (process-put process 'ejn-write-owner token)
    (unwind-protect
        (progn
          (setq timer
                (run-at-time
                 emacs-jupyter-notebook-process--write-timeout nil
                 (lambda ()
                   (when (eq token (process-get process 'ejn-write-owner))
                     (setq expired t)
                     (when (process-live-p process)
                       (delete-process process))))))
          (unless (timerp timer)
            (error "Could not arm local process write deadline"))
          (when expired (error "Local process write timed out"))
          (setq started t)
          (process-send-string process string)
          (when expired (error "Local process write timed out"))
          (setq complete t))
      (when (timerp timer) (cancel-timer timer))
      ;; C-g can unwind a send after only part of a framed request was written.
      ;; Keeping that stream alive would corrupt the next request's framing.
      (when (and started (not complete) (process-live-p process))
        (delete-process process))
      (when (eq token (process-get process 'ejn-write-owner))
        (process-put process 'ejn-write-owner nil)))))

(provide 'emacs-jupyter-notebook-process)
;;; emacs-jupyter-notebook-process.el ends here
