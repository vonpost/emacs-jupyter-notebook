;;; emacs-jupyter-notebook-variable-backend-tests.el --- Metadata boundary -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook)

(defun ejn-variable-backend-test--object (&rest pairs)
  (apply #'emacs-jupyter-notebook-helper-backend--make-object pairs))

(ert-deftest ejn-variable-backend-preserves-scalar-and-unknown-shapes ()
  (let* ((scalar (ejn-variable-backend-test--object
                  "name" "scalar" "type" "numpy.ndarray" "shape" [] "dtype" "float32"))
         (unknown (ejn-variable-backend-test--object
                   "name" "custom" "type" "__main__.Custom" "shape" :null "dtype" :null))
         (reply (emacs-jupyter-notebook-helper-backend--variables-result
                 (ejn-variable-backend-test--object
                  "variables" (vector scalar unknown) "truncated" :false))))
    (should (equal (plist-get (car (plist-get reply :variables)) :shape) []))
    (should-not (plist-get (cadr (plist-get reply :variables)) :shape))
    (should-not (plist-get reply :truncated))
    (dolist (shape (list [-1] [9007199254740992] (make-vector 33 1) "(2, 3)"))
      (puthash "shape" shape scalar)
      (should-error
       (emacs-jupyter-notebook-helper-backend--variables-result
        (ejn-variable-backend-test--object "variables" (vector scalar) "truncated" :false))))))

(ert-deftest ejn-variable-backend-aux-uses-bounded-wire-operation ()
  (with-temp-buffer
    (let* ((session (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (state (emacs-jupyter-notebook-helper-backend--make-state :helper 'fake))
           requests delivered)
      (setf (emacs-jupyter-notebook-backend-session-data session) state)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-request)
                     (lambda (_helper operation params callback &rest keys)
                       (push (list operation params keys) requests)
                       (funcall callback 'fake
                                (ejn-variable-backend-test--object
                                 "ok" t "result" (ejn-variable-backend-test--object
                                                  "variables" [] "truncated" :false)) nil)
                       "wire-variables")))
            (emacs-jupyter-notebook-backend-aux
             session 'variables '(:names nil :limit 200)
             (lambda (_id reply) (setq delivered reply)) #'ert-fail)
            (should-not delivered)
            (accept-process-output nil 0.03)
            (should (equal delivered '(:variables nil :truncated nil)))
            (should (= (length requests) 1))
            (should (equal (caar requests) "variables"))
            (let ((params (nth 1 (car requests))))
              (should (= (hash-table-count params) 2))
              (should (eq (gethash "names" params) :null))
              (should (= (gethash "limit" params) 200)))
            (should (= (plist-get (nth 2 (car requests)) :timeout)
                       emacs-jupyter-notebook-helper-backend--aux-timeout))
            (should (= (hash-table-count
                        (emacs-jupyter-notebook-backend-session-requests session)) 0)))
        (dolist (timer (emacs-jupyter-notebook-backend-session-timers session))
          (cancel-timer timer))
        (setf (emacs-jupyter-notebook-backend-session-closed session) t)))))

(ert-deftest ejn-features-mode-installs-and-removes-local-hooks ()
  (with-temp-buffer
    (python-mode)
    (insert "image = None\n")
    (let ((text (buffer-string)) (modified (buffer-modified-p)))
      (unwind-protect
          (progn
            (emacs-jupyter-notebook-mode 1)
            (should (memq #'emacs-jupyter-notebook--cell-before-change before-change-functions))
            (should (memq #'emacs-jupyter-notebook-variables-eldoc eldoc-documentation-functions))
            (should (emacs-jupyter-notebook--current-cell-key)))
        (emacs-jupyter-notebook-mode -1))
      (should-not (memq #'emacs-jupyter-notebook--cell-before-change before-change-functions))
      (should-not (memq #'emacs-jupyter-notebook-variables-eldoc eldoc-documentation-functions))
      (should (equal text (buffer-string)))
      (should (eq modified (buffer-modified-p))))))

(provide 'emacs-jupyter-notebook-variable-backend-tests)
;;; emacs-jupyter-notebook-variable-backend-tests.el ends here
