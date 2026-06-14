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
:remote-cache-dir, :kernelspec, and :jupyter-command.
:host may include a user as in user@example.com."
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

(defcustom emacs-jupyter-notebook-jupyter-command "jupyter"
  "Default Jupyter command on the remote host.
Can be overridden per-profile with :jupyter-command in the profile plist."
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

(defcustom emacs-jupyter-notebook-result-max-bytes 10485760
  "Maximum byte size of result content stored in overlays."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-result-inline-max-bytes 102400
  "Maximum byte size of result content rendered inline in after-string."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-result-inline-lines 10
  "Number of lines shown inline in result overlays before truncation."
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

(defcustom emacs-jupyter-notebook-jupyter-connect-timeout 45
  "Seconds emacs-jupyter may spend during initial client connection.
This needs to be generous for high-latency remote kernels, especially
when the remote side uses Nix or other environment initialization."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-jupyter-request-timeout 2
  "Seconds to wait for runtime completion, inspect, and completeness replies."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-jupyter-completion-timeout 0.35
  "Seconds to wait for runtime completion replies.
Completion runs from `completion-at-point-functions', so this should stay
short to avoid making normal editing feel blocked."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-check-code-completeness nil
  "Whether to ask the kernel if a cell is complete before evaluation.
This uses Jupyter's `is_complete_request' and may block up to
`emacs-jupyter-notebook-jupyter-request-timeout' seconds."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-evaluation-timeout 120
  "Seconds to wait before warning about a possibly unresponsive evaluation."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-watch-expressions nil
  "Named expressions to evaluate with each Jupyter execute request.
Each element is (NAME . EXPRESSION), where NAME labels the displayed
watch value and EXPRESSION is code evaluated by the kernel through
Jupyter's `user_expressions' field.  Watch values are displayed in the
result overlay when package-owned inline overlays are enabled."
  :type '(alist :key-type string :value-type string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-use-inline-overlays t
  "Whether to show evaluation results as inline overlays.
When non-nil (default), results appear inline below the cell.
When nil, results appear in pop-up buffers."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-inline-result-max-lines 1000
  "Maximum lines for inline result display before truncation."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook-connection-port-keys
  '(:shell_port :iopub_port :stdin_port :hb_port :control_port)
  "Jupyter connection plist keys that contain channel ports.")

(provide 'emacs-jupyter-notebook-vars)

;;; emacs-jupyter-notebook-vars.el ends here
