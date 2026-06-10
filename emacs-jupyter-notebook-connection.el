;;; emacs-jupyter-notebook-connection.el --- Jupyter connection-file helpers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Read, write, and rewrite Jupyter connection metadata for SSH tunnels.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'emacs-jupyter-notebook-vars)

(defun emacs-jupyter-notebook-connection-read-file (file)
  "Read Jupyter connection metadata from FILE as a plist."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((json-object-type 'plist)
          (json-key-type 'keyword)
          (json-array-type 'list)
          (json-false :false))
      (json-read))))

(defun emacs-jupyter-notebook-connection-write-file (plist file)
  "Write Jupyter connection PLIST to FILE as JSON."
  (let ((directory (file-name-directory file)))
    (when directory
      (make-directory directory t)))
  (with-temp-file file
    (insert (json-encode plist))
    (insert "\n"))
  file)

(defun emacs-jupyter-notebook-connection-ports (plist)
  "Return channel ports from connection PLIST as a plist."
  (cl-loop for key in emacs-jupyter-notebook-connection-port-keys
           when (plist-member plist key)
           append (list key (plist-get plist key))))

(defun emacs-jupyter-notebook-connection-rewrite-ports (plist local-ports)
  "Return a copy of PLIST rewritten for LOCAL-PORTS.
LOCAL-PORTS is a plist keyed by
`emacs-jupyter-notebook-connection-port-keys'.  When LOCAL-PORTS
is nil, return an unchanged copy."
  (let ((rewritten (copy-sequence plist)))
    (when local-ports
      (setq rewritten (plist-put rewritten :ip "127.0.0.1"))
      (setq rewritten (plist-put rewritten :transport "tcp"))
      (dolist (key emacs-jupyter-notebook-connection-port-keys)
        (when (plist-member local-ports key)
          (setq rewritten (plist-put rewritten key (plist-get local-ports key))))))
    rewritten))

(defun emacs-jupyter-notebook-connection--free-local-port ()
  "Return a currently free TCP port on 127.0.0.1."
  (let ((server (make-network-process :name "emacs-jupyter-notebook-port"
                                      :server t
                                      :host "127.0.0.1"
                                      :service t
                                      :noquery t)))
    (unwind-protect
        (process-contact server :service)
      (delete-process server))))

(defun emacs-jupyter-notebook-connection-allocate-local-ports ()
  "Return a plist of fresh local ports for all Jupyter channels."
  (cl-loop for key in emacs-jupyter-notebook-connection-port-keys
           append (list key (emacs-jupyter-notebook-connection--free-local-port))))

(provide 'emacs-jupyter-notebook-connection)

;;; emacs-jupyter-notebook-connection.el ends here
