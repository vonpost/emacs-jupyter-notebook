;;; emacs-jupyter-notebook-vars.el --- Customization for remote Jupyter source buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Shared customization and constants for `emacs-jupyter-notebook'.

;;; Code:

(require 'cl-lib)

(defgroup emacs-jupyter-notebook nil
  "Evaluate local source cells against remote Jupyter kernels."
  :group 'tools
  :prefix "emacs-jupyter-notebook-")

(defcustom emacs-jupyter-notebook-remote-profiles nil
  "Remote profile definitions.
Each element is (NAME . PLIST).  Supported PLIST keys include
:host, :user, :port, :identity-file, :ssh-options, :remote-cwd,
:remote-cache-dir, and :kernelspec.  :host may include a user as
in user@example.com."
  :type '(alist :key-type string :value-type plist)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-default-profile "default"
  "Default profile name used by interactive commands."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-command "ssh"
  "SSH executable used for remote commands and tunnels."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-scp-command "scp"
  "SCP executable used to retrieve remote connection files."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-options nil
  "Extra SSH options inserted before the remote destination."
  :type '(repeat string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-remote-working-directory "~"
  "Default remote working directory for launched kernels."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-remote-cache-directory "~/.cache/emacs-jupyter-notebook"
  "Default remote directory for connection files and launch logs."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-default-kernelspec "python3"
  "Default remote Jupyter kernelspec name."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-use-detached nil
  "Whether future process launch adapters may use detached.el when available.
The durable reconnect source remains the registry regardless of this value."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-file
  (locate-user-emacs-file "emacs-jupyter-notebook/registry.el")
  "File containing the durable local remote-kernel registry."
  :type 'file
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-result-max-lines 200
  "Maximum number of result lines shown inline by package-owned overlays."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-image-max-width 800
  "Maximum image width for inline image results, in pixels."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-image-max-height 600
  "Maximum image height for inline image results, in pixels."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-connection-retrieve-attempts 40
  "Number of attempts to retrieve a remote Jupyter connection file."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-connection-retrieve-delay 0.25
  "Seconds between attempts to retrieve a remote connection file."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-tunnel-wait-timeout 10
  "Seconds to wait for local SSH tunnel ports before connecting Jupyter."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-tunnel-wait-delay 0.05
  "Seconds between checks while waiting for SSH tunnel ports."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-jupyter-connect-timeout 15
  "Seconds emacs-jupyter may spend during initial client connection."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-language-cell-markers
  '((python-mode . "^\\s-*# %%\\(?:\\s-+.*\\)?$")
    (python-ts-mode . "^\\s-*# %%\\(?:\\s-+.*\\)?$"))
  "Alist mapping major modes to code-cell marker regexps."
  :type '(alist :key-type symbol :value-type regexp)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-default-cell-marker-regexp
  "^\\s-*# %%\\(?:\\s-+.*\\)?$"
  "Fallback code-cell marker regexp.
The default supports Python v1 # %% cells."
  :type 'regexp
  :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook-connection-port-keys
  '(:shell_port :iopub_port :stdin_port :hb_port :control_port)
  "Jupyter connection plist keys that contain channel ports.")

(provide 'emacs-jupyter-notebook-vars)

;;; emacs-jupyter-notebook-vars.el ends here
