;;; emacs-jupyter-notebook-cell.el --- Code-cell integration via code-cells  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Thin wrapper around code-cells for cell bounds and navigation.

;;; Code:

(require 'code-cells)

(defun emacs-jupyter-notebook-cell-bounds ()
  "Return the current cell code bounds as (BEG . END).
Delegates to `code-cells--bounds' with NO-HEADER non-nil so that
cell marker lines are excluded from the returned code bounds."
  (pcase-let ((`(,beg ,end) (code-cells--bounds 1 nil t)))
    (cons beg end)))

(defun emacs-jupyter-notebook-cell-code ()
  "Return the current cell code without text properties."
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (buffer-substring-no-properties beg end)))

(defun emacs-jupyter-notebook-cell-end-position ()
  "Return the end position of the current cell code."
  (cdr (emacs-jupyter-notebook-cell-bounds)))

(defun emacs-jupyter-notebook-forward-cell (&optional arg)
  "Move to the next cell boundary.
With ARG, repeat that many times.  Negative ARG moves backward."
  (interactive "p")
  (code-cells-forward-cell arg))

(defun emacs-jupyter-notebook-backward-cell (&optional arg)
  "Move to the previous cell boundary.
With ARG, repeat that many times.  Negative ARG moves forward."
  (interactive "p")
  (code-cells-backward-cell arg))

(provide 'emacs-jupyter-notebook-cell)

;;; emacs-jupyter-notebook-cell.el ends here
