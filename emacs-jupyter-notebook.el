;;; emacs-jupyter-notebook.el --- Remote Jupyter kernels for local source files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (jupyter "1.0") (code-cells "0.5"))
;; Keywords: tools, languages, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Edit normal local source files, evaluate # %% style cells against a
;; remote Jupyter kernel, and reconnect through a durable local registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'json)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-cell)
(require 'emacs-jupyter-notebook-registry)
(require 'emacs-jupyter-notebook-connection)
(require 'emacs-jupyter-notebook-ssh)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-events)
(require 'emacs-jupyter-notebook-backend)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook-helper-protocol)
(require 'emacs-jupyter-notebook-viewer)

;;; W8 — local interactive matplotlib viewer: remote formatter injection
;;
;; The remote kernel stays HEADLESS.  On connect (and re-run on restart)
;; Emacs injects a one-time, in-memory hook that makes every displayed
;; `matplotlib.figure.Figure' ALSO emit a custom MIME
;; `application/x-ejn-mpl-pickle' (base64 of `pickle.dumps(fig)') ALONGSIDE
;; the normal `image/png'.  Nothing is written to the remote filesystem and
;; nothing is pip-installed: the snippet only needs matplotlib + stdlib,
;; which a Python Jupyter kernel with matplotlib already has.
;;
;; Implementation note (root cause of an earlier bug): we do NOT register an
;; IPython display formatter for the Figure type.  matplotlib's inline
;; backend reconfigures IPython's display formatters on the first plot and
;; WIPES per-type registrations, which made a formatter degrade silently to
;; the figure `__repr__' (emitting `<Figure ...>' instead of base64).
;; Instead we patch `Figure._repr_mimebundle_' on the class, which the inline
;; reconfiguration does not touch.  Verified against a real ipykernel with
;; the inline backend active; see `viewer/test_formatter_kernel.py'.

(defconst emacs-jupyter-notebook--viewer-formatter-snippet
  "\
try:
    _ejn_ip = get_ipython()
except Exception:
    _ejn_ip = None
if _ejn_ip is not None:
    try:
        import base64 as _ejn_b64, pickle as _ejn_pkl
        _EJN_MIME = 'application/x-ejn-mpl-pickle'
        def _ejn_install():
            # Patch Figure._repr_mimebundle_ on the TYPE.  This survives
            # matplotlib's inline-backend reconfiguration, which clears
            # IPython display-formatter per-type registrations on the first
            # plot (a registered printer gets wiped and formatting falls back
            # to __repr__).  A method on the class is not touched by that, so
            # every figure reliably carries the pickle beside the inline PNG.
            import matplotlib.figure as _ejn_mf
            _EjnFigure = _ejn_mf.Figure
            if getattr(_EjnFigure, '_ejn_patched', False):
                return True
            _ejn_orig = _EjnFigure.__dict__.get('_repr_mimebundle_', None)
            def _ejn_repr_mimebundle_(self, include=None, exclude=None, **kwargs):
                bundle = {}
                if _ejn_orig is not None:
                    try:
                        _r = _ejn_orig(self, include=include, exclude=exclude,
                                       **kwargs)
                        if isinstance(_r, tuple):
                            _r = _r[0]
                        if isinstance(_r, dict):
                            bundle.update(_r)
                    except Exception:
                        pass
                try:
                    bundle[_EJN_MIME] = _ejn_b64.b64encode(
                        _ejn_pkl.dumps(self, protocol=_ejn_pkl.HIGHEST_PROTOCOL)
                    ).decode('ascii')
                except Exception:
                    pass
                return bundle
            _EjnFigure._repr_mimebundle_ = _ejn_repr_mimebundle_
            _EjnFigure._ejn_patched = True
            return True
        def _ejn_try_install(*_a, **_k):
            try:
                _ejn_install()
            except Exception:
                pass
        # Patch now when matplotlib is importable (the common case: the
        # kernel already has it); otherwise the per-cell hook patches as
        # soon as matplotlib appears.
        _ejn_try_install()
        # Re-assert before every cell.  Idempotent (guarded by the
        # `_ejn_patched' flag) and registered once per kernel session.
        if not getattr(_ejn_ip, '_ejn_hook_installed', False):
            try:
                _ejn_ip.events.register('pre_run_cell', _ejn_try_install)
                _ejn_ip._ejn_hook_installed = True
            except Exception:
                pass
    except Exception:
        pass
"
  "In-memory Python snippet installing the W8 matplotlib pickle emitter.
Injected via a silent `execute_request' on connect and restart.  Patches
`matplotlib.figure.Figure._repr_mimebundle_' so every displayed figure
carries a base64-encoded `pickle.dumps(fig)' under the custom MIME type
`application/x-ejn-mpl-pickle', alongside the normal inline `image/png'.

Patching the TYPE (rather than registering an IPython display formatter)
is deliberate: matplotlib's inline backend reconfigures IPython's
display formatters on the first plot and wipes per-type formatter
registrations, so the earlier `for_type_by_name' approach silently
degraded to the figure `__repr__'.  A `_repr_mimebundle_' method on the
class is not affected.  Idempotent (guarded by `_ejn_patched'), chains to
any pre-existing `_repr_mimebundle_', and a graceful no-op when
`get_ipython()' is unavailable or matplotlib cannot be imported.")

;; Forward declarations: these are declared `defvar-local' further down, but
;; the setup and transport-failure helpers above that section reference them.
(defvar emacs-jupyter-notebook--client)
(defvar emacs-jupyter-notebook--tunnel-dead)
(defvar emacs-jupyter-notebook--kernel-status)

(defun emacs-jupyter-notebook--ensure-selected-backend ()
  "Validate the selected local backend before admitting a remote launch."
  (emacs-jupyter-notebook-backend-ensure)
  (when (eq emacs-jupyter-notebook-backend 'helper)
    (emacs-jupyter-notebook-helper-backend-ensure)))

(defun emacs-jupyter-notebook--backend-transport-failed (session reason)
  "Mark the installed SESSION unusable after a local transport failure.

The durable registry and remote kernel remain untouched.  The existing bounded
reconnect loop owns replacement of local helper/tunnel state."
  (when (eq emacs-jupyter-notebook--client session)
    (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
    (setq emacs-jupyter-notebook--tunnel-dead t
          emacs-jupyter-notebook--kernel-status nil)
    (emacs-jupyter-notebook--log-append
     'transport "backend transport failed: %s" reason)
    (force-mode-line-update t)
    (emacs-jupyter-notebook--schedule-auto-reconnect)))

(defun emacs-jupyter-notebook--helper-input-reply
    (client request helper-request-id input-id)
  "Return a deferred-safe reply closure for one helper stdin prompt lease."
  (let ((buffer (current-buffer))
        (used nil))
    (when (and (stringp helper-request-id) (stringp input-id))
      (lambda (value)
      ;; The event reducer invokes this closure only from its zero-delay timer,
      ;; outside the helper process filter.  Recheck local ownership before
      ;; transmitting a one-use lease that may have been superseded meanwhile.
        (unless used
          (setq used t)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (and (eq client emacs-jupyter-notebook--client)
                         (emacs-jupyter-notebook--execution-input-current-p request))
                (condition-case err
                    (emacs-jupyter-notebook-backend-input
                     client (cons helper-request-id input-id) value #'ignore
                     (lambda (_id reason)
                       (emacs-jupyter-notebook--log-append
                        'stdin "input reply failed: %s" reason)))
                  (error
                   (emacs-jupyter-notebook--log-append
                    'stdin "cannot send input reply: %s"
                    (error-message-string err))))))))))))

(defun emacs-jupyter-notebook--backend-event (session event)
  "Synchronously admit normalized helper EVENT through the current EI1R ledger.

Return an explicit boolean to the helper adapter.  In particular, a rejected
published image is not locally admitted as a panel artifact."
  (when (and (eq session emacs-jupyter-notebook--client)
             (eq (plist-get event :type) 'helper-event))
    (let ((ledger-id (plist-get event :ledger-id))
          (backend-id (plist-get event :backend-request-id))
          (generation (plist-get event :panel-generation))
          (normalized (plist-get event :event)))
      ;; Validate ownership before constructing reducer context or touching a
      ;; panel.  The reducer then records reply/idle terminality synchronously
      ;; in the helper drain, before ordinary credit is replenished.
      (when (and (emacs-jupyter-notebook--execution-current-p ledger-id)
                 (let ((record (emacs-jupyter-notebook--execution-record ledger-id)))
                   (and (equal backend-id
                               (plist-get record :backend-request-id))
                        (equal generation (plist-get record :generation)))))
        (let* ((record (emacs-jupyter-notebook--execution-record ledger-id))
               (actions
                (emacs-jupyter-notebook-events-dispatch
                 (list :buffer (current-buffer) :request-id ledger-id
                       :backend-request-id backend-id :panel-generation generation
                       :entry-handle (plist-get record :panel-entry)
                       :cell-key (plist-get record :cell-key)
                       ;; The helper execution wire id plus input id are a
                       ;; one-use lease, consumed later by the reducer timer.
                       :input-reply
                       (and (eq (plist-get normalized :type) 'input-request)
                            (emacs-jupyter-notebook--helper-input-reply
                             session ledger-id
                             (plist-get event :helper-request-id)
                             (plist-get normalized :input-id))))
                 normalized)))
          ;; A successful execute-reply may render no panel action but it is
          ;; still admitted terminal evidence.  Other events must produce a
          ;; non-ignore action; publication validation failures return nil.
          (or (memq (plist-get normalized :type) '(execute-reply status))
              (and actions (not (equal actions '((:action ignore)))))))))))

(defconst emacs-jupyter-notebook--helper-connect-arbitration-maximum 45
  "Maximum core busy-kernel arbitration deadline for the helper backend.

This must stay strictly below the helper backend's bounded `kernel_info'
verification deadline, so PID arbitration always gets the first decision.")

(defun emacs-jupyter-notebook--connect-arbitration-timeout ()
  "Return this backend's bounded core readiness-arbitration deadline.

The helper path caps a user-configured value at
`emacs-jupyter-notebook--helper-connect-arbitration-maximum'; shorter valid
user values are retained.  Other backends preserve the existing setting.
"
  (let ((configured emacs-jupyter-notebook-jupyter-connect-timeout))
    (if (eq emacs-jupyter-notebook-backend 'helper)
        (if (and (numberp configured) (> configured 0))
            (min configured emacs-jupyter-notebook--helper-connect-arbitration-maximum)
          emacs-jupyter-notebook--helper-connect-arbitration-maximum)
      configured)))

(defun emacs-jupyter-notebook--inject-viewer-formatter (&optional client)
  "Inject the W8 matplotlib pickle formatter into the kernel session.
Sends `emacs-jupyter-notebook--viewer-formatter-snippet' through the
silent-execute adapter (no output, no panel entry, no history).  Uses
CLIENT when given, else the buffer-local client.  A no-op when no client
is present.  The snippet is idempotent, so re-running on restart is safe.
Failures are swallowed and logged; formatter injection must never break a
connect or restart."
  (let ((client (or client emacs-jupyter-notebook--client)))
    (when client
      (condition-case err
          (progn
            (emacs-jupyter-notebook-backend-execute
             client emacs-jupyter-notebook--viewer-formatter-snippet
             '(:silent t)
             (lambda (_request-id _result)
               (emacs-jupyter-notebook--log-append
                'viewer-inject "injected matplotlib pickle formatter into kernel"))
             (lambda (_request-id error-data)
               (emacs-jupyter-notebook--log-append
                'viewer-inject "formatter injection failed: %s" error-data))))
        (error
         (emacs-jupyter-notebook--log-append
          'viewer-inject "formatter injection failed: %s"
          (error-message-string err)))))))

;;; W11 — self-reaping idle kernels (injected in-memory watchdog)
;;
;; Motivation: remote kernels are `nohup'-ed and deliberately outlive Emacs,
;; so an Emacs crash or a forgotten buffer leaves a kernel running forever.
;; Over time these accumulate.  W11(A) injects a ZERO-INSTALL idle watchdog
;; (nothing written to the remote FS, only stdlib + get_ipython) that shuts
;; the kernel down after `emacs-jupyter-notebook-kernel-idle-timeout' seconds
;; of inactivity, so abandoned kernels reap themselves.
;;
;; Injection mirrors the W8 formatter exactly: a defconst Python template
;; sent through the mockable silent-execute adapter at the same two sites
;; (connect-finalize and restart-kernel), idempotency-guarded so reconnect /
;; restart never stacks a second watchdog thread.
;;
;; CRITICAL correctness point (a long-running cell must NOT be reaped):
;; the watchdog flips an `executing' flag True on `pre_run_cell' and back to
;; False on `post_run_cell'.  Because that flag stays True for the whole
;; duration of a cell — even one that runs for hours — the "not currently
;; executing" guard in the poll loop means a busy kernel can never trip the
;; idle test.  Only after the cell finishes does the idle clock (bumped at
;; both edges) start counting toward the timeout.

(defconst emacs-jupyter-notebook--kernel-idle-watchdog-snippet
  "\
try:
    import threading as _ejn_wd_th, time as _ejn_wd_time, os as _ejn_wd_os, signal as _ejn_wd_sig
    _ejn_wd_ip = get_ipython()
except Exception:
    _ejn_wd_ip = None
if _ejn_wd_ip is not None:
    try:
        _EJN_WD_TIMEOUT = %d
        # Idempotency guard: never stack a second watchdog thread when this
        # snippet is re-injected on reconnect.  The flag lives on the
        # IPython instance, so a restart (which builds a fresh instance and
        # wipes the namespace) correctly re-installs a new watchdog.
        if _EJN_WD_TIMEOUT > 0 and not getattr(_ejn_wd_ip, '_ejn_watchdog_installed', False):
            # Shared state.  `executing' is True ONLY between a cell's
            # pre_run_cell and its post_run_cell; a cell that runs for hours
            # keeps it True the whole time, so the loop below can never reap a
            # busy kernel.  `last' (last activity) is bumped at both edges so
            # the idle clock only starts once the last cell has finished.
            _ejn_wd_state = {'last': _ejn_wd_time.time(), 'executing': False}
            def _ejn_wd_pre(*_a, **_k):
                _ejn_wd_state['executing'] = True
                _ejn_wd_state['last'] = _ejn_wd_time.time()
            def _ejn_wd_post(*_a, **_k):
                _ejn_wd_state['executing'] = False
                _ejn_wd_state['last'] = _ejn_wd_time.time()
            try:
                _ejn_wd_ip.events.register('pre_run_cell', _ejn_wd_pre)
                _ejn_wd_ip.events.register('post_run_cell', _ejn_wd_post)
            except Exception:
                pass
            # Wake ~10x per idle window, clamped to [1s, 60s].  For the 4h
            # default this polls once a minute; a tiny timeout (tests / smoke)
            # polls about once a second.
            _ejn_wd_interval = min(60.0, max(1.0, _EJN_WD_TIMEOUT / 10.0))
            def _ejn_wd_loop():
                while True:
                    _ejn_wd_time.sleep(_ejn_wd_interval)
                    try:
                        # Never reap a busy kernel: skip while a cell runs.
                        if _ejn_wd_state['executing']:
                            continue
                        if (_ejn_wd_time.time() - _ejn_wd_state['last']) > _EJN_WD_TIMEOUT:
                            try:
                                _ejn_wd_os.write(
                                    2,
                                    b'[ejn] idle watchdog: kernel idle beyond timeout; self-shutting down\\n')
                            except Exception:
                                pass
                            # Prefer a clean termination via SIGTERM so the
                            # kernel process exits normally.  os._exit(0) is a
                            # last resort if the signal was swallowed.
                            try:
                                _ejn_wd_os.kill(_ejn_wd_os.getpid(), _ejn_wd_sig.SIGTERM)
                            except Exception:
                                pass
                            _ejn_wd_time.sleep(5.0)
                            try:
                                _ejn_wd_os._exit(0)
                            except Exception:
                                pass
                            return
                    except Exception:
                        # A transient error in the loop must never crash the
                        # kernel; keep polling.
                        pass
            _ejn_wd_thread = _ejn_wd_th.Thread(
                target=_ejn_wd_loop, name='ejn-idle-watchdog', daemon=True)
            _ejn_wd_thread.start()
            _ejn_wd_ip._ejn_watchdog_installed = True
    except Exception:
        pass
"
  "In-memory Python template for the W11 self-reaping idle watchdog.
Contains a single `%d' placeholder for the configured idle timeout in
seconds; `emacs-jupyter-notebook--inject-idle-watchdog' formats the value
in before sending it through the silent-execute adapter.

Starts ONE daemon thread that periodically checks whether the kernel has
been idle longer than the timeout AND is not currently executing a cell,
and if so shuts the kernel down with `os.kill(getpid, SIGTERM)' (with
`os._exit(0)' as a last-resort fallback).  Activity and executing-state
are tracked via the IPython `pre_run_cell' / `post_run_cell' events, so a
long-running cell is never reaped.  Idempotent (guarded by the
`_ejn_watchdog_installed' flag on the IPython instance) and fully wrapped
so any failure to install is a silent no-op that never breaks the user's
session.  Imports only stdlib (threading, time, os, signal) plus
`get_ipython'; writes nothing to the remote filesystem.")

(defun emacs-jupyter-notebook--inject-idle-watchdog (&optional client)
  "Inject the W11 self-reaping idle watchdog into the kernel session.
Sends `emacs-jupyter-notebook--kernel-idle-watchdog-snippet' (with the
configured `emacs-jupyter-notebook-kernel-idle-timeout' formatted in)
through the silent-execute adapter.  Uses CLIENT when given, else the
buffer-local client.  A no-op when there is no client OR when the timeout
is 0 (the watchdog is disabled: nothing is injected).  The snippet is
idempotent, so re-running on restart is safe.  Failures are swallowed and
logged; watchdog injection must never break a connect or restart."
  (let ((client (or client emacs-jupyter-notebook--client))
        (timeout emacs-jupyter-notebook-kernel-idle-timeout))
    (when (and client (integerp timeout) (> timeout 0))
      (condition-case err
          (progn
            (emacs-jupyter-notebook-backend-execute
             client
             (format emacs-jupyter-notebook--kernel-idle-watchdog-snippet timeout)
             '(:silent t)
             (lambda (_request-id _result)
               (emacs-jupyter-notebook--log-append
                'kernel-watchdog "injected idle watchdog (timeout=%ss)" timeout))
             (lambda (_request-id error-data)
               (emacs-jupyter-notebook--log-append
                'kernel-watchdog "idle watchdog injection failed: %s" error-data))))
        (error
         (emacs-jupyter-notebook--log-append
          'kernel-watchdog "idle watchdog injection failed: %s"
          (error-message-string err)))))))

;;; W8.5 — open a stashed figure interactively in the local viewer

(defun emacs-jupyter-notebook--viewer-hand-off (pickle)
  "Hand confined PICKLE metadata to the local viewer, surfacing start failures.
The hand-off itself is asynchronous (see the viewer manager); only a
synchronous spawn failure (missing script, unspawnable Python) is turned
into a friendly `user-error'."
  (condition-case err
      (progn
        (emacs-jupyter-notebook-viewer-open-pickle-file
         pickle (lambda (_accepted) (ejn-panel-release-pickle pickle)))
        (emacs-jupyter-notebook--log-append
         'viewer "handed figure to local interactive viewer")
        (message "emacs-jupyter-notebook: opening figure in local viewer"))
    (error
     (ejn-panel-release-pickle pickle)
     (emacs-jupyter-notebook--log-append
      'viewer "interactive viewer failed to start: %s"
      (error-message-string err))
     (user-error "Interactive viewer failed to start: %s"
                 (error-message-string err)))))

(defun emacs-jupyter-notebook-open-figure-pickle-lease (pickle)
  "Open leased confined PICKLE metadata in the local viewer.
Surfaces a friendly `user-error' when no local Python is configured/found.
The viewer's bounded asynchronous spawn/ACK transaction diagnoses a missing
matplotlib installation and releases the lease without a separate probe."
  (unless emacs-jupyter-notebook-enable-pickle-viewer
    (ejn-panel-release-pickle pickle)
    (user-error "Interactive pickle viewer is disabled; customize `emacs-jupyter-notebook-enable-pickle-viewer' only for trusted kernels"))
  (let ((python (emacs-jupyter-notebook-viewer--python-path
                 emacs-jupyter-notebook-local-python-command)))
    (cond
     ((null python)
      (ejn-panel-release-pickle pickle)
      (user-error
       "No local Python found; set `emacs-jupyter-notebook-local-python-command'"))
     (t
      (emacs-jupyter-notebook--viewer-hand-off pickle)))))

(defun emacs-jupyter-notebook--figure-pickle-for-current-cell ()
  "Return the newest matplotlib pickle stashed for the current cell, or nil."
  (let ((cell-key (emacs-jupyter-notebook--current-cell-key)))
    (and cell-key
         (emacs-jupyter-notebook-panel-acquire-latest-pickle-for-cell
          (current-buffer) cell-key))))

;;;###autoload
(defun emacs-jupyter-notebook-open-figure-interactive ()
  "Open the current cell's latest figure interactively in the local viewer.
W8.5: bound to `C-c j I'.  Looks up the newest panel entry for the cell at
point that carries matplotlib pickle artifact metadata and hands it to the local
viewer.  Signals a friendly `user-error' when the cell has no interactive
figure or the local viewer is unavailable."
  (interactive)
  (let ((pickle (emacs-jupyter-notebook--figure-pickle-for-current-cell)))
    (unless pickle
      (user-error
       "No interactive figure for this cell; run a cell that displays a matplotlib figure first"))
    (emacs-jupyter-notebook-open-figure-pickle-lease pickle)))

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function nil
  "Previous buffer-local value of `imenu-create-index-function'.")

(defvar-local emacs-jupyter-notebook--saved-imenu-create-index-function-local-p nil
  "Whether `imenu-create-index-function' was buffer-local before enabling.")

(defun emacs-jupyter-notebook--imenu-index ()
  "Return an imenu index of code-cell markers in the current buffer."
  (let ((entries nil)
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward code-cells-boundary-regexp nil t)
        (setq count (1+ count))
        (let* ((title (string-trim
                       (buffer-substring-no-properties
                        (match-end 0) (line-end-position))))
               (name (if (string-empty-p title)
                         (format "Cell %d" count)
                       title)))
          (push (cons name (copy-marker (match-beginning 0) t)) entries))))
    (nreverse entries)))

(defun emacs-jupyter-notebook--enable-imenu ()
  "Use cell markers as the imenu index for the current buffer."
  (setq emacs-jupyter-notebook--saved-imenu-create-index-function
        imenu-create-index-function
        emacs-jupyter-notebook--saved-imenu-create-index-function-local-p
        (local-variable-p 'imenu-create-index-function))
  (setq-local imenu-create-index-function
              #'emacs-jupyter-notebook--imenu-index))

(defun emacs-jupyter-notebook--disable-imenu ()
  "Restore the imenu index function that was active before mode enable."
  (let ((saved-function emacs-jupyter-notebook--saved-imenu-create-index-function)
        (saved-local-p emacs-jupyter-notebook--saved-imenu-create-index-function-local-p))
    (if saved-local-p
        (setq-local imenu-create-index-function saved-function)
      (kill-local-variable 'imenu-create-index-function))
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function)
    (kill-local-variable 'emacs-jupyter-notebook--saved-imenu-create-index-function-local-p)))

(defvar-local emacs-jupyter-notebook--client nil
  "Current buffer's opaque backend session.")

(defvar-local emacs-jupyter-notebook--session-entry nil
  "Current buffer's registry entry plist.")

(defvar-local emacs-jupyter-notebook--tunnel-process nil
  "Current buffer's SSH tunnel process.")

(defvar-local emacs-jupyter-notebook--async-context nil
  "Current buffer's in-progress async start or reconnect context.")

(defvar-local emacs-jupyter-notebook--tunnel-dead nil
  "Non-nil when the current buffer's SSH tunnel has disconnected.")

(defvar-local emacs-jupyter-notebook--reconnect-timer nil
  "Pending timer for automatic reconnect after transport failure.")

(defvar-local emacs-jupyter-notebook--reconnect-attempt 0
  "Number of consecutive automatic reconnect attempts for this buffer.")

(defvar-local emacs-jupyter-notebook--reconnect-next-at nil
  "Absolute time when the next automatic reconnect attempt will run.")

(defvar-local emacs-jupyter-notebook--reconnect-schedule-token nil
  "Identity token owned by the currently scheduled reconnect timer.")

(defvar-local emacs-jupyter-notebook--kernel-status nil
  "Current kernel status: `busy', `idle', or nil.")

(defvar-local emacs-jupyter-notebook--management-operation nil
  "Current local SSH management job, or nil.
The plist contains `:token', `:label', `:started-at', and the current
`:process'.  It never owns a remote kernel or durable registry state.")

(defvar-local emacs-jupyter-notebook--completion-cache nil
  "Buffer-local LRU cache: hash-table mapping context-key -> reply plist.
Created lazily by `emacs-jupyter-notebook--completion-cache-ensure'.")

(defvar-local emacs-jupyter-notebook--completion-cache-order nil
  "LRU order list for the completion cache.
Front of list is most recently used.  Bounded by
`emacs-jupyter-notebook-completion-cache-size'.")

(defvar-local emacs-jupyter-notebook--completion-pending-key nil
  "In-flight completion request context-key (most recent request only).
W3.3 contract: a reply whose key does not match this is dropped on arrival.")

(defvar-local emacs-jupyter-notebook--completion-request-counter 0
  "Monotonic counter for completion request ids.
Bumped every time a request is sent; replies for stale ids are dropped.")

(defvar-local emacs-jupyter-notebook--completion-pending-id nil
  "Numeric request id of the most recent in-flight completion request.")

(defvar-local emacs-jupyter-notebook--completion-idle-timer nil
  "Idle timer for populating completion cache.")

(defvar-local emacs-jupyter-notebook--inspect-request-id 0
  "Monotonic inspect request id.")

(defvar-local emacs-jupyter-notebook--is-complete-request-id 0
  "Monotonic is-complete request id.")

(defconst emacs-jupyter-notebook--max-code-bytes ejn-helper-protocol-max-code-bytes
  "Maximum UTF-8 bytes accepted for one execute request.

This mirrors protocol v1's `EJN_MAX_CODE_BYTES'.  It is checked before a
panel entry, JSON frame, or backend request is created.")

(defvar-local emacs-jupyter-notebook--execution-ledger nil
  "Hash table mapping opaque execution ids to request records.

Records are plists.  Their `:state' progresses from `queued' through
`checking' and `dispatched' to a terminal state.  No callback may infer
currentness from panel position or a mutable singleton request slot.")

(defvar-local emacs-jupyter-notebook--execution-queue nil
  "FIFO list of reserved execution ids, including the active head.")

(defvar-local emacs-jupyter-notebook--execution-active-id nil
  "The single execution id currently being checked, sent, or cancelled.")

(defvar-local emacs-jupyter-notebook--execution-counter 0
  "Monotonic source for buffer-local execution ledger ids.")

(defvar-local emacs-jupyter-notebook--execution-setup-pending nil
  "Non-nil while post-connect silent setup blocks user FIFO dispatch.")

(defvar-local emacs-jupyter-notebook--execution-setup-timer nil
  "Bounded legacy setup-barrier timer, or nil.")

(defvar-local emacs-jupyter-notebook--execution-setup-epoch 0
  "Monotonic identity for the currently admitted silent setup sequence.")

(defvar-local emacs-jupyter-notebook--heartbeat-timer nil
  "Buffer-local repeating timer driving the W4.5 kernel-info heartbeat.")

(defvar-local emacs-jupyter-notebook--heartbeat-misses 0
  "Count of consecutive heartbeat misses on the current buffer.
Reset to 0 on every successful `kernel_info_reply'.")

(defvar-local emacs-jupyter-notebook--heartbeat-inflight nil
  "Token identifying the most recently dispatched heartbeat probe.
The reply callback only updates state when the token still matches; this
prevents a late reply from a previous probe from masking a true miss.")

(defvar-local emacs-jupyter-notebook--heartbeat-timeout-timer nil
  "One-shot timer that fires `--heartbeat-on-miss' when a probe is silent.
Stored so it can be cancelled when the reply lands first, when the user
disables the mode, or when the buffer is killed.  Without this reference
the timer would survive cleanup until it fires.")

(defun emacs-jupyter-notebook--heartbeat-start ()
  "Start the per-buffer kernel-info heartbeat.
The repeating timer fires every `emacs-jupyter-notebook-heartbeat-interval'
seconds and sends a `kernel_info_request' through the configured adapter.
After `emacs-jupyter-notebook-heartbeat-misses-allowed' consecutive misses
the tunnel is flagged dead; the remote kernel is NOT shut down."
  (emacs-jupyter-notebook--heartbeat-cancel)
  (setq emacs-jupyter-notebook--heartbeat-misses 0)
  (let* ((buffer (current-buffer))
         (interval (max 1 (or emacs-jupyter-notebook-heartbeat-interval 20))))
    (setq emacs-jupyter-notebook--heartbeat-timer
          (run-with-timer
           interval interval
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (emacs-jupyter-notebook--heartbeat-tick))))))))

(defun emacs-jupyter-notebook--heartbeat-cancel ()
  "Cancel the buffer-local heartbeat timer and reset its state.
W4.8: also cancels any in-flight per-probe timeout timer so it does not
fire (and miss-bump) after the buffer's heartbeat machinery has been
released by `--release-local-resources' or `--mode-disable-cleanup'."
  (when (timerp emacs-jupyter-notebook--heartbeat-timer)
    (cancel-timer emacs-jupyter-notebook--heartbeat-timer))
  (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
    (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
  (setq emacs-jupyter-notebook--heartbeat-timer nil
        emacs-jupyter-notebook--heartbeat-timeout-timer nil
        emacs-jupyter-notebook--heartbeat-misses 0
        emacs-jupyter-notebook--heartbeat-inflight nil))

(defun emacs-jupyter-notebook--heartbeat-tick ()
  "Fire one kernel-info heartbeat probe with a bounded miss window.
The probe sends a `kernel_info_request' via the configured adapter and
arms a one-shot timeout matching `emacs-jupyter-notebook-heartbeat-timeout'.
The reply (or timeout) routes through `--heartbeat-on-reply' or
`--heartbeat-on-miss', which run in the originating buffer only and only
when the inflight token still matches (so late replies are ignored).

W15-A: while the kernel is BUSY the probe is suspended entirely and the
miss counter reset.  The probe is a shell-channel `kernel_info_request',
and a busy kernel queues shell messages behind the running cell — silence
is the EXPECTED state, not evidence of death.  Counting misses while busy
flagged the tunnel dead ~45 s into any long-running cell (interval 20 s ×
timeout 3 s × 2 misses), producing a false drop/reconnect cycle on every
substantial ML training cell.  Transport death while busy is still caught
by the tunnel process sentinel and the SSH ServerAlive keepalives; probing
resumes on the first tick after the kernel reports non-busy."
  (cond
   ((eq emacs-jupyter-notebook--kernel-status 'busy)
    ;; Busy: expected shell silence — no probe, no misses (W15-A).  A probe
    ;; may have started immediately before the busy status arrived; retire its
    ;; local token so its queued reply/timeout cannot manufacture a miss.
    (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
      (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
    (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil
          emacs-jupyter-notebook--heartbeat-inflight nil
          emacs-jupyter-notebook--heartbeat-misses 0))
   ;; Custom intervals may be shorter than the timeout.  Keep probes
   ;; single-flight instead of overwriting the ownership token and accumulating
   ;; queued shell requests behind a slow or unreachable kernel.
   (emacs-jupyter-notebook--heartbeat-inflight nil)
   ((and emacs-jupyter-notebook--client
         (not emacs-jupyter-notebook--tunnel-dead))
    (let* ((buffer (current-buffer))
           (token (gensym "ejn-heartbeat-")))
      (setq emacs-jupyter-notebook--heartbeat-inflight token)
      (setq emacs-jupyter-notebook--heartbeat-timeout-timer
            (run-with-timer
             (max 0.1 (or emacs-jupyter-notebook-heartbeat-timeout 3))
             nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
                   (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
                     (emacs-jupyter-notebook--heartbeat-on-miss)))))))
      (condition-case _err
          (emacs-jupyter-notebook-backend-aux
           emacs-jupyter-notebook--client 'kernel-info nil
           (lambda (_request-id reply)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
                   ;; The probe answered first; cancel the pending timeout
                   ;; so it does not double-count as a miss.
                   (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
                     (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
                   (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
                   (if reply
                       (emacs-jupyter-notebook--heartbeat-on-reply)
                     (emacs-jupyter-notebook--heartbeat-on-miss))))))
           (lambda (_request-id _error)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
                   (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
                     (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
                   (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
                   (emacs-jupyter-notebook--heartbeat-on-miss))))))
        (error
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (eq emacs-jupyter-notebook--heartbeat-inflight token)
               (when (timerp emacs-jupyter-notebook--heartbeat-timeout-timer)
                 (cancel-timer emacs-jupyter-notebook--heartbeat-timeout-timer))
               (setq emacs-jupyter-notebook--heartbeat-timeout-timer nil)
               (emacs-jupyter-notebook--heartbeat-on-miss))))))))))

(defun emacs-jupyter-notebook--heartbeat-on-reply ()
  "Handle a successful heartbeat reply: clear inflight and reset misses."
  (setq emacs-jupyter-notebook--heartbeat-inflight nil
        emacs-jupyter-notebook--heartbeat-misses 0))

(defun emacs-jupyter-notebook--heartbeat-on-miss ()
  "Handle a heartbeat miss: increment the counter; on threshold flag dead.
Per the binding rule the remote kernel is NOT shut down — heartbeat-driven
death sets `--tunnel-dead' locally so `--ensure-client-async' routes the
next evaluation through `--tunnel-reconnect'.

W6.6: every miss writes a `heartbeat-miss' line to the global log buffer;
crossing the misses-allowed threshold writes a `heartbeat-dead' line."
  (setq emacs-jupyter-notebook--heartbeat-inflight nil)
  (if (eq emacs-jupyter-notebook--kernel-status 'busy)
      ;; A status event can race a probe timeout.  Busy shell silence is not a
      ;; transport failure, regardless of which callback won the timer race.
      (setq emacs-jupyter-notebook--heartbeat-misses 0)
    (cl-incf emacs-jupyter-notebook--heartbeat-misses)
    (emacs-jupyter-notebook--log-append
     'heartbeat-miss
     "kernel-info miss %d/%d in `%s'"
     emacs-jupyter-notebook--heartbeat-misses
     (max 1 (or emacs-jupyter-notebook-heartbeat-misses-allowed 2))
     (buffer-name))
    (when (>= emacs-jupyter-notebook--heartbeat-misses
              (max 1 (or emacs-jupyter-notebook-heartbeat-misses-allowed 2)))
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (setq emacs-jupyter-notebook--kernel-status nil)
      (force-mode-line-update t)
      (emacs-jupyter-notebook--log-append
       'heartbeat-dead
       "tunnel flagged dead after %d consecutive misses in `%s'"
       emacs-jupyter-notebook--heartbeat-misses (buffer-name))
      (display-warning
       'emacs-jupyter-notebook
       (format
        "Heartbeat: %d consecutive kernel-info misses in `%s'; tunnel flagged dead."
        emacs-jupyter-notebook--heartbeat-misses (buffer-name)))
      (emacs-jupyter-notebook--heartbeat-cancel)
      (emacs-jupyter-notebook--schedule-auto-reconnect))))

(defvar-local emacs-jupyter-notebook--async-last-error nil
  "Buffer-local flag: set when the last async operation finished with `error'.
Cleared by any new successful async transition.  W6.2 uses this to drive
the ` EJN✗' lighter branch independently of `--tunnel-dead'.")

(defun emacs-jupyter-notebook--async-phase ()
  "Return the phase symbol of the in-flight async context, or nil.
Returns nil when no context exists or the context is at terminal phase
\\='done or \\='error."
  (let* ((ctx emacs-jupyter-notebook--async-context)
         (phase (and ctx (plist-get ctx :phase))))
    (and (memq phase '(launch probe retrieve tunnel connect)) phase)))

(defun emacs-jupyter-notebook--mode-line-string ()
  "Return the mode-line lighter string for the W6.2 state machine.
Precedence (highest first):
  tunnel-dead       → \" EJN!\"
  management        → \" EJN…manage\"
  async-error       → \" EJN✗\"
  async-in-progress → \" EJN…launch\" / \" EJN…retrieve\" /
                       \" EJN…tunnel\" / \" EJN…connect\"
  kernel busy       → \" EJN*\"
  healthy (idle)    → \" EJN✓\"
  no client         → \" EJN\""
  (let ((phase (emacs-jupyter-notebook--async-phase)))
    (cond
     (emacs-jupyter-notebook--tunnel-dead " EJN!")
     ((emacs-jupyter-notebook--management-active-p) " EJN…manage")
     (emacs-jupyter-notebook--async-last-error " EJN✗")
     ((eq phase 'launch)    " EJN…launch")
     ((eq phase 'probe)     " EJN…probe")
     ((eq phase 'retrieve)  " EJN…retrieve")
     ((eq phase 'tunnel)    " EJN…tunnel")
     ((eq phase 'connect)   " EJN…connect")
     ((eq emacs-jupyter-notebook--kernel-status 'busy) " EJN*")
     ((and emacs-jupyter-notebook--client
           (memq emacs-jupyter-notebook--kernel-status '(idle nil)))
      " EJN✓")
     (t " EJN"))))

(defun emacs-jupyter-notebook--tunnel-state ()
  "Return the current tunnel state as a symbol."
  (cond
   (emacs-jupyter-notebook--tunnel-dead 'dead)
   ((and (processp emacs-jupyter-notebook--tunnel-process)
         (process-live-p emacs-jupyter-notebook--tunnel-process))
    'alive)
   (emacs-jupyter-notebook--tunnel-process 'exited)
   (t 'none)))

(defun emacs-jupyter-notebook-status-snapshot ()
  "Return a plist describing the current buffer's notebook engine state."
  (let ((entry emacs-jupyter-notebook--session-entry)
        (context emacs-jupyter-notebook--async-context)
        (management emacs-jupyter-notebook--management-operation)
        (async-live (emacs-jupyter-notebook--async-in-progress-p))
        (retry-scheduled
         (and (timerp emacs-jupyter-notebook--reconnect-timer)
              emacs-jupyter-notebook--reconnect-schedule-token
              t)))
    (list :buffer (buffer-name)
          :file buffer-file-name
          :client (and emacs-jupyter-notebook--client t)
          :kernel-status emacs-jupyter-notebook--kernel-status
          :tunnel-state (emacs-jupyter-notebook--tunnel-state)
          :async-live async-live
          :async-phase (and async-live (plist-get context :phase))
          :reconnect-owner (and async-live
                                (plist-get context :reconnect-owner))
          :async-error (plist-get context :error)
          :async-age (when-let* ((live async-live)
                                 (started (plist-get context :started-at)))
                       (max 0 (- (float-time) started)))
          :management-label (plist-get management :label)
          :management-age
          (when-let* ((started (plist-get management :started-at)))
            (max 0 (- (float-time) started)))
          :retry-count emacs-jupyter-notebook--reconnect-attempt
          :retry-scheduled retry-scheduled
          :reconnect-next-in
          (when (and retry-scheduled
                     emacs-jupyter-notebook--reconnect-next-at)
            (max 0 (- emacs-jupyter-notebook--reconnect-next-at
                      (float-time))))
          :profile (or (plist-get entry :profile)
                       (plist-get (plist-get context :entry) :profile))
          :session-id (or (plist-get entry :session-id)
                          (plist-get context :session-id))
          :remote-host (plist-get entry :remote-host)
          :remote-pid (plist-get entry :remote-pid)
          :remote-connection-file (plist-get entry :remote-connection-file)
          :local-connection-file (plist-get entry :local-connection-file)
          :tunnel-ports (plist-get entry :tunnel-ports))))

(defvar emacs-jupyter-notebook-cell-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "p") #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "a") #'emacs-jupyter-notebook-beginning-of-cell)
    (define-key map (kbd "e") #'emacs-jupyter-notebook-end-of-cell)
    (define-key map (kbd "i") #'emacs-jupyter-notebook-insert-cell-below)
    (define-key map (kbd "I") #'emacs-jupyter-notebook-insert-cell-above)
    (define-key map (kbd "d") #'emacs-jupyter-notebook-delete-cell)
    (define-key map (kbd "k") #'emacs-jupyter-notebook-kill-cell)
    (define-key map (kbd "K") #'emacs-jupyter-notebook-clear-cell)
    (define-key map (kbd "y") #'emacs-jupyter-notebook-duplicate-cell)
    (define-key map (kbd "P") #'emacs-jupyter-notebook-move-cell-up)
    (define-key map (kbd "N") #'emacs-jupyter-notebook-move-cell-down)
    (define-key map (kbd "@") #'code-cells-mark-cell)
    map)
  "Cell editing keymap, bound under `emacs-jupyter-notebook-prefix-key' + `%'.
The old `s' / `RET' send-current-cell-and-advance bindings have been
removed; use the top-level send-cell binding instead.")

(defun emacs-jupyter-notebook--build-prefix-map ()
  "Return the W6.1 single-prefix command keymap.
All command bindings live under `emacs-jupyter-notebook-prefix-key'
\(default `C-c j').  The cell-editing keymap is attached on `%'."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c")    #'emacs-jupyter-notebook-send-cell)
    (define-key map (kbd "j")    #'emacs-jupyter-notebook-send-cell-and-advance)
    (define-key map (kbd "r")    #'emacs-jupyter-notebook-send-region)
    (define-key map (kbd "SPC")  #'emacs-jupyter-notebook-send-paragraph)
    (define-key map (kbd "d")    #'emacs-jupyter-notebook-send-defun)
    (define-key map (kbd "b")    #'emacs-jupyter-notebook-send-buffer)
    (define-key map (kbd "s")    #'emacs-jupyter-notebook-start-remote-kernel)
    (define-key map (kbd "R")    #'emacs-jupyter-notebook-reconnect-remote-kernel)
    (define-key map (kbd "y")    #'emacs-jupyter-notebook-retry-fresh-kernel)
    (define-key map (kbd "k")    #'emacs-jupyter-notebook-interrupt-kernel)
    (define-key map (kbd "K")    #'emacs-jupyter-notebook-restart-kernel)
    (define-key map (kbd "S")    #'emacs-jupyter-notebook-shutdown-kernel)
    (define-key map (kbd "x")    #'emacs-jupyter-notebook-cancel-operation)
    (define-key map (kbd "z")    #'emacs-jupyter-notebook-cancel-queued-execution)
    (define-key map (kbd "?")    #'emacs-jupyter-notebook-status)
    (define-key map (kbd "L")    #'emacs-jupyter-notebook-show-log-buffer)
    ;; W6.10: `clear-results' was missing from the new prefix map.
    (define-key map (kbd "l")    #'emacs-jupyter-notebook-clear-results)
    (define-key map (kbd "o")    #'emacs-jupyter-notebook-show-output-panel)
    (define-key map (kbd "t")    #'emacs-jupyter-notebook-toggle-panel-view)
    (define-key map (kbd "I")    #'emacs-jupyter-notebook-open-figure-interactive)
    (define-key map (kbd ".")    #'emacs-jupyter-notebook-inspect-at-point)
    (define-key map (kbd "TAB")  #'emacs-jupyter-notebook-complete-at-point)
    (define-key map (kbd "v")    #'emacs-jupyter-notebook-fetch-remote-log)
    (define-key map (kbd "q")    #'emacs-jupyter-notebook-list-remote-processes)
    (define-key map (kbd "w")    #'emacs-jupyter-notebook-clean-orphaned-kernels)
    ;; W11: non-destructive prune of dead registry entries.  (`p' is already
    ;; taken by `backward-cell', so the prune lives on `P'.)
    (define-key map (kbd "P")    #'emacs-jupyter-notebook-prune-dead-kernels)
    (define-key map (kbd "n")    #'emacs-jupyter-notebook-forward-cell)
    (define-key map (kbd "p")    #'emacs-jupyter-notebook-backward-cell)
    (define-key map (kbd "%")    emacs-jupyter-notebook-cell-map)
    map))

(defvar emacs-jupyter-notebook-prefix-map
  (emacs-jupyter-notebook--build-prefix-map)
  "The W6.1 single-prefix command keymap.
Bound under `emacs-jupyter-notebook-prefix-key' in
`emacs-jupyter-notebook-mode-map'.")

(defvar emacs-jupyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd emacs-jupyter-notebook-prefix-key)
                emacs-jupyter-notebook-prefix-map)
    map)
  "Keymap for `emacs-jupyter-notebook-mode'.
A single prefix (`emacs-jupyter-notebook-prefix-key', default `C-c j')
hosts the entire command surface.  See `emacs-jupyter-notebook-prefix-map'.")

(defun emacs-jupyter-notebook--cancel-async-context-locally (context)
  "Cancel CONTEXT's in-flight local processes, timers, and temp files.
Does NOT call `--async-kill-remote-kernel' (the remote kernel must outlive any
buffer-level cleanup) and does NOT delete the context's `:local-file' (the
caller may have already promoted it into the registry entry as the offline
reconnect key).  Each disposer is independently best-effort: a raise from one
disposer does not prevent the remaining disposers from running."
  (when context
    (ignore-errors (emacs-jupyter-notebook--async-cancel-timer context))
    (ignore-errors
      (emacs-jupyter-notebook--async-cancel-overall-timer context))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :launch-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :resolve-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :sidecar-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :launch-probe-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :scp-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :probe-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :busy-probe-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :log-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :restart-upload-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :restart-publish-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :restart-seed-read-process)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-process
       (plist-get context :tunnel-process)))
    (ignore-errors
      (emacs-jupyter-notebook--cleanup-restart-staging context))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-file
       (plist-get context :remote-copy)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-file
       (plist-get context :restart-seed)))
    (ignore-errors
      (emacs-jupyter-notebook--async-delete-file
       (plist-get context :restart-local-file)))
    ;; Review fix: an in-flight connect that is abandoned by buffer kill /
    ;; mode disable must not retain its `:client-unverified' ioloop either.
    (ignore-errors
      (emacs-jupyter-notebook--dispose-unverified-client context))))

(defun emacs-jupyter-notebook--clear-buffer-timers ()
  "Cancel execution-record timers and the completion-idle timer."
  (when (hash-table-p emacs-jupyter-notebook--execution-ledger)
    (maphash (lambda (_id record)
               (when (timerp (plist-get record :timer))
                 (cancel-timer (plist-get record :timer))))
             emacs-jupyter-notebook--execution-ledger))
  (when (timerp emacs-jupyter-notebook--execution-setup-timer)
    (cancel-timer emacs-jupyter-notebook--execution-setup-timer))
  (setq emacs-jupyter-notebook--execution-setup-timer nil)
  (emacs-jupyter-notebook--completion-cancel-idle-timer))

(defun emacs-jupyter-notebook--execution-ledger-ensure ()
  "Return the current buffer's execution ledger, creating it when needed."
  (or emacs-jupyter-notebook--execution-ledger
      (setq emacs-jupyter-notebook--execution-ledger (make-hash-table :test #'eql))))

(defun emacs-jupyter-notebook--execution-record (id)
  "Return the execution record ID in the current buffer, or nil."
  (and (hash-table-p emacs-jupyter-notebook--execution-ledger)
       (gethash id emacs-jupyter-notebook--execution-ledger)))

(defun emacs-jupyter-notebook--execution-current-p (id)
  "Return non-nil when ID remains this buffer's active nonterminal request."
  (let ((record (emacs-jupyter-notebook--execution-record id)))
    (and record (equal id emacs-jupyter-notebook--execution-active-id)
         (memq (plist-get record :state) '(checking dispatched cancelling)))))

(defun emacs-jupyter-notebook--execution-input-current-p (id)
  "Return non-nil only while ID may still receive a stdin reply."
  (let ((record (emacs-jupyter-notebook--execution-record id)))
    (and record (equal id emacs-jupyter-notebook--execution-active-id)
         (eq (plist-get record :state) 'dispatched))))

(defun emacs-jupyter-notebook--execution-put (record)
  "Store RECORD in the current buffer's ledger and return it."
  (puthash (plist-get record :id) record
           (emacs-jupyter-notebook--execution-ledger-ensure))
  record)

(defun emacs-jupyter-notebook--execution-cancel-timer (record)
  "Cancel RECORD's dispatched-only timeout timer."
  (when (timerp (plist-get record :timer))
    (cancel-timer (plist-get record :timer))
    (setq record (plist-put record :timer nil)))
  record)

(defun emacs-jupyter-notebook--execution-remove (record)
  "Retire RECORD from the ledger and FIFO exactly once."
  (let ((id (plist-get record :id)))
    (emacs-jupyter-notebook--execution-cancel-timer record)
    (when (and emacs-jupyter-notebook--client
               (eq (emacs-jupyter-notebook-backend-session-backend
                    emacs-jupyter-notebook--client) 'helper)
               (fboundp 'emacs-jupyter-notebook-helper-backend-retire-ledger-id))
      (ignore-errors
        (emacs-jupyter-notebook-helper-backend-retire-ledger-id
         emacs-jupyter-notebook--client id)))
    (remhash id (emacs-jupyter-notebook--execution-ledger-ensure))
    (setq emacs-jupyter-notebook--execution-queue
          (delq id emacs-jupyter-notebook--execution-queue))
    (when (equal id emacs-jupyter-notebook--execution-active-id)
      (setq emacs-jupyter-notebook--execution-active-id nil))))

(defun emacs-jupyter-notebook--execution-fail (record reason)
  "Terminally present local failure REASON for RECORD and advance its FIFO.
This is for pre-dispatch/completeness/backend failures.  Timeout and explicit
cancel deliberately do not use it: their interrupt leaves the active record
at the FIFO head until correlated terminal evidence arrives.
"
  (when (and record (not (plist-get record :terminal)))
    (let ((text (if (stringp reason) reason "execution failed")))
      (emacs-jupyter-notebook--execution-finish
       record 'error nil
       (format "\n%s" (substring text 0 (min (length text) 512)))))))

(defun emacs-jupyter-notebook--execution-cell-fringe-current-p (record)
  "Return non-nil when RECORD is still the newest live request for its cell."
  (let ((cell-key (plist-get record :cell-key))
        (id (plist-get record :id)))
    (or (null cell-key)
        (not (cl-some
              (lambda (other-id)
                (let ((other (emacs-jupyter-notebook--execution-record other-id)))
                  (and other (> other-id id)
                       (equal (plist-get other :cell-key) cell-key)
                       (not (plist-get other :terminal)))))
              emacs-jupyter-notebook--execution-queue)))))

(defun emacs-jupyter-notebook--execution-finish (record status &optional execution-count suffix)
  "Terminally settle RECORD's local presentation and advance the FIFO."
  (when (and record (not (plist-get record :terminal)))
    (setq record (plist-put record :terminal t))
    (let ((handle (plist-get record :panel-entry))
          (cell-key (plist-get record :cell-key)))
      (when (and suffix (ejn-panel-entry-live-p handle))
        (ignore-errors
          (ejn-panel-append-text handle suffix
                                 'emacs-jupyter-notebook-result-error-face)))
      (when (ejn-panel-entry-live-p handle)
        (ignore-errors (ejn-panel-finish-entry handle status execution-count)))
      ;; Clearing the panel retires this handle's generation.  Terminal
      ;; ownership still settles, but it must not recreate cleared fringe.
      (when (and cell-key (ejn-panel-entry-live-p handle)
                 (emacs-jupyter-notebook--execution-cell-fringe-current-p record))
        (ignore-errors
          (emacs-jupyter-notebook-fringe-set cell-key status execution-count))))
    (emacs-jupyter-notebook--execution-remove record)
    (emacs-jupyter-notebook--execution-pump)))

(defun emacs-jupyter-notebook--execution-code-bytes (code &optional ceiling)
  "Return CODE's UTF-8 byte count, stopping just above CEILING when supplied.
This deliberately avoids `encode-coding-string': an oversize hostile source
must not allocate a second full UTF-8 copy merely to be rejected."
  (let ((limit (or ceiling most-positive-fixnum))
        (total 0)
        (index 0)
        (length (length code))
        (multibyte (multibyte-string-p code)))
    (while (and (< index length) (<= total limit))
      (let ((character (aref code index)))
        (setq total (+ total
                       (if (not multibyte)
                           1
                         (cond ((<= character #x7f) 1)
                               ((<= character #x7ff) 2)
                               ((or (and (>= character #xd800) (<= character #xdfff))
                                    (> character #x10ffff))
                                (1+ limit))
                               ((<= character #xffff) 3)
                               (t 4)))))
        (setq index (1+ index))))
    total))

(defun emacs-jupyter-notebook--execution-setup-finish (client epoch reason)
  "Release CLIENT's user FIFO after a terminal setup decision.
REASON is logged but deliberately does not tear down a durable attachment:
formatter/watchdog setup is best effort, while an unbounded setup request must
never make Emacs appear hung.
"
  (when (and (eq client emacs-jupyter-notebook--client)
             emacs-jupyter-notebook--execution-setup-pending
             (= epoch emacs-jupyter-notebook--execution-setup-epoch))
    (when (timerp emacs-jupyter-notebook--execution-setup-timer)
      (cancel-timer emacs-jupyter-notebook--execution-setup-timer))
    (setq emacs-jupyter-notebook--execution-setup-timer nil
          emacs-jupyter-notebook--execution-setup-pending nil)
    (when reason
      (emacs-jupyter-notebook--log-append 'setup "%s" reason))
    (emacs-jupyter-notebook--execution-pump)))

(defun emacs-jupyter-notebook--execution-setup-barrier (client epoch)
  "Run the bounded legacy shell-order barrier after silent setup sends."
  (let ((buffer (current-buffer))
        (done nil))
    (setq emacs-jupyter-notebook--execution-setup-timer
          (run-at-time
           30 nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (unless done
                   (setq done t)
                   (emacs-jupyter-notebook--execution-setup-finish
                    client epoch "silent setup barrier timed out")))))))
    (condition-case err
        (emacs-jupyter-notebook-backend-aux
         client 'kernel-info nil
         (lambda (_request-id _reply)
           (when (and (not done) (buffer-live-p buffer))
             (setq done t)
             (with-current-buffer buffer
               (emacs-jupyter-notebook--execution-setup-finish client epoch nil))))
         (lambda (_request-id reason)
           (when (and (not done) (buffer-live-p buffer))
             (setq done t)
             (with-current-buffer buffer
               (emacs-jupyter-notebook--execution-setup-finish client epoch reason)))))
      (error
       (unless done
         (setq done t)
         (emacs-jupyter-notebook--execution-setup-finish
          client epoch (format "cannot start silent setup barrier: %s"
                         (error-message-string err))))))))

(defun emacs-jupyter-notebook--execution-setup-send-next (client epoch snippets)
  "Send SNIPPETS serially before permitting user work on CLIENT."
  (if (not snippets)
      (if (eq (emacs-jupyter-notebook-backend-session-backend client) 'helper)
          (emacs-jupyter-notebook--execution-setup-finish client epoch nil)
        (emacs-jupyter-notebook--execution-setup-barrier client epoch))
    (let ((code (car snippets))
          (rest (cdr snippets))
          (buffer (current-buffer)))
      (condition-case err
          (emacs-jupyter-notebook-backend-execute
           client code '(:silent t :setup t)
           (lambda (_request-id _result)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (and (eq client emacs-jupyter-notebook--client)
                            emacs-jupyter-notebook--execution-setup-pending
                            (= epoch emacs-jupyter-notebook--execution-setup-epoch))
                   (emacs-jupyter-notebook--execution-setup-send-next client epoch rest)))))
           (lambda (_request-id reason)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (and (eq client emacs-jupyter-notebook--client)
                            emacs-jupyter-notebook--execution-setup-pending
                            (= epoch emacs-jupyter-notebook--execution-setup-epoch))
                   (emacs-jupyter-notebook--log-append 'setup
                                                       "silent setup request failed: %s"
                                                       reason)
                   (emacs-jupyter-notebook--execution-setup-send-next client epoch rest))))))
        (error
         (emacs-jupyter-notebook--log-append 'setup
                                             "cannot send silent setup request: %s"
                                             (error-message-string err))
         (emacs-jupyter-notebook--execution-setup-send-next client epoch rest))))))

(defun emacs-jupyter-notebook--execution-start-setup (client)
  "Serialize formatter/watchdog setup before any user execution is sent."
  (when (and (eq client emacs-jupyter-notebook--client)
             (not emacs-jupyter-notebook--execution-setup-pending))
    (setq emacs-jupyter-notebook--execution-setup-pending t
          emacs-jupyter-notebook--execution-setup-epoch
          (1+ emacs-jupyter-notebook--execution-setup-epoch))
    (emacs-jupyter-notebook--execution-setup-send-next
     client emacs-jupyter-notebook--execution-setup-epoch
     (append (list emacs-jupyter-notebook--viewer-formatter-snippet)
             (when (and (integerp emacs-jupyter-notebook-kernel-idle-timeout)
                        (> emacs-jupyter-notebook-kernel-idle-timeout 0))
               (list (format emacs-jupyter-notebook--kernel-idle-watchdog-snippet
                             emacs-jupyter-notebook-kernel-idle-timeout)))))))

(defun emacs-jupyter-notebook--evaluation-on-timeout (request-id)
  "Handle timeout of the dispatched execution record REQUEST-ID.
Queued and completeness-checking records deliberately have no timer."
  (let ((record (emacs-jupyter-notebook--execution-record request-id)))
    (when (and record (emacs-jupyter-notebook--execution-current-p request-id)
               (memq (plist-get record :state) '(dispatched cancelling)))
      (let ((timeout emacs-jupyter-notebook-evaluation-timeout)
            (client emacs-jupyter-notebook--client))
        ;; An interrupt is not a terminal outcome.  Keep this record at the
        ;; FIFO head until its correlated reply *and* idle arrive, so B cannot
        ;; execute while A's kernel-side outcome remains unknown.
        (when (eq (plist-get record :state) 'dispatched)
          (setq record (plist-put record :state 'cancelling))
          (setq record (plist-put record :timed-out t))
          (emacs-jupyter-notebook--execution-put record)
          (when (ejn-panel-entry-live-p (plist-get record :panel-entry))
            (ejn-panel-append-text
             (plist-get record :panel-entry)
             (format "\ntimed out after %ss; interrupt requested" timeout)
             'emacs-jupyter-notebook-result-error-face)))
        (unless (plist-get record :interrupt-sent)
          (when client
            (ignore-errors
              (emacs-jupyter-notebook--interrupt-active-execution client))))
        (emacs-jupyter-notebook--log-append
         'eval-timeout "evaluation timed out after %ss; interrupted kernel" timeout)
        (setq emacs-jupyter-notebook--kernel-status 'busy)
        (force-mode-line-update t)))))

(defun emacs-jupyter-notebook--release-local-resources ()
  "Drop the current buffer's local kernel handles without touching durable state.
Cancels the in-flight async context's local processes and timers, tears down the
SSH tunnel process and its stderr buffer, cancels the evaluation timer and the
completion idle timer, and drops the buffer-local backend session.

This is the disposer used by `kill-buffer-hook' and by the mode-disable
cleanup.  It never dispatches a backend `shutdown', starts remote cleanup,
removes registry state, or deletes the local connection file.  A kernel that
was admitted for launch has a provisional durable registry entry before the
launch SSH process is created, so cancelling or losing its originating buffer
leaves an explicit recovery surface rather than guessing whether it started.

Each disposer is independently best-effort: a raise from one does not prevent
the remaining disposers from running, and the final state-clearing setq always
executes."
  (ignore-errors
    (emacs-jupyter-notebook--cancel-async-context-locally
     emacs-jupyter-notebook--async-context))
  (ignore-errors
    (when (emacs-jupyter-notebook--management-active-p)
      (emacs-jupyter-notebook--cancel-management-operation)))
  (ignore-errors (emacs-jupyter-notebook--clear-buffer-timers))
  (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
  (ignore-errors (emacs-jupyter-notebook--cancel-auto-reconnect))
  (ignore-errors
    (when emacs-jupyter-notebook--client
      (emacs-jupyter-notebook-backend-close-local
       emacs-jupyter-notebook--client #'ignore #'ignore)))
  (ignore-errors
    (when (processp emacs-jupyter-notebook--tunnel-process)
      (emacs-jupyter-notebook--async-delete-process
       emacs-jupyter-notebook--tunnel-process)))
  (setq emacs-jupyter-notebook--client nil
        emacs-jupyter-notebook--async-context nil
        emacs-jupyter-notebook--async-last-error nil
        emacs-jupyter-notebook--reconnect-attempt 0
        emacs-jupyter-notebook--reconnect-next-at nil
        emacs-jupyter-notebook--tunnel-process nil
        emacs-jupyter-notebook--tunnel-dead nil
        emacs-jupyter-notebook--kernel-status nil
        emacs-jupyter-notebook--execution-ledger nil
        emacs-jupyter-notebook--execution-queue nil
        emacs-jupyter-notebook--execution-active-id nil
        emacs-jupyter-notebook--execution-setup-pending nil
        emacs-jupyter-notebook--execution-setup-timer nil
        emacs-jupyter-notebook--completion-cache nil
        emacs-jupyter-notebook--completion-cache-order nil
        emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil
        emacs-jupyter-notebook--completion-request-counter 0
        emacs-jupyter-notebook--inspect-request-id 0
        emacs-jupyter-notebook--is-complete-request-id 0
        emacs-jupyter-notebook--management-operation nil))

(defun emacs-jupyter-notebook--mode-disable-cleanup ()
  "Cleanup invoked from the mode-disable branch.
Releases the buffer's LOCAL kernel handles via `--release-local-resources':
cancels the in-flight async context, clears buffer-local timers, disposes
the SSH tunnel process and its stderr buffer, and drops the buffer-local
client handle.  Does NOT touch the session entry, the registry, a
CONNECTED remote kernel, or the local connection file — those are durable
reconnect surfaces and survive mode disable.  An admitted in-progress start
also has a provisional registry entry and is never killed here.  Errors are
swallowed so disable cannot raise."
  (condition-case err
      (emacs-jupyter-notebook--release-local-resources)
    (error
     (message "emacs-jupyter-notebook: mode-disable cleanup failed: %s"
              (error-message-string err)))))

(defun emacs-jupyter-notebook--kill-buffer-hook ()
  "Buffer-local `kill-buffer-hook' that releases local kernel resources.
Errors are swallowed so a failure here cannot prevent the buffer from being
killed.  W2.9 contract: also kills the source buffer's output panel;
killing the panel alone does not touch the kernel or registry (the
panel's own kill-buffer-hook only cancels its flush timer)."
  (condition-case err
      (emacs-jupyter-notebook--release-local-resources)
    (error
     (message "emacs-jupyter-notebook: kill-buffer cleanup failed: %s"
              (error-message-string err))))
  (condition-case err
      (emacs-jupyter-notebook--kill-panel)
    (error
     (message "emacs-jupyter-notebook: panel kill failed: %s"
              (error-message-string err)))))

;;;###autoload
(define-minor-mode emacs-jupyter-notebook-mode
  "Minor mode for evaluating local source cells in remote Jupyter kernels."
  :lighter (:eval (emacs-jupyter-notebook--mode-line-string))
  :keymap emacs-jupyter-notebook-mode-map
  (if emacs-jupyter-notebook-mode
      (progn
        (code-cells-mode 1)
        (add-hook 'completion-at-point-functions
                  #'emacs-jupyter-notebook-completion-at-point nil t)
        (add-hook 'after-change-functions
                  #'emacs-jupyter-notebook--completion-after-change nil t)
        (add-hook 'kill-buffer-hook
                  #'emacs-jupyter-notebook--kill-buffer-hook nil t)
        (emacs-jupyter-notebook--enable-imenu)
        (emacs-jupyter-notebook--completion-start-idle-timer))
    (code-cells-mode -1)
    (remove-hook 'completion-at-point-functions
                 #'emacs-jupyter-notebook-completion-at-point t)
    (remove-hook 'after-change-functions
                 #'emacs-jupyter-notebook--completion-after-change t)
    (remove-hook 'kill-buffer-hook
                 #'emacs-jupyter-notebook--kill-buffer-hook t)
    (emacs-jupyter-notebook-fringe-clear-all)
    (emacs-jupyter-notebook--disable-imenu)
    (emacs-jupyter-notebook--mode-disable-cleanup)))

(add-to-list 'code-cells-eval-region-commands
              '(emacs-jupyter-notebook-mode . emacs-jupyter-notebook-send-region))

(defun emacs-jupyter-notebook--clear-cell-region-artifacts (_beg _end)
  "Clear source-side fringe indicators in the BEG..END region.
With the W2 panel design the source buffer carries no result text, so
only the fringe indicators need clearing on a structural cell edit."
  (emacs-jupyter-notebook-fringe-clear-all))

(defun emacs-jupyter-notebook--clear-all-cell-artifacts ()
  "Clear all source-side fringe indicators before structural cell edits."
  (emacs-jupyter-notebook-fringe-clear-all))

(defun emacs-jupyter-notebook--goto-live-cell-start ()
  "Move point to the current cell body when the buffer is nonempty."
  (unless (= (point-min) (point-max))
    (emacs-jupyter-notebook-cell-goto-code-start)))

(defun emacs-jupyter-notebook-beginning-of-cell ()
  "Move to the first editable line of the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-end-of-cell ()
  "Move to the end of the current cell body."
  (interactive)
  (emacs-jupyter-notebook-cell-goto-code-end))

(defun emacs-jupyter-notebook-insert-cell-below ()
  "Insert an empty cell below the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-below))

(defun emacs-jupyter-notebook-insert-cell-above ()
  "Insert an empty cell above the current cell."
  (interactive)
  (emacs-jupyter-notebook-cell-insert-above))

(defun emacs-jupyter-notebook-delete-cell ()
  "Delete the current cell without touching the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-kill-cell ()
  "Kill the current cell, saving it in the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (kill-region beg end)
    (emacs-jupyter-notebook--goto-live-cell-start)))

(defun emacs-jupyter-notebook-clear-cell ()
  "Delete the current cell body while keeping the cell marker."
  (interactive)
  (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
    (emacs-jupyter-notebook--clear-cell-region-artifacts beg end)
    (delete-region beg end)
    (goto-char beg)))

(defun emacs-jupyter-notebook-duplicate-cell ()
  "Duplicate the current cell below itself and move to the duplicate."
  (interactive)
  (pcase-let* ((`(,beg . ,end) (emacs-jupyter-notebook-cell-full-bounds))
               (text (buffer-substring beg end)))
    (goto-char end)
    (let ((start (point)))
      (insert text)
      (emacs-jupyter-notebook-cell-goto-code-start start))))

(defun emacs-jupyter-notebook-move-cell-up (&optional arg)
  "Move the current cell up ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-up (or arg 1))
  (when-let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
    (emacs-jupyter-notebook-panel--invalidate-structure panel))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-move-cell-down (&optional arg)
  "Move the current cell down ARG cells and clear stale output overlays."
  (interactive "p")
  (emacs-jupyter-notebook--clear-all-cell-artifacts)
  (code-cells-move-cell-down (or arg 1))
  (when-let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
    (emacs-jupyter-notebook-panel--invalidate-structure panel))
  (emacs-jupyter-notebook-cell-goto-code-start))

(defun emacs-jupyter-notebook-send-cell-and-advance ()
  "Send the current cell, then move to the next cell when one exists."
  (interactive)
  (emacs-jupyter-notebook-send-cell)
  (condition-case nil
      (emacs-jupyter-notebook-forward-cell 1)
    (user-error nil)))

(defun emacs-jupyter-notebook--new-session-id (&optional hint)
  "Return a locally unique session id string, optionally containing HINT."
  (let ((base (replace-regexp-in-string
               "[^[:alnum:]_.-]" "_"
               (or hint (format "%s" (emacs-pid))))))
    (format "%s-%s" base
            (md5 (format "%s:%s:%s:%s"
                         (current-time-string) (float-time) (random) (emacs-pid))))))

(defun emacs-jupyter-notebook--timestamp ()
  "Return an ISO-like timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun emacs-jupyter-notebook--read-profile-name ()
  "Read a profile name for interactive commands."
  (let ((names (mapcar (lambda (entry) (format "%s" (car entry)))
                       emacs-jupyter-notebook-remote-profiles)))
    (if names
        (completing-read "Remote profile: " names nil nil nil nil
                         emacs-jupyter-notebook-default-profile)
      emacs-jupyter-notebook-default-profile)))

(defun emacs-jupyter-notebook--prompt-host ()
  "Prompt for a remote-host string, looping until valid input is given.
W6.7 contract: empty / whitespace-only answers re-prompt; a value
containing internal whitespace fails fast with `user-error' before any
SSH command is launched."
  (let (host)
    (while (or (null host) (string-empty-p (string-trim host)))
      (setq host (read-string "Remote host: ")))
    (setq host (string-trim host))
    (when (string-match-p "[ \t]" host)
      (user-error
       "Remote host %S contains whitespace; refusing to launch SSH"
       host))
    host))

(defun emacs-jupyter-notebook--read-host-profile (profile-name)
  "Return PROFILE-NAME profile, prompting for :host when missing.
W6.7: missing host is filled by `--prompt-host', which loops until the
user enters non-empty input and errors when the input contains
whitespace.

W6.10: the whitespace check is also applied to the resolved host
regardless of where it came from — a profile configured with a
whitespace-containing `:host' / `:remote-host' is rejected before any
SSH command can run."
  (let* ((profile (emacs-jupyter-notebook-ssh-profile profile-name))
         (host (or (plist-get profile :host)
                   (plist-get profile :remote-host))))
    (when (and host (string-match-p "[[:space:]]" host))
      (user-error
       "Profile %S has whitespace in its host (%S); refuse to launch SSH"
       (or profile-name (plist-get profile :profile) "?") host))
    (unless host
      (setq profile (plist-put profile :host
                               (emacs-jupyter-notebook--prompt-host))))
    profile))

(defun emacs-jupyter-notebook--parse-pid (output)
  "Parse a remote background PID from OUTPUT.
Match the W4.2 sentinel `EJN_PID=<digits>' anchored on its own line so
spurious numbers in an SSH banner or MOTD cannot poison the parse."
  (when (string-match "^EJN_PID=\\([0-9]+\\)$" output)
    (string-to-number (match-string 1 output))))

(defun emacs-jupyter-notebook--entry-profile (entry)
  "Return the configured profile overlaid with durable fields from ENTRY.
Reconnect used to construct a bare plist from ENTRY, which bypassed the
named profile lookup in `emacs-jupyter-notebook-ssh-profile'.  Immediate
reconnects could appear to work through a still-live ControlMaster, while a
later reconnect silently lost the profile's port, identity file, ProxyJump,
and other SSH options.  Resolve the current named profile first, then pin the
session-specific host, paths, and kernelspec recorded in the registry."
  (let ((profile (emacs-jupyter-notebook-ssh-profile
                  (plist-get entry :profile))))
    (dolist (pair `((:host . ,(plist-get entry :remote-host))
                    (:remote-cwd . ,(plist-get entry :remote-cwd))
                    (:remote-cache-dir
                     . ,(file-name-directory
                         (plist-get entry :remote-connection-file)))
                    (:kernelspec . ,(plist-get entry :kernelspec))))
      (when (cdr pair)
        (setq profile (plist-put profile (car pair) (cdr pair)))))
    profile))

(defun emacs-jupyter-notebook--current-file-registry-entry ()
  "Return the latest registry entry for the current buffer's file, or nil."
  (when buffer-file-name
    (emacs-jupyter-notebook-registry-latest-for-file
     buffer-file-name
     (emacs-jupyter-notebook-registry-load))))

(defun emacs-jupyter-notebook--remove-registry-entry (entry)
  "Remove ENTRY from the durable registry when it has an identity key."
  (when-let* ((key (or (plist-get entry :session-id)
                       (plist-get entry :profile))))
    (emacs-jupyter-notebook-registry-remove-entry key)))

(defun emacs-jupyter-notebook--registry-entry-label (entry)
  "Return a human-readable single-line label for registry ENTRY."
  (format "%s  %s  %s"
          (or (plist-get entry :display-name) "kernel")
          (or (plist-get entry :profile) "")
          (or (plist-get entry :session-id) "")))

(defun emacs-jupyter-notebook--management-active-p (&optional token)
  "Return non-nil when a management job is active and optionally matches TOKEN."
  (and emacs-jupyter-notebook--management-operation
       (or (null token)
           (eq token
               (plist-get emacs-jupyter-notebook--management-operation
                          :token)))))

(defun emacs-jupyter-notebook--management-begin (label)
  "Begin a buffer-local management job named LABEL and return its token."
  (when (emacs-jupyter-notebook--management-active-p)
    (user-error
     "Management operation already in progress (%s); use C-c j x to cancel"
     (plist-get emacs-jupyter-notebook--management-operation :label)))
  (let ((token (gensym "ejn-management-")))
    (setq emacs-jupyter-notebook--management-operation
          (list :token token :label label :started-at (float-time)
                :process nil))
    (force-mode-line-update t)
    (message "emacs-jupyter-notebook: %s (C-c j x cancels)" label)
    token))

(defun emacs-jupyter-notebook--management-finish (token)
  "Clear the management job identified by TOKEN."
  (when (emacs-jupyter-notebook--management-active-p token)
    (setq emacs-jupyter-notebook--management-operation nil)
    (force-mode-line-update t)))

(defun emacs-jupyter-notebook--management-launch
    (token name argv success failure &optional timeout)
  "Launch one management process under TOKEN.
SUCCESS receives stdout.  FAILURE receives a reason and stderr.  Callbacks
run only while TOKEN still owns the buffer and this is its current process."
  (let ((buffer (current-buffer)) process)
    (condition-case _err
        (setq process
              (emacs-jupyter-notebook-ssh-start-management-operation
               name argv
               (lambda (output)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (let ((current
                            (plist-get
                             emacs-jupyter-notebook--management-operation
                             :process)))
                       (when (and
                              (emacs-jupyter-notebook--management-active-p token)
                              (or (null current) (eq current process)))
                         (setq emacs-jupyter-notebook--management-operation
                               (plist-put
                                emacs-jupyter-notebook--management-operation
                                :process nil))
                         (funcall success output))))))
               (lambda (reason stderr)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (let ((current
                            (plist-get
                             emacs-jupyter-notebook--management-operation
                             :process)))
                       (when (and
                              (emacs-jupyter-notebook--management-active-p token)
                              (or (null current) (eq current process)))
                         (setq emacs-jupyter-notebook--management-operation
                               (plist-put
                                emacs-jupyter-notebook--management-operation
                                :process nil))
                         (funcall failure reason stderr))))))
               timeout))
      (error
       (when (emacs-jupyter-notebook--management-active-p token)
         (funcall failure 'failed ""))))
    ;; A test double (or a process that exits immediately) may complete before
    ;; the starter returns.  Do not overwrite a continuation's newer process.
    (when (and process
               (emacs-jupyter-notebook--management-active-p token)
               (null (plist-get emacs-jupyter-notebook--management-operation
                                :process)))
      (setq emacs-jupyter-notebook--management-operation
            (plist-put emacs-jupyter-notebook--management-operation
                       :process process)))
    process))

(defun emacs-jupyter-notebook--management-run
    (label name argv success failure &optional timeout)
  "Run one management command with progress and cancellation state."
  (let ((token (emacs-jupyter-notebook--management-begin label)))
    (emacs-jupyter-notebook--management-launch
     token name argv
     (lambda (output)
       (emacs-jupyter-notebook--management-finish token)
       (funcall success output))
     (lambda (reason stderr)
       (emacs-jupyter-notebook--management-finish token)
       (funcall failure reason stderr))
     timeout)))

(defun emacs-jupyter-notebook--cancel-management-operation ()
  "Cancel the current local management process without touching durable state."
  (let* ((job emacs-jupyter-notebook--management-operation)
         (token (plist-get job :token))
         (process (plist-get job :process)))
    (if (processp process)
        (emacs-jupyter-notebook-ssh-management-cancel process)
      (emacs-jupyter-notebook--management-finish token)
      (message "emacs-jupyter-notebook: management operation cancelled"))))

;;; W11 (B) — non-destructive prune of dead registry entries
;;
;; Ghost kernels: the reconnect picker used to list every registry entry,
;; including ones whose remote kernel is long gone.  W11(B) probes liveness
;; per host and drops entries whose PID a host CONFIRMED dead.  It is strictly
;; NON-DESTRUCTIVE: it never kills a live kernel and never prunes an entry the
;; host could not vouch for.  An entry is only removed on a positive "this PID
;; is gone" answer; an unreachable host, a probe error, or a pre-W4.2 entry
;; without a recorded PID all stay UNKNOWN and are kept.

(defun emacs-jupyter-notebook--classify-registry-liveness (entries &optional probe-fn)
  "Classify ENTRIES by remote-kernel liveness.  W11.
Return an alist mapping each ENTRY (by `eq') to a status symbol: `alive',
`dead', or `unknown'.  Entries are grouped by ssh-destination so each host
is classified through the explicit synchronous test double PROBE-FN.  With
no PROBE-FN every entry remains `unknown'; production commands use
`--classify-registry-liveness-async'.  Entries without a
recorded `:remote-pid', entries whose profile has no resolvable
destination, and every entry on a host that did not answer are `unknown'
and are never pruned; only a host-confirmed-gone PID yields `dead'."
  (let ((probe-fn (or probe-fn
                      (lambda (_profile _pids)
                        (list :answered nil :alive nil))))
        (groups nil)          ; alist: destination -> (profile entries...)
        (result nil))
    ;; Partition entries; ones without a PID or destination are UNKNOWN
    ;; up front and never reach a probe.
    (dolist (entry entries)
      (let ((pid (plist-get entry :remote-pid)))
        (if (not pid)
            (push (cons entry 'unknown) result)
          (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
                 (dest (condition-case nil
                           (emacs-jupyter-notebook-ssh-destination profile)
                         (error nil))))
            (if (not dest)
                (push (cons entry 'unknown) result)
              (let ((cell (assoc dest groups)))
                (if cell
                    (setcdr (cdr cell) (cons entry (cddr cell)))
                  (push (cons dest (cons profile (list entry))) groups))))))))
    ;; One probe per host.
    (dolist (group groups)
      (let* ((profile (cadr group))
             (host-entries (cddr group))
             (pids (mapcar (lambda (e) (plist-get e :remote-pid)) host-entries))
             (probe (condition-case nil
                        (funcall probe-fn profile pids)
                      (error (list :answered nil :alive nil))))
             (answered (plist-get probe :answered))
             (alive (mapcar (lambda (p) (format "%s" p))
                            (plist-get probe :alive))))
        (dolist (entry host-entries)
          (let ((pid (format "%s" (plist-get entry :remote-pid))))
            (push (cons entry
                        (cond ((not answered) 'unknown)
                              ((member pid alive) 'alive)
                              (t 'dead)))
                  result)))))
    result))

(defun emacs-jupyter-notebook--liveness-status (entry classification)
  "Return the W11 liveness status of ENTRY within CLASSIFICATION (by `eq')."
  (cdr (cl-assoc entry classification :test #'eq)))

(defun emacs-jupyter-notebook--classify-registry-liveness-async
    (entries token callback)
  "Classify ENTRIES asynchronously under management TOKEN.
CALLBACK receives CLASSIFICATION and a terminal reason.  The reason is nil on
completion or `cancelled'.  Failed/timed-out hosts are classified `unknown'."
  (let ((groups nil)
        (result nil))
    (dolist (entry entries)
      (let ((pid (plist-get entry :remote-pid)))
        (if (not pid)
            (push (cons entry 'unknown) result)
          (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
                 (destination
                  (condition-case nil
                      (emacs-jupyter-notebook-ssh-destination profile)
                    (error nil))))
            (if (not destination)
                (push (cons entry 'unknown) result)
              (let ((group (assoc destination groups)))
                (if group
                    (setcdr (cdr group) (cons entry (cddr group)))
                  (push (cons destination (cons profile (list entry)))
                        groups))))))))
    (cl-labels
        ((record-group
          (host-entries answered alive)
          (dolist (entry host-entries)
            (let ((pid (format "%s" (plist-get entry :remote-pid))))
              (push (cons entry
                          (cond ((not answered) 'unknown)
                                ((member pid alive) 'alive)
                                (t 'dead)))
                    result))))
         (next
          (remaining)
          (cond
           ((not (emacs-jupyter-notebook--management-active-p token))
            nil)
           ((null remaining)
            (funcall callback result nil))
           (t
            (let* ((group (car remaining))
                   (profile (cadr group))
                   (host-entries (cddr group))
                   (pids (mapcar
                          (lambda (entry)
                            (plist-get entry :remote-pid))
                          host-entries))
                   (argv
                    (condition-case nil
                        (emacs-jupyter-notebook-ssh-build-batch-pid-alive
                         profile pids)
                      (error nil))))
              (if (not argv)
                  (progn
                    (record-group host-entries nil nil)
                    (next (cdr remaining)))
                (emacs-jupyter-notebook--management-launch
                 token "ejn-liveness-probe" argv
                 (lambda (output)
                   (let* ((lines (split-string output "[\r\n]+" t "[ \t]+"))
                          (answered (member "__EJN_DONE__" lines))
                          (alive
                           (and answered
                                (cl-remove-if-not
                                 (lambda (pid)
                                   (member (format "%s" pid) lines))
                                 pids))))
                     (record-group
                      host-entries answered
                      (mapcar (lambda (pid) (format "%s" pid)) alive))
                     (next (cdr remaining))))
                 (lambda (reason _stderr)
                   (if (eq reason 'cancelled)
                       (funcall callback nil 'cancelled)
                     (record-group host-entries nil nil)
                     (next (cdr remaining))))
                 emacs-jupyter-notebook-prune-ssh-timeout)))))))
      (next groups))))

(defun emacs-jupyter-notebook--registry-liveness-result
    (entries classification)
  "Summarize ENTRIES using liveness CLASSIFICATION without doing I/O."
  (let ((dead nil) (alive 0) (unknown 0) (kept nil))
    (dolist (entry entries)
      (pcase (emacs-jupyter-notebook--liveness-status entry classification)
        ('dead (push entry dead))
        ('alive (setq alive (1+ alive)) (push entry kept))
        (_ (setq unknown (1+ unknown)) (push entry kept))))
    (list :pruned (length dead)
          :alive alive
          :unknown unknown
          :kept-entries (nreverse kept)
          :pruned-entries (nreverse dead))))

(defun emacs-jupyter-notebook--prune-dead-registry-entries (&optional file probe-fn)
  "Prune registry entries whose remote kernel is confirmed DEAD.  W11(B).
Load the registry from FILE, classify liveness via PROBE-FN, and rewrite
the registry without the confirmed-dead entries.  NON-DESTRUCTIVE: never
kills a live kernel; keeps every `alive' AND `unknown' entry (an
unreachable host cannot cause a false prune).  The file is only rewritten
when at least one entry is actually pruned.  Return a plist
\(:pruned N :alive A :unknown U :kept-entries (...) :pruned-entries (...))."
  (let* ((entries (emacs-jupyter-notebook-registry-load file))
         (classification (emacs-jupyter-notebook--classify-registry-liveness
                          entries probe-fn))
         (result (emacs-jupyter-notebook--registry-liveness-result
                  entries classification)))
    (when (plist-get result :pruned-entries)
      (emacs-jupyter-notebook-registry-save
       (plist-get result :kept-entries) file))
    result))

(defun emacs-jupyter-notebook--choose-registry-entry (entries)
  "Prompt for and return one entry from ENTRIES."
  (unless entries
    (user-error "No kernel sessions found in registry"))
  (let* ((choices (mapcar
                   (lambda (entry)
                     (cons (emacs-jupyter-notebook--registry-entry-label entry)
                           entry))
                   entries))
         (current (emacs-jupyter-notebook--current-file-registry-entry))
         (current-key (and current
                           (or (plist-get current :session-id)
                               (plist-get current :profile))))
         (default-entry
          (and current-key
               (cl-find-if
                (lambda (entry)
                  (equal current-key
                         (or (plist-get entry :session-id)
                             (plist-get entry :profile))))
                entries)))
         (default (and default-entry
                       (car (rassq default-entry choices))))
         (prompt (if default
                     (format "Reconnect kernel (default %s): " default)
                   "Reconnect kernel: "))
         (choice (completing-read prompt choices nil t nil nil default)))
    (or (cdr (assoc choice choices))
        (error "No registry entry selected"))))

(defun emacs-jupyter-notebook--read-registry-entry ()
  "Read one registry entry without performing remote work."
  (let ((entries (emacs-jupyter-notebook-registry-load)))
    (emacs-jupyter-notebook--choose-registry-entry entries)))

(defun emacs-jupyter-notebook--read-registry-entry-async (callback)
  "Probe the registry asynchronously, then invoke CALLBACK with a chosen entry."
  (let ((entries (emacs-jupyter-notebook-registry-load)))
    (unless entries
      (user-error "No kernel sessions found in registry"))
    (let ((token (emacs-jupyter-notebook--management-begin
                  "checking registered kernels")))
      (emacs-jupyter-notebook--classify-registry-liveness-async
       entries token
       (lambda (classification reason)
         (emacs-jupyter-notebook--management-finish token)
         (cond
          ((eq reason 'cancelled)
           (message "emacs-jupyter-notebook: reconnect selection cancelled"))
          (t
           (let* ((result (emacs-jupyter-notebook--registry-liveness-result
                           entries classification))
                  (dead (plist-get result :pruned-entries))
                  (survivors (plist-get result :kept-entries)))
             (when dead
               (emacs-jupyter-notebook-registry-save survivors)
               (message
                "emacs-jupyter-notebook: pruned %d dead kernel entr%s from picker"
                (length dead) (if (= (length dead) 1) "y" "ies")))
             (if (null survivors)
                 (message
                  "emacs-jupyter-notebook: all registered kernels are dead")
               (condition-case err
                   (funcall callback
                            (emacs-jupyter-notebook--choose-registry-entry
                             survivors))
                 (quit nil)
                 (error
                  (message "emacs-jupyter-notebook: picker failed: %s"
                           (error-message-string err)))))))))))))

;; W4.7: the synchronous `--retrieve-connection-file' that polled with
;; `sleep-for' has been removed.  The async retrieve in
;; `--async-retrieve' / `--async-retrieve-attempt' is the only path; it
;; uses a `run-with-timer' loop and never blocks the UI.

(defun emacs-jupyter-notebook--start-tunnel (profile remote-ports local-ports session-id)
  "Start an SSH tunnel for PROFILE from LOCAL-PORTS to REMOTE-PORTS."
  (let* ((argv (emacs-jupyter-notebook-ssh-tunnel-command
                profile remote-ports local-ports))
         (name (format "emacs-jupyter-notebook-tunnel-%s" session-id)))
    (emacs-jupyter-notebook-ssh-start-bounded-process
     name argv (emacs-jupyter-notebook-ssh--management-output-limit)
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (message "Jupyter tunnel %s: %s" process (string-trim event)))))))

(defun emacs-jupyter-notebook--local-port-open-p (port)
  "Return non-nil when PORT accepts a TCP connection on localhost."
  (condition-case nil
      (let ((proc (open-network-stream
                   (format "emacs-jupyter-notebook-port-%s" port)
                   nil "127.0.0.1" port)))
        (delete-process proc)
        t)
    (error nil)))

;; W4.7: the synchronous `--wait-for-tunnel' that blocked the UI with
;; `sleep-for' has been removed.  The async tunnel-readiness poller in
;; `--async-wait-tunnel-tick' is the only path; it reschedules itself via
;; `run-with-timer' until all ports open or the timeout expires.

(defun emacs-jupyter-notebook--last-lines (text n)
  "Return at most the last N lines of TEXT (trimmed), or nil when TEXT is empty."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let ((lines (split-string (string-trim-right text) "\n")))
      (string-join (last lines (min n (length lines))) "\n"))))

(defun emacs-jupyter-notebook--process-output (process)
  "Return PROCESS output buffer contents."
  (string-join
   (delq nil
         (mapcar (lambda (buffer)
                   (when (and buffer (buffer-live-p buffer))
                     (with-current-buffer buffer
                       (let ((text (string-trim (buffer-string))))
                         (unless (string-empty-p text)
                           text)))))
                 (list (process-buffer process)
                       (process-get process 'emacs-jupyter-notebook-stderr-buffer))))
   "\n"))

(defun emacs-jupyter-notebook--process-stdout (process)
  "Return PROCESS stdout only, never treating stderr as protocol data."
  (when-let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (buffer-string)))))

(defun emacs-jupyter-notebook--install-tunnel-sentinel (process buffer)
  "Install a sentinel on PROCESS that marks the tunnel dead in BUFFER."
  (if (not (process-live-p process))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq emacs-jupyter-notebook--tunnel-dead t)
          (setq emacs-jupyter-notebook--kernel-status nil)
          (force-mode-line-update t)
          (emacs-jupyter-notebook--schedule-auto-reconnect)))
    (set-process-sentinel
     process
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq emacs-jupyter-notebook--tunnel-dead t)
             (setq emacs-jupyter-notebook--kernel-status nil)
             (force-mode-line-update t)
             (emacs-jupyter-notebook--schedule-auto-reconnect))))))))

(defun emacs-jupyter-notebook--cancel-auto-reconnect ()
  "Cancel this buffer's pending automatic reconnect timer."
  (when (timerp emacs-jupyter-notebook--reconnect-timer)
    (cancel-timer emacs-jupyter-notebook--reconnect-timer))
  (setq emacs-jupyter-notebook--reconnect-timer nil
        emacs-jupyter-notebook--reconnect-next-at nil
        emacs-jupyter-notebook--reconnect-schedule-token nil))

(defun emacs-jupyter-notebook--auto-reconnect-delay ()
  "Return the delay before this buffer's next automatic reconnect."
  (let ((initial (max 0.1 emacs-jupyter-notebook-reconnect-initial-delay))
        (maximum (max 0.1 emacs-jupyter-notebook-reconnect-max-delay)))
    (min maximum
         (* initial (expt 2 (min emacs-jupyter-notebook--reconnect-attempt
                                 20))))))

(defun emacs-jupyter-notebook--schedule-auto-reconnect (&optional immediate)
  "Schedule bounded transport recovery for this buffer.
When IMMEDIATE is non-nil, run as soon as Emacs can dispatch the timer.
Retries continue with capped exponential backoff until the transport comes
back or a probe confirms that the registered kernel is no longer the same
live process.  This function never starts or terminates a remote kernel."
  (when (and emacs-jupyter-notebook-auto-reconnect
             emacs-jupyter-notebook-mode
             emacs-jupyter-notebook--tunnel-dead
             emacs-jupyter-notebook--session-entry
             (not (timerp emacs-jupyter-notebook--reconnect-timer))
             (null emacs-jupyter-notebook--reconnect-schedule-token)
             (not (emacs-jupyter-notebook--async-in-progress-p)))
    (let* ((buffer (current-buffer))
           (delay (if immediate 0 (emacs-jupyter-notebook--auto-reconnect-delay)))
           (token (gensym "ejn-reconnect-")))
      (setq emacs-jupyter-notebook--reconnect-next-at (+ (float-time) delay)
            emacs-jupyter-notebook--reconnect-schedule-token token
            emacs-jupyter-notebook--reconnect-timer
            (run-at-time delay nil
                         #'emacs-jupyter-notebook--auto-reconnect-fire
                         buffer token))
      (emacs-jupyter-notebook--log-append
       'auto-reconnect "attempt %d scheduled in %.1fs for `%s'"
       (1+ emacs-jupyter-notebook--reconnect-attempt) delay (buffer-name))
      (force-mode-line-update t))))

(defun emacs-jupyter-notebook--auto-reconnect-fire (buffer token)
  "Run one automatic reconnect attempt for BUFFER owned by TOKEN.
TOKEN prevents a cancelled or superseded timer callback from starting a stale
attempt.  Only the exact non-nil generation installed by
`--schedule-auto-reconnect' may consume the schedule."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and token
                 (eq token
                     emacs-jupyter-notebook--reconnect-schedule-token))
        (setq emacs-jupyter-notebook--reconnect-timer nil
              emacs-jupyter-notebook--reconnect-next-at nil
              emacs-jupyter-notebook--reconnect-schedule-token nil)
        (when (and emacs-jupyter-notebook-auto-reconnect
                   emacs-jupyter-notebook-mode
                   emacs-jupyter-notebook--tunnel-dead
                   emacs-jupyter-notebook--session-entry
                   (not (emacs-jupyter-notebook--async-in-progress-p)))
          (cl-incf emacs-jupyter-notebook--reconnect-attempt)
          (let ((entry emacs-jupyter-notebook--session-entry))
            (condition-case err
                (emacs-jupyter-notebook--begin-reconnect
                 entry
                 (lambda (_context)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (emacs-jupyter-notebook--log-append
                        'auto-reconnect "transport restored for `%s'"
                        (buffer-name)))))
                 (lambda (context error-data)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (if (emacs-jupyter-notebook--reconnect-terminal-p
                            context)
                           (emacs-jupyter-notebook--log-append
                            'auto-reconnect
                            "stopped after confirmed terminal probe: %s"
                            error-data)
                         (emacs-jupyter-notebook--log-append
                          'auto-reconnect "transient attempt failed: %s"
                          error-data)))))
                 'automatic)
              (error
               (setq emacs-jupyter-notebook--tunnel-dead t)
               (emacs-jupyter-notebook--log-append
                'auto-reconnect "could not start attempt: %s"
                (error-message-string err))
               (emacs-jupyter-notebook--schedule-auto-reconnect)))))))))

;;; Async machinery

(defun emacs-jupyter-notebook--async-new-context (&rest properties)
  "Return a new async operation context initialized with PROPERTIES."
  (let ((context (list :phase nil
                       :started-at (float-time)
                       :profile nil
                       :entry nil
                       :session-id nil
                       :launch nil
                       :launch-process nil
                       :launch-process-started nil
                       :scp-process nil
                       :scp-attempt 0
                       :probe-process nil
                       :busy-probe-process nil
                       :log-process nil
                       :tunnel-process nil
                       :local-ports nil
                       :remote-ports nil
                       :connection nil
                       :remote-copy nil
                       :local-file nil
                       :candidate-remote-pid nil
                       :restart-epoch nil
                       :restart-seed nil
                       :restart-staging-file nil
                       :restart-preflight nil
                       :restart-provisional-saved nil
                       :restart-shutdown-sent nil
                       :restart-shutdown-confirmed nil
                       :restart-client nil
                       :lifecycle-failure-handled nil
                       :restart-seed-read-process nil
                       :restart-upload-process nil
                       :restart-publish-process nil
                       :restart-local-file nil
                       :timer nil
                       :overall-timer nil
                       :deadline nil
                       :callback nil
                       :error-callback nil
                       :origin-buffer nil
                       :owns-kernel nil
                       :cancelled nil
                       :reconnect-owner nil
                       :reconnect-failure-handled nil
                       :error nil)))
    (while properties
      (setq context (plist-put context (pop properties) (pop properties))))
    context))

(defun emacs-jupyter-notebook--async-put (context property value)
  "Set PROPERTY to VALUE in async CONTEXT and store it in its buffer."
  (setq context (plist-put context property value))
  (when-let* ((buffer (plist-get context :origin-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-jupyter-notebook--async-context context))))
  context)

(defun emacs-jupyter-notebook--async-get (context property)
  "Return PROPERTY from async CONTEXT."
  (plist-get context property))

(defun emacs-jupyter-notebook--async-in-progress-p ()
  "Return non-nil when an async operation is in progress."
  (and emacs-jupyter-notebook--async-context
       (not (memq (plist-get emacs-jupyter-notebook--async-context :phase)
                  '(done error nil)))))

(defun emacs-jupyter-notebook--async-context-live-p (context)
  "Return non-nil when CONTEXT is its origin buffer's ACTIVE in-flight attempt.
False once CONTEXT was cancelled/failed (its buffer-local phase is now
`error'/`done'/nil) or superseded by a newer attempt (a different context
object now occupies the buffer's `--async-context').

W12/A2: a process sentinel or retry timer belonging to a dead attempt may
still fire after `--cancel-async-operation'/`--async-fail' — either
synchronously while `--async-fail' is deleting the attempt's own processes,
or asynchronously after a superseding attempt has taken the buffer slot.
Without this gate `--async-put' from that stale sentinel would resurrect the
dead context into the buffer, re-arm an SCP retry against a just-killed
kernel, and clobber the newer attempt.  Mirrors the identity check the
W4.4 PID-probe sentinel already performs."
  (let ((buffer (plist-get context :origin-buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (and (eq emacs-jupyter-notebook--async-context context)
                (emacs-jupyter-notebook--async-in-progress-p))))))

(defun emacs-jupyter-notebook--ensure-no-async-operation (&optional supersede-reconnect)
  "Ensure the current buffer holds no in-flight connection attempt.
A single buffer owns a single connection — two attempts must never run
in parallel.  When SUPERSEDE-RECONNECT is non-nil, an existing reconnect
attempt is cancelled locally without prompting; this makes an explicit
reconnect command the reliable escape hatch from a wedged background
attempt.  A start attempt still requires confirmation because cancelling
it may terminate the kernel that attempt launched."
  (when (emacs-jupyter-notebook--async-in-progress-p)
    (if (or (and supersede-reconnect
                 (not (plist-get emacs-jupyter-notebook--async-context
                                 :owns-kernel)))
            (y-or-n-p "A Jupyter connection attempt is already in progress; cancel it and start a new one? "))
        (emacs-jupyter-notebook--cancel-async-operation
         emacs-jupyter-notebook--async-context
         "Superseded by a new connection attempt")
      (user-error "Kept the in-progress Jupyter connection attempt"))))

(defun emacs-jupyter-notebook--live-client-p ()
  "Return non-nil when the current buffer owns a live backend session.
W10: a live `--client' is the ONLY state that must block a fresh start or
reconnect — leaving it in place would leak a running local transport.
A dangling `--session-entry' or SSH `--tunnel-process' with NO client is
recoverable DEBRIS (see `--clientless-debris-p'), never a live session."
  (and emacs-jupyter-notebook--client t))

(defun emacs-jupyter-notebook--clientless-debris-p ()
  "Return non-nil when the buffer carries reapable connection debris.
W10 bug: a source buffer was observed live where the remote kernel and
its SSH tunnel were both alive and `--session-entry' was populated, but
`--client' was nil (the local backend session had dropped) and `--async-context'
sat at `:phase done'.  The old `--active-session-p' predicate classified
that state as an active session, so every non-destructive recovery command
refused it and the buffer was unrecoverable except by nuking the live
kernel.  Debris = NO live client, but a `--session-entry' and/or a live
`--tunnel-process' still lingering; it must be reaped, not defended."
  (and (not (emacs-jupyter-notebook--live-client-p))
       (or emacs-jupyter-notebook--session-entry
           (and (processp emacs-jupyter-notebook--tunnel-process)
                (process-live-p emacs-jupyter-notebook--tunnel-process)))))

(defun emacs-jupyter-notebook--active-session-p ()
  "Return non-nil when the current buffer owns a genuinely LIVE session.
W10: only a live `--client' counts.  A lingering `--session-entry' or SSH
tunnel with NO client is recoverable DEBRIS (see `--clientless-debris-p'
and `--ensure-clean-before-start', which reap it) — NOT an active session,
so it must not block the non-destructive recovery commands."
  (emacs-jupyter-notebook--live-client-p))

(defun emacs-jupyter-notebook--ensure-clean-before-start ()
  "Ensure the current buffer can start or reconnect a kernel without leaking one.
W10 recovery contract: only a genuinely LIVE session blocks — it must be
shut down (or superseded via `retry-fresh-kernel') first so a running
local transport is never leaked.  A client-less buffer that still
carries a dangling `--session-entry' and/or a live SSH tunnel is reapable
DEBRIS (the wedged state seen live: `--client' nil while entry and tunnel
linger); reap the LOCAL resources — disposing the stale tunnel and
clearing the buffer-local session state via `--release-local-resources' —
and continue so the fresh start / reconnect can proceed.  Per the binding
rule the remote kernel is NEVER shut down here; only LOCAL handles go."
  (when (emacs-jupyter-notebook--active-session-p)
    (user-error "A kernel is already active; shut it down or retry fresh first"))
  ;; W10: reap client-less debris so start/reconnect can recover a wedged
  ;; buffer.  `--release-local-resources' disposes the stale tunnel process
  ;; (and its stderr buffer), cancels timers, drops the async context, and
  ;; nils the client — WITHOUT touching the remote kernel.  It intentionally
  ;; preserves `--session-entry' (the durable reconnect surface on kill /
  ;; mode-disable); here we additionally clear the buffer-local entry because
  ;; its LOCAL tunnel is gone and the registry keeps the durable copy.
  (when (emacs-jupyter-notebook--clientless-debris-p)
    (emacs-jupyter-notebook--release-local-resources)
    (setq emacs-jupyter-notebook--session-entry nil))
  ;; W6.2: a brand-new operation clears the lingering ` EJN✗' state.
  (setq emacs-jupyter-notebook--async-last-error nil)
  (force-mode-line-update t))

(defun emacs-jupyter-notebook--async-add-callback (context callback)
  "Add CALLBACK to CONTEXT's callback chain."
  (let ((existing (plist-get context :callback)))
    (emacs-jupyter-notebook--async-put
     context :callback
     (if existing
         (lambda (ctx)
           (funcall existing ctx)
           (funcall callback ctx))
       callback))))

(defun emacs-jupyter-notebook--async-add-error-callback (context callback)
  "Add error CALLBACK to CONTEXT's error-callback chain."
  (let ((existing (plist-get context :error-callback)))
    (emacs-jupyter-notebook--async-put
     context :error-callback
     (if existing
         (lambda (ctx err)
           (funcall existing ctx err)
           (funcall callback ctx err))
       callback))))

(defun emacs-jupyter-notebook--async-buffer-live-p (context)
  "Return non-nil when CONTEXT's origin buffer is live."
  (buffer-live-p (plist-get context :origin-buffer)))

(defun emacs-jupyter-notebook--async-message (context format-string &rest args)
  "Report async progress using FORMAT-STRING and ARGS.
W6.6: every call also writes a structured entry into the global
`*emacs-jupyter-notebook log*' buffer, tagged with the originating
async-context phase (or `none' when the context is nil)."
  (let ((phase (or (plist-get context :phase) 'none)))
    (apply #'emacs-jupyter-notebook--log-append phase format-string args))
  (apply #'message (concat "emacs-jupyter-notebook: " format-string) args))

(defun emacs-jupyter-notebook--async-cancel-timer (context)
  "Cancel CONTEXT's timer if present."
  (when-let* ((timer (plist-get context :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (emacs-jupyter-notebook--async-put context :timer nil))

(defun emacs-jupyter-notebook--async-cancel-overall-timer (context)
  "Cancel CONTEXT's whole-attempt deadline timer, if present."
  (when-let* ((timer (plist-get context :overall-timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (emacs-jupyter-notebook--async-put context :overall-timer nil))

(defun emacs-jupyter-notebook--async-arm-overall-timeout (context)
  "Arm the whole-attempt deadline for CONTEXT and return CONTEXT."
  (let ((timeout emacs-jupyter-notebook-connection-attempt-timeout))
    (if (not (and (numberp timeout) (> timeout 0)))
        context
      (let ((timer
             (run-at-time
              timeout nil
              (lambda ()
                (when (emacs-jupyter-notebook--async-context-live-p context)
                  (emacs-jupyter-notebook--async-fail
                   (emacs-jupyter-notebook--async-put
                    context :error-kind 'attempt-timeout)
                   (format "Connection attempt timed out after %ss" timeout)))))))
        (emacs-jupyter-notebook--async-put context :overall-timer timer)))))

(defun emacs-jupyter-notebook--async-cancel-process-timeout (process)
  "Cancel PROCESS's EJN watchdog timer, if present."
  (when (processp process)
    (when-let* ((timer (process-get process 'emacs-jupyter-notebook-timeout-timer)))
      (when (timerp timer)
        (cancel-timer timer)))
    (process-put process 'emacs-jupyter-notebook-timeout-timer nil)))

(defun emacs-jupyter-notebook--async-arm-process-timeout (context process role &optional timeout)
  "Arm a bounded watchdog for PROCESS belonging to CONTEXT as ROLE.
TIMEOUT, when a positive number, overrides the default
`emacs-jupyter-notebook-ssh-process-timeout' — used for the launch process,
whose remote side may legitimately spend a long time in environment
initialization (Nix etc.) and is instead bounded by the overall attempt
deadline."
  (let ((timeout (or timeout emacs-jupyter-notebook-ssh-process-timeout)))
    (when (and (processp process)
               (process-live-p process)
               (numberp timeout)
               (> timeout 0))
      (process-put
       process 'emacs-jupyter-notebook-timeout-timer
       (run-at-time
        timeout nil
        (lambda ()
          (when (and (process-live-p process)
                     (emacs-jupyter-notebook--async-context-live-p context))
            (let ((detail (emacs-jupyter-notebook--process-output process)))
              (emacs-jupyter-notebook--async-delete-process process)
              (emacs-jupyter-notebook--async-fail
               (emacs-jupyter-notebook--async-put
                context :error-kind 'process-timeout)
               (format "%s timed out after %ss%s"
                       role timeout
                       (if (string-empty-p detail)
                           ""
                         (format ": %s" detail)))))))))))
  process)

(defun emacs-jupyter-notebook--async-delete-process (process)
  "Delete PROCESS and the buffers it carries.
Kills the process if it is still live, then disposes of both its stdout
`process-buffer' and the stderr buffer stashed under the
`emacs-jupyter-notebook-stderr-buffer' process property.  Without the second
disposer, every SSH launch/scp/tunnel process leaked a hidden \" *NAME stderr*\"
buffer per session (see ssh.el).

W13-M1: clear the sentinel BEFORE deleting so a deliberate teardown never
fires the process's death handler.  Otherwise deleting a tunnel whose
`--install-tunnel-sentinel' watcher is armed queues that sentinel, which
runs AFTER cleanup already reset state and re-sets `--tunnel-dead' t on a
buffer that has no session — wedging every later `send-cell' into a silent
no-op.  It also belt-and-suspenders the W12/A2 scp/launch resurrection: a
deleted attempt's sentinel simply never runs."
  (when (processp process)
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (when (process-live-p process)
      (set-process-sentinel process #'ignore)
      (delete-process process))
    (let ((stdout (process-buffer process))
          (stderr (process-get process 'emacs-jupyter-notebook-stderr-buffer)))
      (when (buffer-live-p stdout)
        (kill-buffer stdout))
      (when (buffer-live-p stderr)
        (kill-buffer stderr)))))

(defun emacs-jupyter-notebook--async-delete-file (file)
  "Delete FILE if it exists."
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun emacs-jupyter-notebook--cleanup-restart-staging (context)
  "Best-effort unlink CONTEXT's private remote restart staging artifact."
  (when-let* ((staging (plist-get context :restart-staging-file))
              (entry (plist-get context :entry))
              (connection-file (plist-get entry :remote-connection-file))
              (profile (plist-get context :profile)))
    (ignore-errors
      (emacs-jupyter-notebook-ssh-start-management-operation
       (format "emacs-jupyter-notebook-restart-cleanup-%s"
               (or (plist-get context :session-id) "kernel"))
       (emacs-jupyter-notebook-ssh-build-remote-remove-restart-staging
        profile staging connection-file)
       #'ignore #'ignore))))

(defun emacs-jupyter-notebook--cleanup-remote-entry (entry)
  "Start best-effort asynchronous cleanup for remote kernel ENTRY."
  (when (and (eq (plist-get entry :launch-kind) 'direct)
             (plist-get entry :remote-pid))
    (ignore-errors
      (emacs-jupyter-notebook-ssh-start-management-operation
       (format "emacs-jupyter-notebook-cleanup-%s"
               (or (plist-get entry :session-id) "kernel"))
       (emacs-jupyter-notebook-ssh-build-remote-cleanup
        (emacs-jupyter-notebook--entry-profile entry) entry)
       #'ignore #'ignore))))

(defun emacs-jupyter-notebook--enrich-ssh-error (error-data)
  "Return ERROR-DATA prefixed with a W4.3 SSH-error classification when applicable.
When ERROR-DATA is a string, the SSH-stderr classifier inspects it; any
non-`unknown' kind is surfaced as `<KIND>: <text>\\nHint: <actionable hint>'.
Non-string or unrecognized errors are returned verbatim."
  (if (stringp error-data)
      (let* ((classification (emacs-jupyter-notebook-ssh-classify-stderr error-data))
             (kind (plist-get classification :kind))
             (hint (plist-get classification :hint)))
        (if (eq kind 'unknown)
            error-data
          (format "%s: %s\nHint: %s"
                  (upcase (symbol-name kind))
                  error-data
                  hint)))
    error-data))

(defun emacs-jupyter-notebook--dispose-unverified-client (context)
  "Release the local Jupyter I/O of CONTEXT's abandoned `:client-unverified'.
A connect that fails, times out, or is superseded leaves its unverified
client — and the ZMQ ioloop subprocess behind it — referenced by the context.
emacs-jupyter reclaims that subprocess only through a GC finalizer, so the
reference must be dropped promptly instead of being retained for the whole
lifetime of the context (repeated failed recoveries would otherwise
accumulate ioloop subprocesses between garbage collections).  The client's
local I/O is released via `jupyter-disconnect' and the slot cleared; the
remote kernel is never touched — an unverified client is a conn-info
attachment that was never installed as the buffer's live client.  Mutates
CONTEXT in place and deliberately does NOT write it back to the buffer, so a
superseded context cannot be resurrected into the buffer's async slot."
  (when context
    (when-let* ((client (plist-get context :client-unverified)))
      (ignore-errors
        (emacs-jupyter-notebook-backend-close-local client #'ignore #'ignore)))
    (ignore-errors (plist-put context :client-unverified nil))))

(defun emacs-jupyter-notebook--async-fail (context error-data)
  "Move CONTEXT to error state with ERROR-DATA and clean up.

Releases only LOCAL resources: cancels the deadline timer, disposes the
launch/scp/tunnel processes (and their stderr buffers), disposes any
abandoned `:client-unverified', and removes the fetched :remote-copy.  Does
NOT terminate the remote kernel, even when `:owns-kernel' is set: the
binding rule forbids automatic remote-kernel cleanup from async failure
paths.  Does NOT delete `:local-file' either — once
`--async-connect-finalize' runs that same path becomes the registry entry's
`:local-connection-file' (the offline reconnect key), and this function is
also called from failure paths that may race with that promotion.  A small
temp-file leak is acceptable; loss of the reconnect key is not.

ERROR-DATA is passed through `--enrich-ssh-error' (W4.3) so the
user-visible message carries a kind label and an actionable hint when the
underlying stderr matches a known SSH failure pattern."
  (let ((error-data (emacs-jupyter-notebook--enrich-ssh-error error-data)))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'error))
    (setq context (emacs-jupyter-notebook--async-put context :error error-data))
    (setq context (emacs-jupyter-notebook--async-cancel-timer context))
    (setq context
          (emacs-jupyter-notebook--async-cancel-overall-timer context))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :launch-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :resolve-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :sidecar-process))
    (emacs-jupyter-notebook--async-delete-process
     (plist-get context :launch-probe-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :scp-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :tunnel-process))
    ;; W4.8: dispose the W4.4 PID-probe process too so its stdout/stderr
    ;; buffers do not leak when the probe itself fails the context.
    (emacs-jupyter-notebook--async-delete-process (plist-get context :probe-process))
    (emacs-jupyter-notebook--async-delete-process
     (plist-get context :busy-probe-process))
    (emacs-jupyter-notebook--async-delete-process (plist-get context :log-process))
    (emacs-jupyter-notebook--async-delete-process
     (plist-get context :restart-upload-process))
    (emacs-jupyter-notebook--async-delete-process
     (plist-get context :restart-publish-process))
    (emacs-jupyter-notebook--async-delete-process
     (plist-get context :restart-seed-read-process))
    (emacs-jupyter-notebook--cleanup-restart-staging context)
    (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
    (emacs-jupyter-notebook--async-delete-file (plist-get context :restart-seed))
    (emacs-jupyter-notebook--async-delete-file
     (plist-get context :restart-local-file))
    ;; Review fix: a failed connect must not retain its `:client-unverified'
    ;; (its ZMQ ioloop subprocess is otherwise held until the context is
    ;; released and GC'd).
    (emacs-jupyter-notebook--dispose-unverified-client context)
    ;; W6.2: record the error for the mode-line lighter.
    (when-let* ((buffer (plist-get context :origin-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq emacs-jupyter-notebook--async-last-error t)
          (force-mode-line-update t))))
    (if-let ((callback (plist-get context :error-callback)))
        (funcall callback context error-data)
      (display-warning 'emacs-jupyter-notebook
                       (format "%s" error-data)))
    context))

(defun emacs-jupyter-notebook--cancel-async-operation (context &optional reason)
  "Abort in-flight CONTEXT and clear the buffer-local async slot.
Shared by the interactive `cancel-operation' and the supersede branch of
`--ensure-no-async-operation'.

Then fails CONTEXT with REASON (default \"Operation cancelled\") — which
releases its local processes, timers, and temp files — and nils
`--async-context'.  Never dispatches a backend `shutdown',
`--cleanup-remote-entry', or mutates the registry: an admitted start remains
recoverable even when its launch outcome is ambiguous."
  ;; Mark cancellation before `--async-fail' invokes the reconnect policy;
  ;; otherwise an ordinary transient failure handler would immediately rearm.
  (setq context
        (emacs-jupyter-notebook--async-put context :cancelled t))
  (emacs-jupyter-notebook--async-fail context (or reason "Operation cancelled"))
  (setq emacs-jupyter-notebook--async-context nil))

(defun emacs-jupyter-notebook--async-process-failed-p (process)
  "Return non-nil when PROCESS exited unsuccessfully."
  (or (eq (process-status process) 'signal)
      (not (zerop (process-exit-status process)))))

(defun emacs-jupyter-notebook--kernelspec-bounded-string-p (value &optional limit)
  "Return non-nil when VALUE is a bounded UTF-8 string without NULs."
  (and (stringp value)
       (not (string-match-p (string 0) value))
       (<= (string-bytes value)
           (or limit emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes))))

(defun emacs-jupyter-notebook--resolved-connection-path-matches-p
    (connection-file requested-file)
  "Return non-nil when CONNECTION-FILE is the expanded REQUESTED-FILE.
Absolute requested paths must match byte-for-byte.  A `~/' request is expanded
by the remote login shell, so Emacs verifies its complete home-relative suffix."
  (and (emacs-jupyter-notebook--kernelspec-bounded-string-p connection-file)
       (file-name-absolute-p connection-file)
       (emacs-jupyter-notebook--kernelspec-bounded-string-p requested-file)
       (cond
        ((file-name-absolute-p requested-file)
         (equal connection-file requested-file))
        ((string-prefix-p "~/" requested-file)
         (string-suffix-p (substring requested-file 1) connection-file))
        (t nil))))

(defun emacs-jupyter-notebook--parse-resolved-kernelspec
    (output session-id expected-name requested-connection-file)
  "Strictly parse one bounded remote kernelspec resolver OUTPUT.
Return only launch data needed after resolution.  The transient environment is
present in the return value for immediate launch construction and must never
be copied to a registry entry.  REQUESTED-CONNECTION-FILE binds the response
to the deterministic path supplied to the resolver."
  (unless (and (stringp output)
               (<= (string-bytes output)
                   emacs-jupyter-notebook-ssh-kernelspec-max-bytes))
    (error "Kernelspec resolver output exceeds the limit"))
  (let* ((newline (string-match "\n" output))
         (marker (and newline (substring output 0 newline)))
         (expanded-request
          (and marker
               (string-match "\\`EJN_CONNECTION_FILE=\\(.+\\)\\'" marker)
               (match-string 1 marker)))
         (json-output (and newline (substring output (1+ newline))))
         (object
          (condition-case nil
              (progn
                ;; The native parser validates UTF-8 and rejects trailing data.
                ;; Re-read with string keys so hostile JSON cannot permanently
                ;; intern arbitrary field names in Emacs's global obarray; the
                ;; alist representation also preserves duplicate keys.
                (unless (hash-table-p
                         (json-parse-string
                          json-output :object-type 'hash-table
                          :array-type 'list :null-object nil
                          :false-object :false))
                  (error "Kernelspec resolver did not return a JSON object"))
                (let ((json-object-type 'alist)
                      (json-array-type 'list)
                      (json-key-type 'string)
                      (json-null nil)
                      (json-false :false))
                  (json-read-from-string json-output)))
            (error nil)))
         (kernelspecs (cdr (assoc "kernelspecs" object))))
    (unless (and (listp object)
                 (equal (mapcar #'car object) '("kernelspecs"))
                 (listp kernelspecs) (= (length kernelspecs) 1)
                 (stringp (caar kernelspecs)) (listp (cdar kernelspecs)))
      (error "Kernelspec resolver returned an invalid schema"))
    (let* ((name (caar kernelspecs))
           (entry (cdar kernelspecs))
           (resource (cdr (assoc "resource_dir" entry)))
           (spec (cdr (assoc "spec" entry)))
           (argv (and (listp spec) (cdr (assoc "argv" spec))))
           (env (and (listp spec) (cdr (assoc "env" spec))))
           (metadata (and (listp spec)
                          (cdr (assoc "metadata" spec))))
           (connection-file
            (and (listp metadata)
                 (cdr (assoc "ejn_connection_file" metadata))))
           (resolver-session
            (and (listp metadata)
                 (cdr (assoc "ejn_session_id" metadata))))
           (environment
            (and (listp env)
                 (mapcar (lambda (pair)
                           (and (consp pair) (stringp (car pair)) pair))
                         env))))
      (unless (and (equal name expected-name)
                   (emacs-jupyter-notebook--kernelspec-bounded-string-p name)
                   (cl-every (lambda (pair) (and (consp pair) (stringp (car pair)))) entry)
                   (cl-every (lambda (pair) (and (consp pair) (stringp (car pair)))) spec)
                   (cl-every (lambda (pair) (and (consp pair) (stringp (car pair)))) metadata)
                   (equal (sort (mapcar #'car entry) #'string<)
                          '("resource_dir" "spec"))
                   (equal (sort (mapcar #'car spec) #'string<)
                          '("argv" "env" "metadata"))
                   (equal (sort (mapcar #'car metadata) #'string<)
                          '("ejn_connection_file" "ejn_session_id"))
                   (emacs-jupyter-notebook--kernelspec-bounded-string-p resource)
                   (file-name-absolute-p resource)
                   (emacs-jupyter-notebook--resolved-connection-path-matches-p
                    expanded-request requested-connection-file)
                   (equal connection-file expanded-request)
                   (equal resolver-session session-id)
                   (equal (file-name-nondirectory connection-file)
                          (format "kernel-%s.json" session-id))
                   (listp argv)
                   (<= 1 (length argv)
                       emacs-jupyter-notebook-ssh-kernelspec-max-argv)
                   (cl-every #'emacs-jupyter-notebook--kernelspec-bounded-string-p argv)
                   (listp env)
                   (<= (length env) emacs-jupyter-notebook-ssh-kernelspec-max-env)
                   (cl-every #'identity environment)
                   (cl-every
                    (lambda (pair)
                      (and (consp pair) (stringp (car pair)) (stringp (cdr pair))
                           (emacs-jupyter-notebook--kernelspec-bounded-string-p (car pair))
                           (emacs-jupyter-notebook--kernelspec-bounded-string-p (cdr pair))
                           (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" (car pair))))
                    environment)
                   (= (length environment)
                      (length (delete-dups (mapcar #'car (copy-sequence environment)))))
                   (<= (cl-loop for pair in environment
                                sum (+ (string-bytes (car pair))
                                       (string-bytes (cdr pair))))
                       emacs-jupyter-notebook-ssh-kernelspec-max-env-bytes))
        (error "Kernelspec resolver returned an invalid schema"))
      (unless (and (file-name-absolute-p (car argv))
                   (not (cl-some (lambda (token)
                                   (or (string-empty-p token)
                                       (string-match-p "[{}]" token)))
                                 argv))
                   (<= (apply #'+ (mapcar #'string-bytes argv))
                       emacs-jupyter-notebook-ssh-kernelspec-max-argv-bytes))
        (error "Kernelspec resolver returned an invalid argv"))
      (let* ((connection-index
              (cl-position-if
               (lambda (token)
                 (string-match-p (regexp-quote connection-file) token))
               argv))
             (connection-token (and connection-index
                                    (nth connection-index argv)))
             (connection-tokens
              (if (and connection-index (> connection-index 0)
                       (equal connection-token connection-file)
                       (string-prefix-p "-" (nth (1- connection-index) argv)))
                  (list (nth (1- connection-index) argv) connection-token)
                (and connection-token (list connection-token))))
             (connection-count
              (cl-loop for token in argv sum
                       (let ((start 0) (count 0) (regexp (regexp-quote connection-file)))
                         (while (string-match regexp token start)
                           (setq count (1+ count)
                                 start (match-end 0)))
                         count))))
        (unless (and connection-tokens (= connection-count 1))
          (error "Kernelspec resolver did not return one exact connection-file token"))
        (list :resource-dir resource :argv argv :env environment
              :connection-file connection-file
              :connection-tokens connection-tokens)))))

(defun emacs-jupyter-notebook--parse-pid-sidecar (output session-id)
  "Return the PID in private sidecar OUTPUT only when its session matches."
  (when (and (stringp output)
             (<= (string-bytes output)
                 emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
             (stringp session-id)
             (string-match
              (concat "\\`EJN_PID=\\([0-9]+\\)\nEJN_SESSION="
                      (regexp-quote session-id) "\n?\\'")
              output))
    (let ((pid (string-to-number (match-string 1 output))))
      (and (> pid 0) (<= pid 2147483647) pid))))

(defun emacs-jupyter-notebook--async-resolve-kernelspec (context)
  "Resolve CONTEXT's selected kernelspec without creating durable state."
  (let* ((resolution (plist-get context :resolution))
         (session-id (plist-get context :session-id)))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'resolve))
    (condition-case err
        (let ((process
               (emacs-jupyter-notebook-ssh-start-bounded-process
                (format "emacs-jupyter-notebook-resolve-%s" session-id)
                (plist-get resolution :argv)
                emacs-jupyter-notebook-ssh-kernelspec-max-bytes
                (lambda (process _event)
                  (emacs-jupyter-notebook--async-resolve-sentinel context process)))))
          (setq context (emacs-jupyter-notebook--async-put context :resolve-process process))
          (emacs-jupyter-notebook--async-arm-process-timeout
           context process "Kernelspec resolution")
          (emacs-jupyter-notebook--async-message context "resolving remote kernelspec %s"
                                                  (plist-get (plist-get context :entry) :kernelspec))
          context)
      (error
       (emacs-jupyter-notebook--async-fail
        context (format "Could not start kernelspec resolver: %s"
                        (error-message-string err)))))))

(defun emacs-jupyter-notebook--async-resolve-sentinel (context process)
  "Validate resolver output and move CONTEXT to the direct launch phase."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (let ((output (emacs-jupyter-notebook--process-stdout process))
          (diagnostic (emacs-jupyter-notebook--process-output process))
          (failed (emacs-jupyter-notebook--async-process-failed-p process)))
      (emacs-jupyter-notebook--async-delete-process process)
      (setq context (emacs-jupyter-notebook--async-put context :resolve-process nil))
      (if failed
          (emacs-jupyter-notebook--async-fail
           context (format "Kernelspec resolver failed: %s" diagnostic))
        (condition-case err
            (let* ((entry (plist-get context :entry))
                   (resolved (emacs-jupyter-notebook--parse-resolved-kernelspec
                              output (plist-get context :session-id)
                              (plist-get entry :kernelspec)
                              (plist-get (plist-get context :resolution)
                                         :connection-file)))
                   (launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                            (plist-get context :profile)
                            (plist-get context :session-id) resolved)))
              (setq entry (plist-put entry :remote-connection-file
                                     (plist-get launch :connection-file)))
              (setq entry (plist-put entry :remote-pid-sidecar
                                     (plist-get launch :sidecar-file)))
              (setq entry (plist-put entry :connection-file-tokens
                                     (plist-get launch :connection-tokens)))
              (setq context (emacs-jupyter-notebook--async-put context :entry entry))
              (setq context (emacs-jupyter-notebook--async-put context :launch launch))
              (if (plist-get context :restart-preflight)
                  (emacs-jupyter-notebook--restart-preflight-ready context)
                (emacs-jupyter-notebook--async-launch context)))
          (error
           (emacs-jupyter-notebook--async-fail
            context (format "Invalid resolved kernelspec: %s"
                            (error-message-string err)))))))))

(defun emacs-jupyter-notebook--async-launch (context)
  "Launch CONTEXT's resolved kernel after recording a durable provisional entry."
  (let* ((launch (plist-get context :launch))
         (session-id (plist-get context :session-id))
         (entry (copy-sequence (plist-get context :entry))))
    (unless (plist-get context :launch-admitted)
      ;; This save is deliberately before process creation.  A local spawn
      ;; error or cancellation after this point cannot prove the remote side
      ;; did not receive the request, so only explicit pruning may remove it.
      (setq entry (plist-put entry :launch-kind 'direct))
      (setq entry (plist-put entry :provisional t))
      (setq entry (plist-put entry :remote-pid nil))
      (emacs-jupyter-notebook-registry-save-entry entry)
      (setq context (emacs-jupyter-notebook--async-put context :entry entry))
      (setq context (emacs-jupyter-notebook--async-put context :launch-admitted t)))
    (setq context (emacs-jupyter-notebook--async-put context :phase 'launch))
    (condition-case err
        (let ((process
               (emacs-jupyter-notebook-ssh-start-bounded-process
                (format "emacs-jupyter-notebook-launch-%s" session-id)
                (plist-get launch :argv)
                4096
                (lambda (process _event)
                  (emacs-jupyter-notebook--async-launch-sentinel context process)))))
          (setq context (emacs-jupyter-notebook--async-put context :launch-process process))
          (setq context
                (emacs-jupyter-notebook--async-put
                 context :launch-process-started t))
          (emacs-jupyter-notebook--async-arm-process-timeout
           context process "Remote kernel launch"
           emacs-jupyter-notebook-connection-attempt-timeout)
          (emacs-jupyter-notebook--async-message context "starting remote kernel %s" session-id)
          context)
      (error
       (emacs-jupyter-notebook--async-fail
       context (format "Could not start remote kernel launch process: %s"
                        (error-message-string err)))))))

(defun emacs-jupyter-notebook--launch-admitted-output-p (output)
  "Return non-nil only for one complete launch-admission marker in OUTPUT."
  (and (stringp output)
       (<= (string-bytes output)
           emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes)
       (equal (string-trim output) "EJN_LAUNCH_ADMITTED")))

(defun emacs-jupyter-notebook--async-launch-sentinel (context process)
  "Advance admitted CONTEXT from launcher acknowledgement to sidecar recovery."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (let ((output (emacs-jupyter-notebook--process-stdout process))
          (diagnostic (emacs-jupyter-notebook--process-output process))
          (failed (emacs-jupyter-notebook--async-process-failed-p process)))
      (emacs-jupyter-notebook--async-delete-process process)
      (setq context (emacs-jupyter-notebook--async-put context :launch-process nil))
      (if (or failed
              (not (emacs-jupyter-notebook--launch-admitted-output-p output)))
          (emacs-jupyter-notebook--async-fail
           context (format "Remote kernel launch outcome is unknown: %s"
                           diagnostic))
        (emacs-jupyter-notebook--async-read-pid-sidecar context)))))

(defun emacs-jupyter-notebook--async-read-pid-sidecar (context)
  "Read CONTEXT's private PID sidecar, retrying only while the attempt lives."
  (when (emacs-jupyter-notebook--async-context-live-p context)
    (let ((attempt (1+ (or (plist-get context :sidecar-attempt) 0))))
      (if (> attempt emacs-jupyter-notebook-connection-retrieve-attempts)
          (emacs-jupyter-notebook--async-fail
           context "Remote launch was admitted but its PID sidecar was unavailable")
        (let ((entry (plist-get context :entry)))
        (setq context (emacs-jupyter-notebook--async-put context :phase 'sidecar))
        (setq context (emacs-jupyter-notebook--async-put context :sidecar-attempt attempt))
        (condition-case err
            (let ((process
                   (emacs-jupyter-notebook-ssh-start-bounded-process
                    (format "emacs-jupyter-notebook-sidecar-%s"
                            (plist-get context :session-id))
                    (emacs-jupyter-notebook-ssh-build-remote-read-pid-sidecar
                     (plist-get context :profile) (plist-get entry :remote-pid-sidecar))
                    emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes
                    (lambda (process _event)
                      (emacs-jupyter-notebook--async-sidecar-sentinel context process)))))
              (setq context (emacs-jupyter-notebook--async-put context :sidecar-process process))
              (emacs-jupyter-notebook--async-arm-process-timeout
               context process "Remote PID sidecar read")
              context)
            (error
             (emacs-jupyter-notebook--async-fail
              context (format "Could not read remote PID sidecar: %s"
                              (error-message-string err))))))))))

(defun emacs-jupyter-notebook--async-sidecar-sentinel (context process)
  "Validate a sidecar reply before its PID can be identity-probed."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (let ((failed (emacs-jupyter-notebook--async-process-failed-p process))
          (pid (and (not (emacs-jupyter-notebook--async-process-failed-p process))
                    (emacs-jupyter-notebook--parse-pid-sidecar
                    (emacs-jupyter-notebook--process-stdout process)
                     (plist-get context :session-id)))))
      (emacs-jupyter-notebook--async-delete-process process)
      (setq context (emacs-jupyter-notebook--async-put context :sidecar-process nil))
      (if (and (not failed) pid)
          (emacs-jupyter-notebook--async-verify-launch-pid context pid)
        (let ((timer (run-at-time emacs-jupyter-notebook-connection-retrieve-delay nil
                                  #'emacs-jupyter-notebook--async-read-pid-sidecar context)))
          (emacs-jupyter-notebook--async-put context :timer timer))))))

(defun emacs-jupyter-notebook--async-verify-launch-pid (context pid)
  "Promote CONTEXT's PID only after exact command-line identity verification."
  (condition-case err
      (let* ((entry (plist-get context :entry))
             (process
              (emacs-jupyter-notebook-ssh-start-bounded-process
               (format "emacs-jupyter-notebook-launch-probe-%s" (plist-get context :session-id))
               (emacs-jupyter-notebook-ssh-build-pid-alive
                (plist-get context :profile) pid (plist-get entry :connection-file-tokens))
               emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes
               (lambda (process _event)
                 (emacs-jupyter-notebook--async-launch-pid-sentinel context pid process)))))
        (setq context (emacs-jupyter-notebook--async-put context :phase 'launch-probe))
        (setq context (emacs-jupyter-notebook--async-put context :launch-probe-process process))
        (emacs-jupyter-notebook--async-arm-process-timeout
         context process "Launched-kernel identity probe")
        context)
    (error
     (emacs-jupyter-notebook--async-fail
      context (format "Could not start launched-kernel identity probe: %s"
                      (error-message-string err))))))

(defun emacs-jupyter-notebook--async-launch-pid-sentinel (context pid process)
  "Use only an exact PID identity match to promote an admitted launch."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (let ((kind (emacs-jupyter-notebook--classify-pid-probe
                 (emacs-jupyter-notebook--process-stdout process))))
      (emacs-jupyter-notebook--async-delete-process process)
      (setq context (emacs-jupyter-notebook--async-put context :launch-probe-process nil))
      (if (eq kind 'alive)
          (let ((entry (copy-sequence (plist-get context :entry))))
            (if (plist-get context :restart-epoch)
                ;; A restart has already destroyed the old kernel.  Do not
                ;; replace its durable PID merely because a new process has
                ;; matching argv: only fresh helper kernel-info verification
                ;; may promote the replacement.
                (progn
                  (setq context (emacs-jupyter-notebook--async-put
                                 context :candidate-remote-pid pid))
                  ;; The seed was built from the durable local connection
                  ;; file before shutdown and published before launch.  It is
                  ;; authoritative here; fetching it back would reintroduce a
                  ;; race with a newly launched kernel and leaks an extra SSH
                  ;; operation into the restart critical path.
                  (condition-case err
                      (emacs-jupyter-notebook--async-tunnel context)
                    (error
                     (emacs-jupyter-notebook--async-fail
                      context
                      (format "Could not start replacement tunnel: %s"
                              (error-message-string err))))))
              (setq entry (plist-put entry :remote-pid pid))
              (condition-case err
                  (progn
                    (emacs-jupyter-notebook-registry-save-entry entry)
                    (setq context
                          (emacs-jupyter-notebook--async-put context :entry entry))
                    (emacs-jupyter-notebook--async-retrieve context))
                (error
                 ;; Keep the earlier provisional entry unchanged.  Its private
                 ;; sidecar is enough for a later reconnect to recover the PID.
                 (emacs-jupyter-notebook--async-fail
                  context
                  (format "Could not persist verified remote kernel PID: %s"
                          (error-message-string err)))))))
        (emacs-jupyter-notebook--async-fail
         context (format "Remote launch PID identity was not confirmed (%s)"
                         kind))))))

(defun emacs-jupyter-notebook--async-retrieve (context)
  "Begin asynchronous connection-file retrieval for CONTEXT."
  (unless (plist-get context :remote-copy)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :remote-copy
           (make-temp-file "emacs-jupyter-notebook-remote-" nil ".json"))))
  (unless (plist-get context :local-file)
    (setq context
          (emacs-jupyter-notebook--async-put
           context :local-file
           (make-temp-file "emacs-jupyter-notebook-local-" nil ".json"))))
  (setq context (emacs-jupyter-notebook--async-put context :phase 'retrieve))
  (emacs-jupyter-notebook--async-retrieve-attempt context))

(defun emacs-jupyter-notebook--async-retrieve-timeout (context &optional scp-reason)
  "Fail CONTEXT after retrieval exhaustion, enriched with the remote launch log.
SCP-REASON, when given, is the last retrieve error (e.g. \"SCP failed: …\").

A8: the connection file never appeared, which almost always means the
remote kernel process failed to start (`jupyter' not on the non-interactive
SSH PATH, a bad kernelspec, a `docker run' TTY/mount/network misstep, …).
That cause lives ONLY in the remote launch log, so fetch its tail
best-effort and surface it in the failure message instead of leaving the
user to SSH in and read the log by hand.  The fetch is asynchronous and
guarded by `--async-context-live-p' so a cancel/supersede mid-fetch is a
no-op; if the log is unavailable the base timeout message is still raised."
  (let* ((entry (plist-get context :entry))
         (connection-file (plist-get entry :remote-connection-file))
         (base (concat "Timed out retrieving the remote Jupyter connection "
                       "file; the remote kernel likely failed to start"))
         (header (if scp-reason (format "%s.\nLast retrieve error: %s" base scp-reason)
                   (concat base ".")))
         (finish
          (lambda (log-tail)
            (when (emacs-jupyter-notebook--async-context-live-p context)
              (emacs-jupyter-notebook--async-fail
               context
               (if log-tail
                   (format "%s\nRemote launch log (tail):\n%s" header log-tail)
                 (concat header
                         "\n(Remote launch log empty or unavailable — check"
                         " the selected remote kernelspec.)")))))))
    (if (not connection-file)
        (funcall finish nil)
      (condition-case nil
          (let ((process
                 (emacs-jupyter-notebook-ssh-start-bounded-process
                  (format "emacs-jupyter-notebook-launchlog-%s"
                          (or (plist-get context :session-id) "kernel"))
                  (emacs-jupyter-notebook-ssh-build-remote-cat-log
                   (plist-get context :profile) connection-file)
                  (emacs-jupyter-notebook-ssh--management-output-limit)
                  (lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (emacs-jupyter-notebook--async-cancel-process-timeout proc)
                      (let ((out (emacs-jupyter-notebook--process-output proc)))
                        (emacs-jupyter-notebook--async-delete-process proc)
                        (funcall finish
                                 (emacs-jupyter-notebook--last-lines out 30))))))))
            (setq context
                  (emacs-jupyter-notebook--async-put
                   context :log-process process))
            (emacs-jupyter-notebook--async-arm-process-timeout
             context process "Remote launch-log retrieval"))
        (error (funcall finish nil))))))

(defun emacs-jupyter-notebook--async-retrieve-attempt (context)
  "Start one asynchronous SCP attempt for CONTEXT."
  (let ((attempt (1+ (or (plist-get context :scp-attempt) 0))))
    (if (> attempt emacs-jupyter-notebook-connection-retrieve-attempts)
        (emacs-jupyter-notebook--async-retrieve-timeout context)
      (let* ((entry (plist-get context :entry))
             (argv (emacs-jupyter-notebook-ssh-scp-from-command
                    (plist-get context :profile)
                    (plist-get entry :remote-connection-file)
                    (plist-get context :remote-copy)))
             process)
        ;; Dispose the completed prior attempt before replacing the context
        ;; slot.  Otherwise every retry retains its stdout/stderr buffers.
        (emacs-jupyter-notebook--async-delete-process
         (plist-get context :scp-process))
        (setq context
              (emacs-jupyter-notebook--async-put context :scp-process nil))
        (emacs-jupyter-notebook--async-delete-file (plist-get context :remote-copy))
        (setq context (emacs-jupyter-notebook--async-put context :scp-attempt attempt))
        (condition-case err
            (progn
              (setq process
                    (emacs-jupyter-notebook-ssh-start-bounded-process
                     (format "emacs-jupyter-notebook-scp-%s"
                             (plist-get context :session-id))
                     argv emacs-jupyter-notebook-ssh-kernelspec-max-bytes
                     (lambda (process _event)
                       (emacs-jupyter-notebook--async-scp-sentinel
                        context process))))
              (setq context
                    (emacs-jupyter-notebook--async-put
                     context :scp-process process))
              (emacs-jupyter-notebook--async-arm-process-timeout
               context process "Connection-file retrieval")
              (emacs-jupyter-notebook--async-message
               context "retrieving connection file, attempt %d" attempt)
              context)
          (error
           (emacs-jupyter-notebook--async-fail
            context
            (format "Could not start connection-file retrieval: %s"
                    (error-message-string err)))))))))

(defun emacs-jupyter-notebook--async-retrieve-retry (context reason)
  "Schedule another connection-file retrieval for CONTEXT because of REASON.
On exhaustion the failure is routed through `--async-retrieve-timeout' so
the remote launch log is fetched and surfaced (A8): the connection file
never arriving almost always means the kernel failed to launch, and the
reason lives in that log, not in the SCP-level REASON."
  (if (>= (or (plist-get context :scp-attempt) 0)
          emacs-jupyter-notebook-connection-retrieve-attempts)
      (emacs-jupyter-notebook--async-retrieve-timeout context reason)
    (let ((timer (run-at-time
                  emacs-jupyter-notebook-connection-retrieve-delay nil
                  #'emacs-jupyter-notebook--async-retrieve-attempt context)))
      (emacs-jupyter-notebook--async-put context :timer timer))))

(defun emacs-jupyter-notebook--async-scp-sentinel (context process)
  "Advance CONTEXT after SCP PROCESS exits.
A2: no-op when CONTEXT is no longer the buffer's active attempt.  Without
this gate, cancelling/superseding an attempt (W12) — which deletes its SCP
process — makes the deleted process's sentinel fire, take the retry path,
and `--async-put' the dead context back into the buffer, resurrecting it and
clobbering any newer attempt while re-issuing SCP against a killed kernel."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (cond
     ((emacs-jupyter-notebook--async-process-failed-p process)
      (emacs-jupyter-notebook--async-retrieve-retry
       context (format "SCP failed: %s"
                       (emacs-jupyter-notebook--process-output process))))
     (t
      (condition-case err
          (let* ((connection
                  (emacs-jupyter-notebook-connection-read-file
                   (plist-get context :remote-copy)))
                 (remote-ports
                  (progn
                    (unless (emacs-jupyter-notebook-connection-valid-p connection)
                      (error "Remote Jupyter connection file has invalid metadata"))
                    (emacs-jupyter-notebook-connection-ports connection))))
            (emacs-jupyter-notebook--async-delete-file
             (plist-get context :remote-copy))
            (setq context (emacs-jupyter-notebook--async-put
                           context :connection connection))
            (setq context (emacs-jupyter-notebook--async-put
                           context :remote-ports remote-ports))
            (emacs-jupyter-notebook--async-tunnel context))
        (error
         (emacs-jupyter-notebook--async-retrieve-retry
          context (error-message-string err))))))))

(defun emacs-jupyter-notebook--async-tunnel (context)
  "Start local SSH tunnels for CONTEXT."
  (let* ((connection (plist-get context :connection))
         (remote-ports (plist-get context :remote-ports))
         (local-ports (emacs-jupyter-notebook-connection-allocate-local-ports))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports
                     connection local-ports)))
    ;; Write the local reconnect key before creating a process.  If the write
    ;; fails there is no tunnel to leak; after process creation the context
    ;; owns it immediately and ordinary async failure can dispose it.
    (emacs-jupyter-notebook-connection-write-file rewritten (plist-get context :local-file))
    (let ((tunnel (emacs-jupyter-notebook--start-tunnel
                   (plist-get context :profile)
                   remote-ports local-ports
                   (plist-get context :session-id))))
      (setq context (emacs-jupyter-notebook--async-put context :tunnel-process tunnel))
      (setq context (emacs-jupyter-notebook--async-put context :phase 'tunnel))
      (setq context (emacs-jupyter-notebook--async-put context :local-ports local-ports))
      (when (emacs-jupyter-notebook--async-buffer-live-p context)
        (with-current-buffer (plist-get context :origin-buffer)
          (emacs-jupyter-notebook--install-tunnel-sentinel tunnel (current-buffer))))
      (setq context (emacs-jupyter-notebook--async-put
                     context :deadline
                     (+ (float-time) emacs-jupyter-notebook-tunnel-wait-timeout)))
      (emacs-jupyter-notebook--async-message context "waiting for SSH tunnel ports")
      (emacs-jupyter-notebook--async-wait-tunnel-tick context))))

(defun emacs-jupyter-notebook--async-wait-tunnel-tick (context)
  "Check tunnel readiness for CONTEXT and reschedule if needed."
  (when (eq (plist-get context :phase) 'tunnel)
    (let* ((tunnel (plist-get context :tunnel-process))
           (local-ports (plist-get context :local-ports))
           (pending
            (cl-remove-if
             (lambda (key)
               (emacs-jupyter-notebook--local-port-open-p
                (plist-get local-ports key)))
             emacs-jupyter-notebook-connection-port-keys)))
      (cond
       ((not (process-live-p tunnel))
        (emacs-jupyter-notebook--async-fail
         context "Jupyter SSH tunnel exited before ports were ready"))
       ((null pending)
        (emacs-jupyter-notebook--async-connect context))
       ((>= (float-time) (plist-get context :deadline))
        (emacs-jupyter-notebook--async-fail
         context
         (format "Timed out waiting for Jupyter SSH tunnel ports: %s"
                 (mapconcat #'symbol-name pending ", "))))
       (t
        (let ((timer (run-at-time
                      emacs-jupyter-notebook-tunnel-wait-delay nil
                      #'emacs-jupyter-notebook--async-wait-tunnel-tick context)))
          (emacs-jupyter-notebook--async-put context :timer timer)))))))

(defun emacs-jupyter-notebook--async-connect-finalize (context buffer entry local-ports local-file client &optional busy)
  "Finalize the async connect for CONTEXT in BUFFER with CLIENT.
Returns non-nil when it acted (guards passed), nil when it declined.

W13-H3: guard on CONTEXT IDENTITY, not merely the buffer's current phase.
The bounded verification callback can arrive after busy arbitration, so a
superseded attempt's finalize can still arrive.  Without the identity check it
would act on whatever context now occupies the buffer — installing a stale
client on, or `--async-fail'-ing, a HEALTHY newer attempt that happens to also
be at phase `connect'.  The check makes a stale finalize a no-op.

W15-B: when BUSY is non-nil the kernel's process was PID-probe-confirmed
alive but its shell channel is silent (a long-running cell — think an
overnight training loop).  Connect anyway: install the client, mark
`--kernel-status' busy (which suspends the W4.5 heartbeat per W15-A), and
tell the user.  Sends queue on the shell channel and run when the cell
finishes.  The readiness probe is finite: before its expiry a correlated reply
can notify `--connect-verified-late'; after expiry later heartbeat, EI5, or
user traffic establishes responsiveness without retaining that request."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eq emacs-jupyter-notebook--async-context context)
                 (eq (plist-get context :phase) 'connect))
        (emacs-jupyter-notebook--async-cancel-timer
         emacs-jupyter-notebook--async-context)
        (emacs-jupyter-notebook--async-cancel-overall-timer
         emacs-jupyter-notebook--async-context)
        (if (not client)
            (progn
              (emacs-jupyter-notebook--async-fail
               emacs-jupyter-notebook--async-context
               "Kernel did not respond to kernel_info_request")
              t)
          (let ((old-local-file
                 (plist-get (plist-get context :entry)
                            :local-connection-file))
                persisted)
            (condition-case err
                (progn
                  ;; Never mutate the provisional entry owned by CONTEXT before
                  ;; the normalized replacement is durably saved.  This whole
                  ;; block is guarded because connection validation happens
                  ;; after connect timers have been cancelled.
                  (setq entry (copy-sequence entry))
                  (setq entry (plist-put entry :tunnel-ports local-ports))
                  (unless (emacs-jupyter-notebook-connection-valid-ports-p
                           (plist-get context :remote-ports))
                    (error "Remote Jupyter connection file has invalid channel ports"))
                  (setq entry (plist-put entry :remote-ports
                                         (copy-sequence (plist-get context :remote-ports))))
                  (setq entry (plist-put entry :local-connection-file local-file))
                  (when-let ((candidate (plist-get context :candidate-remote-pid)))
                    (setq entry (plist-put entry :remote-pid candidate)))
                  (setq entry (plist-put entry :provisional nil))
                  ;; Durable truth is committed before CLIENT becomes usable in
                  ;; the buffer.  A write failure therefore closes only the
                  ;; unverified local attachment and leaves the prior
                  ;; provisional registry entry available for recovery.
                  (emacs-jupyter-notebook-registry-save-entry entry)
                  (setq persisted t)
                  (setq context
                        (emacs-jupyter-notebook--async-put context :entry entry))
                  (setq emacs-jupyter-notebook--session-entry entry)
                  (when (and (plist-get context :restart-epoch)
                             (plist-get context :restart-local-file))
                    (unless (equal old-local-file local-file)
                      (emacs-jupyter-notebook--async-delete-file old-local-file))
                    (setq context (emacs-jupyter-notebook--async-put
                                   context :restart-local-file nil)))
                  ;; The adapter only learns this generic state after durable
                  ;; persistence, before assigning the current local client.
                  ;; It must not infer adoption from buffer-local core state.
                  (emacs-jupyter-notebook-backend-session-mark-installed client)
                  (setq emacs-jupyter-notebook--client client)
                  (setq emacs-jupyter-notebook--tunnel-dead nil)
                  ;; W19: the transport is restored — reset the auto-reconnect
                  ;; backoff so the NEXT drop starts from the initial delay.
                  (emacs-jupyter-notebook--cancel-auto-reconnect)
                  (setq emacs-jupyter-notebook--reconnect-attempt 0)
                  (setq emacs-jupyter-notebook--kernel-status
			(if busy 'busy nil))
                  ;; EI5: both adapters now implement bounded kernel-info.
                  ;; The helper process can remain alive while its Jupyter
                  ;; channels are dead, so it needs the same core heartbeat
                  ;; and existing tunnel-dead/retry path as the legacy client.
                  (emacs-jupyter-notebook--heartbeat-start)
                  ;; Restart opened its own gate before the irreversible old
                  ;; shutdown.  It owns exactly one setup sequence after this
                  ;; already-verified replacement attach.
                  (if-let ((restart-epoch (plist-get context :restart-epoch)))
                      (emacs-jupyter-notebook--execution-restart-start-setup
                       client restart-epoch)
                    (emacs-jupyter-notebook--execution-start-setup client))
                  (let ((ctx emacs-jupyter-notebook--async-context))
                    (setq ctx
                          (emacs-jupyter-notebook--async-put ctx :entry entry))
                    (setq ctx
                          (emacs-jupyter-notebook--async-put ctx :phase 'done))
                    (if busy
			(emacs-jupyter-notebook--async-message
			 ctx (concat "connected to BUSY remote kernel %s — a cell is "
                                     "still executing; sends will queue and run when "
                                     "it finishes (interrupt with "
                                     "M-x emacs-jupyter-notebook-interrupt-kernel)")
			 (plist-get ctx :session-id))
                      (emacs-jupyter-notebook--async-message
                       ctx "connected to remote Jupyter kernel %s"
                       (plist-get ctx :session-id)))
                    (let ((cb (plist-get ctx :callback)))
                      (when cb
			;; The transport is committed and CONTEXT is terminal.
			;; Consumer code cannot retroactively turn that success
			;; into local teardown by throwing from its callback.
			(condition-case callback-error
                            (funcall cb ctx)
                          (error
                           (emacs-jupyter-notebook--log-append
                            'connect "success callback failed: %s"
                            (error-message-string callback-error))))))
                    t))
              (error
               ;; Once installation crossed the durable boundary, a later
               ;; local setup error must not leave a closed session looking
               ;; live in the source buffer.  `--async-fail' closes the same
               ;; session via CONTEXT's `:client-unverified' slot; clear only
               ;; this exact client so a superseding attachment cannot be
               ;; disturbed.
               (when (eq emacs-jupyter-notebook--client client)
                 (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
                 (setq emacs-jupyter-notebook--client nil
                       emacs-jupyter-notebook--kernel-status nil
                       emacs-jupyter-notebook--tunnel-dead t))
               (emacs-jupyter-notebook--async-fail
                context
                (format (if persisted
                            "Could not finalize connected kernel session: %s"
                          "Could not persist connected kernel session: %s")
                        (error-message-string err)))
               t))))))))

(defun emacs-jupyter-notebook--connect-verified-late (buffer client)
  "Record that CLIENT answered kernel-info after a busy finalize in BUFFER.
W15-B: when a reconnect finalized as connected-BUSY, the verification
kernel-info may still reply before its finite helper deadline.  Such a reply
proves the kernel is responsive again: flip `--kernel-status' to idle so the
W4.5 heartbeat resumes probing.  After expiry this function is not invoked;
later heartbeat, EI5, or user traffic establishes responsiveness instead.
No-op unless CLIENT is still the
buffer's current client and the status is still `busy' (a newer iopub
status update owns the state otherwise)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eq emacs-jupyter-notebook--client client)
                 (eq emacs-jupyter-notebook--kernel-status 'busy))
        (setq emacs-jupyter-notebook--kernel-status 'idle)
        (force-mode-line-update t)
        (emacs-jupyter-notebook--log-append
         'connect "kernel became responsive (queued kernel-info answered)")))))

(defun emacs-jupyter-notebook--async-connect-timeout (context buffer)
  "Arbitrate CONTEXT in BUFFER after its connect verification timed out.
W13-H3: identity-guarded so a superseded attempt's timeout timer cannot
fail a healthy newer attempt sitting at phase `connect'.

W15-B: no `kernel_info_reply' within the window no longer means dead — a
BUSY kernel (an overnight training cell) queues shell messages and cannot
answer until the cell finishes, yet is exactly the kernel the user wants
to reconnect to.  Arbitrate with a remote PID probe:
- Fresh start (`:owns-kernel'): a just-launched kernel is never
  legitimately busy — hard-fail as before.
- Reconnect with a recorded PID: probe it.  Alive → finalize as
  connected-BUSY.  Answered-dead → fail with the kernel-dead message.
  Host unreachable → fail with a reachability message that never advises
  a fresh start.
- Reconnect without a PID (should not happen post-W4.2) → hard-fail."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eq emacs-jupyter-notebook--async-context context)
                 (eq (plist-get context :phase) 'connect))
        (let* ((entry (plist-get context :entry))
               (pid (and entry (plist-get entry :remote-pid)))
               (client (plist-get context :client-unverified)))
          (if (or (plist-get context :owns-kernel)
                  (not pid)
                  (not (emacs-jupyter-notebook-backend-session-attached-p client)))
              (emacs-jupyter-notebook--async-fail
               emacs-jupyter-notebook--async-context
               "Timed out waiting for kernel_info_reply")
            (emacs-jupyter-notebook--async-message
             context "kernel-info silent; probing whether kernel %s is busy or dead" pid)
            (condition-case nil
                (let ((process
                       (emacs-jupyter-notebook-ssh-start-bounded-process
                        (format "emacs-jupyter-notebook-busy-probe-%s"
                                (or (plist-get context :session-id) pid))
                        (emacs-jupyter-notebook-ssh-build-pid-alive
                         (plist-get context :profile) pid
                         (plist-get entry :connection-file-tokens))
                        (emacs-jupyter-notebook-ssh--management-output-limit)
                        (lambda (process _event)
                          (when (memq (process-status process) '(exit signal))
                            (let* ((output (emacs-jupyter-notebook--process-output process))
                                   (kind (emacs-jupyter-notebook--classify-pid-probe output)))
                              (emacs-jupyter-notebook--async-cancel-process-timeout process)
                              (emacs-jupyter-notebook--async-delete-process process)
                              (when (emacs-jupyter-notebook--async-context-live-p context)
                                (with-current-buffer buffer
                                  (emacs-jupyter-notebook--async-put
                                   context :busy-probe-process nil)
                                  (pcase kind
                                    ((or 'alive 'unverified)
                                     ;; Alive but shell-silent: connected-busy (W15-B).
                                     (emacs-jupyter-notebook--async-connect-finalize
                                      context buffer
                                      (copy-sequence (plist-get context :entry))
                                      (plist-get context :local-ports)
                                      (plist-get context :local-file)
                                      client 'busy))
                                    ('mismatch
                                     (emacs-jupyter-notebook--async-fail
                                      (emacs-jupyter-notebook--async-put
                                       context :error-kind 'kernel-mismatch)
                                      (format
                                       (concat "Remote PID %s is alive but belongs "
                                               "to a different process (the registered "
                                               "kernel is gone).  Start a new one with "
                                               "`M-x emacs-jupyter-notebook-start-remote-kernel'.")
                                       pid)))
                                    ('dead
                                     (emacs-jupyter-notebook--async-fail
                                      (emacs-jupyter-notebook--async-put
                                       context :error-kind 'kernel-dead)
                                      (format
                                       (concat "Remote kernel %s is no longer alive. "
                                               "Start a new one with "
                                               "`M-x emacs-jupyter-notebook-start-remote-kernel'.")
                                       pid)))
                                    (_
                                     (emacs-jupyter-notebook--async-fail
                                      context
                                      (concat "Kernel did not answer and its host could "
                                              "not be reached to check on it; the kernel "
                                              "may still be alive — retry "
                                              "`M-x emacs-jupyter-notebook-reconnect-remote-kernel'."))))))))))))
                  (emacs-jupyter-notebook--async-put context :busy-probe-process process)
                  (emacs-jupyter-notebook--async-arm-process-timeout
                   context process "Busy-kernel probe"))
              (error
               (emacs-jupyter-notebook--async-fail
                context
                (concat "Kernel did not answer and its host could "
                        "not be reached to check on it; the kernel "
                        "may still be alive — retry "
                        "`M-x emacs-jupyter-notebook-reconnect-remote-kernel'."))))))))))

(defun emacs-jupyter-notebook--async-connect (context)
  "Connect emacs-jupyter to the ready tunnel described by CONTEXT."
  (setq context (emacs-jupyter-notebook--async-put context :phase 'connect))
  (setq context (emacs-jupyter-notebook--async-cancel-timer context))
  (if (not (emacs-jupyter-notebook--async-buffer-live-p context))
      (emacs-jupyter-notebook--async-fail context "Origin buffer was killed")
    (with-current-buffer (plist-get context :origin-buffer)
      (condition-case err
          (let* ((entry (copy-sequence (plist-get context :entry)))
                 (local-ports (plist-get context :local-ports))
                 (local-file (plist-get context :local-file))
                 (buffer (current-buffer)))
            (emacs-jupyter-notebook--async-message
             context "connecting Jupyter backend")
            (setq emacs-jupyter-notebook--tunnel-process
                  (plist-get context :tunnel-process))
            (emacs-jupyter-notebook--install-tunnel-sentinel
              emacs-jupyter-notebook--tunnel-process buffer)
            ;; W13-H3: capture the stable context object so the verify
            ;; callback (which can fire hours late off a busy kernel's shell
            ;; queue) and the timeout timer act only on THIS attempt.
            (let ((ctx context))
              (let ((timer (run-at-time
                            (emacs-jupyter-notebook--connect-arbitration-timeout) nil
                            #'emacs-jupyter-notebook--async-connect-timeout
                            ctx buffer)))
                (setq context (emacs-jupyter-notebook--async-put context :timer timer)))
              ;; The opaque session is available immediately, while the
              ;; legacy implementation keeps its unverified EIEIO client
              ;; private inside it for the busy-kernel timeout arbitration.
              ;; The verified callback remains fully asynchronous.
              (let ((session (emacs-jupyter-notebook-backend-session-create
                              #'emacs-jupyter-notebook--backend-event buffer
                              #'emacs-jupyter-notebook--backend-transport-failed)))
                (setq context (emacs-jupyter-notebook--async-put
                               context :client-unverified session))
                (emacs-jupyter-notebook-backend-connect
                 session local-file
                 (lambda (_backend-request-id connected-session)
                   ;; Verified: finalize as idle.  If finalize declines
                   ;; (already busy-finalized or superseded), a late answer
                   ;; means the existing session became responsive (W15-B).
                   (unless (emacs-jupyter-notebook--async-connect-finalize
                            ctx buffer entry local-ports local-file connected-session)
                     (emacs-jupyter-notebook--connect-verified-late
                      buffer connected-session)))
                 (lambda (_backend-request-id error-data)
                   (when (emacs-jupyter-notebook--async-context-live-p ctx)
                     (emacs-jupyter-notebook--async-fail ctx error-data)))))
            context))
        (error
         (emacs-jupyter-notebook--async-fail
          context (error-message-string err)))))))

(defun emacs-jupyter-notebook--async-start-context (profile entry session-id resolution
                                                     &optional callback error-callback)
  "Create and store an async start context.
PROFILE, ENTRY, SESSION-ID, and RESOLUTION describe the kernel.
CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'resolve
                  :profile profile
                  :entry entry
                  :session-id session-id
                  :resolution resolution
                  :origin-buffer (current-buffer)
                  :owns-kernel t
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    (setq context
          (emacs-jupyter-notebook--async-arm-overall-timeout context))
    context))

(defun emacs-jupyter-notebook--async-reconnect-context
    (profile entry &optional callback error-callback owner)
  "Create and store an async reconnect context for PROFILE and ENTRY.
CALLBACK and ERROR-CALLBACK are optional completion hooks.  OWNER records
whether the attempt was started by `explicit', `evaluation', or `automatic'
recovery so status and cancellation target the current live context."
  (let ((context (emacs-jupyter-notebook--async-new-context
                  :phase 'retrieve
                  :profile profile
                  :entry entry
                  :session-id (plist-get entry :session-id)
                  :origin-buffer (current-buffer)
                  :owns-kernel nil
                  :reconnect-owner (or owner 'explicit)
                  :callback callback
                  :error-callback error-callback)))
    (setq emacs-jupyter-notebook--async-context context)
    (setq context
          (emacs-jupyter-notebook--async-arm-overall-timeout context))
    context))

(defun emacs-jupyter-notebook--tunnel-reconnect (buffer &optional callback error-callback)
  "Reconnect the tunnel for BUFFER asynchronously.
CALLBACK is called on success, ERROR-CALLBACK on failure."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((entry emacs-jupyter-notebook--session-entry))
        (emacs-jupyter-notebook--begin-reconnect
         entry callback error-callback 'evaluation)))))

(defun emacs-jupyter-notebook--reconnect-terminal-p (context)
  "Return non-nil when CONTEXT must not schedule another reconnect.
Cancellation is an explicit stop.  The remaining terminal kinds are probe
results that confirm the durable registry entry no longer names that kernel;
transport unreachability and all timeout kinds remain retryable."
  (or (plist-get context :cancelled)
      (memq (plist-get context :error-kind)
            '(kernel-dead kernel-mismatch no-pid))))

(defun emacs-jupyter-notebook--handle-reconnect-failure
    (context error-data callback)
  "Apply the retry policy for failed reconnect CONTEXT exactly once.
ERROR-DATA and CONTEXT are then passed to CALLBACK when non-nil.  Only the
buffer's currently owned context may alter retry state; a late callback from a
superseded attempt is observational and cannot resurrect recovery."
  (unless (plist-get context :reconnect-failure-handled)
    ;; This key is present in every async context, so `plist-put' mutates the
    ;; existing cons structure without writing a stale context into its buffer.
    (plist-put context :reconnect-failure-handled t)
    (when-let* ((buffer (plist-get context :origin-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq emacs-jupyter-notebook--async-context context)
            (if (emacs-jupyter-notebook--reconnect-terminal-p context)
                (emacs-jupyter-notebook--cancel-auto-reconnect)
              (setq emacs-jupyter-notebook--tunnel-dead t)
              (emacs-jupyter-notebook--schedule-auto-reconnect))))))
    (when callback
      (funcall callback context error-data))))

(defun emacs-jupyter-notebook--begin-reconnect
    (entry callback error-callback &optional owner)
  "Replace local transport state and reconnect asynchronously to ENTRY.
CALLBACK and ERROR-CALLBACK receive the async context.  Durable registry
  state and the remote kernel are left untouched.  OWNER is one of `explicit',
`evaluation', or `automatic' and defaults to `explicit'."
  (unless (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
    (error "Registry entry is not a valid direct kernel session; start a fresh kernel"))
  (let ((attempt emacs-jupyter-notebook--reconnect-attempt))
    ;; A stale backend session is only a local handle.  Keeping it is
    ;; what made explicit reconnect reject the exact broken state it is
    ;; intended to repair.
    (emacs-jupyter-notebook--release-local-resources)
    (setq emacs-jupyter-notebook--session-entry entry
          emacs-jupyter-notebook--tunnel-dead t
          emacs-jupyter-notebook--reconnect-attempt attempt)
    (emacs-jupyter-notebook--ensure-selected-backend)
    (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
           (context (emacs-jupyter-notebook--async-reconnect-context
                     profile entry callback
                     (lambda (failed-context error-data)
                       (emacs-jupyter-notebook--handle-reconnect-failure
                        failed-context error-data error-callback))
                     (or owner 'explicit))))
      ;; Process construction can signal synchronously before a sentinel owns
      ;; the failure.  Route that through the same context callback so explicit,
      ;; evaluation, and automatic reconnects all get the identical retry rule.
      (condition-case err
          (emacs-jupyter-notebook--async-probe-pid-alive context)
        (error
         (plist-put context :error-kind 'probe-start-failed)
         (emacs-jupyter-notebook--async-fail
          context
          (format "Could not start kernel liveness probe: %s"
                  (error-message-string err))))))))

(defun emacs-jupyter-notebook--classify-pid-probe (output)
  "Classify a PID-probe stdout string OUTPUT into a liveness kind.
Returns one of:
- `alive'        — the PID is alive AND (when identity was checked) its
                   command line carries this session's connection file.
- `unverified'   — the PID is alive but its identity could not be confirmed
                   (no readable /proc cmdline and no `ps').  Treated as alive
                   for the reconnect decision; the kernel_info verification
                   on connect is the real arbiter.
- `mismatch'     — the PID is alive but belongs to a DIFFERENT process (PID
                   reuse after a long outage).  The registered kernel is gone.
- `dead'         — the host answered and the PID is not alive.
- `unreachable'  — the host did not produce exactly one recognized identity
                   result followed by `__EJN_DONE__'; ssh/infra or the probe
                   protocol failed.  NOT a confirmed-dead kernel."
  (let ((markers
         (cl-remove-if-not
          (lambda (line)
            (string-match-p
             "\\`__EJN_\\(?:ALIVE_MATCH\\|ALIVE_MISMATCH\\|INSPECT_UNAVAILABLE\\|DEAD\\|DONE\\)__\\'"
             line))
          (split-string output "\n" t "[[:space:]]+"))))
    (pcase markers
      ('("__EJN_ALIVE_MATCH__" "__EJN_DONE__") 'alive)
      ('("__EJN_ALIVE_MISMATCH__" "__EJN_DONE__") 'mismatch)
      ('("__EJN_INSPECT_UNAVAILABLE__" "__EJN_DONE__") 'unverified)
      ('("__EJN_DEAD__" "__EJN_DONE__") 'dead)
      (_ 'unreachable))))

(defun emacs-jupyter-notebook--async-probe-pid-alive (context)
  "W4.4/W19: probe the remote kernel PID for CONTEXT before reconnect.
The registry entry MUST carry a `:remote-pid' (W4.2 sentinel).  The probe
is IDENTITY-AWARE: it passes the entry's `:remote-connection-file' so the
remote side confirms the live PID is really THIS session's kernel (its
command line carries the connection file), not a reused PID.  The context
advances to `--async-retrieve' on a live match (or an unverified-but-alive
PID); it fails with `kernel-dead' when the host answers and the PID is
gone, with `kernel-mismatch' when the PID belongs to another process, and
with `probe-unreachable' when the host cannot be reached at all.  The
registry entry is NOT removed — the user may inspect it or clean it
explicitly via `clean-orphaned-kernels' (per the binding rule that only the
explicit user commands may remove durable state).

W4.8: an entry without `:remote-pid' is a session from before W4.2
landed; per the no-backwards-compat rule we surface a clear failure
rather than silently bypass the probe.  The probe process itself is
stored in the context and disposed in the sentinel via
`--async-delete-process' so its stdout/stderr buffers do not leak, and is
bounded by the per-process watchdog so it cannot hang the attempt."
  (let* ((entry (plist-get context :entry))
         (pid (and entry (plist-get entry :remote-pid)))
         (profile (plist-get context :profile))
         (buffer (plist-get context :origin-buffer)))
    (cond
     ((and (plist-get entry :provisional)
           (not pid)
           (stringp (plist-get entry :remote-pid-sidecar)))
      (emacs-jupyter-notebook--async-read-pid-sidecar context))
     ((not pid)
      (emacs-jupyter-notebook--async-fail
       (emacs-jupyter-notebook--async-put context :error-kind 'no-pid)
       (concat "This registry entry has no recorded PID (pre-W4.2 session). "
               "Start a fresh kernel with "
               "`M-x emacs-jupyter-notebook-start-remote-kernel'.")))
     (t
      (setq context (emacs-jupyter-notebook--async-put context :phase 'probe))
      (let* ((argv (emacs-jupyter-notebook-ssh-build-pid-alive
                    profile pid (plist-get entry :connection-file-tokens)))
             (probe-name (format "emacs-jupyter-notebook-pid-probe-%s"
                                 (or (plist-get context :session-id) pid)))
             (sentinel
              (lambda (process _event)
                (when (memq (process-status process) '(exit signal))
                  ;; W13: read the probe's stdout, NOT its exit status, so an
                  ;; ssh/infra failure is never mistaken for a dead kernel.
                  (let* ((output (emacs-jupyter-notebook--process-stdout process))
                         (diagnostic
                          (emacs-jupyter-notebook--process-output process))
                         (kind (emacs-jupyter-notebook--classify-pid-probe output)))
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (when (eq emacs-jupyter-notebook--async-context context)
                          (emacs-jupyter-notebook--async-put
                           context :probe-process nil)
                          (emacs-jupyter-notebook--async-delete-process process)
                          (pcase kind
                            ((or 'alive 'unverified)
                             (when (eq kind 'unverified)
                               (emacs-jupyter-notebook--async-message
                                context
                                (concat "kernel %s alive but identity could not "
                                        "be confirmed; verifying on connect") pid))
                             (emacs-jupyter-notebook--async-retrieve context))
                            ('mismatch
                             (emacs-jupyter-notebook--async-fail
                              (emacs-jupyter-notebook--async-put
                               context :error-kind 'kernel-mismatch)
                              (format
                               (concat
                                "Remote PID %s on %s is alive but belongs to a "
                                "different process (the registered kernel is "
                                "gone).  Start a new one with "
                                "`M-x emacs-jupyter-notebook-start-remote-kernel'.")
                               pid
                               (or (plist-get entry :remote-host)
                                   "the remote host"))))
                            ('dead
                             (emacs-jupyter-notebook--async-fail
                              (emacs-jupyter-notebook--async-put
                               context :error-kind 'kernel-dead)
                              (format
                               (concat
                                "Remote kernel %s is no longer alive on %s. "
                                "Start a new one with "
                                "`M-x emacs-jupyter-notebook-start-remote-kernel'.")
                               pid
                               (or (plist-get entry :remote-host)
                                   "the remote host"))))
                            (_
                             ;; The host never answered — ssh/infra failure, NOT
                             ;; a dead kernel.  Do not deregister or advise a
                             ;; fresh start; surface the reachability problem.
                             (emacs-jupyter-notebook--async-fail
                              (emacs-jupyter-notebook--async-put
                               context :error-kind 'probe-unreachable)
                              (format
                               (concat
                                "Could not reach %s to check kernel %s: %s "
                                "The kernel may still be alive; retry "
                                "`M-x emacs-jupyter-notebook-reconnect-remote-kernel'.")
                               (or (plist-get entry :remote-host) "the remote host")
                               pid
                               (let ((trimmed (string-trim diagnostic)))
                                 (if (string-empty-p trimmed)
                                     "SSH connection failed"
                                   trimmed)))))))))))))
             (process (emacs-jupyter-notebook-ssh-start-bounded-process
                       probe-name argv
                       emacs-jupyter-notebook-ssh-kernelspec-max-text-bytes
                       sentinel)))
        (emacs-jupyter-notebook--async-put context :probe-process process)
        (emacs-jupyter-notebook--async-arm-process-timeout
         context process "Kernel liveness probe"))))))

;; W4.7: the synchronous `--connect-entry' that drove the now-removed
;; `--retrieve-connection-file' and `--wait-for-tunnel' has been removed.
;; All reconnect goes through `--async-probe-pid-alive' →
;; `--async-retrieve' → `--async-wait-tunnel-tick' → `--async-connect'.

;;; Ensure client (async)

(defun emacs-jupyter-notebook--ensure-client-async (callback error-callback)
  "Ensure a kernel client is connected, then call CALLBACK.
On failure, call ERROR-CALLBACK with (context error-data)."
  (cond
   ;; W13-H2: an attempt is already in flight — ATTACH to it and never
   ;; launch a parallel one.  This must precede the `--tunnel-dead' branch:
   ;; a reconnect leaves `--tunnel-dead' t until `--async-connect-finalize',
   ;; so without this a second send mid-reconnect would re-enter
   ;; `--tunnel-reconnect' and clobber the in-flight context with a duplicate
   ;; probe/tunnel.
   ((emacs-jupyter-notebook--async-in-progress-p)
    (emacs-jupyter-notebook--async-add-callback
     emacs-jupyter-notebook--async-context callback)
    (when error-callback
      (emacs-jupyter-notebook--async-add-error-callback
       emacs-jupyter-notebook--async-context error-callback)))
   ;; A dead tunnel with a durable session entry reconnects it.
   ((and emacs-jupyter-notebook--tunnel-dead
         emacs-jupyter-notebook--session-entry)
    (emacs-jupyter-notebook--tunnel-reconnect
     (current-buffer) callback error-callback))
   (emacs-jupyter-notebook--client
    (funcall callback nil))
   (t
    ;; W13-M1: a `--tunnel-dead' flag with no session entry is stale debris
    ;; (e.g. a deliberately torn-down start attempt); clear it so it cannot
    ;; wedge a later send, then start/reconnect normally rather than
    ;; silently no-op in `--tunnel-reconnect'.
    (setq emacs-jupyter-notebook--tunnel-dead nil)
    ;; W4.8: when reconnect to a known registry entry fails (including the
    ;; W4.4 dead-PID case) we MUST NOT auto-remove the entry or auto-start
    ;; a fresh kernel — only the explicit user commands `shutdown-kernel'
    ;; and `clean-orphaned-kernels' may terminate / deregister.  Surface
    ;; the error to the caller; the message produced by `--async-fail'
    ;; (W4.3 / W4.4) already points the user at `start-remote-kernel'.
    (if-let ((entry (emacs-jupyter-notebook--current-file-registry-entry)))
        (emacs-jupyter-notebook-reconnect-remote-kernel
         entry callback
         (lambda (context error-data)
           (when error-callback
             (funcall error-callback context error-data)))
         'evaluation)
      (emacs-jupyter-notebook-start-remote-kernel
       emacs-jupyter-notebook-default-profile callback error-callback)))))

;;; Completion (W3: non-blocking capf with LRU cache + idle delay)
;;
;; Design contract (see ROADMAP.md W3):
;; - capf returns IMMEDIATELY with whatever is in the LRU cache.  No call
;;   ever blocks waiting on the kernel; even a 10-second adapter delay must
;;   not slow the capf hot path beyond a few milliseconds.
;; - A new completion request is sent only after the user has been idle for
;;   `emacs-jupyter-notebook-completion-idle' seconds.  Each keystroke
;;   restarts the idle window.
;; - Each request carries a monotonic id and the cache key
;;   `(point . line-up-to-point)'.  When a new request fires, both the
;;   pending key and the pending id are overwritten; the prior reply is
;;   stale and is DROPPED on arrival without rendering.
;; - The cache is a bounded LRU keyed by `(point . line-up-to-point)'.
;;   Eviction is least-recently-used.

(defun emacs-jupyter-notebook--completion-key ()
  "Return the completion cache key for point in the current buffer.
The key is `(point . line-up-to-point)' per W3 design contract."
  (cons (point)
        (buffer-substring-no-properties (line-beginning-position) (point))))

(defun emacs-jupyter-notebook--completion-context ()
  "Build a completion context from the current cell.
Returns a plist with :key (cache key for LRU lookup), :code (cell source
text sent to the kernel), and :cursor-pos (cursor offset into the code)."
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg)))
    (list :key (emacs-jupyter-notebook--completion-key)
          :code code
          :cursor-pos cursor-pos)))

(defun emacs-jupyter-notebook--completion-cache-ensure ()
  "Return the buffer-local completion cache hash-table, creating it if needed."
  (or emacs-jupyter-notebook--completion-cache
      (setq emacs-jupyter-notebook--completion-cache
            (make-hash-table :test 'equal))))

(defun emacs-jupyter-notebook--completion-cache-get (key)
  "Return the cached reply for KEY or nil.
Side-effect: promotes KEY to most-recently-used in the LRU order."
  (when emacs-jupyter-notebook--completion-cache
    (let ((reply (gethash key emacs-jupyter-notebook--completion-cache)))
      (when reply
        (setq emacs-jupyter-notebook--completion-cache-order
              (cons key (delete key emacs-jupyter-notebook--completion-cache-order)))
        reply))))

(defun emacs-jupyter-notebook--completion-cache-put (key reply)
  "Insert REPLY under KEY into the LRU cache, evicting LRU entries past the cap."
  (let ((cache (emacs-jupyter-notebook--completion-cache-ensure))
        (limit (max 1 (or emacs-jupyter-notebook-completion-cache-size 1))))
    (puthash key reply cache)
    (setq emacs-jupyter-notebook--completion-cache-order
          (cons key (delete key emacs-jupyter-notebook--completion-cache-order)))
    (while (> (length emacs-jupyter-notebook--completion-cache-order) limit)
      (let* ((order emacs-jupyter-notebook--completion-cache-order)
             (victim (car (last order))))
        (remhash victim cache)
        (setq emacs-jupyter-notebook--completion-cache-order (butlast order))))
    reply))

(defun emacs-jupyter-notebook--completion-cache-reset ()
  "Discard all cached completion replies in the current buffer."
  (when (hash-table-p emacs-jupyter-notebook--completion-cache)
    (clrhash emacs-jupyter-notebook--completion-cache))
  (setq emacs-jupyter-notebook--completion-cache-order nil))

(defun emacs-jupyter-notebook--completion-after-change (&rest _ignored)
  "Invalidate completion state after any source-buffer edit.

This hook performs no transport or UI work.  Bumping the request generation
and clearing its public pending identity makes every pre-edit reply stale,
including edits elsewhere in the current cell that leave point and the current
line prefix unchanged."
  (emacs-jupyter-notebook--completion-cache-reset)
  (setq emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil)
  (cl-incf emacs-jupyter-notebook--completion-request-counter))

(defun emacs-jupyter-notebook--completion-result-from-reply (reply)
  "Translate a Jupyter complete_reply plist REPLY into a capf return value."
  (when reply
    (let* ((matches (plist-get reply :matches))
           (cursor-start (plist-get reply :cursor_start))
           (cursor-end (plist-get reply :cursor_end)))
      (when matches
        (list (- (point) (- cursor-end cursor-start))
              (point)
              (append matches nil)
              :exclusive 'no)))))

(defun emacs-jupyter-notebook--completion-result ()
  "Return cached CAPF result for point or nil.
Looks up the LRU cache by the current `(point . line-up-to-point)' key.
Never sends a request and never blocks."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (when-let* ((key (emacs-jupyter-notebook--completion-key))
                (reply (emacs-jupyter-notebook--completion-cache-get key)))
      (emacs-jupyter-notebook--completion-result-from-reply reply))))

(defun emacs-jupyter-notebook--completion-refresh-ui ()
  "Push freshly-cached candidates to the active completion frontend.
Behavior (W3.7):
- If `company-mode' is on and no popup is yet open, kick
  `company-manual-begin' so company picks up the fresh cache.
- If no completion popup is active, drive `completion-in-region'
  directly with the cached result (covers explicit `complete-at-point'
  invocations and the vanilla path).
- If `completion-in-region-mode' is already active (Corfu, vertico,
  consult-completion-in-region, etc.) do nothing: there is no
  cross-version programmatic way to force the popup to re-fetch capf
  candidates.  The next user keystroke causes capf to be re-invoked
  naturally and the popup picks up the new cache then."
  ;; Justification for the missing Corfu hook: `corfu--exhibit' only
  ;; redisplays current corfu state; it does not refresh candidates from
  ;; would stay empty.  We instead rely on the fallback path: when the
  ;; cache fills, the next user keystroke causes capf to be re-invoked
  ;; naturally and the popup picks up the new candidates.  For the
  ;; explicit-completion case (no popup yet active) we drive
  ;; `completion-in-region' directly.
  (cond
   ((and (bound-and-true-p company-mode)
         (not (bound-and-true-p company-candidates))
         (fboundp 'company-manual-begin))
    (funcall 'company-manual-begin))
   ((not (bound-and-true-p completion-in-region-mode))
    (let ((result (emacs-jupyter-notebook--completion-result)))
      (when result
        ;; capf return shape is `(START END COLLECTION . CAPF-PROPS)'
        ;; where CAPF-PROPS include `:exclusive', `:annotation-function',
        ;; etc.  `completion-in-region' does NOT accept those trailing
        ;; keywords, so strip them before calling.
        (apply #'completion-in-region (seq-take result 3)))))))

(defun emacs-jupyter-notebook--completion-on-reply
    (buffer client key request-id show-results context-snapshot reply _error)
  "Cache REPLY for KEY under REQUEST-ID in BUFFER, optionally refreshing UI.
Stale replies are dropped: a reply is stale when REQUEST-ID no longer
matches the buffer-local pending id, when KEY no longer matches the live
pending key, OR when the buffer's current capf context no longer matches
the request's KEY (i.e. point moved or the line changed).  Only fresh
replies update the cache; this prevents `out-of-date' completions from
being cached for the original context after the user moved away from it
(W3.3 + W3.7)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eq client emacs-jupyter-notebook--client)
                 (equal emacs-jupyter-notebook--completion-pending-id request-id)
                 (= request-id emacs-jupyter-notebook--completion-request-counter)
                 (equal emacs-jupyter-notebook--completion-pending-key key))
        (setq emacs-jupyter-notebook--completion-pending-key nil
              emacs-jupyter-notebook--completion-pending-id nil)
        (when (and reply
                   (equal (emacs-jupyter-notebook--completion-context)
                          context-snapshot))
          (emacs-jupyter-notebook--completion-cache-put key reply)
          (when (and show-results
                     (equal (emacs-jupyter-notebook--completion-context)
                            context-snapshot))
            (emacs-jupyter-notebook--completion-refresh-ui)))))))

(defun emacs-jupyter-notebook--request-completion (&optional show-results)
  "Fire an async completion request for point.
SHOW-RESULTS non-nil means push the reply to the active completion UI on
arrival.  The current pending key/id are overwritten so any earlier reply
arriving after this call is dropped (W3.3)."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let* ((context (emacs-jupyter-notebook--completion-context))
           (key (plist-get context :key))
           (code (plist-get context :code))
           (cursor-pos (plist-get context :cursor-pos))
           (buffer (current-buffer))
           (client emacs-jupyter-notebook--client))
      (unless (and (equal emacs-jupyter-notebook--completion-pending-key key)
                   emacs-jupyter-notebook--completion-pending-id)
        (let ((request-id
               (cl-incf emacs-jupyter-notebook--completion-request-counter)))
          (setq emacs-jupyter-notebook--completion-pending-key key
                emacs-jupyter-notebook--completion-pending-id request-id)
          (emacs-jupyter-notebook-backend-aux
           client 'complete
           (list :code code :cursor-pos cursor-pos)
           (lambda (_backend-request-id reply)
             (emacs-jupyter-notebook--completion-on-reply
              buffer client key request-id show-results context reply nil))
           (lambda (_backend-request-id error)
             (emacs-jupyter-notebook--completion-on-reply
              buffer client key request-id show-results context nil error))))))))

(defun emacs-jupyter-notebook--completion-schedule-request (&optional show-results)
  "Restart the idle timer that fires an async completion request.
Any in-flight request is invalidated by bumping the request counter the
next time `--request-completion' runs; pending key/id are cleared so the
older reply is dropped (W3.3)."
  (emacs-jupyter-notebook--completion-cancel-idle-timer)
  ;; Invalidate any in-flight request so its reply is dropped on arrival.
  (setq emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil)
  (let ((buffer (current-buffer))
        (delay (max 0.0 (or emacs-jupyter-notebook-completion-idle 0.10))))
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-timer
           delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacs-jupyter-notebook--completion-idle-timer nil)
                 (when (and emacs-jupyter-notebook-mode
                            emacs-jupyter-notebook--client
                            (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
                   (emacs-jupyter-notebook--request-completion show-results)))))))))

(defun emacs-jupyter-notebook--completion-explicit-command-p ()
  "Return non-nil when `this-command' is an explicit completion invocation.
Covers the vanilla `completion-at-point' (\\[completion-at-point] / M-TAB),
this package's own `emacs-jupyter-notebook-complete-at-point', Company's
`company-manual-begin', and any command whose symbol name contains the
completion verb `complet' (the corfu/company/comint completion TRIGGERS
all do: `corfu-complete', `company-complete', `company-complete-common',
`completion-at-point', ...).

Keying on the `complet' verb rather than a frontend prefix is deliberate
(W9): popup NAVIGATION and dismissal commands — `corfu-next',
`corfu-previous', `corfu-quit', `company-select-next', `company-abort' —
do NOT contain `complet', so they never match and never schedule a kernel
request even if the capf is re-entered under them.  Cursor-motion commands
(`next-line', `forward-char', mouse events, ...) likewise never match,
honoring the W3 \"motion must not request\" contract."
  (let ((cmd this-command))
    (and (symbolp cmd)
         (or (memq cmd '(completion-at-point
                         emacs-jupyter-notebook-complete-at-point
                         company-manual-begin))
             (string-match-p "complet" (symbol-name cmd))))))

(defun emacs-jupyter-notebook-completion-at-point ()
  "CAPF function: return cached completions immediately; schedule async fill.
W3.4 contract: this function never blocks.  When the cache misses we
schedule an idle-delayed async request; the kernel reply (whenever it
arrives) populates the cache and refreshes the frontend so subsequent
capf calls hit.

The miss gate fires for two disjoint situations (W9):
- the user just edited (typed / deleted / yanked), the corfu-auto path;
- completion was invoked EXPLICITLY (M-TAB, a Corfu/Company manual
  trigger, or `emacs-jupyter-notebook-complete-at-point').  This is the
  case that matters for object-attribute completion: after `obj.' the
  attribute prefix is EMPTY, so corfu-auto (min prefix >= 2) never fires
  and the ONLY entry point is a manual invocation.  The narrower
  edit-only gate returned nil here and never sent a request, so `obj.'
  completion silently produced nothing.

Broadening the gate cannot spam the kernel: `--completion-schedule-request'
is debounced (each call cancels the prior idle timer and clears the
pending key/id) and `--request-completion' de-dups on the pending key, so
repeated capf calls for one stable context collapse to at most one
request."
  (when (and emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy)))
    (let ((result (emacs-jupyter-notebook--completion-result)))
      (if result
          result
        (when (or (memq this-command
                        '(self-insert-command
                          delete-backward-char
                          backward-delete-char-untabify
                          yank))
                  (emacs-jupyter-notebook--completion-explicit-command-p))
          (emacs-jupyter-notebook--completion-schedule-request t))
        nil))))

(defun emacs-jupyter-notebook--complete-explicit-now ()
  "Fetch completions immediately and display them when the reply arrives.
Unlike the debounced auto path (which just primes the cache and relies on
the frontend re-invoking capf on the next keystroke), an EXPLICIT
invocation fires the request now and drives `completion-in-region' on
arrival — so a single \\[emacs-jupyter-notebook-complete-at-point] reliably
shows candidates after the round trip regardless of the active frontend,
and reports `No completions' rather than doing nothing."
  (let* ((context (emacs-jupyter-notebook--completion-context))
         (key (plist-get context :key))
         (code (plist-get context :code))
         (cursor-pos (plist-get context :cursor-pos))
         (buffer (current-buffer))
         (client emacs-jupyter-notebook--client)
         (origin-point (point))
         (request-id (cl-incf emacs-jupyter-notebook--completion-request-counter)))
    ;; This immediate request supersedes any debounced cache fill.  Clearing
    ;; its public pending identity prevents the retired callback from leaving a
    ;; same-key request permanently marked in flight.
    (emacs-jupyter-notebook--completion-cancel-idle-timer)
    (message "Requesting completions…")
    (emacs-jupyter-notebook-backend-aux
     client 'complete
     (list :code code :cursor-pos cursor-pos)
     (lambda (_backend-request-id reply)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (and (= request-id emacs-jupyter-notebook--completion-request-counter)
                      (eq client emacs-jupyter-notebook--client)
                      reply (= (point) origin-point)
                      (equal (emacs-jupyter-notebook--completion-context) context))
             (emacs-jupyter-notebook--completion-cache-put key reply)
             (let ((result (emacs-jupyter-notebook--completion-result-from-reply
                            reply)))
               (if (and result (nth 2 result) (> (length (nth 2 result)) 0))
                   (apply #'completion-in-region (seq-take result 3))
                 (message "No completions")))))))
     #'ignore)))

(defun emacs-jupyter-notebook-complete-at-point ()
  "Explicit completion command.
Shows cached candidates immediately when present; otherwise fetches now and
displays them when the reply lands (see `--complete-explicit-now')."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (when (eq emacs-jupyter-notebook--kernel-status 'busy)
    (user-error "Kernel is busy; completion is unavailable until it is idle"))
  (let ((result (emacs-jupyter-notebook--completion-result)))
    (if result
        ;; Strip capf metadata (`:exclusive' etc) before invoking
        ;; `completion-in-region', which only accepts (START END COLL).
        (apply #'completion-in-region (seq-take result 3))
      (emacs-jupyter-notebook--complete-explicit-now))))

(defun emacs-jupyter-notebook--completion-start-idle-timer ()
  "Start the completion cache idle timer (one-shot rescheduled on each tick).
The timer captures the current buffer in a closure so it always operates
on the buffer that armed it, not whatever buffer happens to be current
when the timer fires."
  (emacs-jupyter-notebook--completion-cancel-idle-timer)
  (let ((buffer (current-buffer)))
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-idle-timer
           (max 0.0 (or emacs-jupyter-notebook-completion-idle 0.10))
           nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacs-jupyter-notebook--completion-idle-timer nil)
                 (emacs-jupyter-notebook--completion-idle-populate))))))))

(defun emacs-jupyter-notebook--completion-cancel-idle-timer ()
  "Cancel the completion cache idle timer and clear pending request state.
Clearing the pending key/id ensures that any reply for a request that was
in flight when the timer was cancelled is dropped on arrival per the W3.3
in-flight invalidation contract."
  (when (timerp emacs-jupyter-notebook--completion-idle-timer)
    (cancel-timer emacs-jupyter-notebook--completion-idle-timer))
  (setq emacs-jupyter-notebook--completion-idle-timer nil
        emacs-jupyter-notebook--completion-pending-key nil
        emacs-jupyter-notebook--completion-pending-id nil))

(defun emacs-jupyter-notebook--completion-idle-populate ()
  "Populate completion cache on idle when point sits at a fresh context."
  (when (and emacs-jupyter-notebook-mode
             emacs-jupyter-notebook--client
             (not (eq emacs-jupyter-notebook--kernel-status 'busy))
             (not (emacs-jupyter-notebook--async-in-progress-p)))
    (let ((key (emacs-jupyter-notebook--completion-key)))
      (unless (or (equal key emacs-jupyter-notebook--completion-pending-key)
                  (and emacs-jupyter-notebook--completion-cache
                       (gethash key emacs-jupyter-notebook--completion-cache)))
        (emacs-jupyter-notebook--request-completion)))))

;;; Inspect

(defun emacs-jupyter-notebook-inspect-at-point ()
  "Inspect the symbol at point using the Jupyter kernel."
  (interactive)
  (unless emacs-jupyter-notebook--client
    (user-error "No Jupyter kernel connected"))
  (let* ((code (emacs-jupyter-notebook-cell-code))
         (bounds (emacs-jupyter-notebook-cell-bounds))
         (beg (car bounds))
         (cursor-pos (- (point) beg))
         (client emacs-jupyter-notebook--client)
         (origin-point (point))
         (request-id (cl-incf emacs-jupyter-notebook--inspect-request-id)))
    (emacs-jupyter-notebook-backend-aux
     client 'inspect
     (list :code code :cursor-pos cursor-pos :detail 0)
     (lambda (_backend-request-id reply)
       (when (and (= request-id emacs-jupyter-notebook--inspect-request-id)
                  (eq emacs-jupyter-notebook--client client) reply
                  (= (point) origin-point)
                  (equal (emacs-jupyter-notebook-cell-code) code))
         (let* ((data (plist-get reply :data))
                (text (plist-get data :text/plain)))
           (when (and text (not (string-empty-p text)))
             ;; IPython colourises its inspector (`?') output with ANSI SGR
             ;; escapes; decode them to faces instead of dumping literal
             ;; `\e[0;31m...' into the echo area / *Message* buffer.
             (display-message-or-buffer
              (string-trim-right (ansi-color-apply text)))))))
     (lambda (&rest _ignored) nil))))

;;; Evaluation

(defun emacs-jupyter-notebook--current-cell-key ()
  "Return the cell key for the current cell, or nil if no marker exists.
Cells without a `# %%' marker (i.e., whole-buffer evaluation in marker-less
files) return nil so they flow only to the history-log view."
  (save-excursion
    (let* ((bounds (emacs-jupyter-notebook-cell-bounds))
           (beg (car bounds)))
      ;; Bounds start at the cell body; the marker line begins just before.
      ;; Walk back to the marker line, if any.
      (goto-char beg)
      (cond
       ((and (> beg (point-min))
             (save-excursion
               (goto-char beg)
               (forward-line -1)
               (looking-at code-cells-boundary-regexp)))
        (forward-line -1)
        (emacs-jupyter-notebook--cell-key-for (line-beginning-position)))
       ((save-excursion
          (goto-char (point-min))
          (looking-at code-cells-boundary-regexp))
        (emacs-jupyter-notebook--cell-key-for (point-min)))
       (t nil)))))

(defun emacs-jupyter-notebook--execution-dispatch (record)
  "Send active RECORD and arm its timeout only after the send is admitted."
  (let* ((id (plist-get record :id))
         (buffer (current-buffer))
         (client emacs-jupyter-notebook--client)
         (handle (plist-get record :panel-entry)))
    (if (not (and client (emacs-jupyter-notebook--execution-current-p id)))
        (emacs-jupyter-notebook--execution-fail record "kernel connection was lost")
      (setq record (plist-put record :state 'dispatched))
      ;; Legacy Jupyter handlers can synchronously emit terminal IOPub events
      ;; while this call is still admitting the execute request.  Persist the
      ;; dispatched record before entering the adapter so those events can be
      ;; staged rather than lost.
      (emacs-jupyter-notebook--execution-put record)
      (when (ejn-panel-entry-live-p handle)
        (ejn-panel-set-entry-status handle 'running))
      (when-let ((cell-key (plist-get record :cell-key)))
        (emacs-jupyter-notebook-fringe-set cell-key 'running))
      (condition-case err
          (let ((backend-id
               (emacs-jupyter-notebook-backend-execute
                client (plist-get record :code)
                (list :entry-handle handle :ledger-id id)
                (lambda (_backend-id _result)
                  ;; EI4 terminality is driven only by the real, correlated
                  ;; execute_reply plus status=idle event pair.  The response
                  ;; remains an operation acknowledgement, never synthetic
                  ;; terminal evidence.
                  nil)
                (lambda (_backend-id reason)
                  (when (and (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (emacs-jupyter-notebook--execution-current-p id)))
                    (with-current-buffer buffer
                      (emacs-jupyter-notebook--execution-fail
                       (emacs-jupyter-notebook--execution-record id) reason)))))))
          ;; A test double (or future adapter) may call a terminal callback
          ;; synchronously above.  Never restore A after that callback has
          ;; retired it and possibly made B active.
          (setq record (emacs-jupyter-notebook--execution-record id))
          (when (and record (emacs-jupyter-notebook--execution-current-p id)
                     (eq (plist-get record :state) 'dispatched))
            (setq record (plist-put record :backend-request-id backend-id))
            (emacs-jupyter-notebook--execution-put record)
            (setq record
                  (emacs-jupyter-notebook--execution-consume-staged-terminal
                   record backend-id))
            (when (and record (emacs-jupyter-notebook--execution-current-p id)
                       (eq (plist-get record :state) 'dispatched))
              (setq record
                    (plist-put
                     record :timer
                     (run-at-time
                      emacs-jupyter-notebook-evaluation-timeout nil
                      (lambda ()
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (emacs-jupyter-notebook--evaluation-on-timeout id)))))))
              (emacs-jupyter-notebook--execution-put record))))
        (error (emacs-jupyter-notebook--execution-fail record (error-message-string err)))))))

(defun emacs-jupyter-notebook--execution-completeness-record
    (id client completeness-id)
  "Return active ID's record when COMPLETENESS-ID still owns its check."
  (let ((record (emacs-jupyter-notebook--execution-record id)))
    (when (and (eq client emacs-jupyter-notebook--client)
               (= completeness-id emacs-jupyter-notebook--is-complete-request-id)
               record (emacs-jupyter-notebook--execution-current-p id)
               (= completeness-id (plist-get record :is-complete-request-id))
               (eq (plist-get record :state) 'checking))
      record)))

(defun emacs-jupyter-notebook--execution-after-completeness
    (id client completeness-id reply)
  "Continue active ID only when its correlated completeness REPLY allows it."
  (when-let ((record (emacs-jupyter-notebook--execution-completeness-record
                      id client completeness-id)))
    (if (and reply (equal (plist-get reply :status) "complete"))
        (emacs-jupyter-notebook--execution-dispatch record)
      (emacs-jupyter-notebook--execution-fail record "code is incomplete"))))

(defun emacs-jupyter-notebook--execution-start (record)
  "Start the active head RECORD without allowing later FIFO records through."
  (let ((id (plist-get record :id)) (buffer (current-buffer)))
    (setq record (plist-put record :state 'checking))
    (emacs-jupyter-notebook--execution-put record)
    (emacs-jupyter-notebook--ensure-client-async
     (lambda (_context)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((current (emacs-jupyter-notebook--execution-record id))
                 (client emacs-jupyter-notebook--client))
             (when (and current (emacs-jupyter-notebook--execution-current-p id)
                        (eq (plist-get current :state) 'checking))
               (cond
                ;; Connect finalization can install a silent setup sequence
                ;; while this record was awaiting `ensure-client'.  Give the
                ;; FIFO head back to the queue; setup's terminal decision
                ;; performs the only subsequent pump.
                (emacs-jupyter-notebook--execution-setup-pending
                 (setq current (plist-put current :state 'queued))
                 (emacs-jupyter-notebook--execution-put current)
                 (setq emacs-jupyter-notebook--execution-active-id nil))
                (emacs-jupyter-notebook-check-code-completeness
                 (let ((completeness-id
                        (cl-incf emacs-jupyter-notebook--is-complete-request-id)))
                   (setq current (plist-put current :is-complete-request-id completeness-id))
                   (emacs-jupyter-notebook--execution-put current)
                   (condition-case err
                       (emacs-jupyter-notebook-backend-aux
                        client 'is-complete
                        (list :code (plist-get current :code))
                        (lambda (_backend-id reply)
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (emacs-jupyter-notebook--execution-after-completeness
                               id client completeness-id reply))))
                        (lambda (_backend-id reason)
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (when-let
                                  ((record
                                    (emacs-jupyter-notebook--execution-completeness-record
                                     id client completeness-id)))
                                (emacs-jupyter-notebook--execution-fail
                                 record reason))))))
                     (error
                      (emacs-jupyter-notebook--execution-fail
                       current (error-message-string err))))))
                (t (emacs-jupyter-notebook--execution-dispatch current))))))))
     (lambda (_context reason)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (emacs-jupyter-notebook--execution-current-p id)
             (emacs-jupyter-notebook--execution-fail
              (emacs-jupyter-notebook--execution-record id) reason))))))))

(defun emacs-jupyter-notebook--execution-pump ()
  "Start exactly the oldest reserved request when no active request remains."
  (unless (or emacs-jupyter-notebook--execution-active-id
              emacs-jupyter-notebook--execution-setup-pending)
    (let ((id (car emacs-jupyter-notebook--execution-queue)))
      (when id
        (let ((record (emacs-jupyter-notebook--execution-record id)))
          (if (not record)
              (progn
                (setq emacs-jupyter-notebook--execution-queue
                      (cdr emacs-jupyter-notebook--execution-queue))
                (emacs-jupyter-notebook--execution-pump))
            (setq emacs-jupyter-notebook--execution-active-id id)
            (emacs-jupyter-notebook--execution-start record)))))))

(defun emacs-jupyter-notebook--execution-apply-terminal-event (record event)
  "Apply one already-correlated terminal EVENT to RECORD without finishing it."
  (pcase (plist-get event :type)
    ('execute-reply
     (setq record (plist-put record :reply-seen t))
     ;; Jupyter's legacy `aborted' status and every malformed/non-ok status
     ;; are local errors.  Only the exact string "ok" is successful.
     (setq record (plist-put record :reply-status
                             (if (equal (plist-get event :status) "ok") 'ok 'error)))
     (setq record (plist-put record :execution-count
                             (plist-get event :execution-count))))
    ('status
     (when (equal (plist-get event :execution-state) "idle")
       (setq record (plist-put record :idle-seen t))))
    (_ nil))
  record)

(defun emacs-jupyter-notebook--execution-maybe-finish (record)
  "Store RECORD and finish it once both terminal signals are present."
  (emacs-jupyter-notebook--execution-put record)
  (when (and (plist-get record :reply-seen) (plist-get record :idle-seen))
    (emacs-jupyter-notebook--execution-finish
     record (if (or (plist-get record :timed-out)
                    (eq (plist-get record :state) 'cancelling))
                'error
              (plist-get record :reply-status))
     (plist-get record :execution-count))
    nil))

(defun emacs-jupyter-notebook--execution-stage-terminal-event
    (record backend-id event context)
  "Stage at most one reply and one idle event before execute admission returns."
  (let ((staged-id (plist-get record :staged-backend-id)))
    (when (and (or (eq (plist-get event :type) 'execute-reply)
                   (and (eq (plist-get event :type) 'status)
                        (equal (plist-get event :execution-state) "idle")))
               (or (null staged-id) (equal staged-id backend-id)))
      (setq record (plist-put record :staged-backend-id backend-id))
      (setq record (plist-put record :staged-context context))
      (pcase (plist-get event :type)
        ('execute-reply (setq record (plist-put record :staged-reply event)))
        ('status (when (equal (plist-get event :execution-state) "idle")
                   (setq record (plist-put record :staged-idle t)))))
      (emacs-jupyter-notebook--execution-put record))))

(defun emacs-jupyter-notebook--execution-consume-staged-terminal (record backend-id)
  "Consume RECORD's pre-admission terminal evidence only for BACKEND-ID."
  (if (not (plist-get record :staged-backend-id))
      record
    (if (not (equal backend-id (plist-get record :staged-backend-id)))
        ;; A synchronous callback from a different generic request is stale.
        ;; It never becomes valid after admission and must not retain data.
        (progn
          (setq record (plist-put record :staged-backend-id nil))
          (setq record (plist-put record :staged-reply nil))
          (setq record (plist-put record :staged-idle nil))
          (setq record (plist-put record :staged-context nil))
          (emacs-jupyter-notebook--execution-put record))
    (let ((reply (plist-get record :staged-reply))
          (idle (plist-get record :staged-idle))
          (context (plist-get record :staged-context)))
      (setq record (plist-put record :staged-backend-id nil))
      (setq record (plist-put record :staged-reply nil))
      (setq record (plist-put record :staged-idle nil))
      (setq record (plist-put record :staged-context nil))
      ;; The reducer was deliberately held back before backend-id admission.
      ;; Replay each staged terminal event exactly once now, while suppressing
      ;; its normal ledger callback; this function owns terminal settlement.
      (when context
        (setq context (plist-put (copy-sequence context)
                                 :skip-execution-note t))
        (when reply
          (emacs-jupyter-notebook-events-dispatch context reply))
        (when idle
          (emacs-jupyter-notebook-events-dispatch
           context '(:type status :execution-state "idle"))))
      (when reply
        (setq record (emacs-jupyter-notebook--execution-apply-terminal-event
                      record reply)))
      (when idle
        (setq record (emacs-jupyter-notebook--execution-apply-terminal-event
                      record '(:type status :execution-state "idle"))))
      (emacs-jupyter-notebook--execution-maybe-finish record)))))

(defun emacs-jupyter-notebook--execution-note-event (context event)
  "Record correlated terminal evidence from normalized EVENT.
An execution advances only after both its execute reply and idle status, in
either arrival order.  A legacy callback that arrives before execute admission
returns is boundedly staged until its generic backend id can be validated."
  (let ((id (plist-get context :request-id))
        (backend-id (plist-get context :backend-request-id))
        (generation (plist-get context :panel-generation)))
    (when (and id backend-id (emacs-jupyter-notebook--execution-current-p id))
      (let ((record (emacs-jupyter-notebook--execution-record id)))
        ;; Presentation may be retired by clear-results, but its captured
        ;; generation remains the ownership identity.
        (when (equal generation (plist-get record :generation))
          (cond
           ((null (plist-get record :backend-request-id))
            (when (eq (plist-get record :state) 'dispatched)
              (emacs-jupyter-notebook--execution-stage-terminal-event
               record backend-id event context)))
           ((equal backend-id (plist-get record :backend-request-id))
            (setq record (emacs-jupyter-notebook--execution-apply-terminal-event record event))
            (emacs-jupyter-notebook--execution-maybe-finish record))))))))

(defun emacs-jupyter-notebook--evaluate-code (code cell-key)
  "Reserve CODE in FIFO order before any asynchronous client/completeness work."
  (unless (stringp code)
    (user-error "Evaluation code must be a string"))
  (when (> (emacs-jupyter-notebook--execution-code-bytes
            code emacs-jupyter-notebook--max-code-bytes)
           emacs-jupyter-notebook--max-code-bytes)
    (user-error "Evaluation exceeds EJN_MAX_CODE_BYTES"))
  (let* ((buffer (current-buffer))
         (panel (ejn-panel-ensure buffer))
         (handle (ejn-panel-start-entry panel cell-key code))
         (id (cl-incf emacs-jupyter-notebook--execution-counter))
         (record (list :id id :code code :cell-key cell-key :panel-entry handle
                       :generation (plist-get handle :generation) :state 'queued
                       :reply-seen nil :idle-seen nil :terminal nil :timer nil))
         (modified (buffer-modified-p)))
    (emacs-jupyter-notebook-panel--display panel)
    (ejn-panel-set-entry-status handle 'queued)
    (when cell-key (emacs-jupyter-notebook-fringe-set cell-key 'queued))
    (emacs-jupyter-notebook--execution-put record)
    (setq emacs-jupyter-notebook--execution-queue
          (append emacs-jupyter-notebook--execution-queue (list id)))
    (set-buffer-modified-p modified)
    (emacs-jupyter-notebook--execution-pump)
    id))

;;; Commands

(defun emacs-jupyter-notebook--registry-entry-key (entry)
  "Return the registry key for ENTRY, or nil."
  (or (plist-get entry :session-id)
      (plist-get entry :profile)))

(defun emacs-jupyter-notebook--cleanup-current-state (&optional reason cleanup-entry)
  "Clean current buffer's client, tunnel, async context, and registry state.
REASON is used when cancelling an async context.  CLEANUP-ENTRY, when non-nil,
is an identity-verified replacement candidate owned by the explicit
fresh-kernel command.  Local cleanup never sends a helper shutdown request:
that control is owned exclusively by the confirmed
`emacs-jupyter-notebook-shutdown-kernel' lifecycle path."
  (let ((entry (or cleanup-entry emacs-jupyter-notebook--session-entry))
        (context emacs-jupyter-notebook--async-context))
    (emacs-jupyter-notebook--clear-buffer-timers)
    (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
    (ignore-errors (emacs-jupyter-notebook--cancel-auto-reconnect))
    (when (and context (emacs-jupyter-notebook--async-in-progress-p))
      (plist-put context :cancelled t)
      (ignore-errors
        (emacs-jupyter-notebook--async-fail
         context (or reason "Operation cancelled"))))
    (ignore-errors
      (emacs-jupyter-notebook--cancel-async-context-locally context))
    (ignore-errors (emacs-jupyter-notebook--cancel-auto-reconnect))
    (when emacs-jupyter-notebook--client
      (ignore-errors
        (emacs-jupyter-notebook-backend-close-local
         emacs-jupyter-notebook--client #'ignore #'ignore)))
    (when (processp emacs-jupyter-notebook--tunnel-process)
      (emacs-jupyter-notebook--async-delete-process
       emacs-jupyter-notebook--tunnel-process))
    (when entry
      (emacs-jupyter-notebook--cleanup-remote-entry entry))
    (when-let* ((key (and entry (emacs-jupyter-notebook--registry-entry-key entry))))
      (emacs-jupyter-notebook-registry-remove-entry key))
    (when-let* ((local-file (plist-get entry :local-connection-file)))
      (emacs-jupyter-notebook--async-delete-file local-file))
    (setq emacs-jupyter-notebook--client nil
          emacs-jupyter-notebook--session-entry nil
          emacs-jupyter-notebook--tunnel-process nil
          emacs-jupyter-notebook--tunnel-dead nil
          emacs-jupyter-notebook--kernel-status nil
          emacs-jupyter-notebook--async-context nil
          emacs-jupyter-notebook--execution-ledger nil
          emacs-jupyter-notebook--execution-queue nil
          emacs-jupyter-notebook--execution-active-id nil
          emacs-jupyter-notebook--execution-setup-pending nil
          emacs-jupyter-notebook--execution-setup-timer nil)
    (force-mode-line-update t)
    entry))

(defun emacs-jupyter-notebook--display-command-output (buffer-name output)
  "Display OUTPUT in read-only BUFFER-NAME."
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output)
        (goto-char (point-min)))
      (setq buffer-read-only t))
    (display-buffer buf)))

;;;###autoload
(defun emacs-jupyter-notebook-start-remote-kernel (profile-name &optional callback error-callback)
  "Start a detached remote kernel for PROFILE-NAME asynchronously.
  CALLBACK and ERROR-CALLBACK are optional completion hooks."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (unless buffer-file-name
    (user-error "Buffer has no associated file"))
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (emacs-jupyter-notebook--ensure-clean-before-start)
  (emacs-jupyter-notebook--ensure-selected-backend)
  (let* ((profile (emacs-jupyter-notebook--read-host-profile profile-name))
         (session-id (emacs-jupyter-notebook--new-session-id
                      (file-name-base buffer-file-name)))
         (resolution (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
                      profile session-id))
         (entry (list :profile (plist-get profile :profile)
                       :remote-host (emacs-jupyter-notebook-ssh-destination profile)
                       :remote-cwd (plist-get profile :remote-cwd)
                       :kernelspec (plist-get profile :kernelspec)
                       :remote-pid nil
                       :created-at (emacs-jupyter-notebook--timestamp)
                       :tunnel-ports nil
                       :display-name (format "%s:%s"
                                             (emacs-jupyter-notebook-ssh-destination profile)
                                             (plist-get profile :kernelspec))
                       :session-id session-id
                       :local-file buffer-file-name))
         (context (emacs-jupyter-notebook--async-start-context
                   profile entry session-id resolution callback error-callback)))
    (setq context (emacs-jupyter-notebook--async-resolve-kernelspec context))
    context))

(defun emacs-jupyter-notebook--reconnect-selected-entry
    (entry callback error-callback interactivep &optional owner)
  "Reconnect to ENTRY after an asynchronous picker has selected it.
CALLBACK and ERROR-CALLBACK are completion hooks.  INTERACTIVEP controls the
fresh-kernel recovery prompt for a confirmed dead or mismatched kernel.
OWNER identifies an `explicit', `evaluation', or `automatic' initiator."
  (let ((profile-name (plist-get entry :profile)))
    ;; Explicit reconnect supersedes a stale reconnect attempt without a
    ;; second prompt.  It never supersedes a start attempt silently.
    (emacs-jupyter-notebook--ensure-no-async-operation t)
    (emacs-jupyter-notebook--begin-reconnect
     entry callback
     (lambda (context error-data)
       (when error-callback
         (funcall error-callback context error-data))
       (when (and interactivep
                  (memq (plist-get context :error-kind)
                        '(kernel-dead kernel-mismatch))
                  (y-or-n-p
                   (concat
                    "The registered kernel is gone (possibly after its idle "
                    "timeout); start a fresh kernel on the same profile? ")))
         (emacs-jupyter-notebook-retry-fresh-kernel profile-name)))
     (or owner 'explicit))))

;;;###autoload
(defun emacs-jupyter-notebook-reconnect-remote-kernel
    (&optional entry callback error-callback owner)
  "Reconnect current buffer to remote kernel ENTRY asynchronously.
CALLBACK and ERROR-CALLBACK are optional completion hooks.  Interactively,
probe registered kernels without blocking, then present the reconnect picker.
OWNER is for internal callers and defaults to `explicit'."
  (interactive)
  (let ((interactivep (called-interactively-p 'interactive)))
    (if entry
        (emacs-jupyter-notebook--reconnect-selected-entry
         entry callback error-callback interactivep (or owner 'explicit))
      (emacs-jupyter-notebook--read-registry-entry-async
       (lambda (selected)
         (emacs-jupyter-notebook--reconnect-selected-entry
          selected callback error-callback interactivep
          (or owner 'explicit)))))))

(defun emacs-jupyter-notebook--cold-start-p ()
  "Return non-nil when sending would trigger a cold remote-kernel start.
Cold means no buffer-local client, no in-flight async operation, and no
registry entry for this file."
  (and (not emacs-jupyter-notebook--client)
       (not (emacs-jupyter-notebook--async-in-progress-p))
       (not (emacs-jupyter-notebook--current-file-registry-entry))))

(defun emacs-jupyter-notebook--announce-cold-start (profile-name)
  "Message the W6.3 friendly-first-start banner for PROFILE-NAME."
  (message
   "emacs-jupyter-notebook: starting kernel via profile %s (C-u to choose)"
   profile-name))

;;;###autoload
(defun emacs-jupyter-notebook-send-cell (&optional choose)
  "Send the current # %% cell, posting output to the cell's panel entry.

W6.3 contract: when no kernel is connected and no in-flight async exists,
this command messages the user about which profile it is about to start
with (the package's `default-profile') before the silent launch.  With a
\\[universal-argument] CHOOSE prefix, prompt for the profile to start
instead of using the default."
  (interactive "P")
  (let ((profile (if (and choose (emacs-jupyter-notebook--cold-start-p))
                     (emacs-jupyter-notebook--read-profile-name)
                   emacs-jupyter-notebook-default-profile)))
    (when (and (emacs-jupyter-notebook--cold-start-p) (not choose))
      (emacs-jupyter-notebook--announce-cold-start profile))
    ;; Pin the resolved profile for `--ensure-client-async' fallback path.
    (let ((emacs-jupyter-notebook-default-profile profile))
      (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
        (let ((code (buffer-substring-no-properties beg end))
              (key (emacs-jupyter-notebook--current-cell-key)))
          (emacs-jupyter-notebook--evaluate-code code key))))))

;;;###autoload
(defun emacs-jupyter-notebook--region-bounds ()
  "Return `(BEG END)' for the current region, Evil-aware.
Uses Evil's `evil-visual-beginning' / `evil-visual-end' markers when
Evil visual state is active — Evil sometimes deactivates the standard
Emacs region before an interactively-invoked command runs, which makes
`(interactive \"r\")' error out with `The mark is not set now'.  Falls
back to the standard `region-beginning' / `region-end' when Evil is
not involved.  Signals a `user-error' when no meaningful region is
available."
  (cond
   ((and (bound-and-true-p evil-visual-beginning)
         (bound-and-true-p evil-visual-end)
         (fboundp 'evil-visual-state-p)
         (evil-visual-state-p))
    (list (marker-position evil-visual-beginning)
          (marker-position evil-visual-end)))
   ((use-region-p)
    (list (region-beginning) (region-end)))
   (t
    (user-error "No active region — mark a region first"))))

(defun emacs-jupyter-notebook-send-region (beg end)
  "Send the active region from BEG to END.
Region evaluations have no cell key and appear only in the history-log
view of the panel.  Works with standard Emacs region and with Evil
character-wise / line-wise visual state."
  (interactive (emacs-jupyter-notebook--region-bounds))
  (emacs-jupyter-notebook--evaluate-code
   (buffer-substring-no-properties beg end) nil))

;;;###autoload
(defun emacs-jupyter-notebook-send-paragraph ()
  "Send the current paragraph to the remote kernel.
Uses `mark-paragraph' semantics to delimit the paragraph; output has no
cell key and appears only in the history-log view of the panel."
  (interactive)
  (save-mark-and-excursion
    (mark-paragraph)
    (let ((beg (region-beginning))
          (end (region-end)))
      (emacs-jupyter-notebook--evaluate-code
       (buffer-substring-no-properties beg end) nil))))

;;;###autoload
(defun emacs-jupyter-notebook-send-defun ()
  "Send the current defun to the remote kernel.
Uses `beginning-of-defun' / `end-of-defun' to delimit the defun; output
has no cell key and appears only in the history-log view of the panel."
  (interactive)
  (save-mark-and-excursion
    (let (beg end)
      (end-of-defun)
      (setq end (point))
      (beginning-of-defun)
      (setq beg (point))
      (emacs-jupyter-notebook--evaluate-code
       (buffer-substring-no-properties beg end) nil))))

(defun emacs-jupyter-notebook--confirm (interactive-p force prompt)
  "Return non-nil when a destructive action is authorized.
W6.4 contract: when called from Lisp (INTERACTIVE-P nil) the action is
always authorized — Lisp callers are presumed deliberate.  When called
interactively (INTERACTIVE-P non-nil) and FORCE is non-nil (a raw prefix
arg via \\[universal-argument]) the prompt is skipped.  Otherwise ask
PROMPT via `y-or-n-p' and require an explicit positive answer."
  (or (not interactive-p)
      force
      (y-or-n-p prompt)))

(defun emacs-jupyter-notebook-send-buffer (&optional force)
  "Send the current buffer to the remote kernel.
Buffer evaluations have no cell key and appear only in the history-log
view of the panel.  W6.4: when called interactively, ask `y-or-n-p'
before sending; a \\[universal-argument] FORCE prefix skips the prompt."
  (interactive "P")
  (when (emacs-jupyter-notebook--confirm
         (called-interactively-p 'any) force
         "Send entire buffer to the kernel? ")
    (emacs-jupyter-notebook--evaluate-code
     (buffer-substring-no-properties (point-min) (point-max)) nil)))

;;;###autoload
(defun emacs-jupyter-notebook-interrupt-kernel ()
  "Interrupt only the current active dispatched evaluation."
  (interactive)
  (let ((client (emacs-jupyter-notebook--ensure-client)))
    (unless (emacs-jupyter-notebook--interrupt-active-execution client)
      (user-error "No active EJN evaluation can be interrupted"))))

;;;###autoload
(defun emacs-jupyter-notebook--execution-open-restart-gate (client)
  "Raise a fresh-kernel gate before sending restart control.
The old active execution remains owned until restart is acknowledged.  A
failed or unsupported restart therefore cannot release queued work alongside
an execution that is still running remotely.  Once acknowledged, the caller
settles the old active record while this gate continues to hold the FIFO across
readiness and formatter/watchdog setup."
  (when (eq client emacs-jupyter-notebook--client)
    (unless emacs-jupyter-notebook--execution-setup-pending
      (setq emacs-jupyter-notebook--execution-setup-pending t
            emacs-jupyter-notebook--execution-setup-epoch
            (1+ emacs-jupyter-notebook--execution-setup-epoch))
      emacs-jupyter-notebook--execution-setup-epoch)))

(defun emacs-jupyter-notebook--execution-restart-acknowledged
    (client epoch &optional suffix)
  "Settle old active work after CLIENT acknowledged lifecycle EPOCH.
SUFFIX describes the explicit terminal action in the result panel."
  (when (and (eq client emacs-jupyter-notebook--client)
             emacs-jupyter-notebook--execution-setup-pending
             (= epoch emacs-jupyter-notebook--execution-setup-epoch))
    (when-let ((active (emacs-jupyter-notebook--execution-record
                        emacs-jupyter-notebook--execution-active-id)))
      (emacs-jupyter-notebook--execution-finish
       active 'error nil (or suffix "\nkernel restarted")))
    ;; The new helper's connect path already owns the only admissible
    ;; kernel-info verification.  Replacement setup starts from
    ;; `--async-connect-finalize' after that verification succeeds.
    nil))

(defun emacs-jupyter-notebook--execution-restart-start-setup (client epoch)
  "Run the one replacement setup sequence for CLIENT at restart EPOCH."
  (when (and (eq client emacs-jupyter-notebook--client)
             emacs-jupyter-notebook--execution-setup-pending
             (= epoch emacs-jupyter-notebook--execution-setup-epoch))
    (emacs-jupyter-notebook--execution-setup-send-next
     client epoch
     (append (list emacs-jupyter-notebook--viewer-formatter-snippet)
             (when (and (integerp emacs-jupyter-notebook-kernel-idle-timeout)
                        (> emacs-jupyter-notebook-kernel-idle-timeout 0))
               (list (format emacs-jupyter-notebook--kernel-idle-watchdog-snippet
                             emacs-jupyter-notebook-kernel-idle-timeout)))))))

(defun emacs-jupyter-notebook--execution-release-unattached-gate (epoch)
  "Release EPOCH after terminal lifecycle work when no client remains.
This intentionally does not pump queued evaluations: their outcome cannot be
sent until a later verified attachment owns a new setup sequence."
  (when (and emacs-jupyter-notebook--execution-setup-pending
             (= epoch emacs-jupyter-notebook--execution-setup-epoch)
             (null emacs-jupyter-notebook--client))
    (when (timerp emacs-jupyter-notebook--execution-setup-timer)
      (cancel-timer emacs-jupyter-notebook--execution-setup-timer))
    (setq emacs-jupyter-notebook--execution-setup-pending nil
          emacs-jupyter-notebook--execution-setup-timer nil)))

(defun emacs-jupyter-notebook--execution-active-interruptable-p (client)
  "Return the current active record when CLIENT may interrupt it."
  (when (eq client emacs-jupyter-notebook--client)
    (when-let ((record (emacs-jupyter-notebook--execution-record
                        emacs-jupyter-notebook--execution-active-id)))
      (when (memq (plist-get record :state) '(dispatched cancelling)) record))))

(defun emacs-jupyter-notebook--interrupt-active-execution (client)
  "Request one interrupt for CLIENT's active dispatched execution only."
  (when-let ((record (emacs-jupyter-notebook--execution-active-interruptable-p client)))
    (unless (plist-get record :interrupt-sent)
      (setq record (plist-put record :interrupt-sent t))
      (emacs-jupyter-notebook--execution-put record)
      (condition-case err
          (emacs-jupyter-notebook-backend-control
           client 'interrupt nil
           (lambda (&rest _) nil)
           (lambda (_id reason)
             (when (eq client emacs-jupyter-notebook--client)
               (emacs-jupyter-notebook--log-append 'interrupt
                                                   "interrupt failed: %s" reason))))
        (error
         ;; No backend request was admitted, so a later explicit interrupt may
         ;; retry.  Asynchronous failure remains ambiguous and deliberately
         ;; keeps the marker set to prevent duplicate wire controls.
         (when-let ((current (emacs-jupyter-notebook--execution-record
                              (plist-get record :id))))
           (when (and (eq client emacs-jupyter-notebook--client)
                      (eq (plist-get current :interrupt-sent) t))
             (setq current (plist-put current :interrupt-sent nil))
             (emacs-jupyter-notebook--execution-put current)))
         (signal (car err) (cdr err)))))
    record))

(defun emacs-jupyter-notebook--lifecycle-context-live-p (context client epoch)
  "Return non-nil for the exact current lifecycle CONTEXT/CLIENT/EPOCH."
  (and (emacs-jupyter-notebook--async-context-live-p context)
       (eq (plist-get context :restart-client) client)
       (equal (plist-get context :restart-epoch) epoch)))

(defun emacs-jupyter-notebook--ensure-helper-lifecycle-client ()
  "Return the installed helper client or reject destructive lifecycle work."
  (let ((client (emacs-jupyter-notebook--ensure-client)))
    (unless (and (eq (emacs-jupyter-notebook-backend-session-backend client) 'helper)
                 (emacs-jupyter-notebook-backend-session-installed-p client))
      (user-error
       "Restart and shutdown require an EJN helper session; reconnect with the helper backend"))
    client))

(defun emacs-jupyter-notebook--lifecycle-retire-local-transport (client)
  "Release CLIENT and current tunnel while preserving the execution ledger."
  (when (eq client emacs-jupyter-notebook--client)
    (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
    (ignore-errors
      (emacs-jupyter-notebook-backend-close-local client #'ignore #'ignore))
    (ignore-errors
      (when (processp emacs-jupyter-notebook--tunnel-process)
        (emacs-jupyter-notebook--async-delete-process
         emacs-jupyter-notebook--tunnel-process)))
    (setq emacs-jupyter-notebook--client nil
          emacs-jupyter-notebook--tunnel-process nil
          emacs-jupyter-notebook--kernel-status nil)))

(defun emacs-jupyter-notebook--restart-seed-from-connection (entry connection)
  "Return a private `(SEED . CONNECTION)' rebuilt for durable ENTRY."
  (let* ((ports (plist-get entry :remote-ports))
         (seed (make-temp-file "emacs-jupyter-notebook-restart-" nil ".json"))
         complete)
    (unwind-protect
        (progn
          (setq connection
                (emacs-jupyter-notebook-connection-remote-seed connection ports))
          (emacs-jupyter-notebook-connection-write-file connection seed)
          (set-file-modes seed #o600)
          (setq complete t)
          (cons seed connection))
      (unless complete
        (ignore-errors (delete-file seed))))))

(defun emacs-jupyter-notebook--restart-seed (entry)
  "Synchronously reconstruct `(SEED . CONNECTION)' from durable ENTRY.
This helper is retained for noninteractive validation and tests.  The public
restart path reads the durable file through a bounded asynchronous child."
  (emacs-jupyter-notebook--restart-seed-from-connection
   entry
   (emacs-jupyter-notebook-connection-read-file
    (plist-get entry :local-connection-file))))

(defun emacs-jupyter-notebook--restart-seed-read-command (file)
  "Return portable local argv that reads at most the connection ceiling from FILE."
  (unless (and (stringp file) (file-name-absolute-p file)
               (not (file-remote-p file)))
    (error "Restart connection path must be an absolute local file name"))
  (list "sh" "-c"
        "test -f \"$1\" && test -r \"$1\" && exec head -c \"$2\" \"$1\""
        "ejn-read-connection" file
        (number-to-string (1+ emacs-jupyter-notebook-connection-max-bytes))))

(defun emacs-jupyter-notebook--restart-seed-read-sentinel (context process)
  "Validate PROCESS bytes and advance exact restart CONTEXT to resolution."
  (when (and (memq (process-status process) '(exit signal))
             (emacs-jupyter-notebook--async-context-live-p context))
    (emacs-jupyter-notebook--async-cancel-process-timeout process)
    (let ((raw (emacs-jupyter-notebook--process-stdout process))
          (diagnostic (emacs-jupyter-notebook--process-output process))
          (failed (emacs-jupyter-notebook--async-process-failed-p process)))
      (emacs-jupyter-notebook--async-delete-process process)
      (setq context (emacs-jupyter-notebook--async-put
                     context :restart-seed-read-process nil))
      (if failed
          (emacs-jupyter-notebook--async-fail
           context (format "Could not read durable restart connection: %s"
                           diagnostic))
        (condition-case err
            (pcase-let* ((connection
                          (emacs-jupyter-notebook-connection-parse-bytes raw))
                         (`(,seed . ,remote-connection)
                          (emacs-jupyter-notebook--restart-seed-from-connection
                           (plist-get context :entry) connection)))
              (setq context (emacs-jupyter-notebook--async-put
                             context :restart-seed seed))
              (setq context (emacs-jupyter-notebook--async-put
                             context :connection remote-connection))
              (emacs-jupyter-notebook--async-resolve-kernelspec context))
          (error
           (emacs-jupyter-notebook--async-fail
            context (format "Invalid durable restart connection: %s"
                            (error-message-string err)))))))))

(defun emacs-jupyter-notebook--restart-read-seed-async (context)
  "Read CONTEXT's durable connection without blocking the Emacs event loop."
  (condition-case err
      (let* ((file (plist-get (plist-get context :entry)
                              :local-connection-file))
             (process
              (emacs-jupyter-notebook-ssh-start-bounded-process
               (format "emacs-jupyter-notebook-restart-seed-%s"
                       (plist-get context :session-id))
               (emacs-jupyter-notebook--restart-seed-read-command file)
               (1+ emacs-jupyter-notebook-connection-max-bytes)
               (lambda (finished _event)
                 (emacs-jupyter-notebook--restart-seed-read-sentinel
                  context finished)))))
        (setq context (emacs-jupyter-notebook--async-put
                       context :phase 'restart-seed-read))
        (setq context (emacs-jupyter-notebook--async-put
                       context :restart-seed-read-process process))
        (emacs-jupyter-notebook--async-arm-process-timeout
         context process "Durable restart connection read")
        context)
    (error
     (emacs-jupyter-notebook--async-fail
      context (format "Could not start durable restart connection read: %s"
                      (error-message-string err))))))

(defun emacs-jupyter-notebook--restart-failed (context reason)
  "Handle restart failure while retaining its latest durable recovery state."
  (when-let ((buffer (plist-get context :origin-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((client (plist-get context :restart-client))
              (epoch (plist-get context :restart-epoch)))
          (if (plist-get context :restart-shutdown-sent)
              (progn
                (emacs-jupyter-notebook--lifecycle-retire-local-transport client)
                ;; A confirmed shutdown invalidates the old PID even when the
                ;; following durable save failed.  Keep the buffer's recovery
                ;; surface honest; the error state reports that disk truth may
                ;; still require repair.
                (when (plist-get context :restart-shutdown-confirmed)
                  (setq emacs-jupyter-notebook--session-entry
                        (copy-sequence (plist-get context :entry))))
                (setq emacs-jupyter-notebook--tunnel-dead t)
                (emacs-jupyter-notebook--execution-release-unattached-gate epoch)
                (when (and (plist-get context :launch-process-started)
                           (not (plist-get context :cancelled)))
                  (emacs-jupyter-notebook--schedule-auto-reconnect))
                (emacs-jupyter-notebook--log-append 'restart
                                                    "replacement unavailable: %s" reason))
            (emacs-jupyter-notebook--execution-setup-finish client epoch reason)))))))

(defun emacs-jupyter-notebook--restart-preflight-ready (context)
  "Send terminal helper shutdown only after restart preflight completed."
  (when (emacs-jupyter-notebook--async-context-live-p context)
    (let ((client (plist-get context :restart-client))
          (epoch (plist-get context :restart-epoch)))
      (when (and (eq client emacs-jupyter-notebook--client) epoch)
        (setq context (emacs-jupyter-notebook--async-put context :restart-preflight nil))
        (setq context (emacs-jupyter-notebook--async-put context :phase 'restart-shutdown))
        ;; From admission onward the helper may have observed shutdown even
        ;; when the local request later times out.  Never reuse its old local
        ;; channels in that ambiguous state.
        (setq context (emacs-jupyter-notebook--async-put context :restart-shutdown-sent t))
        (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
        (condition-case err
            (emacs-jupyter-notebook-backend-control
             client 'shutdown nil
             (lambda (&rest _)
               (emacs-jupyter-notebook--restart-shutdown-confirmed
                context client epoch))
             (lambda (_id reason)
               (when (emacs-jupyter-notebook--lifecycle-context-live-p context client epoch)
                 (emacs-jupyter-notebook--async-fail context reason))))
          (error (emacs-jupyter-notebook--async-fail
                  context (error-message-string err))))))))

(defun emacs-jupyter-notebook--restart-upload-seed (context)
  "Upload CONTEXT's private restart seed to its unique remote staging path."
  (when (emacs-jupyter-notebook--async-context-live-p context)
    (condition-case err
        (let (process)
          (setq process
                (emacs-jupyter-notebook-ssh-start-bounded-process
                 (format "emacs-jupyter-notebook-restart-upload-%s"
                         (plist-get context :session-id))
                 (emacs-jupyter-notebook-ssh-scp-to-command
                  (plist-get context :profile) (plist-get context :restart-seed)
                  (plist-get context :restart-staging-file))
                 emacs-jupyter-notebook-connection-max-bytes
                 (lambda (finished _event)
                   (when (and (memq (process-status finished) '(exit signal))
                              (emacs-jupyter-notebook--async-context-live-p context))
                     (emacs-jupyter-notebook--async-cancel-process-timeout finished)
                     (let ((failed (emacs-jupyter-notebook--async-process-failed-p finished))
                           (detail (emacs-jupyter-notebook--process-output finished)))
                       (emacs-jupyter-notebook--async-delete-process finished)
                       (setq context (emacs-jupyter-notebook--async-put
                                      context :restart-upload-process nil))
                       (if failed
                           (emacs-jupyter-notebook--async-fail
                            context (format "Restart seed upload failed: %s" detail))
                         (emacs-jupyter-notebook--restart-publish-seed context)))))))
          (setq context (emacs-jupyter-notebook--async-put
                         context :phase 'restart-upload))
          (setq context (emacs-jupyter-notebook--async-put
                         context :restart-upload-process process))
          (emacs-jupyter-notebook--async-arm-process-timeout
           context process "Restart seed upload")
          context)
      (error (emacs-jupyter-notebook--async-fail context (error-message-string err))))))

(defun emacs-jupyter-notebook--restart-publish-seed (context)
  "Atomically publish CONTEXT's uploaded restart seed before launch."
  (when (emacs-jupyter-notebook--async-context-live-p context)
    (condition-case err
        (let (process)
          (setq process
                (emacs-jupyter-notebook-ssh-start-bounded-process
                 (format "emacs-jupyter-notebook-restart-publish-%s"
                         (plist-get context :session-id))
                 (emacs-jupyter-notebook-ssh-build-remote-publish-connection
                  (plist-get context :profile) (plist-get context :restart-staging-file)
                  (plist-get (plist-get context :entry) :remote-connection-file))
                 emacs-jupyter-notebook-connection-max-bytes
                 (lambda (finished _event)
                   (when (and (memq (process-status finished) '(exit signal))
                              (emacs-jupyter-notebook--async-context-live-p context))
                     (emacs-jupyter-notebook--async-cancel-process-timeout finished)
                     (let ((failed (emacs-jupyter-notebook--async-process-failed-p finished))
                           (detail (emacs-jupyter-notebook--process-output finished)))
                       (emacs-jupyter-notebook--async-delete-process finished)
                       (setq context (emacs-jupyter-notebook--async-put
                                      context :restart-publish-process nil))
                       (if failed
                           (emacs-jupyter-notebook--async-fail
                            context (format "Restart seed publish failed: %s" detail))
                         (emacs-jupyter-notebook--async-delete-file
                          (plist-get context :restart-seed))
                         (setq context (emacs-jupyter-notebook--async-put
                                        context :restart-seed nil))
                         (setq context (emacs-jupyter-notebook--async-put
                                        context :restart-staging-file nil))
                         (condition-case launch-error
                             (emacs-jupyter-notebook--async-launch context)
                           (error
                            (emacs-jupyter-notebook--async-fail
                             context
                             (format "Could not admit replacement launch: %s"
                                     (error-message-string
                                      launch-error)))))))))))
          (setq context (emacs-jupyter-notebook--async-put context :phase 'restart-publish))
          (setq context (emacs-jupyter-notebook--async-put
                         context :restart-publish-process process))
          (emacs-jupyter-notebook--async-arm-process-timeout
           context process "Restart seed publish")
          context)
      (error
       (emacs-jupyter-notebook--async-fail context (error-message-string err))))))

(defun emacs-jupyter-notebook--restart-shutdown-confirmed (context client epoch)
  "Advance exact restart CONTEXT after helper proved old kernel terminal."
  (when (emacs-jupyter-notebook--lifecycle-context-live-p context client epoch)
    (setq context (emacs-jupyter-notebook--async-put
                   context :restart-shutdown-confirmed t))
    (emacs-jupyter-notebook--execution-restart-acknowledged client epoch)
    (emacs-jupyter-notebook--lifecycle-retire-local-transport client)
    (condition-case err
        (let* ((entry (copy-sequence (plist-get context :entry)))
               (path (plist-get entry :remote-connection-file))
               (staging (format "%s.restart-%s" path
                                (emacs-jupyter-notebook--new-session-id "seed"))))
          ;; The old PID is confirmed dead.  Persist this truth before any
          ;; upload or launch request so a failed restore never leaves a
          ;; ready-looking registry entry pointing at that dead process.
          (setq entry (plist-put entry :provisional t))
          (setq entry (plist-put entry :remote-pid nil))
          (setq context (emacs-jupyter-notebook--async-put context :entry entry))
          (setq emacs-jupyter-notebook--session-entry (copy-sequence entry))
          (emacs-jupyter-notebook-registry-save-entry entry)
          (setq context (emacs-jupyter-notebook--async-put
                         context :restart-provisional-saved t))
          (setq context (emacs-jupyter-notebook--async-put
                         context :restart-staging-file staging))
          (setq context (emacs-jupyter-notebook--async-put
                         context :remote-ports
                         (copy-sequence (plist-get entry :remote-ports))))
          (setq context (emacs-jupyter-notebook--async-put
                         context :local-file
                         (make-temp-file
                          "emacs-jupyter-notebook-restart-local-" nil ".json")))
          (set-file-modes (plist-get context :local-file) #o600)
          (setq context (emacs-jupyter-notebook--async-put
                         context :restart-local-file (plist-get context :local-file)))
          (emacs-jupyter-notebook--restart-upload-seed context))
      (error
       (emacs-jupyter-notebook--async-fail
        context (format "Could not prepare replacement kernel state: %s"
                        (error-message-string err)))))))

(defun emacs-jupyter-notebook-restart-kernel ()
  "Restart through confirmed helper shutdown and a fresh direct launch."
  (interactive)
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (let* ((client (emacs-jupyter-notebook--ensure-helper-lifecycle-client))
         (entry emacs-jupyter-notebook--session-entry))
    (when emacs-jupyter-notebook--execution-setup-pending
      (user-error "Kernel setup is already in progress"))
    (unless (and entry (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)
                 (emacs-jupyter-notebook-connection-valid-ports-p
                  (plist-get entry :remote-ports))
                 (stringp (plist-get entry :local-connection-file))
                 (file-name-absolute-p
                  (plist-get entry :local-connection-file))
                 (not (file-remote-p
                       (plist-get entry :local-connection-file))))
      (user-error "Kernel session lacks the direct restart metadata; start a fresh kernel"))
    ;; Gate before even reversible preflight so no new user work can slip
    ;; between an explicit restart gesture and terminal shutdown.
    (let ((epoch (emacs-jupyter-notebook--execution-open-restart-gate client))
          context)
      (unless epoch (user-error "Kernel restart is already in progress"))
      (condition-case err
          (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
                 (resolution (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
                              profile (plist-get entry :session-id)))
                 (new-context
                  (emacs-jupyter-notebook--async-new-context
                   :phase 'restart-resolve :profile profile :entry (copy-sequence entry)
                   :session-id (plist-get entry :session-id)
                   :resolution resolution :origin-buffer (current-buffer)
                   :restart-epoch epoch :restart-client client
                   :restart-preflight t :owns-kernel nil
                   :error-callback #'emacs-jupyter-notebook--restart-failed)))
            (setq context new-context)
            (setq emacs-jupyter-notebook--async-context context)
            (setq context (emacs-jupyter-notebook--async-arm-overall-timeout context))
            (emacs-jupyter-notebook--restart-read-seed-async context))
        (error
         (if (and context (eq context emacs-jupyter-notebook--async-context))
             (emacs-jupyter-notebook--async-fail
              context (format "Could not start kernel restart: %s"
                              (error-message-string err)))
           (emacs-jupyter-notebook--execution-setup-finish
            client epoch (error-message-string err))))))))

(defun emacs-jupyter-notebook--shutdown-failed (context client epoch reason)
  "Leave durable state intact after ambiguous helper shutdown failure."
  (when (and (eq emacs-jupyter-notebook--async-context context)
             (eq emacs-jupyter-notebook--client client)
             (= epoch emacs-jupyter-notebook--execution-setup-epoch)
             (not (plist-get context :lifecycle-failure-handled)))
    (plist-put context :lifecycle-failure-handled t)
    (emacs-jupyter-notebook--lifecycle-retire-local-transport client)
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (emacs-jupyter-notebook--execution-release-unattached-gate epoch)
    (emacs-jupyter-notebook--async-put context :phase 'error)
    (emacs-jupyter-notebook--log-append 'shutdown "shutdown outcome unknown: %s" reason)))

(defun emacs-jupyter-notebook--shutdown-confirmed (context client epoch entry)
  "Remove durable state only after helper proved terminal shutdown."
  (when (emacs-jupyter-notebook--lifecycle-context-live-p context client epoch)
    (setq context
          (emacs-jupyter-notebook--async-cancel-overall-timer context))
    (emacs-jupyter-notebook--execution-restart-acknowledged
     client epoch "\nkernel shut down")
    (emacs-jupyter-notebook--lifecycle-retire-local-transport client)
    (emacs-jupyter-notebook--execution-release-unattached-gate epoch)
    ;; The registry mutation is the deletion boundary.  If it cannot be made
    ;; durable, retain both it and the local connection file for inspection.
    (condition-case err
        (progn
          (emacs-jupyter-notebook-registry-remove-entry
           (emacs-jupyter-notebook--registry-entry-key entry))
          ;; Durable removal succeeded.  Best-effort local/remote cleanup
          ;; must not resurrect an in-memory entry that is no longer on disk.
          (emacs-jupyter-notebook--async-delete-file
           (plist-get entry :local-connection-file))
          (ignore-errors (emacs-jupyter-notebook--cleanup-remote-entry entry))
          (setq emacs-jupyter-notebook--session-entry nil
                emacs-jupyter-notebook--tunnel-dead nil)
          (setq emacs-jupyter-notebook--execution-ledger nil
                emacs-jupyter-notebook--execution-queue nil
                emacs-jupyter-notebook--execution-active-id nil)
          (emacs-jupyter-notebook--async-put context :phase 'done)
          (force-mode-line-update t))
      (error
       (setq emacs-jupyter-notebook--session-entry entry)
       (emacs-jupyter-notebook--async-put context :phase 'error)
       (emacs-jupyter-notebook--log-append
        'shutdown "kernel stopped but registry removal failed: %s"
        (error-message-string err))))))

;;;###autoload
(defun emacs-jupyter-notebook-shutdown-kernel (&optional force)
  "Confirm helper shutdown before removing local durable state.
W6.4: when called interactively, ask for confirmation via `y-or-n-p';
a \\[universal-argument] FORCE prefix skips the prompt."
  (interactive "P")
  (emacs-jupyter-notebook--ensure-no-async-operation)
  (when (emacs-jupyter-notebook--confirm
         (called-interactively-p 'any) force
         "Shut down the remote kernel (this terminates it)? ")
    (let* ((client (emacs-jupyter-notebook--ensure-helper-lifecycle-client))
           (entry emacs-jupyter-notebook--session-entry))
      (unless entry (user-error "No durable kernel session is attached"))
      (when emacs-jupyter-notebook--execution-setup-pending
        (user-error "Kernel setup or restart is already in progress"))
      (let ((epoch (emacs-jupyter-notebook--execution-open-restart-gate client))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'shutdown :entry entry :session-id (plist-get entry :session-id)
                      :origin-buffer (current-buffer) :restart-client client)))
        (setq context (plist-put context :restart-epoch epoch))
        (setq context
              (plist-put context :error-callback
                         (lambda (failed-context reason)
                           (emacs-jupyter-notebook--shutdown-failed
                            failed-context client epoch reason))))
        (setq emacs-jupyter-notebook--async-context context)
        (setq context
              (emacs-jupyter-notebook--async-arm-overall-timeout context))
        (ignore-errors (emacs-jupyter-notebook--heartbeat-cancel))
        (condition-case err
            (emacs-jupyter-notebook-backend-control
             client 'shutdown nil
             (lambda (&rest _)
               (emacs-jupyter-notebook--shutdown-confirmed context client epoch entry))
             (lambda (_id reason)
               (when (emacs-jupyter-notebook--lifecycle-context-live-p
                      context client epoch)
                 (emacs-jupyter-notebook--async-fail context reason))))
          (error
           (emacs-jupyter-notebook--async-fail
            context (error-message-string err))))))))

(defun emacs-jupyter-notebook-retry-fresh-kernel (&optional force-or-profile)
  "Cancel/cleanup current state and start a fresh kernel.
FORCE-OR-PROFILE is the raw prefix arg when called interactively (so a
\\[universal-argument] FORCE prefix skips the confirmation prompt).  A
Lisp caller passing a string is treated as the profile name to start.

W6.4: when called interactively, ask `y-or-n-p' before destroying the
current session and starting fresh; a \\[universal-argument] FORCE prefix
skips the prompt.  Unlike buffer kill / mode disable, this command is an
explicit ROADMAP W6.4 kernel terminator: `--cleanup-current-state' kills
only the identity-validated registered PID (or the verified replacement
candidate from an interrupted restart), removes its registry entry, and then
launches the replacement.  It never sends an in-band helper shutdown or uses
broad process matching."
  (interactive "P")
  (let* ((profile-name (and (stringp force-or-profile) force-or-profile))
         (force (and (not profile-name) force-or-profile))
         (entry emacs-jupyter-notebook--session-entry)
         (context emacs-jupyter-notebook--async-context)
         (candidate (and context (plist-get context :candidate-remote-pid)))
         (cleanup-entry
          (if (and candidate (plist-get context :entry))
              (plist-put (copy-sequence (plist-get context :entry))
                         :remote-pid candidate)
            entry))
         (profile (or profile-name
                      (plist-get entry :profile)
                      (plist-get (plist-get context :profile) :profile)
                      emacs-jupyter-notebook-default-profile)))
    (when (emacs-jupyter-notebook--confirm
           (called-interactively-p 'any) force
           "Discard current session and start a fresh kernel? ")
      (emacs-jupyter-notebook--cleanup-current-state
       "Retrying with fresh kernel" cleanup-entry)
      (emacs-jupyter-notebook-start-remote-kernel profile))))

(defconst emacs-jupyter-notebook--status-buffer-name
  "*emacs-jupyter-notebook status*"
  "Name of the W6.5 live status buffer.")

(defvar emacs-jupyter-notebook--status-refresh-interval 1.0
  "Seconds between live refreshes of the status buffer while visible.")

(defvar-local emacs-jupyter-notebook--status-source-buffer nil
  "Buffer-local pointer to the originating source buffer.
Set by `emacs-jupyter-notebook-status' inside the status buffer so the
live-refresh timer and the action buttons know which buffer's engine they
are reflecting.")

(defvar-local emacs-jupyter-notebook--status-refresh-timer nil
  "Buffer-local refresh timer for the status buffer.")

(defvar-local emacs-jupyter-notebook--status-suggestion-actions nil
  "Buffer-local alist of (LABEL . COMMAND) for clickable suggestions.
Populated by `--status-render'.  Buttons inserted on suggestion lines
look up their command by index in this list.")

(define-derived-mode emacs-jupyter-notebook-status-mode special-mode
  "EJN-Status"
  "Major mode for the EJN live status buffer.
Each refresh re-renders the current engine snapshot; suggested actions
are clickable buttons that switch to the originating source buffer and
invoke the suggested command there."
  (setq buffer-read-only t
        truncate-lines nil)
  (add-hook 'kill-buffer-hook
            #'emacs-jupyter-notebook--status-cancel-refresh nil t))

(defun emacs-jupyter-notebook--status-cancel-refresh ()
  "Cancel the buffer-local status refresh timer if any."
  (when (timerp emacs-jupyter-notebook--status-refresh-timer)
    (cancel-timer emacs-jupyter-notebook--status-refresh-timer))
  (setq emacs-jupyter-notebook--status-refresh-timer nil))

(defun emacs-jupyter-notebook--status-suggestions-for (snapshot)
  "Return a list of `(LABEL . COMMAND)' cons cells for SNAPSHOT.
Each entry corresponds to a suggested next action.  COMMAND is the
interactive function symbol to invoke when the action is chosen; LABEL is
the human-readable string shown in the status buffer."
  (let ((recovery-active (or (plist-get snapshot :async-live)
                             (plist-get snapshot :retry-scheduled)))
        actions)
    (unless (or (plist-get snapshot :client) recovery-active)
      (push (cons "Start a remote kernel"
                  'emacs-jupyter-notebook-start-remote-kernel)
            actions)
      (push (cons "Reconnect to an existing remote kernel"
                  'emacs-jupyter-notebook-reconnect-remote-kernel)
            actions))
    (when (and (plist-get snapshot :client)
               (memq (plist-get snapshot :tunnel-state) '(dead exited))
               (not recovery-active))
      (push (cons "Reconnect to the remote kernel"
                  'emacs-jupyter-notebook-reconnect-remote-kernel)
            actions))
    (when (plist-get snapshot :async-live)
      (push (cons (if (plist-get snapshot :reconnect-owner)
                      "Cancel reconnect"
                    "Cancel connection attempt")
                  'emacs-jupyter-notebook-cancel-operation)
            actions))
    (when (and (plist-get snapshot :retry-scheduled)
               (not (plist-get snapshot :async-live)))
      (push (cons "Cancel scheduled reconnect"
                  'emacs-jupyter-notebook-cancel-operation)
            actions))
    (when (plist-get snapshot :management-label)
      (push (cons "Cancel the management operation"
                  'emacs-jupyter-notebook-cancel-operation)
            actions))
    (when (and (plist-get snapshot :client)
               (not (memq (plist-get snapshot :tunnel-state) '(dead exited)))
               (not (plist-get snapshot :async-live)))
      (push (cons "Send the current cell"
                  'emacs-jupyter-notebook-send-cell)
            actions))
    (nreverse actions)))

(defun emacs-jupyter-notebook--status-snapshot-text (snapshot)
  "Return only the descriptive lines of SNAPSHOT (no suggestions)."
  (string-join
   (list
    (format "Buffer: %s" (plist-get snapshot :buffer))
    (format "File: %s" (or (plist-get snapshot :file) "none"))
    (format "Profile: %s" (or (plist-get snapshot :profile) "none"))
    (format "Session: %s" (or (plist-get snapshot :session-id) "none"))
    (format "Client: %s" (if (plist-get snapshot :client) "connected" "none"))
    (format "Kernel status: %s" (or (plist-get snapshot :kernel-status) "unknown"))
    (format "Tunnel: %s" (plist-get snapshot :tunnel-state))
    (format "Live phase: %s" (or (plist-get snapshot :async-phase) "none"))
    (format "Attempt owner: %s"
            (or (plist-get snapshot :reconnect-owner) "none"))
    (format "Attempt age: %s"
            (if-let* ((age (plist-get snapshot :async-age)))
                (format "%.1fs" age)
              "none"))
    (format "Retry count: %d" (or (plist-get snapshot :retry-count) 0))
    (format "Next retry: %s"
            (if-let* ((delay (plist-get snapshot :reconnect-next-in)))
                (format "%.1fs" delay)
              "none"))
    (format "Management: %s"
            (if-let* ((label (plist-get snapshot :management-label)))
                (format "%s (%.1fs; cancel with C-c j x)" label
                        (or (plist-get snapshot :management-age) 0.0))
              "none"))
    (format "Async error: %s" (or (plist-get snapshot :async-error) "none"))
    (format "Remote host: %s" (or (plist-get snapshot :remote-host) "unknown"))
    (format "Remote PID: %s" (or (plist-get snapshot :remote-pid) "unknown"))
    (format "Remote connection: %s"
            (or (plist-get snapshot :remote-connection-file) "none"))
    (format "Local connection: %s"
            (or (plist-get snapshot :local-connection-file) "none"))
    (format "Tunnel ports: %S" (plist-get snapshot :tunnel-ports)))
   "\n"))

(defun emacs-jupyter-notebook--status-suggestion-button-action (button)
  "Activate suggested action carried by BUTTON.
Switches back to the originating source buffer (recorded on the status
buffer) and invokes the action's command there via `call-interactively'."
  (let* ((source (button-get button 'ejn-source-buffer))
         (command (button-get button 'ejn-action)))
    (cond
     ((not (buffer-live-p source))
      (message "emacs-jupyter-notebook: originating buffer no longer alive"))
     ((not (commandp command))
      (message "emacs-jupyter-notebook: invalid suggested command %s" command))
     (t
      (pop-to-buffer source)
      (call-interactively command)))))

(defun emacs-jupyter-notebook--status-render (status-buffer source-buffer)
  "Render STATUS-BUFFER with the current engine snapshot of SOURCE-BUFFER."
  (require 'button)
  (when (buffer-live-p source-buffer)
    (let* ((snapshot (with-current-buffer source-buffer
                       (emacs-jupyter-notebook-status-snapshot)))
           (actions (emacs-jupyter-notebook--status-suggestions-for snapshot)))
      (with-current-buffer status-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (emacs-jupyter-notebook--status-snapshot-text snapshot))
          (insert "\n\nSuggested actions:\n")
          (if (null actions)
              (insert "  (engine looks healthy)\n")
            (dolist (action actions)
              (insert "  ")
              (insert-text-button
               (car action)
               'follow-link t
               'help-echo (format "Run M-x %s" (cdr action))
               'action #'emacs-jupyter-notebook--status-suggestion-button-action
               'ejn-source-buffer source-buffer
               'ejn-action (cdr action))
              (insert "\n"))))
        (setq emacs-jupyter-notebook--status-source-buffer source-buffer
              emacs-jupyter-notebook--status-suggestion-actions actions)
        (goto-char (point-min))))))

(defun emacs-jupyter-notebook--status-tick ()
  "Refresh-tick body for the status buffer's live timer.
Re-renders the snapshot if the status buffer is visible; otherwise
cancels the timer so an off-screen status buffer doesn't keep ticking.
W6.10: also cancels the timer when the originating source buffer is no
longer live — without this the timer would fire forever after the
source buffer was killed."
  (let* ((status-buffer (get-buffer emacs-jupyter-notebook--status-buffer-name))
         (source (and (buffer-live-p status-buffer)
                      (buffer-local-value
                       'emacs-jupyter-notebook--status-source-buffer
                       status-buffer))))
    (cond
     ((not (buffer-live-p status-buffer)) nil)
     ((not (buffer-live-p source))
      (with-current-buffer status-buffer
        (emacs-jupyter-notebook--status-cancel-refresh)))
     ((not (get-buffer-window status-buffer 'visible))
      (with-current-buffer status-buffer
        (emacs-jupyter-notebook--status-cancel-refresh)))
     (t
      (emacs-jupyter-notebook--status-render status-buffer source)))))

;;;###autoload
(defun emacs-jupyter-notebook-status ()
  "Render the current buffer's engine state in `*emacs-jupyter-notebook status*'.
W6.5: the status buffer is a `special-mode' derivative.  While the
buffer is visible, the content is re-rendered every
`emacs-jupyter-notebook--status-refresh-interval' seconds; the timer is
cancelled when the buffer is buried or killed.  Suggested actions are
clickable buttons that switch back to the originating source buffer and
invoke the relevant command.

When called from Lisp (non-interactively) the function returns the
rendered text instead of displaying a buffer."
  (interactive)
  (if (not (called-interactively-p 'any))
      (emacs-jupyter-notebook--status-snapshot-text
       (emacs-jupyter-notebook-status-snapshot))
    (let ((source (current-buffer))
          (status (get-buffer-create emacs-jupyter-notebook--status-buffer-name)))
      (with-current-buffer status
        (unless (derived-mode-p 'emacs-jupyter-notebook-status-mode)
          (emacs-jupyter-notebook-status-mode)))
      (emacs-jupyter-notebook--status-render status source)
      (display-buffer status)
      (with-current-buffer status
        (emacs-jupyter-notebook--status-cancel-refresh)
        (setq emacs-jupyter-notebook--status-refresh-timer
              (run-with-timer
               emacs-jupyter-notebook--status-refresh-interval
               emacs-jupyter-notebook--status-refresh-interval
               #'emacs-jupyter-notebook--status-tick)))
      status)))

(defconst emacs-jupyter-notebook--log-buffer-name
  "*emacs-jupyter-notebook log*"
  "Name of the W6.6 append-only async log buffer.")

(defun emacs-jupyter-notebook--log-buffer-ensure ()
  "Return the W6.6 log buffer, creating it in `special-mode' if needed."
  (let ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name)))
    (unless buf
      (setq buf (get-buffer-create emacs-jupyter-notebook--log-buffer-name))
      (with-current-buffer buf
        (special-mode)
        (setq-local truncate-lines nil
                    buffer-read-only t)))
    buf))

(defun emacs-jupyter-notebook--log-truncate ()
  "Trim the W6.6 log buffer to `emacs-jupyter-notebook-log-max-lines'.
Called by `--log-append' after every append.  Trims by deleting the
oldest lines (those at the top of the buffer) until the line count is at
most the configured maximum."
  (let* ((max (max 0 (or emacs-jupyter-notebook-log-max-lines 2000)))
         (total (count-lines (point-min) (point-max))))
    (when (> total max)
      (let ((to-delete (- total max))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (forward-line to-delete)
          (delete-region (point-min) (point)))))))

(defun emacs-jupyter-notebook--log-append (phase format-string &rest args)
  "Append a single timestamped entry to the W6.6 log buffer.
PHASE is a short phase symbol or string (`launch', `retrieve',
`heartbeat-miss', etc.).  FORMAT-STRING is the human-readable message;
remaining ARGS are spliced via `format'.  The line shape is:

  ISO-TIMESTAMP  <buffer-name>  [PHASE]  MESSAGE

After each append the buffer is truncated to
`emacs-jupyter-notebook-log-max-lines' lines (oldest dropped first)."
  (let* ((buf (emacs-jupyter-notebook--log-buffer-ensure))
         (msg (apply #'format format-string args))
         (origin (buffer-name))
         (ts (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
         (line (format "%s  %s  [%s]  %s\n" ts origin
                       (if phase (format "%s" phase) "-")
                       msg)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (was-at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert line))
        (emacs-jupyter-notebook--log-truncate)
        (when was-at-end
          (goto-char (point-max)))))))

(defun emacs-jupyter-notebook-show-log-buffer ()
  "Show the global W6.6 async log buffer `*emacs-jupyter-notebook log*'."
  (interactive)
  (display-buffer (emacs-jupyter-notebook--log-buffer-ensure)))

(defun emacs-jupyter-notebook-fetch-remote-log ()
  "Fetch and display the current session's remote kernel log."
  (interactive)
  (unless emacs-jupyter-notebook--session-entry
    (user-error "No active EJN session"))
  (let* ((entry emacs-jupyter-notebook--session-entry)
         (connection-file (plist-get entry :remote-connection-file)))
    (unless connection-file
      (user-error "Current EJN session has no remote connection file"))
    (emacs-jupyter-notebook--management-run
     "fetching remote log" "ejn-fetch-log"
     (emacs-jupyter-notebook-ssh-build-remote-cat-log
      (emacs-jupyter-notebook--entry-profile entry) connection-file)
     (lambda (output)
       (emacs-jupyter-notebook--display-command-output "*ejn-log*" output)
       (message "emacs-jupyter-notebook: remote log fetched"))
     (lambda (reason _stderr)
       (message "emacs-jupyter-notebook: remote log fetch %s" reason)))))

(defun emacs-jupyter-notebook-list-remote-processes (&optional profile-name)
  "List likely remote EJN kernel processes for PROFILE-NAME."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (emacs-jupyter-notebook--management-run
     "listing remote processes" "ejn-list-processes"
     (emacs-jupyter-notebook-ssh-build-remote-ps-command profile)
     (lambda (output)
       (emacs-jupyter-notebook--display-command-output
        "*ejn-remote-processes*" output)
       (message "emacs-jupyter-notebook: remote processes listed"))
     (lambda (reason _stderr)
       (message "emacs-jupyter-notebook: process listing %s" reason)))))

(defun emacs-jupyter-notebook-prune-dead-kernels ()
  "Prune registry entries whose remote kernel is confirmed DEAD.  W11(B).
NON-DESTRUCTIVE: this NEVER terminates a running kernel.  It loads the
durable registry, probes liveness one ssh per host (bounded — an
unreachable host is treated as UNKNOWN and left alone), removes only the
entries whose PID a host positively reported gone, and messages a summary.

This only tidies the local registry.  For the destructive per-profile
remote nuke (kill every kernel in a profile's cache dir and delete its
files) see `emacs-jupyter-notebook-clean-orphaned-kernels'."
  (interactive)
  (let ((entries (emacs-jupyter-notebook-registry-load)))
    (if (not entries)
        (message "emacs-jupyter-notebook: registry is empty; nothing to prune")
      (let ((token (emacs-jupyter-notebook--management-begin
                    "checking registered kernels for pruning")))
        (emacs-jupyter-notebook--classify-registry-liveness-async
         entries token
         (lambda (classification reason)
           (emacs-jupyter-notebook--management-finish token)
           (if (eq reason 'cancelled)
               (message "emacs-jupyter-notebook: registry prune cancelled")
             (let* ((result
                     (emacs-jupyter-notebook--registry-liveness-result
                      entries classification))
                    (pruned (plist-get result :pruned))
                    (alive (plist-get result :alive))
                    (unknown (plist-get result :unknown)))
               (when (> pruned 0)
                 (emacs-jupyter-notebook-registry-save
                  (plist-get result :kept-entries)))
               (message
                "emacs-jupyter-notebook: pruned %d dead kernel entr%s; %d live remain%s"
                pruned (if (= pruned 1) "y" "ies") alive
                (if (> unknown 0)
                    (format " (%d unverified)" unknown)
                  ""))))))))))

(defun emacs-jupyter-notebook-clean-orphaned-kernels (&optional profile-name force)
  "Clean all EJN kernel files and processes in PROFILE-NAME's remote cache.
W6.4: when called interactively, ask `y-or-n-p' before issuing the
remote cleanup; a \\[universal-argument] FORCE prefix skips the prompt.
Lisp callers do not see the prompt and proceed unconditionally."
  (interactive (list (emacs-jupyter-notebook--read-profile-name)
                     current-prefix-arg))
  (let ((profile (emacs-jupyter-notebook--read-host-profile
                  (or profile-name emacs-jupyter-notebook-default-profile))))
    (when (emacs-jupyter-notebook--confirm
           (called-interactively-p 'any) force
           (format "Clean EJN kernels in %s on %s? "
                   (plist-get profile :remote-cache-dir)
                   (emacs-jupyter-notebook-ssh-destination profile)))
      (emacs-jupyter-notebook--management-run
       "cleaning remote orphaned kernels" "ejn-clean-orphans"
       (emacs-jupyter-notebook-ssh-build-remote-cleanup-all profile)
       (lambda (_output)
         (message "emacs-jupyter-notebook: requested remote orphan cleanup"))
       (lambda (reason _stderr)
         (message "emacs-jupyter-notebook: orphan cleanup %s" reason))))))

;;;###autoload
(defun emacs-jupyter-notebook-clear-results ()
  "Clear the source-side fringe indicators and the output panel contents."
  (interactive)
  (emacs-jupyter-notebook-fringe-clear-all)
  (let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (ejn-panel-clear-all panel)
        (emacs-jupyter-notebook-panel-flush-now panel)))))

(defun emacs-jupyter-notebook-cancel-operation ()
  "Cancel the current buffer's in-progress operation.

W5.3/IR4/IR5: four branches.
- If an asynchronous management command is running, cancel its local child and
  deadline.  This never changes the registry or sends a kernel termination.
- If an async context is in progress (launch / retrieve / tunnel /
  connect), cancel it via `--cancel-async-operation' — the evaluation
  branch is NOT taken because there is no live kernel to interrupt.  A
  start attempt (`:owns-kernel') also has the remote kernel it launched
  killed so it is not orphaned; a reconnect attempt leaves its
  pre-existing kernel alone.
- If an automatic reconnect is scheduled, cancel its owned timer and clear
  the advertised next-retry state.  A stale callback from that timer is
  generation-guarded and cannot start an attempt afterward.
- Otherwise, cancel the active execution record.  Queued entries are retired
  locally without a kernel interrupt; a dispatched entry is interrupted but
  remains active until correlated terminal evidence arrives.

If neither is in progress, signal a `user-error'."
  (interactive)
  (cond
   ((emacs-jupyter-notebook--management-active-p)
    (emacs-jupyter-notebook--cancel-management-operation))
   ;; W5.5: only treat the async branch as live when an actual phase is in
   ;; flight.  A successful connect leaves `--async-context' set at phase
   ;; `done', which previously caused cancel-during-evaluation to take the
   ;; wrong branch and never interrupt the kernel.
   ((emacs-jupyter-notebook--async-in-progress-p)
    (emacs-jupyter-notebook--cancel-async-operation
     emacs-jupyter-notebook--async-context "Operation cancelled"))
   ((or (timerp emacs-jupyter-notebook--reconnect-timer)
        emacs-jupyter-notebook--reconnect-schedule-token)
    (emacs-jupyter-notebook--cancel-auto-reconnect)
    (force-mode-line-update t)
    (message "emacs-jupyter-notebook: scheduled reconnect cancelled"))
   (emacs-jupyter-notebook--execution-active-id
    (emacs-jupyter-notebook--cancel-evaluation))
   (t
    (user-error "No emacs-jupyter-notebook operation is in progress"))))

(defun emacs-jupyter-notebook--cancel-queued-execution (id)
  "Retire queued execution ID locally; it has never reached the kernel."
  (let ((record (emacs-jupyter-notebook--execution-record id)))
    (when (and record (eq (plist-get record :state) 'queued))
      (emacs-jupyter-notebook--execution-finish record 'error nil "\ncancelled")
      t)))

;;;###autoload
(defun emacs-jupyter-notebook-cancel-queued-execution ()
  "Cancel the newest user request still waiting in this buffer's FIFO.
Queued work has not reached the remote kernel, so this command never sends an
interrupt.  `emacs-jupyter-notebook-cancel-operation' remains active-first."
  (interactive)
  (let ((id (car (last emacs-jupyter-notebook--execution-queue))))
    (unless (and id (emacs-jupyter-notebook--cancel-queued-execution id))
      (user-error "No queued emacs-jupyter-notebook execution"))
    (message "emacs-jupyter-notebook: cancelled queued execution")))

(defun emacs-jupyter-notebook--cancel-evaluation ()
  "Interrupt the active dispatched execution without admitting the next one."
  (let* ((id emacs-jupyter-notebook--execution-active-id)
         (record (and id (emacs-jupyter-notebook--execution-record id)))
         (client emacs-jupyter-notebook--client))
    (unless record (user-error "No emacs-jupyter-notebook evaluation is active"))
    (if (memq (plist-get record :state) '(queued checking))
        ;; Completeness/client acquisition has not admitted an execute request.
        ;; It has no kernel-side work to interrupt, so retire it locally and
        ;; let the FIFO advance.  Late acquisition/completeness callbacks are
        ;; guarded by the removed ledger id and are therefore inert.
        (if (eq (plist-get record :state) 'checking)
            (emacs-jupyter-notebook--execution-finish
             record 'error nil "\ncancelled")
          (emacs-jupyter-notebook--cancel-queued-execution id))
      (unless (eq (plist-get record :state) 'cancelling)
        (setq record (plist-put record :state 'cancelling))
        (emacs-jupyter-notebook--execution-put record)
        (when (ejn-panel-entry-live-p (plist-get record :panel-entry))
          (ejn-panel-append-text (plist-get record :panel-entry) "\ncancel requested"
                                 'emacs-jupyter-notebook-result-error-face))
        (unless (plist-get record :interrupt-sent)
          (setq record (plist-put record :interrupt-sent t))
          (emacs-jupyter-notebook--execution-put record)
          (when client
          (ignore-errors
            (emacs-jupyter-notebook-backend-control
             client 'interrupt nil #'ignore #'ignore))))))))

(defun emacs-jupyter-notebook-toggle-panel-view ()
  "Toggle the source buffer's output panel between latest and history views."
  (interactive)
  (let ((panel (or (emacs-jupyter-notebook-panel-buffer (current-buffer))
                   (ejn-panel-ensure (current-buffer)))))
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel-toggle-view))))

(defun emacs-jupyter-notebook--ensure-client ()
  "Return the current buffer's kernel client or signal an error."
  (or emacs-jupyter-notebook--client
      (error "No Jupyter kernel connected; run `emacs-jupyter-notebook-start-remote-kernel'")))

(provide 'emacs-jupyter-notebook)

;;; emacs-jupyter-notebook.el ends here
