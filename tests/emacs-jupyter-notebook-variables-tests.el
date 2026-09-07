;;; emacs-jupyter-notebook-variables-tests.el --- Metadata lifetime tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'python)
(require 'emacs-jupyter-notebook-variables)

(defconst ejn-variables-test--reply
  '(:variables ((:name "image" :type "numpy.ndarray" :shape [128 64] :dtype "float32"))
    :truncated nil))

(defmacro ejn-variables-test--with-source (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (python-mode)
     (insert "image = None\n")
     (goto-char (point-min))
     (setq-local emacs-jupyter-notebook-mode t
                 emacs-jupyter-notebook--client
                 (emacs-jupyter-notebook-backend-session-create nil (current-buffer))
                 emacs-jupyter-notebook--kernel-status 'idle
                 emacs-jupyter-notebook--execution-active-id nil
                 emacs-jupyter-notebook--execution-queue nil
                 emacs-jupyter-notebook--execution-setup-pending nil)
     (let (scheduled cancelled requests)
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (delay _repeat function &rest args)
                    (let ((timer (timer-create)))
                      (setq scheduled (append scheduled (list (list timer delay function args))))
                      timer)))
                 ((symbol-function 'cancel-timer)
                  (lambda (timer) (push timer cancelled)))
                 ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                  (lambda (client operation payload callback &optional error-callback)
                    (setq requests (append requests (list (list client operation payload callback error-callback))))
                    (length requests))))
         (unwind-protect
             (progn ,@body)
           (emacs-jupyter-notebook-variables-teardown)
           (when (buffer-live-p emacs-jupyter-notebook-variables--table)
             (kill-buffer emacs-jupyter-notebook-variables--table)))))))

(defun ejn-variables-test--fire (scheduled index)
  (let ((record (nth index scheduled)))
    (apply (nth 2 record) (nth 3 record))))

(ert-deftest ejn-variables-eldoc-is-deferred-caches-shape-and-keeps-source-clean ()
  (ejn-variables-test--with-source
    (let ((text (buffer-string)) (tick (buffer-chars-modified-tick)) delivered)
      (should (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value))))
      (should-not requests)
      (ejn-variables-test--fire scheduled 0)
      (should (eq (nth 1 (car requests)) 'variables))
      (should (equal (nth 2 (car requests)) '(:names ["image"] :limit 1)))
      (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
      (should (equal delivered "image: numpy.ndarray  shape=(128, 64)  dtype=float32"))
      (should (member (car (nth 1 scheduled)) cancelled))
      (should-not emacs-jupyter-notebook-variables--pending)
      (setq delivered nil)
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (should delivered)
      (should (= (length requests) 1))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest ejn-variables-point-move-drops-automatic-reply ()
  (ejn-variables-test--with-source
    (let (delivered)
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (ejn-variables-test--fire scheduled 0)
      (goto-char (point-max))
      (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
      (should-not delivered)
      (should-not emacs-jupyter-notebook-variables--cache)
      (should-not emacs-jupyter-notebook-variables--pending))))

(ert-deftest ejn-variables-edit-drops-automatic-reply ()
  (ejn-variables-test--with-source
    (let (delivered)
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (ejn-variables-test--fire scheduled 0)
      (save-excursion (goto-char (point-max)) (insert "# edit\n"))
      (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
      (should-not delivered)
      (should-not emacs-jupyter-notebook-variables--cache))))

(ert-deftest ejn-variables-invalidation-fences-old-client-and-old-generation ()
  (ejn-variables-test--with-source
    (let (delivered)
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (ejn-variables-test--fire scheduled 0)
      (emacs-jupyter-notebook-variables-invalidate)
      (setq emacs-jupyter-notebook--client
            (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (let ((new-token emacs-jupyter-notebook-variables--pending))
        (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
        (should-not delivered)
        (should (eq new-token emacs-jupyter-notebook-variables--pending))
        (ejn-variables-test--fire scheduled 2)
        (funcall (nth 3 (nth 1 requests)) 2 ejn-variables-test--reply)
        (should delivered)))))

(ert-deftest ejn-variables-timeout-and-teardown-cancel-delivery ()
  (ejn-variables-test--with-source
    (let ((delivered 'unset))
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (ejn-variables-test--fire scheduled 0)
      (ejn-variables-test--fire scheduled 1)
      (should-not delivered)
      (setq delivered 'unset)
      (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
      (should (eq delivered 'unset))
      (emacs-jupyter-notebook-variables-eldoc (lambda (value) (setq delivered value)))
      (emacs-jupyter-notebook-variables-teardown)
      (ejn-variables-test--fire scheduled 2)
      (should (= (length requests) 1))
      (should-not emacs-jupyter-notebook-variables--timer)
      (should-not emacs-jupyter-notebook-variables--pending))))

(ert-deftest ejn-variables-automatic-lookup-skips-busy-and-queued-executions ()
  (ejn-variables-test--with-source
    (setq emacs-jupyter-notebook--kernel-status 'busy)
    (should-not (emacs-jupyter-notebook-variables-eldoc #'ignore))
    (setq emacs-jupyter-notebook--kernel-status 'idle
          emacs-jupyter-notebook--execution-queue '(1))
    (should-not (emacs-jupyter-notebook-variables-eldoc #'ignore))
    (should-not scheduled)
    (setq emacs-jupyter-notebook--execution-queue nil)
    (emacs-jupyter-notebook-variables-eldoc #'ignore)
    (setq emacs-jupyter-notebook--execution-setup-pending t)
    (ejn-variables-test--fire scheduled 0)
    (should-not requests)
    (should-not emacs-jupyter-notebook-variables--pending)))

(ert-deftest ejn-variables-explicit-query-follows-eldoc-without-overlap ()
  (ejn-variables-test--with-source
    (let (explicit)
      (emacs-jupyter-notebook-variables-eldoc #'ignore)
      (ejn-variables-test--fire scheduled 0)
      (emacs-jupyter-notebook-variables--request
       nil (lambda (reply) (setq explicit reply)) #'ignore)
      (should (= (length requests) 1))
      (should emacs-jupyter-notebook-variables--queued)
      (funcall (nth 3 (car requests)) 1 ejn-variables-test--reply)
      (should-not emacs-jupyter-notebook-variables--queued)
      (should (= (length requests) 1))
      (ejn-variables-test--fire scheduled 2)
      (should (= (length requests) 2))
      (funcall (nth 3 (nth 1 requests)) 2 ejn-variables-test--reply)
      (should (equal explicit ejn-variables-test--reply)))))

(ert-deftest ejn-variables-simple-name-detection-rejects-attributes-and-literals ()
  (with-temp-buffer
    (python-mode)
    (dolist (text '("obj.image" "image.shape" "# image" "\"image\""))
      (erase-buffer) (insert text) (goto-char (point-min))
      (search-forward "image") (backward-char 2)
      (should-not (emacs-jupyter-notebook-variables--name-at-point)))
    (erase-buffer) (insert "image[0]") (goto-char (point-min))
    (should (equal "image" (emacs-jupyter-notebook-variables--name-at-point)))))

(ert-deftest ejn-variables-table-renders-scalar-shape-truncation-and-invalidation ()
  (ejn-variables-test--with-source
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (emacs-jupyter-notebook-list-variables))
    (ejn-variables-test--fire scheduled 0)
    (funcall (nth 3 (car requests)) 1
             '(:variables ((:name "scalar" :type "numpy.ndarray" :shape [] :dtype "int64"))
               :truncated t))
    (with-current-buffer emacs-jupyter-notebook-variables--table
      (should (string-match-p "scalar.*numpy.ndarray.*().*int64" (buffer-string)))
      (should (string-match-p "truncated" header-line-format)))
    (emacs-jupyter-notebook-variables-invalidate)
    (with-current-buffer emacs-jupyter-notebook-variables--table
      (should-not tabulated-list-entries)
      (should (string-match-p "refresh" header-line-format)))))

(ert-deftest ejn-variables-setup-restores-eldoc-and-hooks ()
  (with-temp-buffer
    (eldoc-mode -1)
    (emacs-jupyter-notebook-variables-setup)
    (should eldoc-mode)
    (should (memq #'emacs-jupyter-notebook-variables-eldoc eldoc-documentation-functions))
    (emacs-jupyter-notebook-variables-setup)
    (emacs-jupyter-notebook-variables-teardown)
    (should-not eldoc-mode)
    (should-not (memq #'emacs-jupyter-notebook-variables-eldoc eldoc-documentation-functions))
    (add-hook 'eldoc-documentation-functions #'ignore nil t)
    (eldoc-mode 1)
    (emacs-jupyter-notebook-variables-setup)
    (emacs-jupyter-notebook-variables-teardown)
    (should eldoc-mode)))

(ert-deftest ejn-variables-evil-table-commands-cover-normal-and-motion ()
  (let (initial binding)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (&rest args) (setq initial args)))
              ((symbol-function 'evil-define-key*)
               (lambda (&rest args) (setq binding args))))
      (emacs-jupyter-notebook-variables--evil-setup))
    (should (equal initial '(emacs-jupyter-notebook-variables-mode emacs)))
    (should (equal (car binding) '(normal motion)))
    (should (eq (nth 1 binding) emacs-jupyter-notebook-variables-mode-map))
    (should (equal (cddr binding)
                   (list (kbd "g") #'emacs-jupyter-notebook-variables-refresh
                         (kbd "RET") #'emacs-jupyter-notebook-variables-inspect-row
                         (kbd "q") #'quit-window)))))

(provide 'emacs-jupyter-notebook-variables-tests)
;;; emacs-jupyter-notebook-variables-tests.el ends here
