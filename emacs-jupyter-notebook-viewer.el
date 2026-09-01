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

(defvar emacs-jupyter-notebook-viewer-send-max-attempts 25
  "Maximum number of socket-connect attempts when handing a figure off.
The first connect can race the viewer's socket bind; each failed connect
reschedules on a timer, so the hand-off never blocks Emacs.")

(defvar emacs-jupyter-notebook-viewer-send-retry-delay 0.15
  "Seconds between socket-connect retries during an async figure hand-off.")

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
    ;; Fresh stderr buffer per spawn so the sentinel reports THIS process's
    ;; output, not stale text from a prior failed launch.
    (let ((stderr (get-buffer-create " *emacs-jupyter-notebook-viewer-stderr*")))
      (with-current-buffer stderr (erase-buffer))
      (make-process
       :name "emacs-jupyter-notebook-viewer"
       :command (list python "-u" script
                      "--socket" socket-path
                      "--backend" backend
                      "--idle-timeout" idle)
       :noquery t
       :connection-type 'pipe
       :buffer (get-buffer-create " *emacs-jupyter-notebook-viewer*")
       :stderr stderr
       :sentinel #'emacs-jupyter-notebook-viewer--sentinel))))

(defun emacs-jupyter-notebook-viewer--sentinel (proc event)
  "Sentinel for the viewer PROC: log EVENT (+ stderr tail) and clear state.
W8.7(b): the socket hand-off is fire-and-forget, so an abnormal viewer
exit (e.g. no working Qt/Tk backend, which exits 3) would otherwise be
silent.  Surface the exit code and the last stderr line as a user
message and in the log buffer."
  (when (memq (process-status proc) '(exit signal))
    (let* ((code (process-exit-status proc))
           (stderr (get-buffer " *emacs-jupyter-notebook-viewer-stderr*"))
           (lines (and (buffer-live-p stderr)
                       (with-current-buffer stderr
                         (split-string (string-trim (buffer-string)) "\n" t))))
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
      (when (eq proc emacs-jupyter-notebook-viewer--process)
        (when emacs-jupyter-notebook-viewer--active-transaction
          (emacs-jupyter-notebook-viewer--transaction-finish
           emacs-jupyter-notebook-viewer--active-transaction nil))
        (setq emacs-jupyter-notebook-viewer--process nil)
        (emacs-jupyter-notebook-viewer--cleanup-socket-directory)))))

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
    (let ((socket-path (emacs-jupyter-notebook-viewer--new-socket-path)))
      (setq emacs-jupyter-notebook-viewer--socket-path socket-path)
      (setq emacs-jupyter-notebook-viewer--process
            (funcall emacs-jupyter-notebook-viewer-spawn-function socket-path))
      (add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-viewer-reap)
      (emacs-jupyter-notebook-viewer--log
       "spawned local matplotlib viewer (socket %s)" socket-path)))
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
  (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
  (setq emacs-jupyter-notebook-viewer--process nil
        emacs-jupyter-notebook-viewer--socket-path nil)
  (remove-hook 'kill-emacs-hook #'emacs-jupyter-notebook-viewer-reap))

;;; Async figure hand-off

(defun emacs-jupyter-notebook-viewer--stderr-tail (&optional n)
  "Return the last N (default 5) non-empty viewer stderr lines, or nil."
  (let ((stderr (get-buffer " *emacs-jupyter-notebook-viewer-stderr*")))
    (when (buffer-live-p stderr)
      (with-current-buffer stderr
        (let ((lines (split-string (string-trim (buffer-string)) "\n" t)))
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

(defun emacs-jupyter-notebook-viewer--transaction-finish (state accepted)
  "Complete STATE once, releasing every local connection and timer."
  (unless (plist-get state :done)
    (plist-put state :done t)
    (emacs-jupyter-notebook-viewer--transaction-retire-attempt state)
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
  (let* ((pickle (plist-get state :pickle))
         (attempt (1+ (plist-get state :attempt))))
    (plist-put state :attempt attempt)
    (unless (emacs-jupyter-notebook-viewer-live-p)
      (ignore-errors (emacs-jupyter-notebook-viewer-ensure)))
    ;; W16: wedged-viewer restart — alive, but never bound its socket.
    (when (and (= attempt (max 2 (/ emacs-jupyter-notebook-viewer-send-max-attempts 2)))
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
              (plist-put state :timer
                         (run-at-time 10 nil
                                      (lambda ()
                                        (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                                          (emacs-jupyter-notebook-viewer--transaction-finish state nil)
                                          (ignore-errors (delete-process conn))))))
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
               "handed confined figure metadata to viewer (attempt %d)" attempt))
              conn)
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
               (if (>= attempt emacs-jupyter-notebook-viewer-send-max-attempts)
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
                   (plist-put state :timer
                              (run-at-time
                               emacs-jupyter-notebook-viewer-send-retry-delay nil
                               (lambda ()
                                 (when (emacs-jupyter-notebook-viewer--transaction-live-p state token)
                                   (emacs-jupyter-notebook-viewer--send-pickle-attempt state)))))))))))))))

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
                       :token 0 :timer nil :connection nil :done nil)))
      (setq emacs-jupyter-notebook-viewer--active-transaction state)
      (condition-case nil
          (progn
            (emacs-jupyter-notebook-viewer-ensure)
            (emacs-jupyter-notebook-viewer--send-pickle-attempt state))
        (error
         (emacs-jupyter-notebook-viewer--transaction-finish state nil))))))

(provide 'emacs-jupyter-notebook-viewer)

;;; emacs-jupyter-notebook-viewer.el ends here
