;;; emacs-jupyter-notebook-result.el --- Inline result overlays  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Package-owned result overlays.  These never alter visited source text.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

(defface emacs-jupyter-notebook-result-face
  '((t :inherit font-lock-doc-face))
  "Face used for inline text results."
  :group 'emacs-jupyter-notebook)

(defun emacs-jupyter-notebook-result--text (result)
  "Return a display string for RESULT."
  (let ((text (cond
               ((stringp result) result)
               ((and (listp result) (plist-get result :text/plain))
                (plist-get result :text/plain))
               ((and (listp result)
                     (plist-get result :data)
                     (plist-get (plist-get result :data) :text/plain))
                (plist-get (plist-get result :data) :text/plain))
               ((and (listp result) (plist-get result :ename))
                (format "%s: %s"
                        (plist-get result :ename)
                        (or (plist-get result :evalue) "")))
               (t (format "%S" result)))))
    (if (<= emacs-jupyter-notebook-result-max-lines 0)
        text
      (let ((lines (split-string text "\n")))
        (if (<= (length lines) emacs-jupyter-notebook-result-max-lines)
            text
          (concat (string-join
                   (seq-take lines emacs-jupyter-notebook-result-max-lines)
                   "\n")
                  "\n..."))))))

(defun emacs-jupyter-notebook-result--all-overlays ()
  "Return all package-owned result overlays in the current buffer."
  (let (overlays)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'emacs-jupyter-notebook-result)
        (push ov overlays)))
    (dolist (ov (overlays-at (point-max)))
      (when (and (overlay-get ov 'emacs-jupyter-notebook-result)
                 (not (memq ov overlays)))
        (push ov overlays)))
    overlays))

(defun emacs-jupyter-notebook-result-clear-region (beg end)
  "Clear result overlays whose source range intersects BEG and END."
  (dolist (ov (emacs-jupyter-notebook-result--all-overlays))
    (let ((source-beg (overlay-get ov 'emacs-jupyter-notebook-source-begin))
          (source-end (overlay-get ov 'emacs-jupyter-notebook-source-end)))
      (when (and source-beg source-end
                 (<= beg source-end)
                 (<= source-beg end))
        (delete-overlay ov)))))

(defun emacs-jupyter-notebook-result-clear-all ()
  "Clear all package-owned result overlays in the current buffer."
  (interactive)
  (mapc #'delete-overlay (emacs-jupyter-notebook-result--all-overlays)))

(defun emacs-jupyter-notebook-result-create (beg end result)
  "Display RESULT after END as an overlay attached to source BEG and END."
  (emacs-jupyter-notebook-result-clear-region beg end)
  (let* ((text (emacs-jupyter-notebook-result--text result))
         (display (concat "\n"
                          (propertize text 'face 'emacs-jupyter-notebook-result-face)
                          (unless (string-suffix-p "\n" text) "\n")))
         (ov (make-overlay end end (current-buffer) t t)))
    (overlay-put ov 'emacs-jupyter-notebook-result t)
    (overlay-put ov 'emacs-jupyter-notebook-source-begin beg)
    (overlay-put ov 'emacs-jupyter-notebook-source-end end)
    (overlay-put ov 'after-string display)
    (overlay-put ov 'priority 1000)
    ov))

(provide 'emacs-jupyter-notebook-result)

;;; emacs-jupyter-notebook-result.el ends here
