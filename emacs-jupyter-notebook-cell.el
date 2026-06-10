;;; emacs-jupyter-notebook-cell.el --- Code-cell boundary detection  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Python v1 # %% cell boundary support for ordinary source buffers.

;;; Code:

(require 'cl-lib)
(require 'emacs-jupyter-notebook-vars)

(defun emacs-jupyter-notebook-cell-marker-regexp ()
  "Return the cell marker regexp for the current buffer."
  (or (alist-get major-mode emacs-jupyter-notebook-language-cell-markers)
      emacs-jupyter-notebook-default-cell-marker-regexp))

(defun emacs-jupyter-notebook-cell-marker-line-p (&optional pos)
  "Return non-nil when POS is on a cell marker line.
POS defaults to point."
  (save-excursion
    (when pos (goto-char pos))
    (beginning-of-line)
    (looking-at-p (emacs-jupyter-notebook-cell-marker-regexp))))

(defun emacs-jupyter-notebook-cell--previous-marker ()
  "Return the beginning position of the marker for the current cell.
Return nil when there is no previous marker in the accessible
portion of the buffer."
  (save-excursion
    (end-of-line)
    (when (re-search-backward (emacs-jupyter-notebook-cell-marker-regexp)
                              (point-min) t)
      (line-beginning-position))))

(defun emacs-jupyter-notebook-cell--next-marker (from)
  "Return the next marker beginning after FROM, or nil."
  (save-excursion
    (goto-char from)
    (when (re-search-forward (emacs-jupyter-notebook-cell-marker-regexp)
                             (point-max) t)
      (match-beginning 0))))

(defun emacs-jupyter-notebook-cell-bounds ()
  "Return the current cell code bounds as (BEG . END).
Marker lines delimit cells but are not included in the returned
code bounds.  If the buffer has no markers, return the accessible
buffer bounds."
  (let* ((marker (emacs-jupyter-notebook-cell--previous-marker))
         (beg (if marker
                  (save-excursion
                    (goto-char marker)
                    (forward-line 1)
                    (point))
                (point-min)))
         (end (or (emacs-jupyter-notebook-cell--next-marker beg)
                  (point-max))))
    (cons beg end)))

(defun emacs-jupyter-notebook-cell-code ()
  "Return the current cell code without text properties."
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (buffer-substring-no-properties beg end)))

(defun emacs-jupyter-notebook-cell-end-position ()
  "Return the end position of the current cell code."
  (cdr (emacs-jupyter-notebook-cell-bounds)))

(provide 'emacs-jupyter-notebook-cell)

;;; emacs-jupyter-notebook-cell.el ends here
