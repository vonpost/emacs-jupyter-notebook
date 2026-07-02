;;; emacs-jupyter-notebook-viewer.el --- Local interactive matplotlib viewer manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:
;; W8.3: manager for ONE persistent LOCAL Python process that renders remote
;; matplotlib figures interactively.  The remote kernel stays headless; the
;; figure travels as a pickle (W8.1/W8.2) which this manager decodes to a
;; local temp file and hands to the viewer over a unix domain socket.
;;
;; Lifecycle contract (the deliberate inverse of the remote-kernel rule):
;; - The viewer is Emacs-owned.  It is spawned lazily on first use, reused
;;   across figures, and REAPED on `kill-emacs-hook'.
;; - It also self-exits after an idle timeout (W8.4) so a hard Emacs crash
;;   cannot orphan it forever.
;; - Hand-off is asynchronous: connecting to the socket and writing the path
;;   never blocks Emacs; if the socket is not yet bound the send retries on a
;;   timer.
;;
;; The actual spawn routes through `emacs-jupyter-notebook-viewer-spawn-function'
;; so ERTs can substitute a stub process + socket and exercise the full
;; lazy-spawn / reuse / hand-off / reap protocol without a real GUI.

;;; Code:

(require 'cl-lib)
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
  "Return the absolute path to the bundled `viewer/ejn_viewer.py', or nil."
  (let* ((base (or emacs-jupyter-notebook-viewer--load-file
                   (locate-library "emacs-jupyter-notebook-viewer")))
         (dir (and base (file-name-directory base)))
         (path (and dir (expand-file-name "viewer/ejn_viewer.py" dir))))
    (and path (file-exists-p path) path)))

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
         (backend (symbol-name (or emacs-jupyter-notebook-viewer-backend 'qt)))
         (idle (number-to-string
                (max 0 (or emacs-jupyter-notebook-viewer-idle-timeout 900)))))
    (unless python
      (error "Local Python command %S not found on `exec-path'" command))
    (unless script
      (error "Viewer script not found (expected viewer/ejn_viewer.py beside the package)"))
    (make-process
     :name "emacs-jupyter-notebook-viewer"
     :command (list python "-u" script
                    "--socket" socket-path
                    "--backend" backend
                    "--idle-timeout" idle)
     :noquery t
     :connection-type 'pipe
     :buffer (get-buffer-create " *emacs-jupyter-notebook-viewer*")
     :stderr (get-buffer-create " *emacs-jupyter-notebook-viewer-stderr*")
     :sentinel #'emacs-jupyter-notebook-viewer--sentinel)))

(defun emacs-jupyter-notebook-viewer--sentinel (proc event)
  "Sentinel for the viewer PROC: log EVENT (+ stderr tail) and clear state.
W8.7(b): the socket hand-off is fire-and-forget, so an abnormal viewer
exit (e.g. no working Qt/Tk backend, which exits 3) would otherwise be
silent.  Surface the exit code and the last stderr line as a user
message and in the log buffer."
  (when (memq (process-status proc) '(exit signal))
    (let* ((code (process-exit-status proc))
           (stderr (get-buffer " *emacs-jupyter-notebook-viewer-stderr*"))
           (tail (and (buffer-live-p stderr)
                      (with-current-buffer stderr
                        (let ((s (string-trim (buffer-string))))
                          (unless (string-empty-p s)
                            (car (last (split-string s "\n" t)))))))))
      (emacs-jupyter-notebook-viewer--log
       "viewer process exited (%s%s)%s"
       (string-trim (or event ""))
       (if (integerp code) (format ", code %d" code) "")
       (if tail (format ": %s" tail) ""))
      (when (and (integerp code) (not (zerop code)))
        (message "emacs-jupyter-notebook: figure viewer failed to start%s"
                 (if tail (format " — %s" tail) "")))
      (when (eq proc emacs-jupyter-notebook-viewer--process)
        (setq emacs-jupyter-notebook-viewer--process nil)))))

(defun emacs-jupyter-notebook-viewer-live-p ()
  "Return non-nil when the persistent viewer process is live."
  (and (processp emacs-jupyter-notebook-viewer--process)
       (process-live-p emacs-jupyter-notebook-viewer--process)))

(defun emacs-jupyter-notebook-viewer--new-socket-path ()
  "Return a fresh, unused unix-socket path in the temp directory."
  (make-temp-name
   (expand-file-name "ejn-viewer-" temporary-file-directory)))

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
  (when (processp emacs-jupyter-notebook-viewer--process)
    (ignore-errors
      (when (process-live-p emacs-jupyter-notebook-viewer--process)
        (delete-process emacs-jupyter-notebook-viewer--process))))
  (when (and emacs-jupyter-notebook-viewer--socket-path
             (file-exists-p emacs-jupyter-notebook-viewer--socket-path))
    (ignore-errors (delete-file emacs-jupyter-notebook-viewer--socket-path)))
  (setq emacs-jupyter-notebook-viewer--process nil
        emacs-jupyter-notebook-viewer--socket-path nil)
  (remove-hook 'kill-emacs-hook #'emacs-jupyter-notebook-viewer-reap))

;;; Async figure hand-off

(defun emacs-jupyter-notebook-viewer-send-path (path)
  "Hand figure temp-file PATH to the viewer over the unix socket, async.
Ensures the viewer is live, then connects and writes PATH.  A failed
connect (viewer socket not yet bound) reschedules on a timer up to
`emacs-jupyter-notebook-viewer-send-max-attempts' times.  Never blocks."
  (emacs-jupyter-notebook-viewer-ensure)
  (emacs-jupyter-notebook-viewer--send-path-attempt path 1))

(defun emacs-jupyter-notebook-viewer--send-path-attempt (path attempt)
  "Attempt number ATTEMPT to connect and send PATH to the viewer socket.
W8.7(c): if the viewer is not live, respawn it (which allocates a fresh
socket path) before connecting; catch any `error' — not just
`file-error' — so a viewer death after connect (`process-send-string' /
`process-send-eof' signalling) also triggers a retry rather than
propagating.  W8.7(e): the one-shot connection process is disposed via a
sentinel once it closes."
  (unless (emacs-jupyter-notebook-viewer-live-p)
    (ignore-errors (emacs-jupyter-notebook-viewer-ensure)))
  (let ((socket-path emacs-jupyter-notebook-viewer--socket-path))
    (if (null socket-path)
        (emacs-jupyter-notebook-viewer--log
         "no viewer socket; dropping figure hand-off for %s" path)
      (condition-case err
          (let ((conn (make-network-process
                       :name "emacs-jupyter-notebook-viewer-send"
                       :family 'local
                       :service socket-path
                       :coding 'utf-8
                       :noquery t)))
            (set-process-sentinel
             conn
             (lambda (p _e)
               (when (memq (process-status p) '(closed failed exit signal))
                 (ignore-errors (delete-process p)))))
            (process-send-string conn (concat path "\n"))
            (process-send-eof conn)
            (emacs-jupyter-notebook-viewer--log
             "handed figure %s to viewer (attempt %d)" path attempt)
            conn)
        (error
         (if (>= attempt emacs-jupyter-notebook-viewer-send-max-attempts)
             (emacs-jupyter-notebook-viewer--log
              "failed to reach viewer after %d attempts: %s"
              attempt (error-message-string err))
           ;; Invalidate a dead viewer so the next attempt respawns it.
           (unless (emacs-jupyter-notebook-viewer-live-p)
             (setq emacs-jupyter-notebook-viewer--process nil
                   emacs-jupyter-notebook-viewer--socket-path nil))
           (run-at-time
            emacs-jupyter-notebook-viewer-send-retry-delay nil
            #'emacs-jupyter-notebook-viewer--send-path-attempt
            path (1+ attempt))))))))

(defun emacs-jupyter-notebook-viewer-open-pickle (base64)
  "Decode BASE64 matplotlib pickle to a temp file and open it in the viewer.
Returns the temp-file path.  The hand-off is asynchronous."
  (let* ((bytes (base64-decode-string base64))
         (tmp (make-temp-file "ejn-figure-" nil ".pkl")))
    (let ((coding-system-for-write 'binary))
      (with-temp-file tmp
        (set-buffer-multibyte nil)
        (insert bytes)))
    (emacs-jupyter-notebook-viewer-send-path tmp)
    tmp))

(provide 'emacs-jupyter-notebook-viewer)

;;; emacs-jupyter-notebook-viewer.el ends here
