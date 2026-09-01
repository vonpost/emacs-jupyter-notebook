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

(defconst emacs-jupyter-notebook-connection-max-bytes 65536)

(defconst emacs-jupyter-notebook-connection--field-map
  '(("ip" . :ip)
    ("transport" . :transport)
    ("key" . :key)
    ("signature_scheme" . :signature_scheme)
    ("shell_port" . :shell_port)
    ("iopub_port" . :iopub_port)
    ("stdin_port" . :stdin_port)
    ("hb_port" . :hb_port)
    ("control_port" . :control_port)
    ("kernel_name" . :kernel_name))
  "Fixed Jupyter connection fields admitted without interning JSON keys.")

(defun emacs-jupyter-notebook-connection--normalize-object (object)
  "Return validated string-key alist OBJECT as a fixed-key plist."
  (unless (listp object)
    (error "Connection JSON must be an object"))
  (let ((seen (make-hash-table :test #'equal)))
    ;; Validate the complete key set before constructing a plist.  In
    ;; particular, never call `intern' on untrusted connection-file keys.
    (dolist (field object)
      (unless (and (consp field) (stringp (car field))
                   (assoc (car field)
                          emacs-jupyter-notebook-connection--field-map))
        (error "Connection JSON contains an unknown field"))
      (when (gethash (car field) seen)
        (error "Connection JSON contains a duplicate field"))
      (puthash (car field) t seen))
    (cl-loop for (key . value) in object
             append
             (list (cdr (assoc key emacs-jupyter-notebook-connection--field-map))
                   value))))

(defun emacs-jupyter-notebook-connection-parse-bytes (raw)
  "Parse bounded unibyte connection JSON RAW into a fixed-key plist."
  (unless (stringp raw)
    (error "Connection data must be a byte string"))
  (when (> (string-bytes raw) emacs-jupyter-notebook-connection-max-bytes)
    (error "Connection file exceeds %d bytes"
           emacs-jupyter-notebook-connection-max-bytes))
  (let (text)
    (condition-case err
        (setq text (decode-coding-string raw 'utf-8))
      (error (error "Connection file is not valid UTF-8: %s"
                    (error-message-string err))))
    (when (cl-some (lambda (character) (> character #x10ffff)) text)
      (error "Connection file is not valid UTF-8"))
    (condition-case err
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (skip-chars-forward " \t\r\n")
          (unless (eq (char-after) ?{)
            (error "Connection JSON must be an object"))
          (let* ((json-object-type 'alist)
                 (json-key-type 'string)
                 (json-array-type 'list)
                 (json-false :false)
                 (connection (json-read)))
            (skip-chars-forward " \t\r\n")
            (unless (eobp)
              (error "Connection file contains trailing data"))
            (emacs-jupyter-notebook-connection--normalize-object connection)))
      (error (error "Connection file is not valid JSON: %s"
                    (error-message-string err))))))

(defun emacs-jupyter-notebook-connection-read-file (file)
  "Read bounded UTF-8 Jupyter connection metadata from FILE as a plist."
  (unless (and (stringp file)
               (file-name-absolute-p file)
               (not (file-remote-p file))
               (file-regular-p file)
               (file-readable-p file))
    (error "Connection file is not a readable local regular file"))
  (let (raw)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0
                                      (1+ emacs-jupyter-notebook-connection-max-bytes))
      (setq raw (buffer-string)))
    (emacs-jupyter-notebook-connection-parse-bytes raw)))

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

(defun emacs-jupyter-notebook-connection-valid-ports-p (ports)
  "Return non-nil when PORTS has every Jupyter port exactly once.
The durable restart contract cannot guess a missing remote port: a seeded
connection file with one stale local port would make a replacement kernel
unreachable or, worse, point at an unrelated service."
  (and (listp ports)
       (zerop (% (length ports) 2))
       (= (length ports) (* 2 (length emacs-jupyter-notebook-connection-port-keys)))
       (let ((keys (cl-loop for (key _value) on ports by #'cddr collect key))
             (values (cl-loop for (_key value) on ports by #'cddr collect value)))
         (and (cl-every #'symbolp keys)
              (equal (sort (copy-sequence keys)
                           (lambda (left right)
                             (string< (symbol-name left) (symbol-name right))))
                     (sort (copy-sequence emacs-jupyter-notebook-connection-port-keys)
                           (lambda (left right)
                             (string< (symbol-name left) (symbol-name right)))))
              (= (length keys) (length (delete-dups (copy-sequence keys))))
              (cl-every (lambda (port) (and (integerp port) (<= 1 port 65535))) values)
              (= (length values) (length (delete-dups (copy-sequence values))))))))

(defun emacs-jupyter-notebook-connection-valid-p (connection)
  "Return non-nil when CONNECTION satisfies the local helper connection schema."
  (and (listp connection)
       (zerop (% (length connection) 2))
       ;; `plist-get' would otherwise hide a duplicate required field.  The
       ;; helper sees one JSON object, so this preflight rejects ambiguity
       ;; rather than choosing a possibly stale port or signing key.
       (let ((required (append '(:ip :transport :key :signature_scheme)
                               emacs-jupyter-notebook-connection-port-keys)))
         (cl-every
          (lambda (field)
            (= 1 (cl-count field connection :test #'eq)))
          required))
       (equal (plist-get connection :ip) "127.0.0.1")
       (equal (plist-get connection :transport) "tcp")
       (let ((key (plist-get connection :key))
             (signature (plist-get connection :signature_scheme)))
         (and (stringp key) (> (string-bytes key) 0) (<= (string-bytes key) 4096)
              (equal signature "hmac-sha256")))
       (or (not (plist-member connection :kernel_name))
           (let ((kernel-name (plist-get connection :kernel_name)))
             (and (stringp kernel-name)
                  (<= (string-bytes kernel-name) 256))))
       (emacs-jupyter-notebook-connection-valid-ports-p
        (emacs-jupyter-notebook-connection-ports connection))))

(defun emacs-jupyter-notebook-connection-remote-seed (local-connection remote-ports)
  "Return LOCAL-CONNECTION rewritten with validated REMOTE-PORTS.
LOCAL-CONNECTION is the durable local loopback connection file.  Its signing
key stays in this returned in-memory plist and never enters the registry."
  (unless (emacs-jupyter-notebook-connection-valid-p local-connection)
    (error "Local connection file has invalid Jupyter metadata"))
  (unless (emacs-jupyter-notebook-connection-valid-ports-p remote-ports)
    (error "Remote connection ports are missing or invalid"))
  (emacs-jupyter-notebook-connection-rewrite-ports local-connection remote-ports))

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
