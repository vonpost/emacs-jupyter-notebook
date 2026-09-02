;;; emacs-jupyter-notebook-viewer.el --- Local interactive matplotlib viewer manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; W8.3: manager for ONE persistent LOCAL Python process that renders remote
;; matplotlib figures interactively.  The remote kernel stays headless; the
;; figure travels as a helper-published pickle artifact (EI4V) which this
;; manager hands to the viewer over a unix domain socket by confined metadata.
;;
;; Lifecycle contract (the deliberate inverse of the remote-kernel rule):
;; - The viewer is Emacs-owned.  It is spawned lazily on first use, reused
;;   across figures, and REAPED on `kill-emacs-hook'.
;; - It also self-exits after an idle timeout (W8.4) so a hard Emacs crash
;;   cannot orphan it forever.
;; - Hand-off is asynchronous and bounded: at most one confined artifact
;;   descriptor is queued/in flight.  Connecting to the socket and writing the
;;   descriptor never blocks Emacs; if the socket is not yet bound the send
;;   retries on a timer.
;;
;; The actual spawn routes through `emacs-jupyter-notebook-viewer-spawn-function'
;; so ERTs can substitute a stub process + socket and exercise the full
;; lazy-spawn / reuse / hand-off / reap protocol without a real GUI.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

(declare-function emacs-jupyter-notebook--log-append
                  "emacs-jupyter-notebook" (phase format-string &rest args))

(defconst emacs-jupyter-notebook-viewer--load-file
  (or load-file-name buffer-file-name)
  "Path of this file at load time, used to locate the bundled viewer script.")

(defvar emacs-jupyter-notebook-viewer--process nil
  "The single persistent local viewer process, or nil.")

(defvar emacs-jupyter-notebook-viewer--socket-path nil
  "Unix-domain socket path the live viewer listens on, or nil.")

(defvar emacs-jupyter-notebook-viewer--socket-directory nil
  "Private 0700 directory containing the live viewer socket.")

(defvar emacs-jupyter-notebook-viewer--socket-directory-identity nil
  "Pinned identity of the private viewer socket directory.")

(defvar emacs-jupyter-notebook-viewer--next-request-id 0
  "Monotonic local request id for viewer acknowledgement correlation.")

(defvar emacs-jupyter-notebook-viewer--active-transaction nil
  "The single in-flight confined pickle hand-off state, or nil.")

(defconst emacs-jupyter-notebook-viewer--output-max-bytes (* 64 1024)
  "Hard byte limit for each persistent viewer output tail.

Viewer stdout and stderr are diagnostics only.  Keeping a bounded tail avoids
letting a noisy backend or executable pickle retain arbitrary process output in
the Emacs heap.")

(defvar emacs-jupyter-notebook-viewer--stdout-buffer nil
  "Bounded stdout tail buffer for the persistent viewer.")

(defvar emacs-jupyter-notebook-viewer--stderr-buffer nil
  "Bounded stderr tail buffer for the persistent viewer.")

(defvar emacs-jupyter-notebook-viewer--stderr-process nil
  "Pipe receiving stderr from the persistent viewer.")

(defvar emacs-jupyter-notebook-viewer-send-max-attempts 25
  "Maximum number of socket-connect attempts when handing a figure off.
The first connect can race the viewer's socket bind; each failed connect
reschedules on a timer, so the hand-off never blocks Emacs.  Invalid values
fall back to a finite default and values above the hard ceiling are clamped.")

(defvar emacs-jupyter-notebook-viewer-send-retry-delay 0.15
  "Seconds between socket-connect retries during an async figure hand-off.
Invalid values fall back to a finite default.  Valid values are clamped to a
small positive lower bound and a finite upper bound.")

(defconst emacs-jupyter-notebook-viewer--send-max-attempts-hard-limit 64
  "Absolute cap on attempts in one viewer hand-off transaction.")

(defconst emacs-jupyter-notebook-viewer--send-retry-delay-hard-limit 5.0
  "Absolute cap on the delay between viewer hand-off attempts.")

(defconst emacs-jupyter-notebook-viewer--send-transaction-timeout 30.0
  "Absolute lifetime of one viewer hand-off transaction in seconds.

This deadline is independent of the per-connection acknowledgement timer and
the retry budget.  It prevents a succession of pre-connect races from holding
the panel's artifact lease indefinitely.")

(defconst emacs-jupyter-notebook-viewer--send-ack-timeout 10.0
  "Maximum time to wait for one connected viewer acknowledgement.")

(defun emacs-jupyter-notebook-viewer--finite-positive-number-p (value)
  "Return non-nil when VALUE is a finite positive number."
  (and (numberp value) (> value 0)
       (or (not (floatp value))
           (and (not (isnan value)) (< (abs value) 1.0e+INF)))))

(defun emacs-jupyter-notebook-viewer--effective-send-max-attempts ()
  "Return the immutable bounded viewer hand-off attempt count."
  (let ((value emacs-jupyter-notebook-viewer-send-max-attempts))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook-viewer--send-max-attempts-hard-limit)
      25)))

(defun emacs-jupyter-notebook-viewer--effective-send-retry-delay ()
  "Return a finite, non-spinning retry delay for viewer hand-offs."
  (let ((value emacs-jupyter-notebook-viewer-send-retry-delay))
    (if (emacs-jupyter-notebook-viewer--finite-positive-number-p value)
        (min emacs-jupyter-notebook-viewer--send-retry-delay-hard-limit
             (max 0.025 value))
      0.15)))

(defvar emacs-jupyter-notebook-viewer-spawn-function
  #'emacs-jupyter-notebook-viewer--spawn
  "Function called with SOCKET-PATH to spawn the persistent viewer process.
Must return a live process object.  Substituted in tests with a stub that
creates a real unix-socket server and a placeholder process.")

;;; Logging

(defun emacs-jupyter-notebook-viewer--log (format-string &rest args)
  "Append a `viewer'-phase line to the W6 log buffer when available."
  (when (fboundp 'emacs-jupyter-notebook--log-append)
    (apply #'emacs-jupyter-notebook--log-append 'viewer format-string args)))

;;; Script + Python resolution

(defun emacs-jupyter-notebook-viewer--script-path ()
  "Return the absolute path to the bundled `viewer/ejn_viewer.py', or nil.
Looks for `viewer/ejn_viewer.py' beside this file AND beside the symlink
target of its `.el' source.  Package managers such as straight.el load a
byte-compiled `.elc' from a build directory into which only the `.el' files
are symlinked — the `viewer/' Python tree exists only in the source repo.
Following the `.el' symlink via `file-truename' reaches that repo, so the
viewer is found whether the package is a plain local checkout or a
straight/elpa build."
  (let* ((base (or emacs-jupyter-notebook-viewer--load-file
                   (locate-library "emacs-jupyter-notebook-viewer")))
         (dirs
          (when base
            (let ((el (concat (file-name-sans-extension base) ".el")))
              (delq nil
                    (list (file-name-directory base)
                          (file-name-directory (file-truename base))
                          (and (file-exists-p el)
                               (file-name-directory (file-truename el)))))))))
    (cl-loop for dir in (delete-dups dirs)
             for path = (expand-file-name "viewer/ejn_viewer.py" dir)
             when (file-exists-p path) return path)))

(defun emacs-jupyter-notebook-viewer--python-path (command)
  "Resolve COMMAND to an executable path, or nil when not found."
  (cond
   ((null command) nil)
   ((and (file-name-absolute-p command) (file-executable-p command)) command)
   (t (executable-find command))))

;;; Spawn / ensure / reap

(defun emacs-jupyter-notebook-viewer--output-filter (process text)
  "Append TEXT to PROCESS's bounded diagnostic tail.
The process uses binary coding, so `length' is an exact byte count and the
filter can trim without constructing a copy proportional to prior output."
  (let ((buffer (process-get process 'emacs-jupyter-notebook-viewer-output-buffer)))
    (when (and (buffer-live-p buffer) (stringp text))
      (let* ((limit emacs-jupyter-notebook-viewer--output-max-bytes)
             (text (if (> (length text) limit)
                       (substring text (- (length text) limit))
                     text))
             (old-bytes (or (process-get process
                                         'emacs-jupyter-notebook-viewer-output-bytes)
                            0))
             (new-bytes (length text))
             (drop (max 0 (+ old-bytes new-bytes (- limit)))))
        (with-current-buffer buffer
          (set-buffer-multibyte nil)
          (goto-char (point-max))
          (insert text)
          (when (> drop 0)
            (delete-region (point-min) (+ (point-min) drop))))
        (process-put process 'emacs-jupyter-notebook-viewer-output-bytes
                     (- (+ old-bytes new-bytes) drop))))))

(defun emacs-jupyter-notebook-viewer--dispose-output-buffers (&optional process)
  "Dispose viewer diagnostic pipes and their bounded tail buffers.
When PROCESS is supplied, prefer the resources attached to that process;
otherwise use the manager's current resources."
  (let* ((current-p (or (null process)
                        (eq process emacs-jupyter-notebook-viewer--process)))
         (stdout (or (and (processp process)
                          (process-get process
                                       'emacs-jupyter-notebook-viewer-output-buffer))
                     (and current-p
                          emacs-jupyter-notebook-viewer--stdout-buffer)))
         (stderr (or (and (processp process)
                          (process-get process
                                       'emacs-jupyter-notebook-viewer-stderr-buffer))
                     (and current-p
                          emacs-jupyter-notebook-viewer--stderr-buffer)))
         (stderr-process
          (or (and (processp process)
                   (process-get process
                                'emacs-jupyter-notebook-viewer-stderr-process))
              (and current-p
                   emacs-jupyter-notebook-viewer--stderr-process))))
    (when (processp stderr-process)
      (process-put stderr-process
                   'emacs-jupyter-notebook-viewer-output-buffer nil)
      (ignore-errors
        (when (process-live-p stderr-process)
          (delete-process stderr-process))))
    (when (buffer-live-p stdout)
      (kill-buffer stdout))
    (when (buffer-live-p stderr)
      (kill-buffer stderr))
    (when current-p
      (setq emacs-jupyter-notebook-viewer--stdout-buffer nil
            emacs-jupyter-notebook-viewer--stderr-buffer nil
            emacs-jupyter-notebook-viewer--stderr-process nil))))

(defun emacs-jupyter-notebook-viewer--spawn (socket-path)
  "Spawn the persistent local viewer process listening on SOCKET-PATH.
Signals a plain `error' when the local Python or the bundled viewer script
cannot be found; the command surface (W8.5) converts these into friendly
`user-error's.  The process is `:noquery' so it never blocks Emacs exit and
is reaped explicitly on `kill-emacs-hook'."
  (let* ((command emacs-jupyter-notebook-local-python-command)
         (python (emacs-jupyter-notebook-viewer--python-path command))
         (script (emacs-jupyter-notebook-viewer--script-path))
         (backend (symbol-name (or emacs-jupyter-notebook-viewer-backend 'tk)))
         (idle (number-to-string
                (max 0 (or emacs-jupyter-notebook-viewer-idle-timeout 900)))))
    (unless python
      (error "Local Python command %S not found on `exec-path'" command))
    (unless script
      (error "Viewer script not found (expected viewer/ejn_viewer.py beside the package)"))
    ;; Log the exact command BEFORE launch so the log shows what ran even if
    ;; the process aborts immediately (e.g. a GUI-backend failure).
    (emacs-jupyter-notebook-viewer--log
     "starting viewer: %s -u %s --backend %s --socket %s"
     python script backend socket-path)
    ;; Keep both streams in bounded tails.  A pipe is used for stderr so it
    ;; can share the same filter as stdout; ordinary `:buffer' destinations
    ;; have no size limit.
    (let* ((stdout (generate-new-buffer " *emacs-jupyter-notebook-viewer*"))
           (stderr (generate-new-buffer " *emacs-jupyter-notebook-viewer-stderr*"))
           (stderr-process nil)
           (process nil)
           (setup-complete nil)
           (pending-terminal nil))
      (with-current-buffer stdout
        (erase-buffer)
        (set-buffer-multibyte nil))
      (with-current-buffer stderr
        (erase-buffer)
        (set-buffer-multibyte nil))
      (condition-case err
          (progn
            (setq stderr-process
                  (make-pipe-process
                   :name "emacs-jupyter-notebook-viewer-stderr"
                   :buffer nil :coding 'binary :noquery t
                   :filter #'emacs-jupyter-notebook-viewer--output-filter))
            (process-put stderr-process
                         'emacs-jupyter-notebook-viewer-output-buffer stderr)
            (process-put stderr-process
                         'emacs-jupyter-notebook-viewer-output-bytes 0)
            (setq process
                  (make-process
                   :name "emacs-jupyter-notebook-viewer"
                   :command (list python "-u" script
                                  "--socket" socket-path
                                  "--backend" backend
                                  "--idle-timeout" idle)
                   :noquery t
                   :connection-type 'pipe
                   :coding 'binary
                   :buffer nil
                   :stderr stderr-process
                   :filter #'emacs-jupyter-notebook-viewer--output-filter
                   ;; A process can terminate and call its sentinel while
                   ;; `make-process' is still returning.  Defer that terminal
                   ;; event until the resource properties below exist, then
                   ;; dispatch through the ordinary sentinel exactly once.
                   :sentinel
                   (lambda (proc event)
                     (if setup-complete
                         (emacs-jupyter-notebook-viewer--sentinel proc event)
                       (when (and (memq (process-status proc) '(exit signal))
                                  (not pending-terminal))
                         (setq pending-terminal (cons proc event)))))))
            (process-put process
                         'emacs-jupyter-notebook-viewer-output-buffer stdout)
            (process-put process
                         'emacs-jupyter-notebook-viewer-output-bytes 0)
            (process-put process
                         'emacs-jupyter-notebook-viewer-stderr-buffer stderr)
            (process-put process
                         'emacs-jupyter-notebook-viewer-stderr-process stderr-process)
            (process-put stderr-process
                         'emacs-jupyter-notebook-viewer-owner process)
            (setq setup-complete t)
            (cond
             (pending-terminal
              (emacs-jupyter-notebook-viewer--sentinel
               (car pending-terminal) (cdr pending-terminal))
              (error "Viewer process terminated during startup"))
             ((not (process-live-p process))
              ;; A terminal process may be observed before its sentinel is
              ;; delivered.  Route it through the same lifecycle cleanup.
              (emacs-jupyter-notebook-viewer--sentinel
               process "terminated during startup")
              (error "Viewer process terminated during startup")))
            process)
        (error
         (when (processp process)
           (ignore-errors
             (when (process-live-p process)
               (delete-process process))))
         (ignore-errors (delete-process stderr-process))
         (when (buffer-live-p stdout) (kill-buffer stdout))
         (when (buffer-live-p stderr) (kill-buffer stderr))
         (signal (car err) (cdr err)))))))

(defun emacs-jupyter-notebook-viewer--sentinel (proc event)
  "Sentinel for the viewer PROC: log EVENT (+ stderr tail) and clear state.
W8.7(b): the socket hand-off is fire-and-forget, so an abnormal viewer
exit (e.g. no working Qt/Tk backend, which exits 3) would otherwise be
silent.  Surface the exit code and the last stderr line as a user
message and in the log buffer."
  (when (memq (process-status proc) '(exit signal))
    (let* ((code (process-exit-status proc))
           (current-p (eq proc emacs-jupyter-notebook-viewer--process))
           (stderr (or (process-get proc
                                    'emacs-jupyter-notebook-viewer-stderr-buffer)
                       emacs-jupyter-notebook-viewer--stderr-buffer))
           (lines (and (buffer-live-p stderr)
                       (with-current-buffer stderr
                         (split-string
                          (string-trim
                           (buffer-substring-no-properties (point-min) (point-max)))
                          "\n" t))))
           ;; Log up to the last 8 non-empty stderr lines so a multi-line
           ;; failure (e.g. a Qt/Tk backend traceback) is visible, not just
           ;; its generic final sentence.
           (excerpt (when lines
                      (string-join (last lines 8) " | ")))
           (headline (when lines (car (last lines)))))
      (emacs-jupyter-notebook-viewer--log
       "viewer process exited (%s%s)%s"
       (string-trim (or event ""))
       (if (integerp code) (format ", code %d" code) "")
       (if excerpt (format "\n    stderr: %s" excerpt) ""))
      (when (and (integerp code) (not (zerop code)))
        (message "emacs-jupyter-notebook: figure viewer failed to start%s"
                 (if headline (format " — %s" headline) "")))
      (when current-p
        (when emacs-jupyter-notebook-viewer--active-transaction
          (emacs-jupyter-notebook-viewer--transaction-finish
           emacs-jupyter-notebook-viewer--active-transaction nil))
        ;; Dispose while the manager still points at PROC so its global
        ;; stdout/stderr resources are cleared as well as the attached ones.
        (emacs-jupyter-notebook-viewer--dispose-output-buffers proc)
        (setq emacs-jupyter-notebook-viewer--process nil)
        (emacs-jupyter-notebook-viewer--cleanup-socket-directory))
      ;; A stale process can signal after a replacement has already been
      ;; spawned.  Its streams still own buffers and must be disposed too.
      (unless current-p
        (emacs-jupyter-notebook-viewer--dispose-output-buffers proc)))))

(defun emacs-jupyter-notebook-viewer-live-p ()
  "Return non-nil when the persistent viewer process is live."
  (and (processp emacs-jupyter-notebook-viewer--process)
       (process-live-p emacs-jupyter-notebook-viewer--process)))

(defun emacs-jupyter-notebook-viewer--new-socket-path ()
  "Create a private socket directory and return its socket path."
  (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
  (setq emacs-jupyter-notebook-viewer--socket-directory
        (make-temp-file "ejn-viewer-" t))
  (set-file-modes emacs-jupyter-notebook-viewer--socket-directory #o700)
  (setq emacs-jupyter-notebook-viewer--socket-directory-identity
        (file-attribute-file-identifier
         (file-attributes emacs-jupyter-notebook-viewer--socket-directory 'integer)))
  (expand-file-name "socket" emacs-jupyter-notebook-viewer--socket-directory))

(defun emacs-jupyter-notebook-viewer--cleanup-socket-directory ()
  "Remove this manager's prior private socket directory exactly once."
  (when (and (stringp emacs-jupyter-notebook-viewer--socket-directory)
             (file-directory-p emacs-jupyter-notebook-viewer--socket-directory)
             (not (file-symlink-p emacs-jupyter-notebook-viewer--socket-directory))
             (let ((attrs (file-attributes emacs-jupyter-notebook-viewer--socket-directory 'integer)))
               (and attrs
                    (equal emacs-jupyter-notebook-viewer--socket-directory-identity
                           (file-attribute-file-identifier attrs))
                    (equal (file-attribute-user-id attrs) (user-uid))
                    (= (logand (file-modes emacs-jupyter-notebook-viewer--socket-directory) #o7777) #o700))))
    (let ((socket (expand-file-name "socket" emacs-jupyter-notebook-viewer--socket-directory)))
      (when (and (file-attributes socket 'integer) (not (file-symlink-p socket)))
        (ignore-errors (delete-file socket)))
      (ignore-errors (delete-directory emacs-jupyter-notebook-viewer--socket-directory))))
  (setq emacs-jupyter-notebook-viewer--socket-directory nil
        emacs-jupyter-notebook-viewer--socket-directory-identity nil))

(defun emacs-jupyter-notebook-viewer-ensure ()
  "Ensure the persistent viewer process is live and return it.
Lazily spawns on first use via `emacs-jupyter-notebook-viewer-spawn-function'
and installs the `kill-emacs-hook' reaper.  Reused on subsequent calls."
  (unless (emacs-jupyter-notebook-viewer-live-p)
    ;; A dead process can be observed before its sentinel runs.  Release only
    ;; resources attached to that generation before named buffers are reused.
    (when (processp emacs-jupyter-notebook-viewer--process)
      (emacs-jupyter-notebook-viewer--dispose-output-buffers
       emacs-jupyter-notebook-viewer--process)
      (setq emacs-jupyter-notebook-viewer--process nil))
    (let ((socket-path (emacs-jupyter-notebook-viewer--new-socket-path))
          (spawned nil))
      (setq emacs-jupyter-notebook-viewer--socket-path socket-path)
      (condition-case err
          (progn
            (setq spawned
                  (funcall emacs-jupyter-notebook-viewer-spawn-function socket-path))
            ;; Never publish a generation which exited during its constructor.
            ;; A later sentinel only gets manager ownership after this check.
            (unless (and (processp spawned) (process-live-p spawned))
              (when (processp spawned)
                (emacs-jupyter-notebook-viewer--dispose-output-buffers spawned))
              (error "Viewer process terminated during startup"))
            (setq emacs-jupyter-notebook-viewer--process spawned)
            (add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-viewer-reap)
            (emacs-jupyter-notebook-viewer--log
             "spawned local matplotlib viewer (socket %s)" socket-path))
        (error
         (when (processp spawned)
           (emacs-jupyter-notebook-viewer--dispose-output-buffers spawned)
           (ignore-errors
             (when (process-live-p spawned)
               (delete-process spawned))))
         (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
         (setq emacs-jupyter-notebook-viewer--process nil
               emacs-jupyter-notebook-viewer--socket-path nil)
         (signal (car err) (cdr err))))))
  emacs-jupyter-notebook-viewer--process)

(defun emacs-jupyter-notebook-viewer-reap ()
  "Kill the local viewer process and remove its socket file.
Installed on `kill-emacs-hook'.  Safe to call repeatedly."
  (when emacs-jupyter-notebook-viewer--active-transaction
    (emacs-jupyter-notebook-viewer--transaction-finish
     emacs-jupyter-notebook-viewer--active-transaction nil))
  (when (processp emacs-jupyter-notebook-viewer--process)
    (ignore-errors
      (when (process-live-p emacs-jupyter-notebook-viewer--process)
        (delete-process emacs-jupyter-notebook-viewer--process))))
  (emacs-jupyter-notebook-viewer--dispose-output-buffers
   emacs-jupyter-notebook-viewer--process)
  (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
  (setq emacs-jupyter-notebook-viewer--process nil
        emacs-jupyter-notebook-viewer--socket-path nil)
  (remove-hook 'kill-emacs-hook #'emacs-jupyter-notebook-viewer-reap))

;;; Async figure hand-off

(defun emacs-jupyter-notebook-viewer--stderr-tail (&optional n)
  "Return the last N (default 5) non-empty viewer stderr lines, or nil."
  (let ((stderr emacs-jupyter-notebook-viewer--stderr-buffer))
    (when (buffer-live-p stderr)
      (with-current-buffer stderr
        (let ((lines (split-string
                      (string-trim
                       (buffer-substring-no-properties (point-min) (point-max)))
                      "\n" t)))
          (when lines
            (string-join (last lines (or n 5)) "\n    ")))))))

(defun emacs-jupyter-notebook-viewer--parse-ack (line request-id)
  "Return `(matched . ACCEPTED)' for one bounded viewer ACK, else nil."
  (condition-case nil
      (let ((ack (json-parse-string line :object-type 'alist
                                    :false-object :ejn-false)))
        (when (and (= (length ack) 2)
                   (assoc 'id ack) (assoc 'accepted ack)
                   (stringp (alist-get 'id ack))
                   (memq (alist-get 'accepted ack) '(t :ejn-false))
                   (equal (alist-get 'id ack) request-id))
          (cons t (eq (alist-get 'accepted ack) t))))
    (error nil)))

(defun emacs-jupyter-notebook-viewer--wire-file-identity (value)
  "Return Emacs file identity VALUE as protocol `[device, inode]' order.
`file-attribute-file-identifier' returns `(inode . device)' (printed as a
two-element proper list on some Emacs versions).  Python's `os.stat' exposes
  the same values as `st_dev' then `st_ino', which is the viewer wire contract."
  (let ((inode (car-safe value))
        (device (cond
                 ((and (consp value) (consp (cdr value))
                       (null (cddr value)))
                  (cadr value))
                 ((and (consp value) (integerp (cdr value)))
                  (cdr value)))))
    (unless (and (integerp inode) (integerp device))
      (error "invalid file identity"))
    (list device inode)))

(defun emacs-jupyter-notebook-viewer--transaction-live-p (state token)
  "Return non-nil when STATE still owns callback TOKEN."
  (and (not (plist-get state :done))
       (= token (plist-get state :token))))

(defun emacs-jupyter-notebook-viewer--transaction-retire-attempt (state)
  "Make all current STATE callbacks inert and release their local resources."
  (plist-put state :token (1+ (plist-get state :token)))
  (when-let ((timer (plist-get state :timer)))
    (when (timerp timer) (cancel-timer timer)))
  (plist-put state :timer nil)
  (when-let ((conn (plist-get state :connection)))
    (plist-put state :connection nil)
    (ignore-errors (delete-process conn))))

(defun emacs-jupyter-notebook-viewer--transaction-cancel-deadline (state)
  "Cancel STATE's independent hand-off deadline timer, if any."
  (when-let ((timer (plist-get state :deadline-timer)))
    (when (timerp timer) (cancel-timer timer)))
  (plist-put state :deadline-timer nil))

(defun emacs-jupyter-notebook-viewer--transaction-install-timer
    (state slot seconds callback)
  "Install CALLBACK in STATE's SLOT after SECONDS without a setup race.
The normal timer API calls CALLBACK only after returning.  Keep the state
correct even when a test double or a future timer wrapper invokes CALLBACK
synchronously while `run-at-time' is constructing the timer: a replacement
timer installed by CALLBACK must not be overwritten by the stale return
value."
  (let ((pending (list 'emacs-jupyter-notebook-viewer-pending-timer
                       (gensym "ejn-viewer-timer-"))))
    (plist-put state slot pending)
    (condition-case err
        (let ((timer (run-at-time seconds nil callback)))
          (if (eq (plist-get state slot) pending)
              (plist-put state slot timer)
            ;; CALLBACK settled or replaced this slot before the timer factory
            ;; returned.  Do not leave the returned timer live.
            (when (timerp timer) (cancel-timer timer)))
          timer)
      (error
       ;; A failing timer factory must not strand a non-timer marker in state.
       (when (eq (plist-get state slot) pending)
         (plist-put state slot nil))
       (signal (car err) (cdr err))))))

(defun emacs-jupyter-notebook-viewer--transaction-arm-deadline (state)
  "Arm STATE's immutable total hand-off deadline and return STATE."
  (emacs-jupyter-notebook-viewer--transaction-install-timer
   state :deadline-timer emacs-jupyter-notebook-viewer--send-transaction-timeout
   (lambda ()
     ;; This timer owns the entire transaction, including time spent between
     ;; pre-connect retries.  Finishing retires every attempt token before
     ;; calling the completion, so late retry and ACK callbacks are inert.
     (unless (plist-get state :done)
       (emacs-jupyter-notebook-viewer--log
        "viewer hand-off exceeded the %gs transaction deadline"
        emacs-jupyter-notebook-viewer--send-transaction-timeout)
       (emacs-jupyter-notebook-viewer--transaction-finish state nil))))
  state)

(defun emacs-jupyter-notebook-viewer--transaction-finish (state accepted)
  "Complete STATE once, releasing every local connection and timer."
  (unless (plist-get state :done)
    (plist-put state :done t)
    (emacs-jupyter-notebook-viewer--transaction-retire-attempt state)
    (emacs-jupyter-notebook-viewer--transaction-cancel-deadline state)
    (when (eq state emacs-jupyter-notebook-viewer--active-transaction)
      (setq emacs-jupyter-notebook-viewer--active-transaction nil))
    (funcall (plist-get state :completion) accepted)))

(defun emacs-jupyter-notebook-viewer--send-pickle-attempt (state)
  "Start STATE's current bounded confined-pickle hand-off attempt.
W8.7(c): if the viewer is not live, respawn it (which allocates a fresh
socket path) before connecting; retry bounded pre-connect failures.  Once a
socket client has been created, delivery is ambiguous, so a send error fails
that hand-off without replaying it.  W8.7(e): the one-shot connection process
is disposed via a sentinel once it closes.

W16: a viewer that is ALIVE but whose socket never appears is wedged (a
GUI backend that hangs instead of exiting — seen with macOS Tk).  The old
loop retried the same never-appearing socket to exhaustion and buried the
reason in the log.  Now: halfway through the attempt budget a live viewer
with no bound socket is killed and respawned fresh, and exhaustion raises
a user-visible `message' carrying the viewer's stderr tail so the cause is
readable without hunting for the log buffer."
  ;; Timer callbacks normally check their token before calling us, but this
  ;; guard also makes a manually invoked stale callback harmless.
  (when (plist-get state :done)
    (cl-return-from emacs-jupyter-notebook-viewer--send-pickle-attempt nil))
  (let* ((pickle (plist-get state :pickle))
         (max-attempts
          (emacs-jupyter-notebook-viewer--effective-send-max-attempts))
         ;; `/' produced a non-integral threshold for odd budgets, so the
         ;; old restart path never ran with its default 25 attempts.
         (restart-attempt (max 2 (ceiling (/ max-attempts 2.0))))
         (attempt (1+ (plist-get state :attempt))))
    (plist-put state :attempt attempt)
    (unless (emacs-jupyter-notebook-viewer-live-p)
      (ignore-errors (emacs-jupyter-notebook-viewer-ensure)))
    ;; W16: wedged-viewer restart — alive, but never bound its socket.
    (when (and (= attempt restart-attempt)
               (emacs-jupyter-notebook-viewer-live-p)
               emacs-jupyter-notebook-viewer--socket-path
               (not (file-exists-p emacs-jupyter-notebook-viewer--socket-path)))
      (emacs-jupyter-notebook-viewer--log
       "viewer alive but socket never bound after %d attempts; restarting it"
       attempt)
      (ignore-errors (delete-process emacs-jupyter-notebook-viewer--process))
      (setq emacs-jupyter-notebook-viewer--process nil
            emacs-jupyter-notebook-viewer--socket-path nil)
      (ignore-errors (emacs-jupyter-notebook-viewer-ensure)))
    (let ((socket-path emacs-jupyter-notebook-viewer--socket-path))
      (if (null socket-path)
          (progn
            (emacs-jupyter-notebook-viewer--log "no viewer socket; dropping figure hand-off")
            (emacs-jupyter-notebook-viewer--transaction-finish state nil))
        (condition-case err
            (let ((conn (make-network-process
                       :name "emacs-jupyter-notebook-viewer-send"
                       :family 'local
                       :service socket-path
                       :nowait t
                       :coding 'utf-8
                       :noquery t)))
            (let* ((token (1+ (plist-get state :token)))
                   (request-id (format "v%d" (cl-incf emacs-jupyter-notebook-viewer--next-request-id))))
              (plist-put state :token token)
              (plist-put state :connection conn)
              (set-process-filter
               conn
               (lambda (p output)
                 (let ((buffer (concat (or (process-get p 'ejn-viewer-ack-buffer) "") output)))
                   (while (string-match "\n" buffer)
                     (let ((line (substring buffer 0 (match-beginning 0))))
                       (setq buffer (substring buffer (match-end 0)))
                       (when-let ((ack (and (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                                            (emacs-jupyter-notebook-viewer--parse-ack line request-id))))
                         (emacs-jupyter-notebook-viewer--transaction-finish state (cdr ack))
                         (ignore-errors (delete-process p)))))
                   (if (<= (string-bytes buffer) 1024)
                       (process-put p 'ejn-viewer-ack-buffer buffer)
                     ;; A peer that never terminates a frame cannot keep a
                     ;; panel lease alive until the deadline.
                     (process-put p 'ejn-viewer-ack-buffer nil)
                     (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                       (emacs-jupyter-notebook-viewer--transaction-finish state nil))
                     (ignore-errors (delete-process p))))))
              (set-process-sentinel
               conn
               (lambda (p _e)
                 (when (memq (process-status p) '(closed failed exit signal))
                   (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                     (emacs-jupyter-notebook-viewer--transaction-finish state nil))
                   (ignore-errors (delete-process p)))))
              (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                (emacs-jupyter-notebook-viewer--transaction-install-timer
                 state :timer emacs-jupyter-notebook-viewer--send-ack-timeout
                 (lambda ()
                   (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                     (emacs-jupyter-notebook-viewer--transaction-finish state nil)
                     (ignore-errors (delete-process conn)))))
                ;; A timer wrapper or a promptly closed socket may have settled
                ;; the transaction while the acknowledgement timer was created.
                ;; Never send a hand-off frame after that outcome.
                (when (and (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                           (eq (plist-get state :connection) conn))
                  (process-send-string
                   conn
                   (concat (json-encode
                            `((id . ,request-id)
                              (root . ,(plist-get pickle :root))
                              (path . ,(plist-get pickle :file))
                              (root_identity . ,(emacs-jupyter-notebook-viewer--wire-file-identity
                                                 (plist-get pickle :root-identity)))
                              (file_identity . ,(emacs-jupyter-notebook-viewer--wire-file-identity
                                                 (plist-get pickle :identity)))
                              (size . ,(plist-get pickle :size))
                              (sha256 . ,(plist-get pickle :sha256)))) "\n"))
                  (emacs-jupyter-notebook-viewer--log
                   "handed confined figure metadata to viewer (attempt %d)" attempt)))
              conn))
          (error
           (let ((connected (plist-get state :connection)))
             ;; After a connection object exists, `process-send-string' failure
             ;; is ambiguous: the viewer may have received the frame.  Do not
             ;; replay the request; fail it once and release the panel lease.
             (emacs-jupyter-notebook-viewer--transaction-retire-attempt state)
             (if connected
                 (progn
                   (emacs-jupyter-notebook-viewer--log
                    "viewer hand-off failed after connect: %s"
                    (error-message-string err))
                   (emacs-jupyter-notebook-viewer--transaction-finish state nil))
               (if (>= attempt max-attempts)
                   (let ((tail (emacs-jupyter-notebook-viewer--stderr-tail)))
                     (emacs-jupyter-notebook-viewer--log
                      "failed to reach viewer after %d attempts: %s%s"
                      attempt (error-message-string err)
                      (if tail (format "\n    viewer stderr: %s" tail) ""))
                     ;; W16: surface the failure — and WHY — to the user directly;
                     ;; the panel PNG is unaffected, only the interactive open failed.
                     (message
                      (concat "emacs-jupyter-notebook: could not reach the figure "
                              "viewer (%s)%s")
                      (error-message-string err)
                      (if tail (format "; viewer said: %s" tail) ""))
                     (emacs-jupyter-notebook-viewer--transaction-finish state nil))
                 ;; Invalidate a dead viewer so the next attempt respawns it.
                 (unless (emacs-jupyter-notebook-viewer-live-p)
                   (setq emacs-jupyter-notebook-viewer--process nil
                         emacs-jupyter-notebook-viewer--socket-path nil))
                 (let ((token (plist-get state :token)))
                   (emacs-jupyter-notebook-viewer--transaction-install-timer
                    state :timer
                    (emacs-jupyter-notebook-viewer--effective-send-retry-delay)
                    (lambda ()
                      (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                        (emacs-jupyter-notebook-viewer--send-pickle-attempt state))))))))))))))

(defun emacs-jupyter-notebook-viewer-open-pickle-file (pickle completion)
  "Hand confined PICKLE metadata to the viewer and call COMPLETION once.
COMPLETION receives non-nil only after the viewer has securely opened the
artifact, making it safe for the panel to release its deletion lease."
  (when (and emacs-jupyter-notebook-viewer--active-transaction
             (plist-get emacs-jupyter-notebook-viewer--active-transaction
                        :done))
    (setq emacs-jupyter-notebook-viewer--active-transaction nil))
  (if emacs-jupyter-notebook-viewer--active-transaction
      (funcall completion nil)
    (let ((state (list :pickle pickle :completion completion :attempt 0
                       :token 0 :timer nil :deadline-timer nil
                       :connection nil :done nil)))
      (setq emacs-jupyter-notebook-viewer--active-transaction state)
      ;; Start this before spawning so a failed or wedged local setup cannot
      ;; leave the panel's artifact lease open forever.
      (condition-case nil
          (progn
            (emacs-jupyter-notebook-viewer--transaction-arm-deadline state)
            (unless (plist-get state :done)
              (emacs-jupyter-notebook-viewer-ensure)
              (emacs-jupyter-notebook-viewer--send-pickle-attempt state)))
        (error
         (emacs-jupyter-notebook-viewer--transaction-finish state nil))))))

(provide 'emacs-jupyter-notebook-viewer)

;;; emacs-jupyter-notebook-viewer.el ends here
