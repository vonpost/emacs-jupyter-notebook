;;; emacs-jupyter-notebook-jupyter.el --- Lazy emacs-jupyter adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Thin, mockable adapter around emacs-jupyter.  This file intentionally
;; avoids requiring emacs-jupyter at top level so local ERT tests can run
;; without that package installed.

;;; Code:

(require 'cl-lib)

(declare-function jupyter-kernel "jupyter-kernel" (&rest args))
(declare-function jupyter-client "jupyter-client" (kernel &optional client-class))
(declare-function jupyter-eval-string "jupyter-client" (str &optional insert beg end))
(declare-function jupyter-interrupt-kernel "jupyter-client" (client))
(declare-function jupyter-restart-kernel "jupyter-client" (client))
(declare-function jupyter-shutdown-kernel "jupyter-client" (client))
(declare-function jupyter-insert "jupyter-mime" (mime-or-plist &optional metadata))
(declare-function jupyter-eval-remove-overlays "jupyter-client" ())
(defvar jupyter-current-client)
(defvar jupyter-eval-use-overlays)

(defvar emacs-jupyter-notebook-jupyter-connect-function
  #'emacs-jupyter-notebook-jupyter--connect
  "Function used by `emacs-jupyter-notebook-jupyter-connect'.")

(defvar emacs-jupyter-notebook-jupyter-evaluate-function
  #'emacs-jupyter-notebook-jupyter--evaluate
  "Function used by `emacs-jupyter-notebook-jupyter-evaluate'.")

(defvar emacs-jupyter-notebook-jupyter-interrupt-function
  #'emacs-jupyter-notebook-jupyter--interrupt
  "Function used by `emacs-jupyter-notebook-jupyter-interrupt'.")

(defvar emacs-jupyter-notebook-jupyter-restart-function
  #'emacs-jupyter-notebook-jupyter--restart
  "Function used by `emacs-jupyter-notebook-jupyter-restart'.")

(defvar emacs-jupyter-notebook-jupyter-shutdown-function
  #'emacs-jupyter-notebook-jupyter--shutdown
  "Function used by `emacs-jupyter-notebook-jupyter-shutdown'.")

(defun emacs-jupyter-notebook-jupyter-available-p ()
  "Return non-nil when emacs-jupyter can be loaded."
  (require 'jupyter nil t))

(defun emacs-jupyter-notebook-jupyter--ensure ()
  "Ensure emacs-jupyter is loaded or signal a helpful error."
  (unless (emacs-jupyter-notebook-jupyter-available-p)
    (error "emacs-jupyter is not installed or not on `load-path'")))

(defun emacs-jupyter-notebook-jupyter--connect (connection-file)
  "Connect to an existing kernel described by CONNECTION-FILE."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-kernel)
  (require 'jupyter-client)
  (jupyter-client (jupyter-kernel :conn-info connection-file :connect-p t)))

(defun emacs-jupyter-notebook-jupyter--evaluate (client code beg end)
  "Evaluate CODE using CLIENT with source bounds BEG and END."
  (emacs-jupyter-notebook-jupyter--ensure)
  (require 'jupyter-client)
  (let ((jupyter-current-client client)
        (jupyter-eval-use-overlays t))
    (jupyter-eval-string code nil beg end)))

(defun emacs-jupyter-notebook-jupyter--interrupt (client)
  "Interrupt CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-interrupt-kernel client))

(defun emacs-jupyter-notebook-jupyter--restart (client)
  "Restart CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-restart-kernel client))

(defun emacs-jupyter-notebook-jupyter--shutdown (client)
  "Shut down CLIENT's kernel."
  (emacs-jupyter-notebook-jupyter--ensure)
  (jupyter-shutdown-kernel client))

(defun emacs-jupyter-notebook-jupyter-connect (connection-file)
  "Connect to CONNECTION-FILE through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-connect-function connection-file))

(defun emacs-jupyter-notebook-jupyter-evaluate (client code beg end)
  "Evaluate CODE through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-evaluate-function client code beg end))

(defun emacs-jupyter-notebook-jupyter-interrupt (client)
  "Interrupt CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-interrupt-function client))

(defun emacs-jupyter-notebook-jupyter-restart (client)
  "Restart CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-restart-function client))

(defun emacs-jupyter-notebook-jupyter-shutdown (client)
  "Shut down CLIENT through the configured adapter."
  (funcall emacs-jupyter-notebook-jupyter-shutdown-function client))

(defun emacs-jupyter-notebook-jupyter-clear-overlays ()
  "Clear emacs-jupyter's own evaluation overlays when available."
  (when (and (featurep 'jupyter-client)
             (fboundp 'jupyter-eval-remove-overlays))
    (jupyter-eval-remove-overlays)))

(provide 'emacs-jupyter-notebook-jupyter)

;;; emacs-jupyter-notebook-jupyter.el ends here
