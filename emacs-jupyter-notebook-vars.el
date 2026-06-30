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

(defcustom emacs-jupyter-notebook-result-max-bytes 10485760
  "Maximum byte size of result content stored per panel entry."
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

(defcustom emacs-jupyter-notebook-tunnel-keepalive-interval 15
  "Seconds between SSH ServerAlive keepalive probes for the tunnel.
Passed as `-o ServerAliveInterval=<N>' alongside
`-o ServerAliveCountMax=3' on the tunnel argv.  When the remote
fails to respond to three consecutive probes the SSH client tears
the tunnel down, which lets the tunnel sentinel mark the buffer
dead within a bounded time window even when TCP keepalives are
swallowed by a stateful NAT.  Set to 0 to disable keepalives."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-heartbeat-interval 20
  "Seconds between per-buffer kernel-info heartbeat probes.
The heartbeat fires a `kernel_info_request' and treats no reply
within `emacs-jupyter-notebook-heartbeat-timeout' as a miss.  After
`emacs-jupyter-notebook-heartbeat-misses-allowed' consecutive
misses the tunnel is flagged dead."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-heartbeat-timeout 3
  "Seconds to wait for a kernel-info heartbeat reply before counting a miss."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-heartbeat-misses-allowed 2
  "Number of consecutive heartbeat misses tolerated before declaring death.
When this many heartbeats in a row time out, the buffer's tunnel is
marked dead, the kernel status is cleared, and the mode-line is
refreshed.  The remote kernel is NOT shut down — heartbeat-driven
death is a local-state-only signal, consistent with the binding rule
that the remote kernel outlives Emacs."
  :type 'integer
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

;;; W3 completion customization

(defcustom emacs-jupyter-notebook-completion-idle 0.10
  "Seconds of idle time before sending an async completion request.
The capf returns immediately; the request fires only after the user
pauses typing for this long.  Smaller values feel snappier but hammer
the kernel during fast typing."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-completion-cache-size 200
  "Maximum number of cached completion replies per buffer.
Evicted in least-recently-used order.  The cache key is
\(point . line-up-to-point\), so identical contexts within a single
buffer reuse the prior reply without a round trip."
  :type 'integer
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
panel under the entry header."
  :type '(alist :key-type string :value-type string)
  :group 'emacs-jupyter-notebook)

;; W2.10: removed legacy inline-overlay customizations
;;   emacs-jupyter-notebook-use-inline-overlays
;;   emacs-jupyter-notebook-inline-result-max-lines
;;   emacs-jupyter-notebook-result-inline-lines
;;   emacs-jupyter-notebook-result-inline-max-bytes
;;   emacs-jupyter-notebook-result-max-lines
;; These no longer apply: the source buffer carries no result text and all
;; per-entry sizing is bounded by `emacs-jupyter-notebook-result-max-bytes'.

;;; W2 panel customization

(defcustom emacs-jupyter-notebook-panel-side 'right
  "Side of the frame where the output panel side window opens."
  :type '(choice (const :tag "Right" right)
                 (const :tag "Left" left)
                 (const :tag "Top" top)
                 (const :tag "Bottom" bottom))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-width 80
  "Width of the panel side window in columns."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-default-view 'latest
  "Default view for newly-opened output panels."
  :type '(choice (const :tag "Latest per cell" latest)
                 (const :tag "History log" history))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-stream-throttle-ms 50
  "Maximum time in milliseconds between panel renders during streaming.
A value of 50 caps redisplay churn at roughly 20 Hz.  Higher values
reduce churn further."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-fringe-side 'left-margin
  "Where to draw the per-cell status indicator in the source buffer.
Only the margin sides are fully supported today: fringe rendering of an
arbitrary glyph string would require `define-fringe-bitmap' variants per
state and per digit, which is out of scope.  If a fringe side is chosen
the indicator silently falls back to `left-margin'."
  :type '(choice (const :tag "Left margin (default)" left-margin)
                 (const :tag "Right margin" right-margin)
                 (const :tag "Left fringe (falls back to left-margin)"
                        left-fringe)
                 (const :tag "Right fringe (falls back to left-margin)"
                        right-fringe))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-prefix-key "C-c j"
  "Single keymap prefix under which all `emacs-jupyter-notebook' commands live.
W6.1 contract: every command moves under one prefix to make the surface
discoverable.  Setting this customization after `emacs-jupyter-notebook'
is loaded does NOT retroactively rebind the keymap.  Set it before the
package is loaded, or rebuild the keymap manually."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-log-max-lines 2000
  "Maximum number of lines retained in the `*emacs-jupyter-notebook log*' buffer.
The log buffer is append-only.  After every append the oldest lines are
trimmed until the buffer is at most this many lines tall.  Set to a small
value to keep memory bounded on long sessions; set to a large value if you
want a longer scrollback for debugging."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-fringe-margin-width 2
  "Buffer-local margin width applied when an indicator first appears.
Margin contents are only visible when the window's margin is wide enough
to render them; the indicator setter raises `left-margin-width' or
`right-margin-width' to at least this value the first time a cell gains an
indicator in a buffer."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook-connection-port-keys
  '(:shell_port :iopub_port :stdin_port :hb_port :control_port)
  "Jupyter connection plist keys that contain channel ports.")

(provide 'emacs-jupyter-notebook-vars)

;;; emacs-jupyter-notebook-vars.el ends here
