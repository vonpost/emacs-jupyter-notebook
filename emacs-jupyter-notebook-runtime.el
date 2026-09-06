;;; emacs-jupyter-notebook-runtime.el --- Async local runtime bootstrap  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Build the bundled helper and registry worker once, asynchronously, when the
;; default executables are unavailable.  This module owns only a local Nix
;; process and has no access to kernels, SSH, or the durable registry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

(defconst emacs-jupyter-notebook-runtime--module-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory))))

(defconst emacs-jupyter-notebook-runtime--hard-timeout 1800)
(defconst emacs-jupyter-notebook-runtime--hard-output-bytes (* 1024 1024))
(defconst emacs-jupyter-notebook-runtime--progress-line-chars 512)

(defvar emacs-jupyter-notebook-runtime-progress-function nil
  "Function called as (FUNCTION BUFFER LINE) for bounded Nix progress.
Exactly one live waiter receives at most one sample per stderr callback.")

(cl-defstruct (emacs-jupyter-notebook-runtime--waiter
               (:constructor emacs-jupyter-notebook-runtime--make-waiter))
  token buffer probe callback failure viewer progress)

(cl-defstruct (emacs-jupyter-notebook-runtime--build
               (:constructor emacs-jupyter-notebook-runtime--make-build))
  token process stdout-buffer stderr-buffer stderr-process timer waiters
  root started-at stdout-bytes stderr-bytes output-overflow terminal
  stderr-closed last-progress-line viewer)

(defvar emacs-jupyter-notebook-runtime--build nil
  "The single in-flight local runtime build, or nil.")

(defvar emacs-jupyter-notebook-runtime--viewer-build nil
  "The independently deduplicated local viewer build, or nil.")

(defvar emacs-jupyter-notebook-runtime-viewer-directory nil
  "Successful separate viewer output; never used as the headless runtime.")

(defun emacs-jupyter-notebook-runtime--build-slot (viewer)
  "Return the global build slot for VIEWER or the headless runtime."
  (if viewer 'emacs-jupyter-notebook-runtime--viewer-build
    'emacs-jupyter-notebook-runtime--build))

(defun emacs-jupyter-notebook-runtime--current-build-p (build)
  "Whether BUILD still owns its package-specific process generation."
  (eq build (symbol-value (emacs-jupyter-notebook-runtime--build-slot
                           (emacs-jupyter-notebook-runtime--build-viewer build)))))

(defun emacs-jupyter-notebook-runtime--clear-current-build (build)
  "Retire BUILD without touching another package's or generation's build."
  (when (emacs-jupyter-notebook-runtime--current-build-p build)
    (set (emacs-jupyter-notebook-runtime--build-slot
          (emacs-jupyter-notebook-runtime--build-viewer build)) nil)))

(defun emacs-jupyter-notebook-runtime--timeout ()
  "Return the bounded automatic build timeout."
  (let ((value emacs-jupyter-notebook-runtime-build-timeout))
    (if (and (numberp value) (> value 0)
             (or (not (floatp value))
                 (and (not (isnan value)) (< value 1.0e+INF)))
             (<= value emacs-jupyter-notebook-runtime--hard-timeout))
        value
      600)))

(defun emacs-jupyter-notebook-runtime--output-limit ()
  "Return the bounded per-stream automatic build output limit."
  (let ((value emacs-jupyter-notebook-runtime-build-output-max-bytes))
    (if (and (integerp value) (> value 0)
             (<= value emacs-jupyter-notebook-runtime--hard-output-bytes))
        value
      65536)))

(defun emacs-jupyter-notebook-runtime--package-root ()
  "Return the physical package root containing the pinned Nix flake."
  (let* ((located
          (ignore-errors
            (locate-library "emacs-jupyter-notebook-runtime")))
         (directories
          (delete-dups
           (delq nil
                 (list emacs-jupyter-notebook-runtime--module-directory
                       (and located (file-name-directory located)))))))
    (cl-loop
     for source in directories
     when (and (stringp source) (file-name-absolute-p source)
               (not (file-remote-p source)))
     thereis
     (cl-loop
      ;; Straight loads regular byte-code from its build tree, while source
      ;; files and the packaged flake are symlinks to the repository.  Native
      ;; compilation instead sets `load-file-name' to the .eln cache.  Either
      ;; packaged anchor can therefore lead back to the complete source tree.
      for name in '("flake.nix" "emacs-jupyter-notebook-runtime.el")
      for anchor = (expand-file-name name source)
      when (file-regular-p anchor)
      thereis
      (let ((root (file-name-directory (file-truename anchor))))
        (and (not (file-remote-p root))
             (file-regular-p (expand-file-name "flake.nix" root))
             (file-regular-p (expand-file-name "flake.lock" root))
             (file-name-as-directory (file-truename root))))))))

(defun emacs-jupyter-notebook-runtime--nix-program ()
  "Resolve local Nix without consulting file handlers.
The standard profile paths cover GUI Emacs on Darwin and Linux, where the
login shell's Nix path is commonly absent from `exec-path'."
  (cl-loop for candidate in
           (append
            (cl-loop for directory in exec-path
                     when (and (stringp directory)
                               (file-name-absolute-p directory)
                               (not (file-remote-p directory)))
                     collect (expand-file-name "nix" directory))
            (list (expand-file-name "~/.nix-profile/bin/nix")
                  "/nix/var/nix/profiles/default/bin/nix"
                  "/opt/homebrew/bin/nix"
                  "/usr/local/bin/nix"
                  "/run/current-system/sw/bin/nix"))
           when (and (not (file-remote-p candidate))
                     (file-executable-p candidate))
           return candidate))

(defun emacs-jupyter-notebook-runtime--probe (probe)
  "Call PROBE and normalize exceptions into an unbuildable status plist."
  (condition-case err
      (let ((status (funcall probe)))
        (if (and (listp status) (plist-member status :ready)
                 (plist-member status :buildable))
            status
          (list :ready nil :buildable nil
                :reason "Local runtime probe returned an invalid result")))
    (error
     (list :ready nil :buildable nil :reason (error-message-string err)))))

(defun emacs-jupyter-notebook-runtime--waiter-live-p (waiter)
  "Return non-nil when WAITER still has a live owning buffer."
  (buffer-live-p (emacs-jupyter-notebook-runtime--waiter-buffer waiter)))

(defun emacs-jupyter-notebook-runtime--call-waiter (waiter success value)
  "Deliver SUCCESS with VALUE to live WAITER without disrupting its peers."
  (when (emacs-jupyter-notebook-runtime--waiter-live-p waiter)
    (with-current-buffer (emacs-jupyter-notebook-runtime--waiter-buffer waiter)
      (condition-case err
          (if success
              (funcall (emacs-jupyter-notebook-runtime--waiter-callback waiter))
            (funcall (emacs-jupyter-notebook-runtime--waiter-failure waiter) value))
        (error
         (message "emacs-jupyter-notebook runtime callback failed: %s"
                  (error-message-string err)))))))

(defun emacs-jupyter-notebook-runtime--delete-process (process)
  "Retire local PROCESS without allowing its sentinel to retain ownership."
  (when (processp process)
    (set-process-sentinel process #'ignore)
    (when (process-live-p process)
      (delete-process process))))

(defun emacs-jupyter-notebook-runtime--dispose (build)
  "Dispose BUILD's local process, timer, and output buffers."
  (condition-case nil
      (when (timerp (emacs-jupyter-notebook-runtime--build-timer build))
        (cancel-timer (emacs-jupyter-notebook-runtime--build-timer build)))
    ((error quit) nil))
  (condition-case nil
      (emacs-jupyter-notebook-runtime--delete-process
       (emacs-jupyter-notebook-runtime--build-process build))
    ((error quit) nil))
  (condition-case nil
      (emacs-jupyter-notebook-runtime--delete-process
       (emacs-jupyter-notebook-runtime--build-stderr-process build))
    ((error quit) nil))
  (dolist (buffer (list (emacs-jupyter-notebook-runtime--build-stdout-buffer build)
                        (emacs-jupyter-notebook-runtime--build-stderr-buffer build)))
    (when (buffer-live-p buffer)
      (condition-case nil
          (kill-buffer buffer)
        ((error quit) nil)))))

(defun emacs-jupyter-notebook-runtime--decode-output (bytes)
  "Decode bounded unibyte output BYTES into printable text."
  (let ((text (condition-case nil
                  (decode-coding-string bytes 'utf-8)
                (error (decode-coding-string bytes 'binary)))))
    (replace-regexp-in-string "[^[:print:]\n\t]" "?" text)))

(defun emacs-jupyter-notebook-runtime--buffer-output (buffer)
  "Return decoded bounded output retained in BUFFER, or an empty string."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (emacs-jupyter-notebook-runtime--decode-output (buffer-string)))
    ""))

(defun emacs-jupyter-notebook-runtime--diagnostic (build fallback)
  "Return BUILD's complete retained bounded stderr, or FALLBACK.
The process filter already enforces the configured immutable output ceiling,
so a second arbitrary tail cut here would only discard the beginning of the
real error and could start the displayed result in the middle of a line."
  (condition-case nil
      (let ((text
             (string-trim
              (emacs-jupyter-notebook-runtime--buffer-output
               (emacs-jupyter-notebook-runtime--build-stderr-buffer build)))))
        (if (string-empty-p text) fallback text))
    ((error quit) fallback)))

(defun emacs-jupyter-notebook-runtime--fail (build reason)
  "Fail BUILD once with bounded REASON and release all of its waiters."
  (unless (emacs-jupyter-notebook-runtime--build-terminal build)
    (setf (emacs-jupyter-notebook-runtime--build-terminal build) t)
    (emacs-jupyter-notebook-runtime--clear-current-build build)
    (let ((waiters (emacs-jupyter-notebook-runtime--build-waiters build)))
      (setf (emacs-jupyter-notebook-runtime--build-waiters build) nil)
      (unwind-protect
          (condition-case nil
              (emacs-jupyter-notebook-runtime--dispose build)
            ((error quit) nil))
        (dolist (waiter waiters)
          (emacs-jupyter-notebook-runtime--call-waiter waiter nil reason))))))

(defun emacs-jupyter-notebook-runtime--parse-output-directory (build)
  "Return the one absolute output directory printed by successful BUILD."
  (condition-case nil
      (let* ((buffer (emacs-jupyter-notebook-runtime--build-stdout-buffer build))
             (raw (and (buffer-live-p buffer)
                       (with-current-buffer buffer (buffer-string))))
             (text (and raw (decode-coding-string raw 'utf-8)))
             (lines (and text
                         (split-string text "[\r\n]+" t "[[:space:]]+"))))
        (when (and (= (length lines) 1)
                   (file-name-absolute-p (car lines))
                   (not (file-remote-p (car lines)))
                   (file-directory-p (car lines)))
          (file-name-as-directory (file-truename (car lines)))))
    (error nil)))

(defun emacs-jupyter-notebook-runtime--succeed (build)
  "Publish BUILD's output and resume waiters whose complete runtime resolves."
  (let ((directory (emacs-jupyter-notebook-runtime--parse-output-directory build)))
    (if (not directory)
        (emacs-jupyter-notebook-runtime--fail
         build "Nix build succeeded but did not report one usable runtime output")
      (if (emacs-jupyter-notebook-runtime--build-viewer build)
          (setq emacs-jupyter-notebook-runtime-viewer-directory directory)
        (setq emacs-jupyter-notebook--runtime-directory directory))
      (setf (emacs-jupyter-notebook-runtime--build-terminal build) t)
      (emacs-jupyter-notebook-runtime--clear-current-build build)
      (let ((waiters (emacs-jupyter-notebook-runtime--build-waiters build)))
        (setf (emacs-jupyter-notebook-runtime--build-waiters build) nil)
        (unwind-protect
            (condition-case nil
                (emacs-jupyter-notebook-runtime--dispose build)
              ((error quit) nil))
          (dolist (waiter waiters)
            (let* ((status (emacs-jupyter-notebook-runtime--probe
                            (emacs-jupyter-notebook-runtime--waiter-probe waiter)))
                   (ready (plist-get status :ready)))
              (emacs-jupyter-notebook-runtime--call-waiter
               waiter ready
               (or (plist-get status :reason)
                   "Nix runtime output is missing a required executable")))))))))

(defun emacs-jupyter-notebook-runtime--progress-text (output &optional cut-first-line)
  "Return a short printable sample from bounded accumulated OUTPUT.
CUT-FIRST-LINE says OUTPUT starts mid-line.  Omit that line: a credential
key may have preceded the retained suffix and cannot be redacted afterward."
  (let* ((start (max 0 (- (length output) 2048)))
         (cut (if (> start 0)
                  (not (memq (aref output (1- start)) '(?\r ?\n)))
                cut-first-line))
         (tail (substring output start))
         (tail (if cut
                   (if (string-match "[\r\n]" tail)
                       (substring tail (match-end 0)) "")
                 tail))
         (lines (split-string
                 (emacs-jupyter-notebook-runtime--decode-output tail)
                 "[\r\n]+" t "[[:space:]]+"))
         (line (and lines (car (last lines)))))
    (when line
      (substring line 0
                 (min (length line)
                      emacs-jupyter-notebook-runtime--progress-line-chars)))))

(defun emacs-jupyter-notebook-runtime--report-progress (build _output)
  "Report one safe accumulated stderr sample through a live BUILD waiter.
The filter has already appended its chunk to BUILD's bounded stderr buffer.
Use that buffer, not the isolated chunk: credential keys can straddle chunks."
  (when-let* ((stderr (emacs-jupyter-notebook-runtime--build-stderr-buffer build))
              (line
               (when (buffer-live-p stderr)
                 (with-current-buffer stderr
                   (save-restriction
                     (widen)
                     (let* ((end (point-max))
                            (start (max (point-min) (- end 2048)))
                            (cut (and (> start (point-min))
                                      (not (memq (char-before start) '(?\r ?\n))))))
                       (emacs-jupyter-notebook-runtime--progress-text
                        (buffer-substring-no-properties start end) cut))))))
              (waiter
               (cl-find-if
                #'emacs-jupyter-notebook-runtime--waiter-live-p
                (emacs-jupyter-notebook-runtime--build-waiters build))))
    (when (and (functionp (or (emacs-jupyter-notebook-runtime--waiter-progress waiter)
                             emacs-jupyter-notebook-runtime-progress-function))
               (not (equal
                     line
                     (emacs-jupyter-notebook-runtime--build-last-progress-line
                      build))))
      (setf (emacs-jupyter-notebook-runtime--build-last-progress-line build) line)
      (condition-case nil
          (funcall (or (emacs-jupyter-notebook-runtime--waiter-progress waiter)
                       emacs-jupyter-notebook-runtime-progress-function)
                   (emacs-jupyter-notebook-runtime--waiter-buffer waiter) line)
        ((error quit) nil)))))

(defun emacs-jupyter-notebook-runtime--settle (build)
  "Settle BUILD after both its main process and stderr pipe have closed."
  (let ((process (emacs-jupyter-notebook-runtime--build-process build)))
    (when (and (not (emacs-jupyter-notebook-runtime--build-terminal build))
               (emacs-jupyter-notebook-runtime--current-build-p build)
               (processp process)
               (memq (process-status process) '(exit signal))
               (emacs-jupyter-notebook-runtime--build-stderr-closed build))
      (cond
       ((emacs-jupyter-notebook-runtime--build-output-overflow build)
        (emacs-jupyter-notebook-runtime--fail
         build "Automatic Nix runtime build exceeded its output limit"))
       ((and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
        (emacs-jupyter-notebook-runtime--succeed build))
       (t
        (let ((fallback (format "process exited with status %s"
                                (process-exit-status process))))
          (emacs-jupyter-notebook-runtime--fail
           build
           (format "Automatic Nix runtime build failed: %s"
                   (condition-case nil
                       (emacs-jupyter-notebook-runtime--diagnostic
                        build fallback)
                     ((error quit) fallback))))))))))

(defun emacs-jupyter-notebook-runtime--sentinel (build process _event)
  "Record BUILD's exact main PROCESS exit and await stderr EOF."
  (when (and (not (emacs-jupyter-notebook-runtime--build-terminal build))
             (emacs-jupyter-notebook-runtime--current-build-p build)
             (or (null (emacs-jupyter-notebook-runtime--build-process build))
                 (eq process (emacs-jupyter-notebook-runtime--build-process build)))
             (memq (process-status process) '(exit signal)))
    (setf (emacs-jupyter-notebook-runtime--build-process build) process)
    (emacs-jupyter-notebook-runtime--settle build)))

(defun emacs-jupyter-notebook-runtime--stderr-sentinel
    (build process _event)
  "Mark BUILD's exact stderr PROCESS drained after it closes."
  (when (and (not (emacs-jupyter-notebook-runtime--build-terminal build))
             (emacs-jupyter-notebook-runtime--current-build-p build)
             (eq process
                 (emacs-jupyter-notebook-runtime--build-stderr-process build))
             (not (process-live-p process)))
    (setf (emacs-jupyter-notebook-runtime--build-stderr-closed build) t)
    (emacs-jupyter-notebook-runtime--settle build)))

(defun emacs-jupyter-notebook-runtime--filter (build stream process output)
  "Append PROCESS OUTPUT to BUILD's STREAM within its immutable bound."
  (when (and (not (emacs-jupyter-notebook-runtime--build-terminal build))
             (emacs-jupyter-notebook-runtime--current-build-p build))
    ;; Publish an exceptionally fast stdout child before an inline test double
    ;; or process callback can fail it.  The stderr pipe is never the owner.
    (when (and (eq stream 'stdout)
               (null (emacs-jupyter-notebook-runtime--build-process build)))
      (setf (emacs-jupyter-notebook-runtime--build-process build) process))
    (let* ((stdout (eq stream 'stdout))
           (old (if stdout
                    (emacs-jupyter-notebook-runtime--build-stdout-bytes build)
                  (emacs-jupyter-notebook-runtime--build-stderr-bytes build)))
           (total (+ old (string-bytes output)))
           (limit (emacs-jupyter-notebook-runtime--output-limit)))
      (if (> total limit)
          (progn
            (setf (emacs-jupyter-notebook-runtime--build-output-overflow build) t)
            (emacs-jupyter-notebook-runtime--fail
             build "Automatic Nix runtime build exceeded its output limit"))
        (if stdout
            (setf (emacs-jupyter-notebook-runtime--build-stdout-bytes build) total)
          (setf (emacs-jupyter-notebook-runtime--build-stderr-bytes build) total))
        (let ((buffer (process-buffer process)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert output))))
        (unless stdout
          (emacs-jupyter-notebook-runtime--report-progress build output))))))

(defun emacs-jupyter-notebook-runtime--timeout-fired (build)
  "Fail BUILD only if it still owns the global build slot."
  (when (and (emacs-jupyter-notebook-runtime--current-build-p build)
             (not (emacs-jupyter-notebook-runtime--build-terminal build)))
    (emacs-jupyter-notebook-runtime--fail
     build (format "Automatic Nix runtime build timed out after %.0f seconds"
                   (emacs-jupyter-notebook-runtime--timeout)))))

(defun emacs-jupyter-notebook-runtime--start-unguarded (waiter)
  "Start the one local build owned initially by WAITER."
  (let ((root (emacs-jupyter-notebook-runtime--package-root))
        (nix (emacs-jupyter-notebook-runtime--nix-program)))
    (cond
     ((not emacs-jupyter-notebook-auto-build-runtime)
      (emacs-jupyter-notebook-runtime--call-waiter
       waiter nil "Automatic local runtime builds are disabled"))
     ((not root)
      (emacs-jupyter-notebook-runtime--call-waiter
       waiter nil "Cannot find the package's pinned flake.nix and flake.lock"))
     ((not nix)
      (emacs-jupyter-notebook-runtime--call-waiter
       waiter nil
       "The bundled local runtime is missing and Nix is not available in exec-path"))
     (t
      (let* ((stdout (generate-new-buffer " *ejn-runtime-build*"))
             (stderr (generate-new-buffer " *ejn-runtime-build stderr*"))
             (command
              (list nix "--extra-experimental-features" "nix-command flakes"
                    "build" "--no-link" "--print-out-paths"
                    "--print-build-logs" "--show-trace"
                    (if (emacs-jupyter-notebook-runtime--waiter-viewer waiter)
                        ".#ejn-viewer" ".#default")))
             (build (emacs-jupyter-notebook-runtime--make-build
                     :token (gensym "ejn-runtime-build-")
                     :viewer (emacs-jupyter-notebook-runtime--waiter-viewer waiter)
                     :stdout-buffer stdout :stderr-buffer stderr
                     :waiters (list waiter) :root root
                     :started-at (float-time) :stdout-bytes 0 :stderr-bytes 0)))
        (with-current-buffer stdout (set-buffer-multibyte nil))
        (with-current-buffer stderr (set-buffer-multibyte nil))
        (set (emacs-jupyter-notebook-runtime--build-slot
              (emacs-jupyter-notebook-runtime--build-viewer build)) build)
        (setf (emacs-jupyter-notebook-runtime--build-timer build)
              (run-at-time
               (emacs-jupyter-notebook-runtime--timeout) nil
               #'emacs-jupyter-notebook-runtime--timeout-fired build))
        (condition-case err
            (let* ((default-directory root)
                   (process
                    (make-process
                     :name "ejn-runtime-build"
                     :buffer stdout
                     :stderr stderr
                     :command command
                     :connection-type 'pipe :coding 'binary :noquery t
                     :filter (lambda (process output)
                               (emacs-jupyter-notebook-runtime--filter
                                build 'stdout process output))
                     :sentinel (lambda (process event)
                                 (emacs-jupyter-notebook-runtime--sentinel
                                  build process event)))))
              (when (emacs-jupyter-notebook-runtime--current-build-p build)
                (setf (emacs-jupyter-notebook-runtime--build-process build) process)
                (if-let ((stderr-process (get-buffer-process stderr)))
                    (progn
                      (setf (emacs-jupyter-notebook-runtime--build-stderr-process
                             build)
                            stderr-process)
                      (set-process-filter
                       stderr-process
                       (lambda (process output)
                         (emacs-jupyter-notebook-runtime--filter
                          build 'stderr process output)))
                      (set-process-sentinel
                       stderr-process
                       (lambda (process event)
                         (emacs-jupyter-notebook-runtime--stderr-sentinel
                          build process event)))
                      (unless (process-live-p stderr-process)
                        (emacs-jupyter-notebook-runtime--stderr-sentinel
                         build stderr-process "already closed")))
                  (setf (emacs-jupyter-notebook-runtime--build-stderr-closed
                         build)
                        t))
                (emacs-jupyter-notebook-runtime--settle build)))
          (error
           (emacs-jupyter-notebook-runtime--fail
            build
            (format "Could not start automatic Nix runtime build: %s"
                    (error-message-string err))))))))))

(defun emacs-jupyter-notebook-runtime--start (waiter)
  "Start a local build for WAITER and settle discovery failures immediately."
  (condition-case err
      (emacs-jupyter-notebook-runtime--start-unguarded waiter)
    ((error quit)
     (let ((build (symbol-value (emacs-jupyter-notebook-runtime--build-slot
                                (emacs-jupyter-notebook-runtime--waiter-viewer waiter))))
           (reason
            (format "Could not inspect the bundled Nix runtime: %.1000s"
                    (error-message-string err))))
       (if (and build
                (memq waiter
                      (emacs-jupyter-notebook-runtime--build-waiters
                       build)))
           (emacs-jupyter-notebook-runtime--fail
            build reason)
         (emacs-jupyter-notebook-runtime--call-waiter waiter nil reason))))))

(defun emacs-jupyter-notebook-runtime-ensure
    (probe callback failure &optional buffer viewer progress)
  "Ensure the bundled runtime according to PROBE, then call CALLBACK.
PROBE returns a plist with `:ready', `:buildable', and optional `:reason'.
FAILURE receives one bounded diagnostic.  BUFFER owns the returned waiter
token and may cancel it without affecting waiters from other buffers.
VIEWER requests the independently built GUI output, never the headless one.
PROGRESS, when non-nil, receives (BUFFER LINE) instead of the global progress
function.  It lets callers without a kernel bootstrap context report builds."
  (let* ((buffer (or buffer (current-buffer)))
         (status (emacs-jupyter-notebook-runtime--probe probe)))
    (cond
     ((plist-get status :ready)
      (funcall callback)
      nil)
     ((not (plist-get status :buildable))
      (funcall failure (or (plist-get status :reason)
                           "The configured local runtime cannot be resolved"))
      nil)
     (t
      (let* ((slot (emacs-jupyter-notebook-runtime--build-slot viewer))
             (build (symbol-value slot))
             (waiter (emacs-jupyter-notebook-runtime--make-waiter
                     :token (gensym "ejn-runtime-waiter-") :buffer buffer
                     :viewer viewer :progress progress
                     :probe probe :callback callback :failure failure)))
        (if (and build
                 (not (emacs-jupyter-notebook-runtime--build-terminal
                       build)))
            (progn
              (setf (emacs-jupyter-notebook-runtime--build-waiters
                     build)
                    (append
                     (emacs-jupyter-notebook-runtime--build-waiters
                      build)
                     (list waiter)))
              (emacs-jupyter-notebook-runtime--waiter-token waiter))
          (emacs-jupyter-notebook-runtime--start waiter)
          (setq build (symbol-value slot))
          (when (and build
                     (memq waiter
                           (emacs-jupyter-notebook-runtime--build-waiters
                            build)))
            (emacs-jupyter-notebook-runtime--waiter-token waiter))))))))

(defun emacs-jupyter-notebook-runtime-waiter-active-p (token &optional viewer)
  "Whether TOKEN still belongs to a live waiter in the selected build slot.
This checks bookkeeping only; a live build retains its own bounded deadline."
  (let ((build (symbol-value (emacs-jupyter-notebook-runtime--build-slot viewer))))
    (and token build
         (not (emacs-jupyter-notebook-runtime--build-terminal build))
         (cl-some (lambda (waiter)
                    (and (eq token (emacs-jupyter-notebook-runtime--waiter-token waiter))
                         (emacs-jupyter-notebook-runtime--waiter-live-p waiter)))
                  (emacs-jupyter-notebook-runtime--build-waiters build)))))

(defun emacs-jupyter-notebook-runtime-cancel-waiter (token)
  "Cancel the waiter identified by TOKEN and stop an otherwise unused build."
  (let ((changed nil))
   (dolist (build (delq nil (list emacs-jupyter-notebook-runtime--build
                                emacs-jupyter-notebook-runtime--viewer-build)))
    (let* ((old (emacs-jupyter-notebook-runtime--build-waiters build))
           (new (cl-remove token old
                           :key #'emacs-jupyter-notebook-runtime--waiter-token
                           :test #'eq)))
      (setf (emacs-jupyter-notebook-runtime--build-waiters build) new)
      (when (and (/= (length old) (length new)) (null new))
        (emacs-jupyter-notebook-runtime--fail build "Runtime build cancelled"))
      (setq changed (or changed (/= (length old) (length new))))))
   changed))

(defun emacs-jupyter-notebook-runtime-shutdown ()
  "Stop the local runtime build, if any, without invoking buffer callbacks."
  (dolist (build (delq nil (list emacs-jupyter-notebook-runtime--build
                               emacs-jupyter-notebook-runtime--viewer-build)))
    (setf (emacs-jupyter-notebook-runtime--build-waiters build) nil)
    (emacs-jupyter-notebook-runtime--fail build "Emacs is exiting")))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-runtime-shutdown)

(provide 'emacs-jupyter-notebook-runtime)

;;; emacs-jupyter-notebook-runtime.el ends here
