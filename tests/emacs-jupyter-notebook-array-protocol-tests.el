;;; emacs-jupyter-notebook-array-protocol-tests.el --- Array manifest gates -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'emacs-jupyter-notebook-helper-protocol)

(defconst ejn-array-protocol-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (file-truename load-file-name)))))

(defun ejn-array-protocol-test--fixture ()
  (let ((json-object-type 'hash-table)
        (json-array-type 'vector)
        (json-key-type 'string))
    (json-read-file
     (expand-file-name "tests/fixtures/viewer-contract-v1.json"
                       ejn-array-protocol-test--root))))

(defun ejn-array-protocol-test--header (vector)
  (let ((json-object-type 'hash-table)
        (json-array-type 'vector)
        (json-key-type 'string))
    (json-read-from-string (gethash "header_json" vector))))

(defun ejn-array-protocol-test--bytes (vector)
  (+ 12 (gethash "header_length" vector)
     (/ (length (gethash "raw_hex" vector)) 2)))

(ert-deftest ejn-array-protocol-valid-fixture-headers-pass ()
  (let ((fixture (ejn-array-protocol-test--fixture)))
    (dotimes (index (length (gethash "valid" fixture)))
      (let ((vector (aref (gethash "valid" fixture) index)))
        (should (ejn-helper-protocol-array-manifest-p
                 (ejn-array-protocol-test--header vector)
                 (ejn-array-protocol-test--bytes vector)))))))

(ert-deftest ejn-array-protocol-rejection-fixtures-fail ()
  (let ((fixture (ejn-array-protocol-test--fixture)))
    (dotimes (index (length (gethash "rejections" fixture)))
      (let ((vector (aref (gethash "rejections" fixture) index)))
        (unless (member (gethash "name" vector)
                        '("duplicate-json-key" "trailing-bytes"))
          (should-not (ejn-helper-protocol-array-manifest-p
                       (ejn-array-protocol-test--header vector)
                       (ejn-array-protocol-test--bytes vector))))))))

(ert-deftest ejn-array-protocol-rejects-too-many-planes-and-bad-offset ()
  (let* ((fixture (ejn-array-protocol-test--fixture))
         (manifest (ejn-array-protocol-test--header (aref (gethash "valid" fixture) 0)))
         (planes (gethash "planes" manifest))
         (bad-plane (copy-hash-table (aref planes 0))))
    (puthash "offset" 2 bad-plane)
    (puthash "planes" (vector (aref planes 0) bad-plane) manifest)
    (should-not (ejn-helper-protocol-array-manifest-p manifest 40))
    (puthash "planes" (make-vector 5 (aref planes 0)) manifest)
    (should-not (ejn-helper-protocol-array-manifest-p manifest 100))))

(provide 'emacs-jupyter-notebook-array-protocol-tests)
;;; emacs-jupyter-notebook-array-protocol-tests.el ends here
