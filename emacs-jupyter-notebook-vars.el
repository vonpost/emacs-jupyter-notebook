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
:remote-cache-dir, :kernelspec, :python-command, :launcher,
:docker-image, and :docker-options.
:host may include a user as in user@example.com.
An omitted :launcher means `direct', which launches the kernel on the
SSH host.  `docker' launches a dedicated detached container on that host
and requires :docker-image.  :docker-options is an argv list of supported
container resource/environment/volume options; EJN owns container identity,
networking and lifetime.  For Docker, :remote-cwd and :python-command refer
to paths and executables inside the image."
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
  "Extra SSH options inserted before the remote destination.
The persistent target tunnel appends `-S none' after user options to keep
its connection independent of shared control sockets."
  :type '(repeat string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-connect-timeout 10
  "Bounded SSH `ConnectTimeout' (seconds) applied to every ssh/scp command.
Caps how long an unreachable or black-holed remote can stall a launch,
retrieve, tunnel, or management command during connection setup.  Set to
nil or a non-positive value to omit the option entirely.  This is separate
from `emacs-jupyter-notebook-prune-ssh-timeout', which bounds only the W11
liveness probe."
  :type '(choice (const :tag "No connect timeout" nil) integer)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-batch-mode t
  "When non-nil, pass `-o BatchMode=yes' on every ssh/scp command.
BatchMode disables all interactive prompts (password/passphrase and the
host-key confirmation), so an ssh that would otherwise block forever on a
prompt fails fast instead.  Enabled by default because a silently blocking
prompt is exactly the kind of wedge that strands reconnect attempts; the
cost is that first-time host-key acceptance for a brand-new remote must be
done once by hand (run `ssh HOST' in a terminal).  Set nil only if you add
new remotes from Emacs and rely on the interactive host-key prompt."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-control-master t
  "When non-nil, multiplex one-shot ssh/scp over a shared master connection.
A kernel start otherwise pays a full TCP+SSH+auth handshake on EACH of its
many short commands (launch, up to N connection-file polls, PID probe,
cleanup).  With multiplexing the first command opens a master that the rest
ride, collapsing those handshakes to roughly one — a large win on
high-latency links and through a ProxyJump.  When nil, one-shot commands
continue to honor multiplexing settings from SSH options and ssh_config.
The persistent target tunnel always opts out with a final `-S none', so
its lifetime can be supervised.  ProxyJump children retain their jump
host's SSH configuration, including any multiplexing configured there.
Requires OpenSSH 6.7+ (for the `%C'/`%i' ControlPath tokens)."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-control-persist "60"
  "Value for SSH `ControlPersist' when multiplexing is enabled.
Seconds (as a string) to keep the background master alive after the last
client exits, or \"yes\"/\"no\".  A short window (e.g. \"60\") is enough to
cover a full start's burst of commands without leaving idle masters around."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-control-path "/tmp/ejn-%i-%C"
  "SSH `ControlPath' template for multiplexed connections.
`%i' (local uid) keeps the socket private per local user and `%C' hashes
the connection tuple, so the socket is collision-free.  The default is
anchored at `/tmp' (not `temporary-file-directory') because `%C' expands to
a 40-character SHA1 and macOS's per-user `$TMPDIR' under `/var/folders/…'
would push the full path past the ~104-byte unix-domain-socket limit,
failing every ssh with \"path too long for unix domain socket\".  The
containing directory must already exist; `/tmp' always does.  This template
applies to one-shot commands only.  Disabling
`emacs-jupyter-notebook-ssh-control-master' leaves the user's SSH options
and ssh_config in effect for those commands."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-remote-working-directory "~"
  "Default remote working directory for launched kernels."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-remote-cache-directory "~/.cache/emacs-jupyter-notebook"
  "Default remote directory for connection files and launch logs."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-python-command '("python3")
  "Python command argv used to resolve a kernelspec in the selected launcher.
Each element is one argument; this is never parsed as a shell command.  The
argv must accept appended `-c SCRIPT ARG...' Python arguments, as direct
Python, `uv run ... python', and `nix shell ... -c python' do.  Shell
activation command strings are unsupported.  Profiles override it with a
non-empty `:python-command' string list.  The default `direct' launcher
runs it on the SSH host; the `docker' launcher runs it inside :docker-image."
  :type '(repeat string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-helper-command '("ejn-helper" "--protocol")
  "Local helper command argv.
The first element names the executable and remaining elements are passed
unchanged.  The default invokes the helper's protocol mode; do not remove
`--protocol' unless the replacement executable enters protocol mode by
default.  A bare executable name is resolved through `exec-path' and then
beside this package's source/build tree, so loading the package through a
checkout or Nix result symlink does not make the command depend on the
current default directory.  With the default command, the first runtime-using
operation may asynchronously build the pinned bundled Nix closure.  The
bounded startup handshake rejects a helper with missing runtime dependencies
or a protocol-version mismatch."
  :type '(repeat string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-auto-build-runtime t
  "Build the bundled local runtime with Nix when it is first needed.
When non-nil and the default helper or registry-worker executable is missing,
the first start, reconnect, or evaluation command runs the repository's pinned
`nix build .#default' asynchronously.  Concurrent source buffers share that
one bounded build.  Successful outputs are retained below
user-emacs-directory/ejn/runtime and reused across Emacs restarts while their
package inputs are unchanged.  Nil disables new builds, not cached reuse.
Custom executable names are never replaced or built."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-runtime-build-timeout 600
  "Maximum seconds allowed for the automatic local Nix runtime build.
Invalid or excessive values fall back to a finite internal deadline."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-runtime-build-output-max-bytes 65536
  "Maximum bytes retained from each automatic Nix build output stream.
Exceeding the effective bounded limit terminates the local build."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defvar emacs-jupyter-notebook--runtime-directory nil
  "Resolved Nix store directory containing the auto-built local runtime.
Restored from the matching persistent output link after Emacs restarts.
This is local executable discovery state, not durable notebook state.")

(defcustom emacs-jupyter-notebook-helper-hello-timeout 5
  "Maximum seconds allowed for the helper's initial hello response.
Invalid values fall back to a finite internal deadline."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-helper-partial-frame-timeout 5
  "Maximum seconds an incomplete helper frame may remain buffered.
Invalid values fall back to a finite internal deadline."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-helper-stderr-max-bytes 65536
  "Maximum bytes retained from one local helper's stderr stream.
The supervisor clamps this to a finite protocol-independent hard maximum."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-helper-max-to-emacs-frame 262144
  "Complete helper-to-Emacs frame ceiling, including its four-byte prefix.
This may lower but never raise the protocol v1 ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-helper-raw-accumulator-max-bytes 1048576
  "Maximum undecoded helper stdout bytes retained by one session.
This may lower but never raise the protocol v1 accumulator ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-default-kernelspec "python3"
  "Default remote Jupyter kernelspec name."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-file
  (locate-user-emacs-file "emacs-jupyter-notebook/registry-v1.json")
  "Versioned JSON file containing the durable local remote-kernel registry.
The one-shot registry worker exclusively owns file access.  The legacy Lisp
registry format is intentionally not read or migrated."
  :type 'file
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-command
  '("ejn-registry-worker")
  "One-shot local registry transaction worker argv.
The executable is resolved through PATH, the auto-built Nix closure, a Nix
`result/bin' link, or the checkout wrapper.  It receives one JSON request on
stdin and writes exactly one bounded JSON response on stdout."
  :type '(repeat string)
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-request-timeout 5
  "Maximum seconds for one registry worker invocation.
An invocation timeout is durability-uncertain because the worker may have
committed before its response was lost; it is never retried automatically."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-retry-deadline 15
  "Maximum seconds for one logical registry request, including busy retries."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.05
  "Initial delay in seconds before retrying a worker `busy' response."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-retry-max-delay 1.0
  "Maximum delay in seconds between worker `busy' retries."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-output-max-bytes (* 384 1024)
  "Maximum stdout bytes retained from one registry worker invocation."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-registry-worker-stderr-max-bytes (* 64 1024)
  "Maximum stderr bytes retained from one registry worker invocation."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-result-max-bytes 10485760
  "Maximum byte size of result content stored per panel entry.
This option may lower, but cannot raise, the package's immutable safety
ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-history-entries 200
  "Maximum number of result entries retained by one panel.
When this or either total-retention budget is exceeded, the panel retires
the oldest history entries and their local artifacts.  This option may lower,
but cannot raise, the package's immutable safety ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-total-text-bytes (* 20 1024 1024)
  "Maximum total byte size of text retained by one result panel.
This option may lower, but cannot raise, the package's immutable safety
ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-total-artifact-bytes (* 100 1024 1024)
  "Maximum total byte size of image and MIME artifacts retained by one panel.
This includes the actual bytes of panel-owned image files and matplotlib
pickle MIME payloads.  This option may lower, but cannot raise, the package's
immutable safety ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-output-segments 4096
  "Maximum ordered output segments retained by one panel.
This bounds structural rendering even when a kernel emits many tiny images or
independent display values.  The option may lower, but cannot raise, the
package's immutable safety ceiling."
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

(defcustom emacs-jupyter-notebook-helper-inline-image-max-pixels 4194304
  "Maximum source pixels permitted in a helper-published image preview.
This option can only lower the helper protocol's immutable 4,194,304-pixel
ceiling.  A non-positive value disables helper image previews while retaining
their bounded original files for the asynchronous external viewer.  The value
is sent with each helper attachment and enforced before its isolated decoder
starts.  Emacs receives only a bounded uncompressed PPM derivative; compressed
remote bytes never reach an Emacs native image API."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-slice-images nil
  "When non-nil, insert panel images sliced into line-height rows.
A tall image inserted as one display property is a single screen line, so
scrolling must jump its whole height at once (window-start can only land
on line boundaries — even pixel-precise scroll modes anchor there).
Slicing (the `doc-view'/EWW technique) makes each row its own screen
line, so the scroll walks smoothly across figures.  Slicing uses the
helper-validated preview dimensions and never asks a native decoder to size
retained history.  The panel's hard inline-preview budget bounds the work.
Zoom, `o', `v', and RET continue to treat the figure as one output.  Only
effective on graphical displays."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-inline-images 8
  "Maximum number of image previews materialized inline in a panel view.
The newest this-many visible images are rendered; older images remain as
lightweight placeholders and can still be opened externally with `o'.
Keeping this value small bounds Emacs's native image-cache memory.  A
non-positive value disables inline previews while preserving originals.
Values above the package's immutable safety ceiling are clamped."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-external-image-viewer-command nil
  "Command argv used to open a panel image in an external application.
The image file name is appended as the final argument and the command is
started asynchronously without a shell.  Nil selects the platform opener:
`open' on macOS, `xdg-open' on GNU/Linux and BSD, and the Windows shell on
Windows."
  :type '(choice (const :tag "Platform default" nil)
                 (repeat :tag "Command and arguments" string))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-external-image-snapshot-ttl 300
  "Seconds to retain a verified image snapshot after launching its viewer.
Platform launchers such as `open' and `xdg-open' commonly exit before the GUI
application consumes the path.  The independent snapshot therefore remains
available for this bounded handoff period.  This option may lower, but cannot
raise, the package's immutable lifetime ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-external-image-max-snapshots 4
  "Maximum pending and retained external image snapshots.
Each snapshot may contain one original image up to the helper's artifact
limit.  When sequential opens reach this bound, the oldest completed handoff
is retired to make room.  A new open is rejected only when every slot belongs
to a pending verification, which cannot be safely evicted.  This option may
lower, but cannot raise, the package's immutable count ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-max-pickles 20
  "Maximum number of panel entries that retain matplotlib pickle artifacts.
Each interactive-figure entry holds confined file metadata plus a deletion
lease for a helper-spooled pickle artifact.  The panel keeps full history, so
an image-heavy session (re-running an `imshow' cell many times) would
otherwise keep every artifact file reachable.  Only the newest this-many
entries keep the metadata used by the interactive viewer; older entries keep
their PNG thumbnail and text but retire the pickle file.  Zero or a negative
value retains no pickle artifacts."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-enable-pickle-viewer nil
  "Whether to permit locally unpickling interactive figure artifacts.
Pickle is executable Python data supplied by the remote kernel.  Keep this
disabled unless that kernel and its transport are explicitly trusted."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-connection-retrieve-attempts 40
  "Number of attempts to retrieve a remote Jupyter connection file.
This option may lower, but cannot raise, the immutable attempt ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-connection-retrieve-delay 0.25
  "Seconds between attempts to retrieve a remote connection file.
The effective value has immutable positive lower and upper bounds."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-tunnel-wait-timeout 10
  "Seconds to wait for local SSH tunnel ports before connecting Jupyter.
The effective value has immutable positive lower and upper bounds."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-tunnel-wait-delay 0.05
  "Seconds between checks while waiting for SSH tunnel ports.
The effective value has immutable positive lower and upper bounds."
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

(defcustom emacs-jupyter-notebook-auto-reconnect t
  "When non-nil, automatically try to restore a dropped tunnel.
When the transport dies (SSH tunnel exit or heartbeat misses) the buffer
schedules a background reconnect and retries with exponential backoff
capped at `emacs-jupyter-notebook-reconnect-max-delay'.  Recovery is
TRANSPORT-ONLY: it rebuilds the tunnel and client against the durable
registry entry.  It never starts a remote kernel and never terminates one —
a probe that confirms the registered kernel is gone (or is a different
process) stops the loop and leaves the entry for an explicit command.
Retries stop on a successful connect, on that confirmed-terminal probe, when
`emacs-jupyter-notebook-reconnect-attempt-limit' is reached, or when the
minor mode is disabled / the buffer killed.  Set nil to only ever reconnect
through an explicit command."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-reconnect-initial-delay 2
  "Seconds before the first automatic reconnect attempt after a drop.
Each subsequent failed attempt doubles the delay (exponential backoff)
until it reaches `emacs-jupyter-notebook-reconnect-max-delay'.  The effective
value cannot be zero or exceed the package's immutable recovery ceiling."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-reconnect-max-delay 300
  "Maximum seconds between automatic reconnect attempts.
The exponential backoff that starts at
`emacs-jupyter-notebook-reconnect-initial-delay' never grows past this
value, so a long outage settles into one attempt every this-many seconds
instead of giving up.  The effective value cannot be zero or exceed the
package's immutable five-minute recovery ceiling."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-reconnect-attempt-limit 72
  "Maximum automatic reconnect attempts in one transport-loss episode.
Automatic recovery is deliberately finite: after this many failed attempts,
EJN stops its timer and leaves the durable kernel registry entry untouched for
an explicit reconnect or helper restart.  The effective value is always a
positive finite integer and cannot exceed the package's immutable 288-attempt
ceiling; invalid values fall back to 72."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-heartbeat-interval 20
  "Seconds between per-buffer kernel-info heartbeat probes.
The heartbeat fires a `kernel_info_request' and treats no reply
within `emacs-jupyter-notebook-heartbeat-timeout' as a miss.  After
`emacs-jupyter-notebook-heartbeat-misses-allowed' consecutive
misses the tunnel is flagged dead.  The effective interval is positive and
cannot exceed the package's immutable liveness ceiling."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-heartbeat-timeout 3
  "Seconds to wait for a kernel-info heartbeat reply before counting a miss.
The effective timeout is positive and capped independently of the interval."
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

(defcustom emacs-jupyter-notebook-connect-arbitration-timeout 45
  "Seconds allowed to arbitrate helper readiness against remote PID liveness.
The core caps this below the helper's own kernel-info verification deadline so
a live but busy kernel can be adopted without waiting for that later timeout."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-connection-attempt-timeout 180
  "Hard wall-clock deadline for a single start or reconnect attempt.
An attempt that is still in flight (any phase: launch, probe, retrieve,
tunnel, connect) after this many seconds is failed with a timeout error.
This is the backstop that guarantees no connection attempt can wedge a
buffer forever even if an individual phase's own bounding fails.  Invalid or
non-positive values fall back to 180 seconds, and values above the package's
hard ten-minute ceiling are capped."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-ssh-process-timeout 60
  "Hard wall-clock deadline for a single one-shot remote process.
Each launch, PID probe, connection-file retrieval (scp), and log fetch
process that is still running after this many seconds is killed and its
attempt failed with a timeout error.  This bounds the processes that ride
a ControlMaster or otherwise outlive their `ConnectTimeout'.  The tunnel
is NOT bounded here (it is meant to live indefinitely); it is bounded by
the keepalives and the overall attempt deadline instead.  The effective
one-shot deadline is always finite and cannot be disabled."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-management-process-timeout 60
  "Hard deadline in seconds for one-shot interactive management commands.
Unlike the general SSH process watchdog, this deadline cannot be disabled:
fetch, list, liveness, prune, and explicit clean operations must never wedge
Emacs.  A non-positive or non-numeric value falls back to 60 seconds."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-management-output-max-bytes (* 1024 1024)
  "Maximum bytes retained per stdout or stderr management buffer.
The newest output is retained with an explicit truncation marker.  This bound
cannot be disabled or raised: invalid or larger values use the immutable 1 MiB
ceiling so a noisy remote command cannot grow Emacs memory without limit while
its watchdog is pending."
  :type 'integer
  :group 'emacs-jupyter-notebook)

;;; W3 completion customization

(defcustom emacs-jupyter-notebook-completion-idle 0.10
  "Seconds of idle time before sending an async completion request.
The capf returns immediately; the request fires only after the user
pauses typing for this long.  The effective value has immutable positive
lower and upper bounds so invalid customization cannot create a timer storm
or silently defer completion for hours."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-completion-cache-size 200
  "Maximum number of cached completion replies per buffer.
Evicted in least-recently-used order.  The cache key is
\(point . line-up-to-point\), so identical contexts within a single
buffer reuse the prior reply without a round trip.  This option may lower,
but cannot raise, the package's immutable cache ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-check-code-completeness nil
  "Whether to ask the kernel if a cell is complete before evaluation.
The request is asynchronous and uses the helper backend's bounded auxiliary
request deadline."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-evaluation-timeout 120
  "Seconds before interrupting a possibly unresponsive evaluation.
The effective value is positive and capped at one hour, after which one equal
terminal grace may elapse before the ambiguous local transport is retired."
  :type 'number
  :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook--hard-connection-retrieve-attempts 160)
(defconst emacs-jupyter-notebook--hard-connection-retrieve-delay 5.0)
(defconst emacs-jupyter-notebook--hard-tunnel-wait-timeout 60.0)
(defconst emacs-jupyter-notebook--hard-tunnel-wait-delay 1.0)
(defconst emacs-jupyter-notebook--hard-reconnect-initial-delay 60.0)
(defconst emacs-jupyter-notebook--hard-reconnect-max-delay 300.0)
(defconst emacs-jupyter-notebook--hard-reconnect-attempt-limit 288)
(defconst emacs-jupyter-notebook--hard-evaluation-timeout 3600.0)
(defconst emacs-jupyter-notebook--hard-heartbeat-interval 300.0)
(defconst emacs-jupyter-notebook--hard-heartbeat-timeout 60.0)
(defconst emacs-jupyter-notebook--hard-heartbeat-misses 10)
(defconst emacs-jupyter-notebook--hard-completion-idle 5.0)
(defconst emacs-jupyter-notebook--hard-ssh-process-timeout 600.0)
(defconst emacs-jupyter-notebook--hard-prune-ssh-timeout 60)

(defun emacs-jupyter-notebook--bounded-positive-option
    (value fallback minimum maximum)
  "Normalize numeric VALUE between MINIMUM and MAXIMUM, else FALLBACK."
  (if (and (numberp value) (= value value) (> value 0))
      (min maximum (max minimum value))
    fallback))

(defun emacs-jupyter-notebook--effective-connection-retrieve-attempts ()
  "Return the immutable bounded connection retrieval attempt count."
  (let ((value emacs-jupyter-notebook-connection-retrieve-attempts))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook--hard-connection-retrieve-attempts)
      40)))

(defun emacs-jupyter-notebook--effective-connection-retrieve-delay ()
  "Return the immutable bounded connection retrieval delay."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-connection-retrieve-delay 0.25 0.05
   emacs-jupyter-notebook--hard-connection-retrieve-delay))

(defun emacs-jupyter-notebook--effective-tunnel-wait-timeout ()
  "Return the immutable bounded tunnel readiness deadline."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-tunnel-wait-timeout 10.0 1.0
   emacs-jupyter-notebook--hard-tunnel-wait-timeout))

(defun emacs-jupyter-notebook--effective-tunnel-wait-delay ()
  "Return the immutable bounded tunnel readiness polling delay."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-tunnel-wait-delay 0.05 0.025
   emacs-jupyter-notebook--hard-tunnel-wait-delay))

(defun emacs-jupyter-notebook--effective-reconnect-initial-delay ()
  "Return the immutable bounded initial automatic reconnect delay."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-reconnect-initial-delay 2.0 0.1
   emacs-jupyter-notebook--hard-reconnect-initial-delay))

(defun emacs-jupyter-notebook--effective-reconnect-max-delay ()
  "Return the immutable bounded maximum automatic reconnect delay."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-reconnect-max-delay 300.0 0.1
   emacs-jupyter-notebook--hard-reconnect-max-delay))

(defun emacs-jupyter-notebook--effective-reconnect-attempt-limit ()
  "Return the immutable bounded automatic reconnect attempt limit."
  (let ((value emacs-jupyter-notebook-reconnect-attempt-limit))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook--hard-reconnect-attempt-limit)
      72)))

(defun emacs-jupyter-notebook--effective-evaluation-timeout ()
  "Return the immutable bounded user execution timeout."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-evaluation-timeout 120.0 1.0
   emacs-jupyter-notebook--hard-evaluation-timeout))

(defun emacs-jupyter-notebook--effective-heartbeat-interval ()
  "Return the immutable bounded heartbeat interval."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-heartbeat-interval 20.0 1.0
   emacs-jupyter-notebook--hard-heartbeat-interval))

(defun emacs-jupyter-notebook--effective-heartbeat-timeout ()
  "Return the immutable bounded per-heartbeat reply timeout."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-heartbeat-timeout 3.0 0.1
   emacs-jupyter-notebook--hard-heartbeat-timeout))

(defun emacs-jupyter-notebook--effective-heartbeat-misses ()
  "Return the immutable bounded consecutive heartbeat miss count."
  (let ((value emacs-jupyter-notebook-heartbeat-misses-allowed))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook--hard-heartbeat-misses)
      2)))

(defun emacs-jupyter-notebook--effective-completion-idle ()
  "Return the immutable bounded completion debounce delay."
  (emacs-jupyter-notebook--bounded-positive-option
   emacs-jupyter-notebook-completion-idle 0.10 0.025
   emacs-jupyter-notebook--hard-completion-idle))

(defun emacs-jupyter-notebook--effective-ssh-process-timeout (&optional override)
  "Return a finite bounded one-shot SSH deadline, honoring OVERRIDE."
  (emacs-jupyter-notebook--bounded-positive-option
   (or override emacs-jupyter-notebook-ssh-process-timeout)
   60.0 0.1 emacs-jupyter-notebook--hard-ssh-process-timeout))

(defcustom emacs-jupyter-notebook-max-pending-executions 32
  "Maximum active and queued user executions retained by one source buffer.
New evaluations are rejected before panel or ledger allocation when this
bound is reached.  This option may lower, but cannot raise, the package's
immutable queue ceiling."
  :type 'integer
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
  "Direction from the selected window for a newly displayed output buffer.
The output uses an ordinary window.  An existing output window is reused
in place, and `display-buffer-alist' can override the default placement."
  :type '(choice (const :tag "Right" right)
                 (const :tag "Left" left)
                 (const :tag "Top" top)
                 (const :tag "Bottom" bottom))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-panel-width 80
  "Preferred initial output window width in columns for left/right placement.
Redisplaying a visible output buffer preserves its window size."
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
trimmed until the buffer is at most this many lines tall.  This option may
lower, but cannot raise, the package's immutable line ceiling."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-log-max-bytes (* 2 1024 1024)
  "Maximum bytes retained in the `*emacs-jupyter-notebook log*' buffer.
The byte and line limits are enforced together after every append.  This
option may lower, but cannot raise, the package's immutable byte ceiling."
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

;;; W8 local interactive matplotlib viewer customization

(defcustom emacs-jupyter-notebook-local-python-command "python3"
  "Local Python executable used by bounded local helper processes.
This is the LOCAL workstation's Python (never a remote one).  It must
run the bundled artifact verifier.  Interactive pickle viewing additionally
requires matplotlib with a GUI backend (Qt or Tk), pinned to the same version
as the remote kernels.  Set this to an absolute path or a command found on
`exec-path'."
  :type 'string
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-viewer-backend 'tk
  "Preferred GUI backend for the local matplotlib viewer.
The viewer selects `TkAgg' for `tk', `QtAgg' for `qt', and the native
Cocoa backend for `macosx', falling back through the other candidates
automatically when the preferred one is unavailable.

On macOS the viewer ALWAYS tries the native `MacOSX' backend first
regardless of this setting (W16): system Tk there commonly renders blank
canvases or fails to run its event loop, Qt needs a separately-installed
binding, and the Cocoa backend ships with every matplotlib.

Default is `tk' (for Linux): under a bare nix `python3.withPackages' env,
PyQt5 cannot locate its Qt platform plugin (xcb) and aborts before
matplotlib's fallback can run, whereas TkAgg inherits Emacs's DISPLAY and
just works.  Choose `qt' only if your local Python has a properly-wrapped
PyQt5."
  :type '(choice (const :tag "Tk (TkAgg)" tk)
                 (const :tag "Qt (QtAgg)" qt)
                 (const :tag "macOS native (Cocoa)" macosx))
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-viewer-idle-timeout 900
  "Seconds the local viewer stays alive with no open figures before self-exiting.
The viewer is Emacs-owned and reaped on `kill-emacs-hook', but it also
self-exits after this idle period so a hard Emacs crash cannot orphan it
forever.  Set to 0 to disable the idle self-exit."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-kernel-idle-timeout 43200
  "Seconds a remote kernel may sit idle before it self-reaps (W11).
On connect (and re-run on restart) Emacs injects an in-memory idle
watchdog into the kernel: a daemon thread that shuts the kernel down once
it has been idle for longer than this many seconds.  This is the
self-reaping half of the W11 kernel-lifecycle work — abandoned kernels
reap themselves even if Emacs crashed, so remote kernels stop
accumulating.

The watchdog NEVER reaps a busy kernel: a cell that runs for hours keeps
the kernel marked executing for its whole duration and is not counted as
idle.  The default is 43200 (12 hours).  Set to 0 to disable the watchdog
entirely (nothing is injected)."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-prune-ssh-timeout 5
  "Bounded SSH `ConnectTimeout' (seconds) for the W11 liveness probe.
The non-destructive registry prune (`prune-dead-kernels' and the
reconnect picker) runs ONE ssh per host to ask which recorded kernel PIDs
are still alive.  This caps how long an unreachable host can stall Emacs;
a host that does not answer within the timeout is treated as UNKNOWN and
its entries are NEVER pruned.  The effective value is an integer from one to
sixty seconds so it is valid for both OpenSSH and the local watchdog."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(defun emacs-jupyter-notebook--effective-prune-ssh-timeout (&optional override)
  "Return a finite OpenSSH-compatible liveness timeout, honoring OVERRIDE."
  (ceiling
   (emacs-jupyter-notebook--bounded-positive-option
    (or override emacs-jupyter-notebook-prune-ssh-timeout)
    5.0 1.0 emacs-jupyter-notebook--hard-prune-ssh-timeout)))

(defcustom emacs-jupyter-notebook-viewer-auto-open nil
  "When non-nil, automatically open every pickled figure in the local viewer.
By default figures open on demand (`C-c j I', or `v' on a panel entry).
Enabling this pops a GUI window for every inline figure produced on the
remote kernel, which requires a GUI Emacs and a working local viewer."
  :type 'boolean
  :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook-connection-port-keys
  '(:shell_port :iopub_port :stdin_port :hb_port :control_port)
  "Jupyter connection plist keys that contain channel ports.")

(provide 'emacs-jupyter-notebook-vars)

;;; emacs-jupyter-notebook-vars.el ends here
