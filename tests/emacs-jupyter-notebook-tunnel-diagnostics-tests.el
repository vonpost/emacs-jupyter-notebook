;;; emacs-jupyter-notebook-tunnel-diagnostics-tests.el --- SSH exit evidence -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-jupyter-notebook)

(defmacro ejn-tunnel-diagnostic-test--with-process (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((source (current-buffer))
           (stderr (generate-new-buffer " *ejn-test-tunnel-stderr*"))
           (live nil) (status 'exit) (exit-code 255) sentinel reason expected
           (stderr-reads 0))
       (setq-local emacs-jupyter-notebook--tunnel-process 'test-tunnel)
       (unwind-protect
           (cl-letf (((symbol-function 'process-live-p) (lambda (_) live))
                     ((symbol-function 'process-status) (lambda (_) status))
                     ((symbol-function 'process-exit-status) (lambda (_) exit-code))
                     ((symbol-function 'set-process-sentinel)
                      (lambda (_process function) (setq sentinel function)))
                     ((symbol-function 'process-get)
                      (lambda (_process property)
                        (when (eq property 'emacs-jupyter-notebook-stderr-buffer)
                          (cl-incf stderr-reads)
                          stderr)))
                     ((symbol-function 'emacs-jupyter-notebook--transport-lost)
                      (lambda (detail _client process)
                        (setq reason detail expected process)
                        ;; Simulate teardown immediately; diagnostics must
                        ;; have been captured before this buffer disappears.
                        (when (buffer-live-p stderr) (kill-buffer stderr)))))
             ,@body)
         (when (buffer-live-p stderr) (kill-buffer stderr))))))

(ert-deftest ejn-tunnel-diagnostic-already-dead-preserves-status-and-redacted-stderr ()
  (ejn-tunnel-diagnostic-test--with-process
    (with-current-buffer stderr
      (insert "Permission denied (publickey).\npassword=hunter-test-secret\n"))
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should (equal expected 'test-tunnel))
    (should (string-match-p "exit status 255" reason))
    (should (string-match-p "Permission denied" reason))
    (should-not (string-match-p "hunter-test-secret" reason))
    (should-not (buffer-live-p stderr))))

(ert-deftest ejn-tunnel-diagnostic-live-sentinel-preserves-signal-and-sanitizes-controls ()
  (ejn-tunnel-diagnostic-test--with-process
    (setq live t)
    (with-current-buffer stderr (insert "Connection closed\r\n\e[31mbroken\0\n"))
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should-not reason)
    (setq live nil status 'signal exit-code 15)
    (funcall sentinel 'test-tunnel "untrusted ignored event")
    (should (string-match-p "signal 15" reason))
    (should (string-match-p "Connection closed" reason))
    (should-not (string-match-p "[[:cntrl:]]" reason))))

(ert-deftest ejn-tunnel-diagnostic-missing-stderr-still-preserves-exit-code ()
  (ejn-tunnel-diagnostic-test--with-process
    (kill-buffer stderr)
    (setq stderr nil exit-code 0)
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should (string-match-p "exit status 0" reason))))

(ert-deftest ejn-tunnel-diagnostic-stale-tunnel-never-reads-stderr-or-transitions ()
  (ejn-tunnel-diagnostic-test--with-process
    (setq live t)
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (setq-local emacs-jupyter-notebook--tunnel-process 'replacement-tunnel)
    (setq live nil)
    (funcall sentinel 'test-tunnel "finished")
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should-not reason)
    (should (= stderr-reads 0))))

(ert-deftest ejn-tunnel-diagnostic-bounds-read-and-omits-cut-credential-line ()
  (ejn-tunnel-diagnostic-test--with-process
    (with-current-buffer stderr
      (insert "password=" (make-string 20000 ?s) "TAIL_SECRET\nConnection reset by peer\n"))
    (let ((substring-function (symbol-function 'buffer-substring-no-properties)))
      (cl-letf (((symbol-function 'buffer-string)
                 (lambda () (ert-fail "Unbounded whole-buffer diagnostic copy")))
                ((symbol-function 'buffer-substring-no-properties)
                 (lambda (start end)
                   (should (<= (- end start) 4096))
                   (funcall substring-function start end))))
        (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)))
    (should (<= (string-bytes reason) 512))
    (should (string-match-p "Connection reset by peer" reason))
    (should-not (string-match-p "TAIL_SECRET" reason))))

(ert-deftest ejn-tunnel-diagnostic-single-overlong-line-is-omitted ()
  (ejn-tunnel-diagnostic-test--with-process
    (with-current-buffer stderr (insert "password=" (make-string 20000 ?s) "TAIL_SECRET"))
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should (string-match-p "exit status 255" reason))
    (should-not (string-match-p "TAIL_SECRET" reason))
    (should (<= (string-bytes reason) 512))))

(ert-deftest ejn-tunnel-diagnostic-multibyte-output-is-byte-bounded ()
  (ejn-tunnel-diagnostic-test--with-process
    (with-current-buffer stderr (dotimes (_ 1500) (insert "界 ")))
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (should (string-match-p "exit status 255" reason))
    (should (<= (string-bytes reason) 512))
    (should (string-suffix-p "[truncated]" reason))))

(ert-deftest ejn-tunnel-diagnostic-redacts-credentials-before-flattening-lines ()
  (ejn-tunnel-diagnostic-test--with-process
    (with-current-buffer stderr
      (insert "token: token-test-value\nhttps://user:pass-test-value@example.invalid/path\n"
              "Bearer bearer-test-value\nConnection reset by peer\n"))
    (emacs-jupyter-notebook--install-tunnel-sentinel 'test-tunnel source)
    (dolist (secret '("token-test-value" "pass-test-value" "bearer-test-value"))
      (should-not (string-match-p secret reason)))
    (should (string-match-p "Connection reset by peer" reason))
    (should-not (string-match-p "[[:cntrl:]]" reason))))

(provide 'emacs-jupyter-notebook-tunnel-diagnostics-tests)
;;; emacs-jupyter-notebook-tunnel-diagnostics-tests.el ends here
