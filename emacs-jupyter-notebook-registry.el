;;; emacs-jupyter-notebook-registry.el --- Durable remote-kernel registry  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Registry serialization for reconnecting to remote kernels after restart.

;;; Code:

(require 'cl-lib)
(require 'emacs-jupyter-notebook-vars)

(defun emacs-jupyter-notebook-registry--entry-key (entry)
  "Return the durable identity key for ENTRY."
  (or (plist-get entry :session-id)
      (plist-get entry :profile)
      (error "Registry entry has no :session-id or :profile")))

(defun emacs-jupyter-notebook-registry-load (&optional file)
  "Load registry entries from FILE.
When FILE is nil, use `emacs-jupyter-notebook-registry-file'.
Return nil for missing or unreadable files."
  (let ((file (or file emacs-jupyter-notebook-registry-file)))
    (if (not (file-readable-p file))
        nil
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (let ((data (read (current-buffer))))
              (unless (listp data)
                (error "Registry root is not a list"))
              data))
        (error
         (display-warning 'emacs-jupyter-notebook
                          (format "Ignoring unreadable registry %s: %s"
                                  file (error-message-string err)))
         nil)))))

(defun emacs-jupyter-notebook-registry-save (entries &optional file)
  "Atomically save ENTRIES to FILE with mode 0600.
When FILE is nil, use `emacs-jupyter-notebook-registry-file'."
  (let* ((file (or file emacs-jupyter-notebook-registry-file))
         (directory (file-name-directory file)))
    (when directory
      (make-directory directory t))
    (let ((tmp (make-temp-file (concat (or directory "")
                                       (file-name-nondirectory file) ".")
                               nil ".tmp")))
      (unwind-protect
          (progn
            (with-temp-file tmp
              (let ((print-length nil)
                    (print-level nil))
                (prin1 entries (current-buffer))
                (insert "\n")))
            (set-file-modes tmp #o600)
            (rename-file tmp file t)
            (set-file-modes file #o600))
        (when (file-exists-p tmp)
          (ignore-errors (delete-file tmp)))))))

(defun emacs-jupyter-notebook-registry-upsert (entry &optional entries)
  "Return ENTRIES with ENTRY inserted or replaced by identity key."
  (let* ((entries (copy-sequence entries))
         (key (emacs-jupyter-notebook-registry--entry-key entry))
         (replaced nil))
    (setq entries
          (mapcar (lambda (existing)
                    (if (equal key (emacs-jupyter-notebook-registry--entry-key existing))
                        (progn
                          (setq replaced t)
                          entry)
                      existing))
                  entries))
    (if replaced entries (cons entry entries))))

(defun emacs-jupyter-notebook-registry-save-entry (entry &optional file)
  "Insert or replace ENTRY in FILE."
  (emacs-jupyter-notebook-registry-save
   (emacs-jupyter-notebook-registry-upsert
    entry (emacs-jupyter-notebook-registry-load file))
   file))

(defun emacs-jupyter-notebook-registry-remove (key &optional entries)
  "Return ENTRIES without an entry identified by KEY."
  (cl-remove-if (lambda (entry)
                  (equal key (emacs-jupyter-notebook-registry--entry-key entry)))
                entries))

(defun emacs-jupyter-notebook-registry-remove-entry (key &optional file)
  "Remove registry entry identified by KEY from FILE."
  (emacs-jupyter-notebook-registry-save
   (emacs-jupyter-notebook-registry-remove
    key (emacs-jupyter-notebook-registry-load file))
   file))

(defun emacs-jupyter-notebook-registry-find (key &optional entries)
  "Return the entry identified by KEY in ENTRIES."
  (cl-find-if (lambda (entry)
                (equal key (emacs-jupyter-notebook-registry--entry-key entry)))
              entries))

(defun emacs-jupyter-notebook-registry-latest-for-profile (profile &optional entries)
  "Return the newest registry entry for PROFILE in ENTRIES."
  (car (sort (cl-remove-if-not
              (lambda (entry)
                (equal profile (plist-get entry :profile)))
              (copy-sequence entries))
             (lambda (a b)
               (string> (or (plist-get a :created-at) "")
                        (or (plist-get b :created-at) ""))))))

(provide 'emacs-jupyter-notebook-registry)

;;; emacs-jupyter-notebook-registry.el ends here
