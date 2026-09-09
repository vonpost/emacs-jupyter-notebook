;;; emacs-jupyter-notebook-cell.el --- Code-cell integration via code-cells  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Thin wrapper around code-cells for cell bounds and navigation.

;;; Code:

(require 'cl-lib)
(require 'code-cells)

(defvar-local emacs-jupyter-notebook-cell--bounds-cache nil
  "Last complete cell bounds and the source context in which they were scanned.")

(defconst emacs-jupyter-notebook-cell--automatic-scan-limit 1048576
  "Maximum source characters scanned by automatic follow/edit-label hooks.
Explicit cell commands and exact deletion tracking still work in larger files.")

(defun emacs-jupyter-notebook-cell-bounds ()
  "Return the current cell code bounds as (BEG . END).
Delegates to `code-cells--bounds' with NO-HEADER non-nil so that
cell marker lines are excluded from the returned code bounds."
  (pcase-let ((`(,beg ,end) (code-cells--bounds 1 nil t)))
    (cons beg end)))

(defun emacs-jupyter-notebook-cell-full-bounds ()
  "Return current cell bounds as (BEG . END), including the marker line.
Reuse the current cell's scan while text, restriction, and boundary syntax
remain unchanged.  Source-follow hooks run on every command, including small
point motions, and must not repeatedly scan a multi-megabyte cell."
  (let* ((context (list (buffer-chars-modified-tick) (point-min) (point-max)
                        code-cells-boundary-regexp (syntax-table)))
         (cached emacs-jupyter-notebook-cell--bounds-cache)
         (bounds (cdr cached)))
    (if (and (equal context (car cached)) bounds
             (<= (car bounds) (point))
             (or (< (point) (cdr bounds))
                 (= (point) (cdr bounds) (point-max))))
        (cons (car bounds) (cdr bounds))
      (pcase-let ((`(,beg ,end) (code-cells--bounds 1 nil nil)))
        (setq emacs-jupyter-notebook-cell--bounds-cache
              (cons context (cons beg end)))
        (cons beg end)))))

(defun emacs-jupyter-notebook-cell-code-start (&optional position)
  "Return the code start for the cell at POSITION or point."
  (save-excursion
    (when position
      (goto-char position))
    (pcase-let ((`(,beg . ,_end) (emacs-jupyter-notebook-cell-full-bounds)))
      (goto-char beg)
      (when (looking-at-p code-cells-boundary-regexp)
        (forward-line 1))
      (point))))

(defun emacs-jupyter-notebook-cell-goto-code-start (&optional position)
  "Move to the code start for the cell at POSITION or point."
  (goto-char (emacs-jupyter-notebook-cell-code-start position)))

(defun emacs-jupyter-notebook-cell-code ()
  "Return the current cell code without text properties."
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (buffer-substring-no-properties beg end)))

(defun emacs-jupyter-notebook-cell-end-position ()
  "Return the end position of the current cell code."
  (cdr (emacs-jupyter-notebook-cell-bounds)))

(defun emacs-jupyter-notebook-forward-cell (&optional arg)
  "Move to the next cell body.
With ARG, repeat that many times.  Negative ARG moves backward."
  (interactive "p")
  (let ((origin (car (emacs-jupyter-notebook-cell-full-bounds))))
    (code-cells-forward-cell (or arg 1))
    (when (= origin (car (emacs-jupyter-notebook-cell-full-bounds)))
      (user-error "No next cell"))
    (emacs-jupyter-notebook-cell-goto-code-start)))

(defun emacs-jupyter-notebook-backward-cell (&optional arg)
  "Move to the previous cell body.
With ARG, repeat that many times.  Negative ARG moves forward."
  (interactive "p")
  (let ((arg (or arg 1)))
    (if (< arg 0)
        (emacs-jupyter-notebook-forward-cell (- arg))
      (let ((origin (car (emacs-jupyter-notebook-cell-full-bounds))))
        (goto-char origin)
        (code-cells-backward-cell arg)
        (when (= origin (car (emacs-jupyter-notebook-cell-full-bounds)))
          (user-error "No previous cell"))
        (emacs-jupyter-notebook-cell-goto-code-start)))))

(defun emacs-jupyter-notebook-cell-goto-code-end ()
  "Move to the end of the current cell code."
  (goto-char (emacs-jupyter-notebook-cell-end-position)))

(defun emacs-jupyter-notebook-cell-insert-below ()
  "Insert an empty cell below the current cell and move into it."
  (pcase-let ((`(,_beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (goto-char end)
    (unless (or (bolp) (= (point) (point-min)))
      (insert "\n"))
    (let ((start (point)))
      (insert "# %%\n")
      (emacs-jupyter-notebook-cell-goto-code-start start))))

(defun emacs-jupyter-notebook-cell-insert-above ()
  "Insert an empty cell above the current cell and move into it."
  (pcase-let ((`(,beg . ,_end) (emacs-jupyter-notebook-cell-full-bounds)))
    (goto-char beg)
    (let ((start (point)))
      (insert "# %%\n")
      (emacs-jupyter-notebook-cell-goto-code-start start))))

(provide 'emacs-jupyter-notebook-cell)

;;; emacs-jupyter-notebook-cell.el ends here
