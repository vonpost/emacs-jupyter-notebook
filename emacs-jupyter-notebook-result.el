;;; emacs-jupyter-notebook-result.el --- Output panel & fringe indicator  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; W2: A dedicated side-panel buffer per source buffer that owns all
;; evaluation output.  The source buffer carries no result text and only
;; a fringe/margin indicator (W2.8) that cannot interfere with editing.
;;
;; Public API used by the normalized helper event reducer:
;;
;;   (ejn-panel-ensure SOURCE-BUFFER)        => panel buffer
;;   (ejn-panel-start-entry PANEL KEY CODE)  => handle (plist)
;;   (ejn-panel-append-text HANDLE TEXT &optional FACE)
;;   (ejn-panel-replace-text HANDLE TEXT)
;;   (ejn-panel-set-image HANDLE IMAGE-SPEC)
;;   (ejn-panel-finish-entry HANDLE STATUS EXECUTION-COUNT)
;;   (ejn-panel-clear-entry HANDLE)
;;
;; An entry HANDLE is a plist:
;;   (:panel PANEL :id N :generation N :cell-key KEY)
;;
;; A KEY for cell-bound evaluation is a cons of (file-name . stable-cell-id)
;; produced by the source buffer's cell tracking.  Region/paragraph/defun
;; evaluation uses KEY = nil; those entries flow only to the history-log
;; view.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'emacs-jupyter-notebook-helper-protocol)
(require 'emacs-jupyter-notebook-vars)
(require 'emacs-jupyter-notebook-artifacts)
(require 'emacs-jupyter-notebook-cell)

(defconst emacs-jupyter-notebook-result--load-file
  (or load-file-name buffer-file-name)
  "Path of this file at load time, used to locate bundled local helpers.")

;;; Faces

(defface emacs-jupyter-notebook-result-face
  '((t :inherit default))
  "Face used for output text in the result panel."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-result-header-face
  '((t :inherit shadow))
  "Face used for entry headers in the result panel."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-result-error-face
  '((t :inherit error))
  "Face used for error output in the result panel."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-execution-count-face
  '((t :inherit font-lock-comment-face))
  "Face used for execution counts displayed in the panel."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-fringe-running-face
  '((t :inherit warning))
  "Face for the running indicator in the source buffer's fringe."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-fringe-ok-face
  '((t :inherit success))
  "Face for the success indicator in the source buffer's fringe."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-fringe-error-face
  '((t :inherit error))
  "Face for the error indicator in the source buffer's fringe."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-fringe-queued-face
  '((t :inherit shadow))
  "Face for the queued indicator in the source buffer's fringe."
  :group 'emacs-jupyter-notebook)

(defun emacs-jupyter-notebook--last-bytes (text max-bytes)
  "Return the last MAX-BYTES bytes of TEXT."
  (if (<= (string-bytes text) max-bytes)
      text
    (let ((lo 0)
          (hi (length text)))
      (while (< (1+ lo) hi)
        (let ((mid (/ (+ lo hi) 2)))
          (if (<= (string-bytes (substring text mid)) max-bytes)
              (setq hi mid)
            (setq lo mid))))
      (substring text hi))))

;;; Panel buffer state

(defvar-local emacs-jupyter-notebook-panel--source-buffer nil
  "The source buffer this panel is attached to.")

(defvar-local emacs-jupyter-notebook-panel--entries nil
  "Alist of (ID . ENTRY-PLIST), newest insertion at the tail.
Each entry plist supports:
  :id N
  :cell-key KEY-or-nil
  :code STRING
  :status queued|running|ok|error|cancelled|outcome-unknown
  :exec-count INTEGER-or-\"*\"
  :timestamp ISO-string
  :outputs ordered text/image segments
  :mpl-pickle confined metadata plist or nil
  :pickle-open-timer TIMER-or-nil
  :pickle-open-token TOKEN-or-nil
  :pending-clear BOOL")

(defvar-local emacs-jupyter-notebook-panel--hidden-cells nil
  "Hash table of cell keys whose output bodies are hidden in this panel.")

(defvar-local emacs-jupyter-notebook-panel--restore-entry-id nil
  "Entry whose header should regain point after an output visibility toggle.")

(defcustom emacs-jupyter-notebook-panel-follow-source t
  "Reveal the current source cell's output when moving between cells.
The output window is never selected.  Scrolling output pauses following until
the source moves to another cell, a new evaluation is revealed, or `f' resumes."
  :type 'boolean :group 'emacs-jupyter-notebook)

(defvar-local emacs-jupyter-notebook-panel--follow-paused nil
  "Non-nil while the user is reading output independently of the source.")
(defvar-local emacs-jupyter-notebook-panel--follow-empty nil
  "Non-nil when the current source cell has no retained output to reveal.")
(defvar-local emacs-jupyter-notebook-panel--reveal-entry-id nil
  "Entry to reveal once the pending panel layout has finished rendering.")
(defvar-local emacs-jupyter-notebook-panel--navigation-snapshot nil
  "Reading positions retained across a complete or interrupted redraw.")
(defvar-local emacs-jupyter-notebook-panel--duration-timer nil
  "Timer refreshing elapsed durations in a visible panel.")
(defvar-local emacs-jupyter-notebook-panel--last-source-cell nil
  "Last source-cell identity observed by the local post-command hook.")
(defvar emacs-jupyter-notebook-panel--adjusting-window nil
  "Non-nil during a programmatic reveal or reading-position restoration.")

(defvar-local emacs-jupyter-notebook-panel--next-id 0
  "Monotonic id counter for new entries.")

(defvar-local emacs-jupyter-notebook-panel--generation 0
  "Generation assigned to newly created entry handles.

Clearing a panel advances this value, retiring every existing handle even
before a future implementation chooses to reuse entry ids.")

(defvar-local emacs-jupyter-notebook-panel--view 'latest
  "Current view: `latest' or `history'.")

(defvar-local emacs-jupyter-notebook-panel--flush-timer nil
  "Pending flush timer for streaming throttle.")

(defvar-local emacs-jupyter-notebook-panel--sliced-render-timer nil
  "Regular timer driving the current bounded full-panel render, if any.")

(defvar-local emacs-jupyter-notebook-panel--sliced-render-generation 0
  "Monotonic ownership token for bounded full-panel render callbacks.")

(defvar-local emacs-jupyter-notebook-panel--sliced-render-job nil
  "State of the current bounded full-panel render, or nil.")

(defvar-local emacs-jupyter-notebook-panel--dirty nil
  "Non-nil when the panel needs a redisplay.")

(defvar-local emacs-jupyter-notebook-panel--render-count 0
  "Counter incremented every time the panel re-renders.  Test instrument.")

(defvar-local emacs-jupyter-notebook-panel--image-directory nil
  "Private temporary directory holding this panel's original images.")

(defvar-local emacs-jupyter-notebook-panel--image-artifact-capability nil
  "Identity-bound authority for `--image-directory'.")

(defvar-local emacs-jupyter-notebook-panel--published-artifact-capabilities nil
  "One live lease per helper artifact root retained by this panel.")

(defvar-local emacs-jupyter-notebook-panel--deferred-artifact-capabilities nil
  "Shared helper leases retained by an outstanding viewer or verifier.")

(defvar emacs-jupyter-notebook-panel--bulk-retiring-capability nil
  "Dynamically bound local root already handled by panel-wide retirement.")

(defvar emacs-jupyter-notebook-panel--bulk-published-deletions nil
  "Dynamically bound hash table collecting identity-pinned helper deletions.")

(defvar-local emacs-jupyter-notebook-panel--inline-image-specs nil
  "Image specs materialized by the most recent panel render.")

(defvar-local emacs-jupyter-notebook-panel--dirty-entry-ids nil
  "Entry ids eligible for an incremental render on the next flush.")

(defvar-local emacs-jupyter-notebook-panel--force-full-render nil
  "Non-nil when the next flush must rebuild the complete panel view.")

(defvar-local emacs-jupyter-notebook-panel--history-evicted-p nil
  "Non-nil once this panel has evicted retained history entries.")

(defvar-local emacs-jupyter-notebook-panel--retained-text-bytes 0
  "Cached total source and output text bytes retained by this panel.")

(defvar-local emacs-jupyter-notebook-panel--retained-artifact-bytes 0
  "Cached total image and MIME artifact bytes retained by this panel.")

(defvar-local emacs-jupyter-notebook-panel--retained-output-segments 0
  "Cached number of ordered output segments retained by this panel.")

(defvar emacs-jupyter-notebook-panel--next-array-identity 0
  "Process-local identity counter for numerical publications and workspaces.")

(defvar-local emacs-jupyter-notebook--array-workspace-identity nil
  "Stable source-buffer namespace for the numerical viewer.")

(defvar emacs-jupyter-notebook-panel--array-handoff-count 0
  "Number of outstanding numerical artifact handoff leases.")

(defconst emacs-jupyter-notebook-panel--max-array-handoffs 8
  "Global numerical handoff bound, including publications retired by panels.")

(defvar ejn-panel-array-published-hook nil
  "Hook run after a numerical publication is committed and retained.
Functions receive its effective entry handle and exact local output ID.
Consumers should schedule asynchronous inspection; hooks receive no lease.
Rejected, immediately evicted, or omitted publications do not run this hook.")

(defconst emacs-jupyter-notebook-panel--max-published-original-bytes 67108864
  "Maximum bytes retained for one compressed external-viewer original.")

(defconst emacs-jupyter-notebook-panel--max-published-preview-bytes 4194304
  "Maximum byte length of a canonical helper-generated PPM preview.")

(defconst emacs-jupyter-notebook-panel--max-inline-image-data-bytes
  emacs-jupyter-notebook-panel--max-published-preview-bytes
  "Maximum byte length accepted by the direct inline image API.
The helper-only runtime publishes image artifacts rather than inline data.
This narrow compatibility path remains synchronous, so it is deliberately
limited to the same 4 MiB ceiling as a helper preview and rejected before any
private artifact file is created.")

(defconst emacs-jupyter-notebook-panel--hard-image-pixels 4194304
  "Immutable helper protocol pixel ceiling for native image previews.")

(defconst emacs-jupyter-notebook-panel--hard-rendered-image-dimension 2048
  "Maximum scaled preview width or height handed to native redisplay.")

(defconst emacs-jupyter-notebook-panel--hard-image-slice-rows 256
  "Maximum display rows inserted synchronously for one preview.")

(defconst emacs-jupyter-notebook-panel--hard-inline-images 32
  "Immutable ceiling on native image specs materialized by one panel view.")

(defconst emacs-jupyter-notebook-panel--hard-entry-output-segments 256
  "Immutable ceiling on ordered output segments retained by one entry.")

(defconst emacs-jupyter-notebook-panel--hard-output-segments 4096
  "Immutable ceiling on ordered output segments retained by one panel.")

(defconst emacs-jupyter-notebook-panel--hard-history-entries 200
  "Immutable ceiling on entries retained by one panel.")

(defconst emacs-jupyter-notebook-panel--hard-entry-text-bytes (* 10 1024 1024)
  "Immutable ceiling on output text retained by one entry.")

(defconst emacs-jupyter-notebook-panel--hard-total-text-bytes (* 20 1024 1024)
  "Immutable ceiling on text retained by one panel.")

(defconst emacs-jupyter-notebook-panel--hard-total-artifact-bytes
  (* 100 1024 1024)
  "Immutable ceiling on artifacts retained by one panel.")

(defconst emacs-jupyter-notebook-panel--sliced-render-max-work-items 4
  "Immutable maximum logical render operations performed in one idle tick.")

(defconst emacs-jupyter-notebook-panel--sliced-render-max-text-bytes 65536
  "Immutable maximum text bytes inserted by one bounded render tick.")

(defconst emacs-jupyter-notebook-panel--sliced-render-max-clear-characters 8192
  "Immutable maximum panel-buffer characters deleted by one render tick.")

(defconst emacs-jupyter-notebook-panel--sliced-render-delay 0.001
  "Immutable positive delay between bounded full-render slices.
Using a regular timer rather than a zero-delay idle timer guarantees that an
event-loop turn occurs between slices, even while Emacs would otherwise remain
idle long enough to drain a whole retained history in one idle cycle.")

(defconst emacs-jupyter-notebook-panel--header-scan-max-characters 8192
  "Immutable maximum leading-code characters inspected for a panel header.")

(defconst emacs-jupyter-notebook-panel--hard-external-image-snapshots 4
  "Immutable ceiling on pending and retained external image snapshots.")

(defconst emacs-jupyter-notebook-panel--hard-external-image-snapshot-ttl 3600
  "Immutable lifetime ceiling in seconds for an external image snapshot.")

(defconst emacs-jupyter-notebook-panel--segment-omission-text
  "[additional output segments omitted]\n"
  "Marker retained once when an entry reaches its structural output bound.")

(defconst emacs-jupyter-notebook-panel--max-published-pickle-bytes 67108864
  "Maximum bytes accepted for one helper-published matplotlib pickle.
This finite ceiling matches the helper's decoded artifact ceiling.")

(defconst emacs-jupyter-notebook-panel--admitted-metadata-token
  (make-symbol "ejn-admitted-metadata")
  "Opaque token marking metadata that passed publication admission.
The token lets redraws use the immutable cached admission record without
mistaking an arbitrary user-created image plist for a helper publication.")

(defun emacs-jupyter-notebook-panel--positive-clamped (value hard-limit)
  "Return positive integer VALUE clamped to HARD-LIMIT, or zero."
  (if (and (integerp value) (> value 0))
      (min value hard-limit)
    0))

(defun emacs-jupyter-notebook-panel--entry-text-budget ()
  "Return the effective immutable per-entry text budget."
  (emacs-jupyter-notebook-panel--positive-clamped
   emacs-jupyter-notebook-result-max-bytes
   emacs-jupyter-notebook-panel--hard-entry-text-bytes))

(defun emacs-jupyter-notebook-panel--output-segment-budget ()
  "Return the effective immutable panel output-segment budget."
  (emacs-jupyter-notebook-panel--positive-clamped
   emacs-jupyter-notebook-panel-max-output-segments
   emacs-jupyter-notebook-panel--hard-output-segments))

(defun emacs-jupyter-notebook-panel--external-image-snapshot-budget ()
  "Return the effective immutable external image snapshot budget."
  (emacs-jupyter-notebook-panel--positive-clamped
   emacs-jupyter-notebook-external-image-max-snapshots
   emacs-jupyter-notebook-panel--hard-external-image-snapshots))

(defun emacs-jupyter-notebook-panel--external-image-snapshot-ttl ()
  "Return the effective bounded external image snapshot lifetime."
  (let ((value emacs-jupyter-notebook-external-image-snapshot-ttl))
    (if (and (numberp value) (> value 0))
        (min value
             emacs-jupyter-notebook-panel--hard-external-image-snapshot-ttl)
      1)))

(defun emacs-jupyter-notebook-panel--inline-image-pixel-budget ()
  "Return the configured helper preview budget, clamped to its hard ceiling."
  (let ((value emacs-jupyter-notebook-helper-inline-image-max-pixels))
    (if (and (integerp value) (> value 0))
        (min value emacs-jupyter-notebook-panel--hard-image-pixels)
      0)))

(defun emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p (width height)
  "Return non-nil when WIDTH and HEIGHT satisfy immutable and local limits."
  (and (integerp width) (integerp height)
       (> width 0) (> height 0)
       (<= width 1024)
       (<= height 1024)
       (<= (* width height)
           (emacs-jupyter-notebook-panel--inline-image-pixel-budget))))

(defvar emacs-jupyter-notebook-panel--text-materialization-count nil
  "Test instrument for text materializations, or nil when disabled.")

(defvar emacs-jupyter-notebook-panel--text-trim-chunk-visits nil
  "Test instrument for chunks examined by trimming, or nil when disabled.")

;;; Panel mode

(defvar emacs-jupyter-notebook-panel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'emacs-jupyter-notebook-panel-quit)
    (define-key map (kbd "H") #'emacs-jupyter-notebook-panel-toggle-view)
    (define-key map (kbd "TAB") #'emacs-jupyter-notebook-toggle-cell-output)
    (define-key map (kbd "<tab>") #'emacs-jupyter-notebook-toggle-cell-output)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-panel-visit-source)
    (define-key map (kbd "n") #'emacs-jupyter-notebook-panel-next-entry)
    (define-key map (kbd "p") #'emacs-jupyter-notebook-panel-previous-entry)
    (define-key map (kbd "f") #'emacs-jupyter-notebook-panel-resume-follow)
    (define-key map (kbd "i") #'emacs-jupyter-notebook-inspect)
    (define-key map (kbd "a") #'emacs-jupyter-notebook-actions)
    ;; W2.5: native image zoom keys for images rendered inline in the panel.
    (define-key map (kbd "+") #'emacs-jupyter-notebook-panel-image-zoom-in)
    (define-key map (kbd "=") #'emacs-jupyter-notebook-panel-image-zoom-in)
    (define-key map (kbd "-") #'emacs-jupyter-notebook-panel-image-zoom-out)
    ;; W18: open the original static image through a local external viewer.
    (define-key map (kbd "o") #'emacs-jupyter-notebook-panel-open-image-externally)
    ;; W8.5: open the figure at point interactively in the local viewer.
    (define-key map (kbd "v") #'emacs-jupyter-notebook-panel-open-figure)
    map)
  "Keymap for `emacs-jupyter-notebook-panel-mode'.")

(define-derived-mode emacs-jupyter-notebook-panel-mode special-mode
  "EJN-Panel"
  "Side-panel buffer that displays Jupyter evaluation output.
The latest-per-cell view shows the most recent output for each
evaluated cell, keyed by the cell's `# %%' marker location.  The
history-log view appends every evaluation in time order."
  (setq buffer-read-only t)
  ;; Text retention and sliced insertion do not bound redisplay's line layout.
  ;; A single long repr/stream must not wrap or run bidi paragraph analysis
  ;; every time a minibuffer frontend changes window geometry.
  (setq-local truncate-lines t)
  (setq-local bidi-display-reordering nil)
  (setq-local bidi-inhibit-bpa t)
  (setq header-line-format
        '(:eval (cond (emacs-jupyter-notebook-panel--follow-paused
                       "Reading output · f: follow source · a: actions")
                      (emacs-jupyter-notebook-panel--follow-empty
                       "Current cell has no output · a: actions")
                      (t "Following source · TAB: fold · i: inspect · a: actions"))))
  (add-hook 'window-scroll-functions
            #'emacs-jupyter-notebook-panel--window-scrolled nil t)
  (add-hook 'pre-command-hook #'emacs-jupyter-notebook-panel--user-command nil t)
  (add-hook 'post-command-hook #'emacs-jupyter-notebook-panel--user-command-finished nil t)
  (add-hook 'kill-buffer-hook
            #'emacs-jupyter-notebook-panel--on-kill nil t))

;; W16: under evil (Doom, Spacemacs, ...) special-mode buffers land in
;; motion/normal state, whose maps SHADOW the panel's single-key commands —
;; `H' becomes move-to-window-top, `v' starts visual selection, `+'/`-' are
;; line motions — so toggle/zoom/open-figure silently never ran.  Put the
;; panel in emacs state so its keymap works exactly as designed.
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function emacs-jupyter-notebook-inspect "emacs-jupyter-notebook-actions")
(declare-function emacs-jupyter-notebook-actions "emacs-jupyter-notebook-actions")
(with-eval-after-load 'evil
  (evil-set-initial-state 'emacs-jupyter-notebook-panel-mode 'emacs)
  ;; Honor an explicit switch to normal/motion state as well as Doom's
  ;; special-buffer state preferences without affecting insert-state TAB.
  (evil-define-key* '(normal motion) emacs-jupyter-notebook-panel-mode-map
    (kbd "TAB") #'emacs-jupyter-notebook-toggle-cell-output
    (kbd "<tab>") #'emacs-jupyter-notebook-toggle-cell-output
    (kbd "f") #'emacs-jupyter-notebook-panel-resume-follow
    (kbd "i") #'emacs-jupyter-notebook-inspect
    (kbd "a") #'emacs-jupyter-notebook-actions))

(defun emacs-jupyter-notebook-panel--on-kill ()
  "Release timers, cached images, and private files owned by this panel."
  (when (timerp emacs-jupyter-notebook-panel--flush-timer)
    (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
  (setq emacs-jupyter-notebook-panel--flush-timer nil)
  (when (timerp emacs-jupyter-notebook-panel--duration-timer)
    (cancel-timer emacs-jupyter-notebook-panel--duration-timer))
  (setq emacs-jupyter-notebook-panel--duration-timer nil)
  (emacs-jupyter-notebook-panel--cancel-sliced-render)
  (emacs-jupyter-notebook-panel--cleanup-external-image-opens-for-panel
   (current-buffer))
  (emacs-jupyter-notebook-panel--retire-all-artifacts (current-buffer)))

(defun emacs-jupyter-notebook-panel--cleanup-published-artifacts-on-exit ()
  "Release panel-owned image files and image-cache objects on Emacs exit.
This deliberately only touches local panel buffers.  It does not kill a
panel, inspect the registry, contact SSH, or send any kernel action."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
          (emacs-jupyter-notebook-panel--retire-all-artifacts buffer))))))

(add-hook 'kill-emacs-hook
          #'emacs-jupyter-notebook-panel--cleanup-published-artifacts-on-exit)

;;; Buffer naming & lookup

(defun emacs-jupyter-notebook-panel--name-for (source-buffer)
  "Return the panel buffer name for SOURCE-BUFFER.
Uses SOURCE-BUFFER's `buffer-name' verbatim (which Emacs already
disambiguates with `<2>' suffixes when two buffers visit different files
with the same basename) so distinct sources always map to distinct panels."
  (format "*ejn: %s*" (buffer-name source-buffer)))

(defvar-local emacs-jupyter-notebook--panel-buffer nil
  "Source-buffer-local: the panel buffer attached to this source.")

(defun ejn-panel-ensure (source-buffer)
  "Return (creating if needed) the panel buffer for SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (or (and (buffer-live-p emacs-jupyter-notebook--panel-buffer)
             emacs-jupyter-notebook--panel-buffer)
        (let* ((name (emacs-jupyter-notebook-panel--name-for source-buffer))
               (panel (get-buffer-create name)))
          (with-current-buffer panel
            (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
              (emacs-jupyter-notebook-panel-mode))
            (setq emacs-jupyter-notebook-panel--source-buffer source-buffer)
            (setq emacs-jupyter-notebook-panel--view
                  emacs-jupyter-notebook-panel-default-view))
          (setq emacs-jupyter-notebook--panel-buffer panel)
          ;; The panel owns disposable temp images even when tests or callers
          ;; use the panel API without enabling the source minor mode.
          (add-hook 'kill-buffer-hook
                    #'emacs-jupyter-notebook--kill-panel nil t)
          panel))))

(defun emacs-jupyter-notebook-panel-buffer (source-buffer)
  "Return SOURCE-BUFFER's panel buffer, or nil if not yet created."
  (when (buffer-live-p source-buffer)
    (with-current-buffer source-buffer
      (and (buffer-live-p emacs-jupyter-notebook--panel-buffer)
           emacs-jupyter-notebook--panel-buffer))))

(defun emacs-jupyter-notebook-panel--display (panel)
  "Pop PANEL up in a side window honoring the user's customization."
  (prog1
      (display-buffer
       panel
       `((display-buffer-in-side-window)
         (side . ,emacs-jupyter-notebook-panel-side)
         (window-width . ,emacs-jupyter-notebook-panel-width)))
    (emacs-jupyter-notebook-panel--track-duration panel)))

(defun emacs-jupyter-notebook-show-output-panel ()
  "Open or pop up the current source buffer's output panel."
  (interactive)
  (let ((panel (ejn-panel-ensure (current-buffer))))
    (emacs-jupyter-notebook-panel--display panel)
    (emacs-jupyter-notebook-panel--source-post-command t)))

(defun emacs-jupyter-notebook-panel--pause-follow ()
  "Keep this panel's reading position until the source changes cells."
  (setq emacs-jupyter-notebook-panel--follow-paused t
        emacs-jupyter-notebook-panel--reveal-entry-id nil)
  (force-mode-line-update))

(defun emacs-jupyter-notebook-panel--user-command ()
  "Treat navigation in the selected panel as a request to read independently."
  (unless (memq this-command '(emacs-jupyter-notebook-panel-resume-follow
                              emacs-jupyter-notebook-toggle-cell-output
                              emacs-jupyter-notebook-actions
                              emacs-jupyter-notebook-inspect))
    (emacs-jupyter-notebook-panel--pause-follow)))

(defun emacs-jupyter-notebook-panel--user-command-finished ()
  "Retain navigation made while a sliced redraw is still in progress."
  (when (and emacs-jupyter-notebook-panel--follow-paused
             emacs-jupyter-notebook-panel--navigation-snapshot)
    (setq emacs-jupyter-notebook-panel--navigation-snapshot nil)
    (emacs-jupyter-notebook-panel--capture-navigation)))

(defun emacs-jupyter-notebook-panel--window-scrolled (window start)
  "Pause following when an interactive scroll moves WINDOW to START.
Mouse wheels may scroll an unselected panel while point remains in source.
Ignore redisplay-driven and programmatic window changes."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (not emacs-jupyter-notebook-panel--adjusting-window)
             (not (equal start (window-parameter window 'ejn-panel-programmatic-start)))
             (symbolp this-command)
             (string-match-p (regexp-opt '("scroll" "wheel" "recenter"))
                             (symbol-name this-command)))
    (emacs-jupyter-notebook-panel--pause-follow)
    (emacs-jupyter-notebook-panel--user-command-finished)))

(defun emacs-jupyter-notebook-panel--position-anchor (position)
  "Describe panel POSITION by entry identity and offset for later restoration."
  (save-excursion
    (goto-char (max (point-min) (min (point-max) position)))
    (let* ((id (emacs-jupyter-notebook-panel--entry-id-at-point))
           (bounds (and id (emacs-jupyter-notebook-panel--entry-bounds id))))
      (if bounds
          (let* ((position (point))
                 (body-start (progn (goto-char (car bounds))
                                    (min (cdr bounds) (1+ (line-end-position))))))
            (if (>= position body-start)
                (list :id id :body-offset (- position body-start))
              (list :id id :offset (- position (car bounds)))))
        (list :absolute (point))))))

(defun emacs-jupyter-notebook-panel--anchor-position (anchor)
  "Resolve a retained reading ANCHOR against the current panel layout."
  (if-let ((id (plist-get anchor :id)))
      (when-let ((bounds (emacs-jupyter-notebook-panel--entry-bounds id)))
        (min (max (car bounds) (1- (cdr bounds)))
             (if (plist-member anchor :body-offset)
                 (+ (save-excursion
                      (goto-char (car bounds))
                      (1+ (line-end-position)))
                    (plist-get anchor :body-offset))
               (+ (car bounds) (plist-get anchor :offset)))))
    (max (point-min) (min (point-max) (or (plist-get anchor :absolute) (point-min))))))

(defun emacs-jupyter-notebook-panel--capture-navigation ()
  "Remember panel reading positions once before a cancellable full redraw."
  (unless emacs-jupyter-notebook-panel--navigation-snapshot
    (setq emacs-jupyter-notebook-panel--navigation-snapshot
          (list :point (emacs-jupyter-notebook-panel--position-anchor (point))
                :at-end (= (point) (point-max))
                :windows
                (mapcar
                 (lambda (window)
                   (list window
                         (emacs-jupyter-notebook-panel--position-anchor (window-start window))
                         (emacs-jupyter-notebook-panel--position-anchor (window-point window))
                         (window-vscroll window t)))
                 (get-buffer-window-list (current-buffer) nil t))))))

(defun emacs-jupyter-notebook-panel--apply-reveal ()
  "Reveal a requested entry once this panel has a complete current layout."
  (when (and emacs-jupyter-notebook-panel--reveal-entry-id
             (not emacs-jupyter-notebook-panel--follow-paused)
             (not emacs-jupyter-notebook-panel--dirty)
             (not emacs-jupyter-notebook-panel--sliced-render-job))
    (when-let ((bounds (emacs-jupyter-notebook-panel--entry-bounds
                       emacs-jupyter-notebook-panel--reveal-entry-id)))
      (let ((position (car bounds))
            (emacs-jupyter-notebook-panel--adjusting-window t))
        (goto-char position)
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (set-window-parameter window 'ejn-panel-programmatic-start position)
          (set-window-start window position t)
          (set-window-point window position)
          (set-window-vscroll window 0 t)))
      (setq emacs-jupyter-notebook-panel--reveal-entry-id nil))))

(defun emacs-jupyter-notebook-panel--finish-navigation ()
  "Restore reading positions, then apply an explicit reveal or fold target."
  (let ((snapshot emacs-jupyter-notebook-panel--navigation-snapshot)
        (emacs-jupyter-notebook-panel--adjusting-window t))
    (setq emacs-jupyter-notebook-panel--navigation-snapshot nil)
    (if (and snapshot
             (not (and (plist-get snapshot :at-end)
                       (eq emacs-jupyter-notebook-panel--view 'history)
                       (not emacs-jupyter-notebook-panel--follow-paused))))
        (progn
          (when-let ((position (emacs-jupyter-notebook-panel--anchor-position
                               (plist-get snapshot :point))))
            (goto-char position))
          (dolist (saved (plist-get snapshot :windows))
            (let ((window (nth 0 saved)))
              (when (and (window-live-p window)
                         (eq (window-buffer window) (current-buffer)))
                (when-let ((position (emacs-jupyter-notebook-panel--anchor-position (nth 1 saved))))
                  (set-window-parameter window 'ejn-panel-programmatic-start position)
                  (set-window-start window position t)
                  (set-window-vscroll window (nth 3 saved) t))
                (when-let ((position (emacs-jupyter-notebook-panel--anchor-position (nth 2 saved))))
                  (set-window-point window position))))))
      (goto-char (if (eq emacs-jupyter-notebook-panel--view 'history)
                     (point-max) (point-min))))
    (emacs-jupyter-notebook-panel--restore-entry-point)
    (emacs-jupyter-notebook-panel--apply-reveal)))

(defun ejn-panel-reveal-entry (handle)
  "Reveal live HANDLE without selecting the output window.
History-only executions select history view so region/inspection output is
visible immediately.  A pending render performs the reveal when it completes."
  (when (ejn-panel-entry-live-p handle)
    (with-current-buffer (plist-get handle :panel)
      ;; The evaluation command itself will run the source post-command hook.
      ;; Remember its cell now so that hook cannot immediately replace a
      ;; region/inspection reveal with the last whole-cell result.
      (when (buffer-live-p emacs-jupyter-notebook-panel--source-buffer)
        (with-current-buffer emacs-jupyter-notebook-panel--source-buffer
          (setq emacs-jupyter-notebook-panel--last-source-cell
                (emacs-jupyter-notebook--cell-key-for
                 (car (emacs-jupyter-notebook-cell-full-bounds))))))
      (setq emacs-jupyter-notebook-panel--follow-paused nil
            emacs-jupyter-notebook-panel--follow-empty nil
            emacs-jupyter-notebook-panel--reveal-entry-id (plist-get handle :id))
      (when (and (null (plist-get handle :cell-key))
                 (not (eq emacs-jupyter-notebook-panel--view 'history)))
        (setq emacs-jupyter-notebook-panel--view 'history)
        (emacs-jupyter-notebook-panel--invalidate-structure (current-buffer)))
      (emacs-jupyter-notebook-panel--apply-reveal)
      (emacs-jupyter-notebook-panel--track-duration (current-buffer))
      (force-mode-line-update))))

(defun emacs-jupyter-notebook-panel--source-post-command (&optional force)
  "Reveal the current source cell after crossing its boundary.
FORCE permits an explicit reveal while a panel or action menu is selected.
Automatic following skips large sources to bound work during ordinary editing."
  (when (and (or force emacs-jupyter-notebook-panel-follow-source)
             (or force (<= (buffer-size) emacs-jupyter-notebook-cell--automatic-scan-limit))
             (or force (eq (window-buffer (selected-window)) (current-buffer))))
    (when-let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
      (when (get-buffer-window panel t)
        (let* ((start (car (emacs-jupyter-notebook-cell-full-bounds)))
               ;; Following an unevaluated cell needs no durable output ID.
               ;; Allocating one here made each subsequent edit walk every
               ;; cell the user had merely navigated through.
               (key (or (emacs-jupyter-notebook--cell-key-for start t)
                        (cons :unevaluated start))))
          (when (or force (not (equal key emacs-jupyter-notebook-panel--last-source-cell)))
            (setq emacs-jupyter-notebook-panel--last-source-cell key)
            (with-current-buffer panel
              (let ((entry (cl-find-if
                            (lambda (cell) (equal key (plist-get (cdr cell) :cell-key)))
                            (reverse emacs-jupyter-notebook-panel--entries))))
                (setq emacs-jupyter-notebook-panel--follow-paused nil
                      emacs-jupyter-notebook-panel--follow-empty (null entry)
                      emacs-jupyter-notebook-panel--reveal-entry-id (car-safe entry))
                (emacs-jupyter-notebook-panel--apply-reveal)
                (force-mode-line-update)))))))))

(defun emacs-jupyter-notebook-panel-resume-follow ()
  "Resume following the current source cell without changing selected windows."
  (interactive)
  (let ((source (if (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
                    emacs-jupyter-notebook-panel--source-buffer (current-buffer))))
    (unless (buffer-live-p source) (user-error "The source buffer is no longer open"))
    (with-current-buffer source
      (setq-local emacs-jupyter-notebook-panel-follow-source t)
      (emacs-jupyter-notebook-panel--source-post-command t))))

;;; Entry handle helpers

(defun emacs-jupyter-notebook-panel--entry (panel id)
  "Return the entry plist with ID in PANEL, or nil."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (cdr (assq id emacs-jupyter-notebook-panel--entries)))))

(defun emacs-jupyter-notebook-panel--set-entry (panel id new-entry)
  "Replace entry with ID in PANEL with NEW-ENTRY."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (let ((cell (assq id emacs-jupyter-notebook-panel--entries)))
        (if cell
            (setcdr cell new-entry)
          (setq emacs-jupyter-notebook-panel--entries
                (append emacs-jupyter-notebook-panel--entries
                        (list (cons id new-entry)))))))))

(defun emacs-jupyter-notebook-panel--handle (panel id key)
  "Return a public entry handle for ID in PANEL with cell KEY."
  (list :panel panel :id id
        :generation (with-current-buffer panel
                      emacs-jupyter-notebook-panel--generation)
        :cell-key key))

(defun ejn-panel-entry-live-p (handle)
  "Return non-nil when HANDLE still names its original live panel entry.
The generation check turns all handles created before `ejn-panel-clear-all'
into inert values.  Callback code uses this before decoding or storing any
payload, so late IOPub output cannot recreate retired local artifacts."
  (let ((panel (plist-get handle :panel)))
    (and handle
         (buffer-live-p panel)
         (with-current-buffer panel
           (and (equal (plist-get handle :generation)
                       emacs-jupyter-notebook-panel--generation)
                (emacs-jupyter-notebook-panel--entry
                 panel (plist-get handle :id)))))))

(defun emacs-jupyter-notebook-panel--update-entry (handle updater &optional force-full)
  "Apply UPDATER to the entry referenced by HANDLE and schedule a render.
UPDATER is called with the current entry plist and must return a new plist.
When FORCE-FULL is non-nil, rebuild the whole view because image-preview
membership or entry ordering may have changed.  FORCE-FULL may also be a
function receiving OLD-ENTRY and NEW-ENTRY and returning that boolean."
  (when (ejn-panel-entry-live-p handle)
    (let ((panel (plist-get handle :panel))
          (id (plist-get handle :id)))
      (when (buffer-live-p panel)
        (let ((entry (emacs-jupyter-notebook-panel--entry panel id)))
          (when entry
            (let ((old-text (emacs-jupyter-notebook-panel--entry-text-bytes entry))
                  (old-artifacts (emacs-jupyter-notebook-panel--entry-artifact-bytes entry))
                  (old-segments (length (plist-get entry :outputs)))
                  (new (funcall updater entry)))
              (when (functionp force-full)
                (setq force-full (funcall force-full entry new)))
              (with-current-buffer panel
                (cl-incf emacs-jupyter-notebook-panel--retained-text-bytes
                         (- (emacs-jupyter-notebook-panel--entry-text-bytes new) old-text))
                (cl-incf emacs-jupyter-notebook-panel--retained-artifact-bytes
                         (- (emacs-jupyter-notebook-panel--entry-artifact-bytes new)
                            old-artifacts))
                (cl-incf emacs-jupyter-notebook-panel--retained-output-segments
                         (- (length (plist-get new :outputs))
                            old-segments)))
              (emacs-jupyter-notebook-panel--set-entry panel id new)
              (emacs-jupyter-notebook-panel--schedule-render
               panel id force-full))))))))

(defun emacs-jupyter-notebook-panel--cancel-pickle-open-timer (entry)
  "Cancel ENTRY's pending auto-viewer timer and return the cleared entry."
  (when (timerp (plist-get entry :pickle-open-timer))
    (cancel-timer (plist-get entry :pickle-open-timer)))
  (setq entry (plist-put entry :pickle-open-timer nil))
  (plist-put entry :pickle-open-token nil))

(defun emacs-jupyter-notebook-panel--mutate-live-entry (handle updater)
  "Apply UPDATER to live HANDLE without scheduling a presentation render."
  (when (ejn-panel-entry-live-p handle)
    (let ((panel (plist-get handle :panel))
          (id (plist-get handle :id)))
      (with-current-buffer panel
        (when-let ((cell (assq id emacs-jupyter-notebook-panel--entries)))
          (setcdr cell (funcall updater (cdr cell)))
          t)))))

(defun emacs-jupyter-notebook-panel--claim-pickle-open-timer (handle token timer)
  "Return HANDLE's current pickle when TOKEN and TIMER still own its slot.
The matching slot is cleared atomically before the caller opens the viewer."
  (let (pickle)
    (when (emacs-jupyter-notebook-panel--mutate-live-entry
           handle
           (lambda (entry)
             (when (and (eq token (plist-get entry :pickle-open-token))
                        (eq timer (plist-get entry :pickle-open-timer)))
               (setq pickle (plist-get entry :mpl-pickle))
               (when pickle
                 (plist-put pickle :leases (1+ (or (plist-get pickle :leases) 0))))
               (setq entry (plist-put entry :pickle-open-timer nil))
               (setq entry (plist-put entry :pickle-open-token nil)))
             entry))
      pickle)))

(defun ejn-panel-schedule-pickle-open (handle opener)
  "Coalesce HANDLE's deferred pickle open and call OPENER with live metadata.
Only one idle timer may be pending per entry.  Neither the timer nor OPENER
captures artifact contents; the callback revalidates HANDLE and reads the
entry metadata only after claiming its current timer slot."
  (when (ejn-panel-entry-live-p handle)
    (let ((token (list))
          timer)
      (when (emacs-jupyter-notebook-panel--mutate-live-entry
             handle
             (lambda (entry)
               (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                            entry))
               (plist-put entry :pickle-open-token token)))
        (setq timer
              (run-with-idle-timer
               0 nil
               (lambda ()
                 (when-let ((pickle (emacs-jupyter-notebook-panel--claim-pickle-open-timer
                                     handle token timer)))
                   (funcall opener pickle)))))
        (unless (emacs-jupyter-notebook-panel--mutate-live-entry
                 handle
                 (lambda (entry)
                   (if (eq token (plist-get entry :pickle-open-token))
                       (plist-put entry :pickle-open-timer timer)
                     entry)))
          (cancel-timer timer))))))

;;; Render scheduling (W2.4 throttle)

(defconst emacs-jupyter-notebook-panel--hard-stream-throttle-min-ms 25)
(defconst emacs-jupyter-notebook-panel--hard-stream-throttle-max-ms 1000)

(defun emacs-jupyter-notebook-panel--stream-throttle-delay ()
  "Return the immutable bounded panel flush delay in seconds."
  (/ (emacs-jupyter-notebook--bounded-positive-option
      emacs-jupyter-notebook-panel-stream-throttle-ms 50
      emacs-jupyter-notebook-panel--hard-stream-throttle-min-ms
      emacs-jupyter-notebook-panel--hard-stream-throttle-max-ms)
     1000.0))

(defun emacs-jupyter-notebook-panel--cancel-sliced-render ()
  "Retire the current full render without changing retained panel state.
The generation token blocks a callback queued before cancellation from
writing stale output."
  (when (or emacs-jupyter-notebook-panel--sliced-render-job
            (timerp emacs-jupyter-notebook-panel--sliced-render-timer))
    (when (timerp emacs-jupyter-notebook-panel--sliced-render-timer)
      (cancel-timer emacs-jupyter-notebook-panel--sliced-render-timer))
    (setq emacs-jupyter-notebook-panel--sliced-render-timer nil
          emacs-jupyter-notebook-panel--sliced-render-job nil)
    (cl-incf emacs-jupyter-notebook-panel--sliced-render-generation)))

(defun emacs-jupyter-notebook-panel--schedule-render (panel &optional entry-id force-full)
  "Mark PANEL dirty and schedule a flush within the throttle window.

W2.4: every API call that changes an entry routes through this scheduler.
The actual render runs at most once per
`emacs-jupyter-notebook-panel-stream-throttle-ms' milliseconds; intervening
calls just set the dirty flag.  This is non-blocking: stream events keep
arriving while the timer is pending, and the next flush picks up whatever
state the entries are in at flush time."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      ;; A partially rendered full view is only a presentation cache.  Any
      ;; mutation invalidates it before the next scheduled callback can insert old
      ;; segments or clear a newly accumulated stream suffix.
      (let ((sliced-render-active-p
             (or emacs-jupyter-notebook-panel--sliced-render-job
                 (timerp emacs-jupyter-notebook-panel--sliced-render-timer))))
        (emacs-jupyter-notebook-panel--cancel-sliced-render)
        ;; The visible buffer is now a prefix of an old generation, so an
        ;; entry-local replacement cannot safely find its true bounds.  Route
        ;; the next pass through the bounded full renderer instead.
        (when sliced-render-active-p
          (setq force-full t)))
      (setq emacs-jupyter-notebook-panel--dirty t)
      (when entry-id
        (cl-pushnew entry-id emacs-jupyter-notebook-panel--dirty-entry-ids))
      (when force-full
        (setq emacs-jupyter-notebook-panel--force-full-render t))
      (unless (timerp emacs-jupyter-notebook-panel--flush-timer)
        (let ((delay (emacs-jupyter-notebook-panel--stream-throttle-delay)))
          (setq emacs-jupyter-notebook-panel--flush-timer
                (run-at-time
                 delay nil
                 #'emacs-jupyter-notebook-panel--flush panel)))))))

(defun emacs-jupyter-notebook-panel--invalidate-structure (panel)
  "Schedule a complete PANEL render after its visible layout changes.

Use this for changes to the current view, its visible entry membership, or
the source-cell ordering that determines latest-view order.  Content-only
updates continue to carry an entry id through `--schedule-render' and can use
the incremental renderer."
  (emacs-jupyter-notebook-panel--schedule-render panel nil t))

(defun emacs-jupyter-notebook-panel--flush (panel)
  "Flush pending changes for PANEL by re-rendering."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (setq emacs-jupyter-notebook-panel--flush-timer nil)
      (when emacs-jupyter-notebook-panel--dirty
        (setq emacs-jupyter-notebook-panel--dirty nil)
        (if (or emacs-jupyter-notebook-panel--force-full-render
                (null emacs-jupyter-notebook-panel--dirty-entry-ids))
            (emacs-jupyter-notebook-panel--start-sliced-render panel)
          (emacs-jupyter-notebook-panel--render-dirty-entries panel t))))))

(defun emacs-jupyter-notebook-panel-flush-now (panel)
  "Force PANEL to render immediately, cancelling any pending throttle timer."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (when (timerp emacs-jupyter-notebook-panel--flush-timer)
        (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
      (setq emacs-jupyter-notebook-panel--flush-timer nil)
      (emacs-jupyter-notebook-panel--cancel-sliced-render)
      (setq emacs-jupyter-notebook-panel--dirty nil)
      (if (or emacs-jupyter-notebook-panel--force-full-render
              (null emacs-jupyter-notebook-panel--dirty-entry-ids))
          (emacs-jupyter-notebook-panel--render panel)
        (emacs-jupyter-notebook-panel--render-dirty-entries panel)))))

;;; Rendering

;; Forward declaration: the buffer-local definition lives further down (see
;; `defvar-local' near the cell-key marker registry); referenced here on the
;; SOURCE buffer via `with-current-buffer'.
(defvar emacs-jupyter-notebook--cell-key-markers)

(defun emacs-jupyter-notebook-panel--key-position (key source-buffer)
  "Return the current buffer position for cell KEY in SOURCE-BUFFER.
If KEY's cdr is an integer cell id and SOURCE-BUFFER has a registered
marker for it, return that marker's current position.  Otherwise fall
back to the cdr verbatim when it is a number, or nil."
  (let ((id (cdr key)))
    (or (and (integerp id)
             (buffer-live-p source-buffer)
             (with-current-buffer source-buffer
               (let ((marker (and emacs-jupyter-notebook--cell-key-markers
                                  (gethash id emacs-jupyter-notebook--cell-key-markers))))
                 (and (markerp marker)
                      (eq (marker-buffer marker) source-buffer)
                      (marker-position marker)))))
        (and (numberp id) id))))

(defun emacs-jupyter-notebook-panel--latest-per-cell (entries)
  "Return ENTRIES filtered to one (latest) per cell-key.
Order of the returned list is preserved from ENTRIES."
  (let ((seen (make-hash-table :test 'equal))
        keep)
    ;; Walk back-to-front; first occurrence per key (i.e. the latest) wins.
    (dolist (e (reverse entries))
      (let ((key (plist-get e :cell-key)))
        (when (and key (not (gethash key seen)))
          (puthash key t seen)
          (push e keep))))
    keep))

(defun emacs-jupyter-notebook-panel--visible-entries ()
  "Return the entries visible under the current view, in display order.
History view shows every entry in insertion order.  Latest-per-cell view
collapses to the most recent entry per cell key and sorts by the cell's
current position in the source buffer (falling back to the key cdr when
no source-buffer marker is registered, e.g. in tests)."
  (let ((all (mapcar #'cdr emacs-jupyter-notebook-panel--entries)))
    (cond
     ((eq emacs-jupyter-notebook-panel--view 'history)
      all)
     (t
      (let* ((source (or emacs-jupyter-notebook-panel--source-buffer
                         (current-buffer)))
             (entries (cl-remove-if-not
                       (lambda (e) (plist-get e :cell-key))
                       (emacs-jupyter-notebook-panel--latest-per-cell all))))
        (sort (copy-sequence entries)
              (lambda (a b)
                (let ((pa (emacs-jupyter-notebook-panel--key-position
                           (plist-get a :cell-key) source))
                      (pb (emacs-jupyter-notebook-panel--key-position
                           (plist-get b :cell-key) source)))
                  (cond
                   ((and (numberp pa) (numberp pb)) (< pa pb))
                   ((numberp pa) t)
                   (t nil))))))))))

(defun emacs-jupyter-notebook-panel--image-specs (entries)
  "Return image specs in ENTRIES in their display order."
  (cl-loop for entry in entries
           unless (plist-get entry :hidden)
           append (cl-loop for seg in (plist-get entry :outputs)
                           when (eq (car seg) 'image)
                           collect (cdr seg))))

(defun emacs-jupyter-notebook-panel--native-image-safe-p (image)
  "Return non-nil when IMAGE may reach an Emacs native image API.
Legacy image specs have no helper publication root and are presentation-only on
graphical displays.  A helper-published image is native-safe only through its
separate canonical PPM preview; its compressed original is never examined.
The PPM bytes, digest, identity, dimensions, and size are checked once at
admission and then reused from the opaque cached metadata record, so repeated
redisplay performs no file stat or content read on Emacs's UI thread."
  (let ((props (and (consp image) (cdr image))))
    (if (not (plist-member props :ejn-publication-root))
        ;; Direct/legacy specs are retained for non-graphic batch rendering,
        ;; but must never hand an unvalidated local file or inline payload to a
        ;; graphical native decoder.  Helper publications use the strict PPM
        ;; branch below.
        (not (display-graphic-p))
      (let* ((preview (plist-get props :ejn-preview))
             (path (plist-get props :file))
             (width (and preview (plist-get preview :width)))
             (height (and preview (plist-get preview :height))))
        (and (listp preview)
             (eq (plist-get preview :ejn-admitted)
                 emacs-jupyter-notebook-panel--admitted-metadata-token)
             (eq (plist-get props :type) 'pbm)
             (equal path (plist-get preview :file))
             (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p
              width height)
             (condition-case nil
                 (let ((checked
                        (emacs-jupyter-notebook-panel--published-artifact-metadata
                         (plist-get preview :root) (plist-get preview :file)
                         (plist-get preview :sha256) (plist-get preview :size)
                         (plist-get preview :root-identity)
                         emacs-jupyter-notebook-panel--max-published-preview-bytes
                         nil nil nil
                         (plist-get preview :artifact-capability)
                         preview)))
                   (eq checked preview))
               (error nil)))))))

(defun emacs-jupyter-notebook-panel--bounded-image-scale (image scale)
  "Return positive SCALE bounded by IMAGE's rendered dimensions.
Published previews carry trusted dimensions; direct batch-only specs use a
fixed scale ceiling.  Invalid, infinite, and excessive scales cannot enlarge
native surfaces or make image slicing allocate an unbounded list."
  (let* ((preview (plist-get (cdr image) :ejn-preview))
         (width (plist-get preview :width))
         (height (plist-get preview :height))
         (limit (if (and (integerp width) (> width 0)
                         (integerp height) (> height 0))
                    (min 8.0
                         (/ (float emacs-jupyter-notebook-panel--hard-rendered-image-dimension)
                            (max width height)))
                  8.0)))
    (if (and (numberp scale) (> scale 0))
        (min limit (max 0.05 scale))
      (min limit 1.0))))

(defun emacs-jupyter-notebook-panel--native-preview-spec (image)
  "Return IMAGE's minimal native preview spec, with no original metadata.
Helper image records intentionally retain their compressed original for `o'.
That record must never become part of an argument to a native image function,
including cache flushing.  Legacy local image specs retain their established
path because they do not carry helper publication fields."
  (let ((props (and (consp image) (cdr image))))
    (if (not (plist-member props :ejn-publication-root))
        image
      (let ((preview (plist-get props :ejn-preview)))
        (when (listp preview)
          (append
           (list 'image :type 'pbm :file (plist-get preview :file))
           (when (plist-member props :scale)
             (list :scale (emacs-jupyter-notebook-panel--bounded-image-scale
                           image (plist-get props :scale))))
           (when (plist-member props :max-width)
             (list :max-width (plist-get props :max-width)))
           (when (plist-member props :max-height)
             (list :max-height (plist-get props :max-height)))))))))

(defun emacs-jupyter-notebook-panel--trusted-preview-slice-rows (image)
  "Return IMAGE's slice row count from admitted preview metadata.
Unlike `image-size', this only uses the validated PPM dimensions and the
explicit panel scale bounds.  Legacy specs have no trusted dimensions and
therefore decline slicing rather than synchronously asking a native decoder."
  (let* ((props (and (consp image) (cdr image)))
         (preview (and props (plist-get props :ejn-preview)))
         (width (and (listp preview) (plist-get preview :width)))
         (height (and (listp preview) (plist-get preview :height)))
         (raw-scale (and props (plist-get props :scale)))
         (scale (emacs-jupyter-notebook-panel--bounded-image-scale image raw-scale))
         (max-width (and props (plist-get props :max-width)))
         (max-height (and props (plist-get props :max-height)))
         (rendered-width (and (integerp width) (* width scale)))
         (rendered-height (and (integerp height) (* height scale)))
         (ratio 1.0))
    (when (and (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p
               width height)
               (> rendered-width 0) (> rendered-height 0))
      (when (and (numberp max-width) (> max-width 0))
        (setq ratio (min ratio (/ max-width (float rendered-width)))))
      (when (and (numberp max-height) (> max-height 0))
        (setq ratio (min ratio (/ max-height (float rendered-height)))))
      (let ((char-height (max 1 (or (frame-char-height) 1))))
        (min emacs-jupyter-notebook-panel--hard-image-slice-rows
             (max 1 (ceiling (* rendered-height ratio) char-height)))))))

(defun emacs-jupyter-notebook-panel--inline-image-admitted-p (image)
  "Return non-nil when IMAGE is a cheap candidate for bounded inline preview.
This deliberately performs no file access.  The full fixed-header and identity
check belongs immediately at the native image boundary, after the panel has
already reduced candidates to its small inline-preview budget.
"
  (let ((props (and (consp image) (cdr image))))
    (or (not (plist-member props :ejn-publication-root))
        (let ((preview (plist-get props :ejn-preview)))
          (and (listp preview)
               (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p
                (plist-get preview :width)
                (plist-get preview :height)))))))

(defun emacs-jupyter-notebook-panel--bounded-inline-specs (entries)
  "Return the newest bounded subset of image specs visible in ENTRIES.
Newness follows entry creation ids, rather than source-position display order."
  (let* ((creation-order
          (sort (copy-sequence entries)
                (lambda (a b) (< (plist-get a :id) (plist-get b :id)))))
         (specs (emacs-jupyter-notebook-panel--image-specs creation-order))
         (max (emacs-jupyter-notebook-panel--positive-clamped
               emacs-jupyter-notebook-panel-max-inline-images
               emacs-jupyter-notebook-panel--hard-inline-images)))
    (if (and (integerp max) (> max 0))
        (let ((safe (cl-remove-if-not
                     #'emacs-jupyter-notebook-panel--inline-image-admitted-p specs)))
          (last safe (min max (length safe))))
      nil)))

(defun emacs-jupyter-notebook-panel--image-update-needs-full-p
    (panel new-entry old-image new-image)
  "Return non-nil when replacing OLD-IMAGE needs a full PANEL render.
An existing inline image can be replaced incrementally when both old and new
specs occupy the same inline admission state.  A transition between inline
and placeholder changes another entry's materialization and therefore needs a
complete view rebuild."
  (if (null old-image)
      t
    (with-current-buffer panel
      (let* ((old-inline (and (memq old-image
                                    emacs-jupyter-notebook-panel--inline-image-specs)
                              t))
             (new-id (plist-get new-entry :id))
             (prospective
              (mapcar (lambda (entry)
                        (if (= (plist-get entry :id) new-id)
                            new-entry
                          entry))
                      (emacs-jupyter-notebook-panel--visible-entries)))
             (new-inline
              (emacs-jupyter-notebook-panel--bounded-inline-specs prospective))
             (new-inline-p (and (memq new-image new-inline) t)))
        (not (eq old-inline new-inline-p))))))

(defun emacs-jupyter-notebook-panel--set-inline-specs (specs)
  "Install SPECS as the inline set, flushing previews that were demoted."
  (dolist (old emacs-jupyter-notebook-panel--inline-image-specs)
    (unless (member old specs)
      ;; A demoted placeholder was never decoded.  Do not re-read/hash every
      ;; retained image merely to decide whether to flush its cache entry.
      (when (plist-get (cdr old) :ejn-materialized)
        (when-let ((preview (emacs-jupyter-notebook-panel--native-preview-spec old)))
          (ignore-errors (image-flush preview t)))
        (plist-put (cdr old) :ejn-materialized nil))))
  (setq emacs-jupyter-notebook-panel--inline-image-specs specs))

(defun emacs-jupyter-notebook-panel--insert-image-placeholder (image index)
  "Insert a lightweight placeholder for IMAGE tagged with segment INDEX."
  (let* ((type (or (plist-get (cdr image) :type) 'image))
         (file (plist-get (cdr image) :file))
         ;; Admission already records the artifact size.  Never stat every
         ;; retained placeholder during a full history render.
         (bytes (or (plist-get (cdr image) :ejn-artifact-bytes)
                    (plist-get (plist-get (cdr image) :ejn-original) :size)))
         (label (if bytes
                    (format "[%s image, %s]" type
                            (file-size-human-readable bytes))
                  (format "[%s image]" type))))
    (insert (propertize label
                        'face 'shadow
                        'help-echo file
                        'emacs-jupyter-notebook-segment-index index))))

(defun emacs-jupyter-notebook-panel--insert-image (image index &optional inline-p)
  "Insert IMAGE tagged with segment INDEX when INLINE-P is non-nil.
When INLINE-P is nil, insert a lightweight placeholder that retains the
segment identity needed by `o', `v', zoom, and source navigation.

W17: a tall image inserted as ONE display property is a single screen
line — window-start can only land on line boundaries, so any scroll
crossing the figure jumps its whole height at once, even under
pixel-precise scroll modes (emacs-mac included).  Slicing the image into
line-height rows via `insert-sliced-image' (the doc-view/EWW technique)
gives every row its own screen line, so scrolling walks smoothly across
the figure.  All slice rows carry the segment-index text property, so the
zoom keys resolve the right output segment with point anywhere on the
figure.  Falls back to a plain single-property insert when slicing is
disabled, on non-graphic displays (batch/tty — the pixel size is unknown
there), or if the slice insert fails.  W18 bounds this work to the newest
configured inline previews; placeholder images never call `image-size'."
  (let ((start (point)))
    (if (not (and inline-p
                  (emacs-jupyter-notebook-panel--native-image-safe-p image)))
        (emacs-jupyter-notebook-panel--insert-image-placeholder image index)
      (let ((native (emacs-jupyter-notebook-panel--native-preview-spec image)))
        (if (not native)
            (emacs-jupyter-notebook-panel--insert-image-placeholder image index)
          ;; Set only after strict PPM revalidation and immediately before the
          ;; first native call.  Retirement can then flush exactly materialized
          ;; preview specs without touching original files or retained history.
          (plist-put (cdr image) :ejn-materialized t)
          (let ((rows (and emacs-jupyter-notebook-panel-slice-images
                           (display-graphic-p)
                           (emacs-jupyter-notebook-panel--trusted-preview-slice-rows
                            image))))
            (if rows
                (condition-case nil
                    (insert-sliced-image native " " nil rows 1)
                  (error (insert (propertize " " 'display native))))
              (insert (propertize " " 'display native)))))))
    (add-text-properties
     start (point) (list 'emacs-jupyter-notebook-segment-index index))))

(defun emacs-jupyter-notebook-panel--short-line (text &optional limit)
  "Return the bounded first line of TEXT without control characters.
LIMIT defaults to 80 characters.  Never scan an unbounded source line."
  (when (stringp text)
    (let* ((prefix (substring-no-properties text 0 (min (length text) (or limit 80))))
           (line (substring prefix 0 (string-search "\n" prefix))))
      (string-trim (replace-regexp-in-string "[[:cntrl:]]" " " line)))))

(defun emacs-jupyter-notebook-panel--source-cell-title (key source)
  "Return the current explicit marker title for KEY in SOURCE, if present."
  (when (and key (buffer-live-p source))
    (with-current-buffer source
      (when-let ((marker (and emacs-jupyter-notebook--cell-key-markers
                             (gethash (cdr key) emacs-jupyter-notebook--cell-key-markers))))
        (when (eq (marker-buffer marker) source)
          (save-restriction
            (widen)
            (save-excursion
              (save-match-data
                (goto-char marker)
                (when (looking-at code-cells-boundary-regexp)
                  (goto-char (match-end 0))
                  (let ((title (emacs-jupyter-notebook-panel--short-line
                                (buffer-substring-no-properties
                                 (point) (min (point-max) (+ (point) 80))))))
                    (unless (string-empty-p title) title)))))))))))

(defun emacs-jupyter-notebook-panel--newline-count (text)
  "Count newline characters in bounded TEXT."
  (let ((start 0) (count 0) next)
    (while (setq next (string-search "\n" text start))
      (setq count (1+ count) start (1+ next)))
    count))

(defun emacs-jupyter-notebook-panel--text-segment-lines (segment)
  "Return the retained logical line count for text SEGMENT without joining it."
  (let ((value (cdr segment)))
    (if (emacs-jupyter-notebook-panel--text-state-p value)
        (+ (or (plist-get value :newlines) 0)
           (if (or (zerop (plist-get value :bytes))
                   (plist-get value :ends-newline)) 0 1))
      (+ (emacs-jupyter-notebook-panel--newline-count value)
         (if (or (string-empty-p value) (string-suffix-p "\n" value)) 0 1)))))

(defun emacs-jupyter-notebook-panel--last-output-line (entry)
  "Return ENTRY's final nonempty text line, examining at most 512 characters."
  (let ((remaining 512) pieces)
    (dolist (segment (reverse (plist-get entry :outputs)))
      (when (and (> remaining 0) (eq (car segment) 'text))
        (let* ((value (cdr segment))
               (chunks (if (emacs-jupyter-notebook-panel--text-state-p value)
                           (reverse (plist-get value :chunks)) (list value))))
          (while (and chunks (> remaining 0))
            (let* ((chunk (pop chunks))
                   (suffix (substring chunk (max 0 (- (length chunk) remaining)))))
              (push suffix pieces)
              (cl-decf remaining (length suffix)))))))
    (when-let ((line (car (last (split-string (apply #'concat pieces) "\n" t "[ \t]+")))))
      (emacs-jupyter-notebook-panel--short-line line 120))))

(defun emacs-jupyter-notebook-panel--folded-summary (entry)
  "Summarize ENTRY using retained counters and bounded error text only."
  (let ((lines 0) (images 0) (planes 0) labels)
    (dolist (segment (plist-get entry :outputs))
      (pcase (car segment)
        ('text (cl-incf lines (emacs-jupyter-notebook-panel--text-segment-lines segment)))
        ('image (cl-incf images))
        ('array
         (let ((manifest (plist-get (cdr segment) :manifest)))
           (cl-incf planes (if (hash-table-p manifest)
                               (length (gethash "planes" manifest)) 1))))))
    (when (> lines 0) (push (format "%d line%s" lines (if (= lines 1) "" "s")) labels))
    (when (> images 0) (push (format "%d image%s" images (if (= images 1) "" "s")) labels))
    (when (> planes 0) (push (format "%d plane%s" planes (if (= planes 1) "" "s")) labels))
    (when (eq (plist-get entry :status) 'error)
      (when-let ((message (emacs-jupyter-notebook-panel--last-output-line entry)))
        (push message labels)))
    (if labels (mapconcat #'identity (nreverse labels) " · ") "no output")))

(defun emacs-jupyter-notebook-panel--duration-text (entry)
  "Return ENTRY's finished duration or current running elapsed time."
  (let ((seconds (or (plist-get entry :duration)
                     (and (eq (plist-get entry :status) 'running)
                          (plist-get entry :started-at)
                          (- (float-time) (plist-get entry :started-at))))))
    (if (numberp seconds) (format " · %.1fs" (max 0 seconds)) "")))

(defun emacs-jupyter-notebook-panel--replace-header (entry bounds)
  "Replace only ENTRY's bounded header at rendered BOUNDS."
  (goto-char (car bounds))
  (let ((end (min (cdr bounds) (1+ (line-end-position))))
        (header (emacs-jupyter-notebook-panel--format-header entry)))
    (unless (equal-including-properties
             header (buffer-substring (point) end))
      (delete-region (point) end)
      (insert header)))
  (plist-put entry :metadata-dirty-p nil))

(defun emacs-jupyter-notebook-panel--format-header (entry)
  "Return the propertized header string for ENTRY."
  (let* ((count (or (plist-get entry :exec-count) "*"))
         (status (or (plist-get entry :status) 'running))
         (ts (or (plist-get entry :timestamp) ""))
         (code (or (plist-get entry :code) ""))
         ;; Preserve the established first nonempty-line title for ordinary
         ;; source while putting a fixed upper bound on an adversarial cell
         ;; made entirely of leading newlines.  `split-string' used to scan
         ;; and allocate from the entire cell during every full render.
         (scan-limit (min (length code)
                          emacs-jupyter-notebook-panel--header-scan-max-characters))
         (title-start 0))
    (while (and (< title-start scan-limit)
                (eq (aref code title-start) ?\n))
      (cl-incf title-start))
    (let ((title-end title-start)
          ;; Reaching the scan cap means there may still be only newlines.
          ;; Do not turn the next sixty of those into physical header lines.
          (title-limit (if (>= title-start scan-limit)
                           title-start
                         (min (length code) (+ title-start 60)))))
      (while (and (< title-end title-limit)
                  (not (eq (aref code title-end) ?\n)))
        (cl-incf title-end))
      (let ((title (or (plist-get entry :title)
                       (emacs-jupyter-notebook-panel--source-cell-title
                        (plist-get entry :cell-key) emacs-jupyter-notebook-panel--source-buffer)
                       (substring code title-start title-end)))
          (status-s (pcase status
                      ('running "running")
                      ('ok "ok")
                      ('error "error")
                      ('cancelled "cancelled")
                      ('outcome-unknown "outcome unknown")
                      (_ (format "%s" status)))))
        (propertize
         (format "[%s] %s [%s] %s%s%s%s\n" count ts status-s title
                 (emacs-jupyter-notebook-panel--duration-text entry)
                 (if (plist-get entry :edited-since-run) " · edited since run" "")
                 (if (plist-get entry :hidden)
                     (format " [outputs hidden: %s]"
                             (emacs-jupyter-notebook-panel--folded-summary entry)) ""))
         'face 'emacs-jupyter-notebook-result-header-face
         'emacs-jupyter-notebook-entry-id (plist-get entry :id)
         'emacs-jupyter-notebook-cell-key (plist-get entry :cell-key))))))

(defun emacs-jupyter-notebook-panel--text-state-p (value)
  "Return non-nil when VALUE is the internal streamed text representation."
  (and (listp value) (plist-member value :chunks)))

(defconst emacs-jupyter-notebook-panel--hard-text-chunks 256
  "Immutable retained chunk ceiling for one streamed text segment.")

(defconst emacs-jupyter-notebook-panel--hard-pending-text-chunks 256
  "Immutable unrendered suffix-chunk ceiling for one streamed text segment.")

(defconst emacs-jupyter-notebook-panel--hard-text-chunk-bytes 65536
  "Immutable byte ceiling for one retained streamed-text chunk.")

(defconst emacs-jupyter-notebook-panel--text-chunk-character-step 8192
  "Conservative character step used to construct byte-bounded text chunks.")

(defun emacs-jupyter-notebook-panel--text-state-drop-oldest-chunk (state)
  "Drop STATE's oldest whole chunk in bounded work and return STATE."
  (when-let* ((chunks (plist-get state :chunks))
              (chunk (car chunks)))
    (let* ((chunk-bytes (string-bytes chunk))
           (count (or (plist-get state :chunk-count) (length chunks)))
           (line-count (or (plist-get state :last-line-chunks) 0)))
      (setq state (plist-put state :chunks (cdr chunks)))
      (setq state (plist-put state :chunk-count (1- count)))
      (setq state (plist-put state :bytes
                             (- (plist-get state :bytes) chunk-bytes)))
      (setq state (plist-put state :newlines
                             (- (or (plist-get state :newlines) 0)
                                (emacs-jupyter-notebook-panel--newline-count chunk))))
      ;; The current line always occupies the final LINE-COUNT chunks.
      (when (<= count line-count)
        (setq state (plist-put state :last-line-chunks (1- line-count)))
        (setq state (plist-put state :last-line-bytes
                               (- (or (plist-get state :last-line-bytes) 0)
                                  chunk-bytes))))
      (when (null (cdr chunks))
        (setq state (plist-put state :tail nil)))
      state)))

(defun emacs-jupyter-notebook-panel--text-state-note-pending (state text)
  "Retain TEXT as a bounded incremental suffix for STATE."
  (cond
   ((plist-get state :pending-overflow) state)
   ((>= (or (plist-get state :pending-count) 0)
        emacs-jupyter-notebook-panel--hard-pending-text-chunks)
    (setq state (plist-put state :pending nil))
    (setq state (plist-put state :pending-count 0))
    (plist-put state :pending-overflow t))
   (t
    (setq state (plist-put state :pending
                           (cons text (plist-get state :pending))))
    (plist-put state :pending-count
               (1+ (or (plist-get state :pending-count) 0))))))

(defun emacs-jupyter-notebook-panel--text-state-add-chunk
    (state text current-line-p)
  "Append nonempty TEXT to STATE and update bounded chunk accounting.
CURRENT-LINE-P means TEXT belongs to the logical line after the last newline."
  (unless (string-empty-p text)
    (while (>= (or (plist-get state :chunk-count) 0)
               emacs-jupyter-notebook-panel--hard-text-chunks)
      (setq state
            (emacs-jupyter-notebook-panel--text-state-drop-oldest-chunk state)))
    (let ((cell (list text))
          (bytes (string-bytes text)))
      (if-let ((tail (plist-get state :tail)))
          (setcdr tail cell)
        (setq state (plist-put state :chunks cell)))
      (setq state (plist-put state :tail cell))
      (setq state (plist-put state :chunk-count
                             (1+ (or (plist-get state :chunk-count) 0))))
      (setq state (plist-put state :bytes
                             (+ (plist-get state :bytes) bytes)))
      (setq state (plist-put state :newlines
                             (+ (or (plist-get state :newlines) 0)
                                (emacs-jupyter-notebook-panel--newline-count text))))
      (setq state
            (emacs-jupyter-notebook-panel--text-state-note-pending state text))
      (if current-line-p
          (progn
            (setq state (plist-put state :last-line-chunks
                                   (1+ (or (plist-get state :last-line-chunks) 0))))
            (setq state (plist-put state :last-line-bytes
                                   (+ (or (plist-get state :last-line-bytes) 0)
                                      bytes))))
        (setq state (plist-put state :last-line-chunks 0))
        (setq state (plist-put state :last-line-bytes 0)))))
  state)

(defun emacs-jupyter-notebook-panel--text-state-add-bounded-chunks
    (state text current-line-p)
  "Append TEXT to STATE as bounded pieces with CURRENT-LINE-P semantics."
  (let ((start 0)
        (length (length text)))
    (while (< start length)
      (let* ((end (min length
                       (+ start
                          emacs-jupyter-notebook-panel--text-chunk-character-step)))
             (piece (substring text start end)))
        ;; The conservative character step is already below the ceiling for
        ;; ordinary Unicode.  Retain a byte check for unusual Emacs raw-byte
        ;; characters without ever searching more than one small candidate.
        (while (> (string-bytes piece)
                  emacs-jupyter-notebook-panel--hard-text-chunk-bytes)
          (setq end (+ start (max 1 (/ (- end start) 2))))
          (setq piece (substring text start end)))
        (setq state
              (emacs-jupyter-notebook-panel--text-state-add-chunk
               state piece current-line-p))
        (setq start end))))
  state)

(defun emacs-jupyter-notebook-panel--make-text-state (text)
  "Return a chunked text state initialized with TEXT."
  (emacs-jupyter-notebook-panel--text-state-append
   (list :chunks nil :tail nil :chunk-count 0 :bytes 0 :newlines 0 :cache nil
         :pending nil :pending-count 0 :pending-overflow nil
         :last-line-chunks 0 :last-line-bytes 0
         :ends-newline nil :rendered-ends-newline nil)
   (or text "")))

(defun emacs-jupyter-notebook-panel--text-state-value (segment)
  "Materialize SEGMENT's logical text once after its most recent mutation."
  (let ((value (cdr segment)))
    (if (not (emacs-jupyter-notebook-panel--text-state-p value))
        value
      (or (plist-get value :cache)
          (let ((text (mapconcat #'identity (plist-get value :chunks) "")))
            (when (integerp emacs-jupyter-notebook-panel--text-materialization-count)
              (cl-incf emacs-jupyter-notebook-panel--text-materialization-count))
            (setcdr segment (plist-put value :cache text))
            text)))))

(defun emacs-jupyter-notebook-panel--text-state-append (state text)
  "Append TEXT to STATE with immutable chunk bounds and return STATE."
  (unless (string-empty-p text)
    ;; Split at the final newline.  That invariant lets a later carriage
    ;; return discard the current terminal line by chunk count, without ever
    ;; materializing or scanning retained history.
    (let ((search 0) last-newline next)
      (while (setq next (string-search "\n" text search))
        (setq last-newline next
              search (1+ next)))
      (if last-newline
          (let ((boundary (1+ last-newline)))
            (setq state
                  (emacs-jupyter-notebook-panel--text-state-add-bounded-chunks
                   state (substring text 0 boundary) nil))
            (when (< boundary (length text))
              (setq state
                    (emacs-jupyter-notebook-panel--text-state-add-bounded-chunks
                     state (substring text boundary) t))))
        (setq state
              (emacs-jupyter-notebook-panel--text-state-add-bounded-chunks
               state text t))))
    (setq state (plist-put state :cache nil))
    (setq state (plist-put state :ends-newline (string-suffix-p "\n" text))))
  state)

(defun emacs-jupyter-notebook-panel--text-state-drop-current-line (state)
  "Drop STATE's current logical terminal line in bounded chunk work."
  (let* ((count (or (plist-get state :chunk-count) 0))
         (line-count (min count (or (plist-get state :last-line-chunks) 0)))
         (keep (- count line-count))
         (chunks (plist-get state :chunks)))
    (cond
     ((zerop keep)
      (setq state (plist-put state :chunks nil))
      (setq state (plist-put state :tail nil)))
     ((> line-count 0)
      (let ((tail (nthcdr (1- keep) chunks)))
        (setcdr tail nil)
        (setq state (plist-put state :tail tail)))))
    (setq state (plist-put state :chunk-count keep))
    (setq state (plist-put state :bytes
                           (- (plist-get state :bytes)
                              (or (plist-get state :last-line-bytes) 0))))
    (setq state (plist-put state :last-line-chunks 0))
    (setq state (plist-put state :last-line-bytes 0))
    (setq state (plist-put state :pending nil))
    (setq state (plist-put state :pending-count 0))
    (setq state (plist-put state :pending-overflow nil))
    (setq state (plist-put state :cache nil))
    (setq state (plist-put state :ends-newline t))
    state))

(defun emacs-jupyter-notebook-panel--text-state-drop-front (state bytes)
  "Drop BYTES from STATE's oldest retained chunks and return STATE."
  (while (and (> bytes 0) (plist-get state :chunks))
    (let* ((chunks (plist-get state :chunks))
           (chunk (car chunks))
           (chunk-bytes (string-bytes chunk)))
      (when (integerp emacs-jupyter-notebook-panel--text-trim-chunk-visits)
        (cl-incf emacs-jupyter-notebook-panel--text-trim-chunk-visits))
      (if (>= bytes chunk-bytes)
          (progn
            (setq state
                  (emacs-jupyter-notebook-panel--text-state-drop-oldest-chunk
                   state))
            (setq bytes (- bytes chunk-bytes)))
        (let ((kept (emacs-jupyter-notebook--last-bytes
                     chunk (- chunk-bytes bytes))))
          (setq state (plist-put state :newlines
                                 (+ (- (or (plist-get state :newlines) 0)
                                       (emacs-jupyter-notebook-panel--newline-count chunk))
                                    (emacs-jupyter-notebook-panel--newline-count kept))))
          (setcar chunks kept)
          (setq state (plist-put state :bytes
                                 (- (plist-get state :bytes)
                                    (- chunk-bytes (string-bytes kept)))))
          (when (= (or (plist-get state :chunk-count) 0)
                   (or (plist-get state :last-line-chunks) 0))
            (setq state (plist-put state :last-line-bytes
                                   (- (or (plist-get state :last-line-bytes) 0)
                                      (- chunk-bytes (string-bytes kept))))))
          (setq bytes 0)))))
  (setq state (plist-put state :cache nil))
  ;; Trimming always schedules a structural render, so stale incremental
  ;; chunks must not keep pre-cap stream strings alive until that render.
  (setq state (plist-put state :pending nil))
  (setq state (plist-put state :pending-count 0))
  (setq state (plist-put state :pending-overflow nil))
  state)

(defun emacs-jupyter-notebook-panel--text-segment-bytes (segment)
  "Return retained byte count for text SEGMENT."
  (let ((value (cdr segment)))
    (if (emacs-jupyter-notebook-panel--text-state-p value)
        (plist-get value :bytes)
      (string-bytes value))))

(defun emacs-jupyter-notebook-panel--insert-text-segment (segment index)
  "Insert text SEGMENT and tag its logical content with INDEX."
  (let* ((content (copy-sequence
                   (emacs-jupyter-notebook-panel--text-state-value segment)))
         (start (point)))
    (unless (string-empty-p content)
      (add-face-text-property
       0 (length content) 'emacs-jupyter-notebook-result-face 'append content)
      (insert content)
      (add-text-properties
       start (point) (list 'emacs-jupyter-notebook-text-segment-index index))
      (unless (string-suffix-p "\n" content)
        (insert "\n")))
    (when (emacs-jupyter-notebook-panel--text-state-p (cdr segment))
      (let ((state (cdr segment)))
        (setq state (plist-put state :pending nil))
        (setq state (plist-put state :pending-count 0))
        (setq state (plist-put state :pending-overflow nil))
        (setq state (plist-put state :rendered-ends-newline
                               (plist-get state :ends-newline)))
        (setcdr segment state)))))

(defun emacs-jupyter-notebook-panel--insert-entry (entry inline-specs)
  "Insert ENTRY, materializing only images present in INLINE-SPECS."
  (insert (emacs-jupyter-notebook-panel--format-header entry))
  (let ((index -1))
    (dolist (seg (unless (plist-get entry :hidden) (plist-get entry :outputs)))
      (cl-incf index)
      (pcase (car seg)
        ('array
         (emacs-jupyter-notebook-panel--insert-array (cdr seg) index))
        ('image
         (emacs-jupyter-notebook-panel--insert-image
          (cdr seg) index (member (cdr seg) inline-specs))
         (unless (bolp) (insert "\n")))
        ('text
         (emacs-jupyter-notebook-panel--insert-text-segment seg index)))))
  (insert "\n")
  (plist-put entry :metadata-dirty-p nil)
  (plist-put entry :stream-dirty-p nil))

(defun emacs-jupyter-notebook-panel--pending-text-fits-p (pending max-bytes)
  "Return non-nil when PENDING totals no more than MAX-BYTES bytes.
The check traverses bounded chunk metadata without constructing the pending
suffix string.  It lets ordinary scheduled patches decline a large suffix
before `mapconcat' could allocate it on the UI thread."
  (let ((bytes 0))
    (while (and pending (<= bytes max-bytes))
      (let ((chunk (pop pending)))
        (unless (stringp chunk)
          (setq bytes (1+ max-bytes)))
        (when (stringp chunk)
          (cl-incf bytes (string-bytes chunk)))))
    (<= bytes max-bytes)))

(defun emacs-jupyter-notebook-panel--render-stream-suffix
    (entry bounds &optional max-bytes)
  "Insert ENTRY's pending trailing text chunks at BOUNDS without rebuilding it.
Return non-nil when the existing rendered text segment could be extended.
When MAX-BYTES is non-nil, decline a larger pending suffix without allocating
it so the caller can use the bounded full renderer instead."
  (let* ((segments (plist-get entry :outputs))
         (index (1- (length segments)))
         (segment (car (last segments)))
         (state (and segment (cdr segment))))
    (when (and (not (plist-get entry :hidden))
               (eq (car-safe segment) 'text)
               (emacs-jupyter-notebook-panel--text-state-p state)
               (plist-get state :pending)
               (or (null max-bytes)
                   (emacs-jupyter-notebook-panel--pending-text-fits-p
                    (plist-get state :pending) max-bytes)))
      (let* ((property 'emacs-jupyter-notebook-text-segment-index)
             (start (text-property-any (car bounds) (cdr bounds) property index)))
        (when start
          (let* ((end (next-single-property-change start property nil (cdr bounds)))
                 (suffix (mapconcat #'identity (nreverse (copy-sequence
                                                           (plist-get state :pending))) ""))
                 (old-auto-newline (not (plist-get state :rendered-ends-newline)))
                 (new-ends-newline (plist-get state :ends-newline))
                 (insert-start end))
            (goto-char end)
            (insert suffix)
            (add-face-text-property insert-start (point)
                                    'emacs-jupyter-notebook-result-face 'append)
            (add-text-properties insert-start (point) (list property index))
            ;; The full renderer owns one separator newline for a text segment
            ;; that did not end in one.  Adjust that separator in place.
            (cond
             ((and old-auto-newline new-ends-newline (eq (char-after) ?\n))
              (delete-char 1))
             ((and (not old-auto-newline) (not new-ends-newline))
              (insert "\n")))
            (setq state (plist-put state :pending nil))
            (setq state (plist-put state :pending-count 0))
            (setq state (plist-put state :pending-overflow nil))
            (setq state (plist-put state :rendered-ends-newline new-ends-newline))
            (setcdr segment state)
            (plist-put entry :stream-dirty-p nil)
            ;; A stream can arrive after a status/source edit but before its
            ;; scheduled redraw.  Refresh metadata too, so a suffix-only patch
            ;; cannot leave a stale status, title, or edited-since-run label.
            (when (plist-get entry :metadata-dirty-p)
              (emacs-jupyter-notebook-panel--replace-header entry bounds))
            t))))))

(defun emacs-jupyter-notebook-panel--sliced-render-insert-text (text index)
  "Insert bounded TEXT for output segment INDEX at point.
TEXT is already capped by the render scheduler, so adding the normal fallback
face directly to the panel buffer never copies an arbitrarily large segment."
  (let ((start (point)))
    (insert text)
    (add-face-text-property
     start (point) 'emacs-jupyter-notebook-result-face 'append)
    (add-text-properties
     start (point) (list 'emacs-jupyter-notebook-text-segment-index index))))

(defun emacs-jupyter-notebook-panel--sliced-render-raw-text-piece
    (text position)
  "Return the next hard-bounded piece of TEXT after POSITION.
The return value is `(PIECE . NEXT-POSITION)'.  This compatibility path is
only for hand-constructed legacy segments; normal panel segments are already
chunked by `--make-text-state'."
  (let* ((length (length text))
         (end (min length
                   (+ position
                      emacs-jupyter-notebook-panel--text-chunk-character-step)))
         (piece (substring text position end)))
    (while (> (string-bytes piece)
              emacs-jupyter-notebook-panel--sliced-render-max-text-bytes)
      (setq end (+ position (max 1 (/ (- end position) 2))))
      (setq piece (substring text position end)))
    (cons piece end)))

(defun emacs-jupyter-notebook-panel--sliced-render-clear-text-pending (job)
  "Finalize JOB's current text segment and return the advanced JOB state."
  (let* ((segment (plist-get job :text-segment))
         (state (plist-get job :text-state))
         (had-content (plist-get job :text-had-content))
         (ends-newline
          (if state
              (plist-get state :ends-newline)
            (string-suffix-p "\n" (or (plist-get job :text-value) "")))))
    ;; A streamed state remains unmodified until its last chunk has reached
    ;; the buffer.  A mutation always cancels this generation first, so this
    ;; cannot clear a pending suffix from a newer stream event.
    (when state
      (setq state (plist-put state :pending nil))
      (setq state (plist-put state :pending-count 0))
      (setq state (plist-put state :pending-overflow nil))
      (setq state (plist-put state :rendered-ends-newline ends-newline))
      (setcdr segment state))
    (when (and had-content (not ends-newline))
      (insert "\n"))
    (setq job (plist-put job :text-segment nil))
    (setq job (plist-put job :text-state nil))
    (setq job (plist-put job :text-chunks nil))
    (setq job (plist-put job :text-value nil))
    (setq job (plist-put job :text-position nil))
    (setq job (plist-put job :text-had-content nil))
    (plist-put job :phase 'segments)))

(defun emacs-jupyter-notebook-panel--sliced-render-finish-entry (job)
  "Finish JOB's current entry and return the next-entry state."
  (let ((entry (plist-get job :current-entry)))
    (insert "\n")
    (when entry
      (setq entry (plist-put entry :metadata-dirty-p nil))
      ;; `plist-put' can return a fresh plist when this optional key was not
      ;; already present, so install it back in the durable entry table.
      (emacs-jupyter-notebook-panel--set-entry
       (current-buffer) (plist-get entry :id)
       (plist-put entry :stream-dirty-p nil)))
    (setq job (plist-put job :current-entry nil))
    (setq job (plist-put job :current-segments nil))
    (setq job (plist-put job :segment-index 0))
    (plist-put job :phase 'entry)))

(defun emacs-jupyter-notebook-panel--sliced-render-step
    (job text-budget image-used clear-characters)
  "Perform one bounded operation from full-render JOB.
TEXT-BUDGET is the number of bytes already inserted in this timer callback.
IMAGE-USED prevents more than one potentially decoding native image from
being inserted in that callback.  CLEAR-CHARACTERS is the prefix already
deleted from the prior view.  Return a plist with updated `:job' and optional
`:text-bytes', `:clear-characters', `:image-p', `:blocked', or `:complete'
flags."
  (pcase (plist-get job :phase)
    ('begin
     ;; `erase-buffer' can itself be a visible pause for a retained 20 MiB
     ;; history.  Retire the old presentation in small character slices
     ;; before inserting the new header.  The panel is ordinary multibyte
     ;; text, so this is also comfortably under the text-byte work budget.
     (if (> (buffer-size) 0)
         (if (> clear-characters 0)
             (list :job job :blocked t)
           (let ((count
                  (min (buffer-size)
                       emacs-jupyter-notebook-panel--sliced-render-max-clear-characters)))
             (delete-region (point-min) (+ (point-min) count))
             (list :job job :clear-characters count :blocked t)))
       (insert (propertize
                (format "Output panel — view: %s   (H toggle, RET visit, q bury)\n\n"
                        emacs-jupyter-notebook-panel--view)
                'face 'emacs-jupyter-notebook-result-header-face))
       (when (and (eq emacs-jupyter-notebook-panel--view 'history)
                  emacs-jupyter-notebook-panel--history-evicted-p)
         (insert (propertize "[older output evicted]\n\n"
                             'face 'emacs-jupyter-notebook-result-header-face)))
       (list :job (plist-put job :phase 'entry))))
    ('entry
     (let ((remaining (plist-get job :remaining-entries)))
       (if (null remaining)
           (list :job job :complete t)
         (let ((entry (car remaining)))
           (insert (emacs-jupyter-notebook-panel--format-header entry))
           (setq job (plist-put job :remaining-entries (cdr remaining)))
           (setq job (plist-put job :current-entry entry))
           (setq job (plist-put job :current-segments
                                (unless (plist-get entry :hidden)
                                  (plist-get entry :outputs))))
           (setq job (plist-put job :segment-index 0))
           (list :job (plist-put job :phase 'segments))))))
    ('segments
     (let ((segments (plist-get job :current-segments)))
       (if (null segments)
           (list :job (emacs-jupyter-notebook-panel--sliced-render-finish-entry
                       job))
         (let* ((segment (car segments))
                (index (plist-get job :segment-index)))
           (setq job (plist-put job :current-segments (cdr segments)))
           (setq job (plist-put job :segment-index (1+ index)))
           (pcase (car-safe segment)
             ('array
              (let ((bytes (+ 10 (string-bytes
                                  (emacs-jupyter-notebook-panel--array-card
                                   (cdr segment))))))
                (if (> (+ text-budget bytes)
                       emacs-jupyter-notebook-panel--sliced-render-max-text-bytes)
                    (progn
                      (setq job (plist-put job :current-segments segments))
                      (setq job (plist-put job :segment-index index))
                      (list :job job :blocked t))
                  (emacs-jupyter-notebook-panel--insert-array (cdr segment) index)
                  (list :job job :text-bytes bytes))))
             ('image
              (if image-used
                  ;; Restore the segment so the next timer callback sees it.
                  (progn
                    (setq job (plist-put job :current-segments segments))
                    (setq job (plist-put job :segment-index index))
                    (list :job job :blocked t))
                (emacs-jupyter-notebook-panel--insert-image
                 (cdr segment) index
                 (member (cdr segment)
                         (plist-get job :inline-image-specs)))
                (unless (bolp) (insert "\n"))
                (list :job job :image-p t)))
             ('text
              (let ((value (cdr segment)))
                (setq job (plist-put job :text-segment segment))
                (setq job (plist-put job :text-state
                                     (and (emacs-jupyter-notebook-panel--text-state-p
                                           value)
                                          value)))
                (setq job (plist-put job :text-chunks
                                     (and (emacs-jupyter-notebook-panel--text-state-p
                                           value)
                                          (plist-get value :chunks))))
                (setq job (plist-put job :text-value
                                     (unless (emacs-jupyter-notebook-panel--text-state-p
                                             value)
                                       value)))
                (setq job (plist-put job :text-position 0))
                (setq job (plist-put job :text-had-content nil))
                (setq job (plist-put job :text-index index))
                (list :job (plist-put job :phase 'text))))
             (_ (list :job job)))))))
    ('text
     (let ((state (plist-get job :text-state))
           (index (plist-get job :text-index)))
       (if state
           (if-let ((chunks (plist-get job :text-chunks)))
               (let* ((piece (car chunks))
                      (bytes (string-bytes piece)))
                 (if (> (+ text-budget bytes)
                        emacs-jupyter-notebook-panel--sliced-render-max-text-bytes)
                     (list :job job :blocked t)
                   (emacs-jupyter-notebook-panel--sliced-render-insert-text
                    piece index)
                   (setq job (plist-put job :text-chunks (cdr chunks)))
                   (setq job (plist-put job :text-had-content t))
                   (list :job job :text-bytes bytes)))
             (list :job (emacs-jupyter-notebook-panel--sliced-render-clear-text-pending
                         job)))
         (let* ((text (or (plist-get job :text-value) ""))
                (position (or (plist-get job :text-position) 0)))
           (if (>= position (length text))
               (list :job (emacs-jupyter-notebook-panel--sliced-render-clear-text-pending
                           job))
             (let* ((next (emacs-jupyter-notebook-panel--sliced-render-raw-text-piece
                           text position))
                    (piece (car next))
                    (bytes (string-bytes piece)))
               (if (> (+ text-budget bytes)
                      emacs-jupyter-notebook-panel--sliced-render-max-text-bytes)
                   (list :job job :blocked t)
                 (emacs-jupyter-notebook-panel--sliced-render-insert-text
                  piece index)
                 (setq job (plist-put job :text-position (cdr next)))
                 (setq job (plist-put job :text-had-content t))
                 (list :job job :text-bytes bytes))))))))
    (_ (list :job job :complete t))))

(defun emacs-jupyter-notebook-panel--sliced-render-arm (panel token)
  "Schedule PANEL's next bounded full-render slice for TOKEN."
  (setq emacs-jupyter-notebook-panel--sliced-render-timer
        (run-at-time
         emacs-jupyter-notebook-panel--sliced-render-delay nil
         (lambda ()
           (when (buffer-live-p panel)
             (with-current-buffer panel
               (emacs-jupyter-notebook-panel--sliced-render-tick panel token)))))))

(defun emacs-jupyter-notebook-panel--sliced-render-tick (panel token)
  "Render one bounded timer slice for PANEL when TOKEN still owns it."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (when (and (= token emacs-jupyter-notebook-panel--sliced-render-generation)
                 emacs-jupyter-notebook-panel--sliced-render-job)
        (let ((inhibit-read-only t)
              (job emacs-jupyter-notebook-panel--sliced-render-job)
              (work 0)
              (reader-position (copy-marker (point)))
              (text-bytes 0)
              (clear-characters 0)
              (image-used nil)
              complete blocked)
          (setq emacs-jupyter-notebook-panel--sliced-render-timer nil)
          ;; Point belongs to the reader between slices.  Always append the
          ;; next render slice at the end, even after panel navigation.
          (goto-char (point-max))
          (while (and (< work emacs-jupyter-notebook-panel--sliced-render-max-work-items)
                      (not complete) (not blocked))
            (let ((result
                   (emacs-jupyter-notebook-panel--sliced-render-step
                    job text-bytes image-used clear-characters)))
              (setq job (plist-get result :job))
              (cl-incf work)
              (cl-incf text-bytes (or (plist-get result :text-bytes) 0))
              (cl-incf clear-characters
                       (or (plist-get result :clear-characters) 0))
              (setq image-used (or image-used (plist-get result :image-p)))
              (setq complete (plist-get result :complete))
              (setq blocked (plist-get result :blocked))))
          (setq emacs-jupyter-notebook-panel--sliced-render-job job)
          (if complete
              (progn
                (setq emacs-jupyter-notebook-panel--sliced-render-job nil)
                (cl-incf emacs-jupyter-notebook-panel--render-count)
                (emacs-jupyter-notebook-panel--finish-navigation))
            (goto-char reader-position)
            (emacs-jupyter-notebook-panel--sliced-render-arm panel token))
          (set-marker reader-position nil))))))

(defun emacs-jupyter-notebook-panel--start-sliced-render (panel)
  "Start a cancellable, bounded full render of PANEL on regular timers.
Only fixed-size state is prepared synchronously.  The callback inserts at
most `--sliced-render-max-text-bytes' text bytes and one image per tick."
  (with-current-buffer panel
    (emacs-jupyter-notebook-panel--capture-navigation)
    (emacs-jupyter-notebook-panel--cancel-sliced-render)
    (let* ((entries (emacs-jupyter-notebook-panel--visible-entries))
           (inline (emacs-jupyter-notebook-panel--bounded-inline-specs entries))
           (token (cl-incf emacs-jupyter-notebook-panel--sliced-render-generation)))
      (setq emacs-jupyter-notebook-panel--dirty-entry-ids nil)
      (setq emacs-jupyter-notebook-panel--force-full-render nil)
      (emacs-jupyter-notebook-panel--set-inline-specs inline)
      (setq emacs-jupyter-notebook-panel--sliced-render-job
            (list :phase 'begin
                  :remaining-entries entries
                  :inline-image-specs inline
                  :current-entry nil
                  :current-segments nil
                  :segment-index 0))
      (emacs-jupyter-notebook-panel--sliced-render-arm panel token))))

(defun emacs-jupyter-notebook-panel--entry-bounds (id)
  "Return the rendered buffer bounds for entry ID, or nil."
  (let* ((property 'emacs-jupyter-notebook-entry-id)
         (start (text-property-any (point-min) (point-max) property id)))
    (when start
      (let ((pos (next-single-property-change start property nil (point-max))))
        (while (and (< pos (point-max))
                    (null (get-text-property pos property)))
          (setq pos (next-single-property-change pos property nil (point-max))))
        (cons start pos)))))

(defun emacs-jupyter-notebook-panel--render-dirty-entries
    (panel &optional sliced-fallback)
  "Incrementally re-render dirty entries in PANEL.
Falls back to a full render if an affected visible entry has no existing
section, which means ordering or view membership changed unexpectedly."
  (with-current-buffer panel
    (emacs-jupyter-notebook-panel--capture-navigation)
    (let ((ids (prog1 emacs-jupyter-notebook-panel--dirty-entry-ids
                 (setq emacs-jupyter-notebook-panel--dirty-entry-ids nil))))
      (setq emacs-jupyter-notebook-panel--force-full-render nil)
      (if sliced-fallback
          ;; This is the ordinary timer path.  Replacing one whole retained
          ;; entry can still be 10 MiB, and a coalesced stream can carry up to
          ;; 256 chunks, so only one bounded suffix patch is permitted here.
          ;; Everything else restarts as a fully sliced presentation rebuild.
          (if (/= (length ids) 1)
              (emacs-jupyter-notebook-panel--start-sliced-render panel)
            (let* ((visible (emacs-jupyter-notebook-panel--visible-entries))
                   (entry (cl-find (car ids) visible
                                   :key (lambda (e) (plist-get e :id))))
                   (bounds (and entry
                                (emacs-jupyter-notebook-panel--entry-bounds
                                 (car ids))))
                   (was-at-end (= (point) (point-max)))
                   (inhibit-read-only t))
              (if (and entry bounds (plist-get entry :stream-dirty-p)
                       (emacs-jupyter-notebook-panel--render-stream-suffix
                        entry bounds
                        emacs-jupyter-notebook-panel--sliced-render-max-text-bytes))
                  (progn
                    (cl-incf emacs-jupyter-notebook-panel--render-count)
                    (when was-at-end (goto-char (point-max))))
                (emacs-jupyter-notebook-panel--start-sliced-render panel))))
        ;; `flush-now' and direct diagnostic callers retain the former
        ;; synchronous incremental behaviour; no ordinary command reaches
        ;; this branch.
        (let* ((visible (emacs-jupyter-notebook-panel--visible-entries))
               ;; A same-entry image replacement may swap one inline spec for
               ;; another without changing admission membership.  Refresh the
               ;; bounded spec list before reinserting the dirty entry, while
               ;; the caller's structural check decides whether another entry
               ;; needs a full rebuild.
               (inline (progn
                         (emacs-jupyter-notebook-panel--set-inline-specs
                          (emacs-jupyter-notebook-panel--bounded-inline-specs visible))
                         emacs-jupyter-notebook-panel--inline-image-specs))
               (was-at-end (= (point) (point-max)))
               (fallback nil)
               (inhibit-read-only t))
          (dolist (id ids)
            (let ((entry (cl-find id visible :key (lambda (e) (plist-get e :id))))
                  (bounds (emacs-jupyter-notebook-panel--entry-bounds id)))
              (cond
               ((and entry bounds (plist-get entry :stream-dirty-p)
                     (emacs-jupyter-notebook-panel--render-stream-suffix entry bounds)))
               ((and entry bounds)
                (save-excursion
                  (goto-char (car bounds))
                  (delete-region (car bounds) (cdr bounds))
                  (emacs-jupyter-notebook-panel--insert-entry entry inline)))
               ((and (null entry) bounds)
                (delete-region (car bounds) (cdr bounds)))
               (entry
                (setq fallback t)))))
          (if fallback
              (emacs-jupyter-notebook-panel--render panel)
            (cl-incf emacs-jupyter-notebook-panel--render-count)
            (when was-at-end
              (goto-char (point-max)))))))
    (when (and emacs-jupyter-notebook-panel--navigation-snapshot
               (not emacs-jupyter-notebook-panel--sliced-render-job))
      (emacs-jupyter-notebook-panel--finish-navigation))))

(defun emacs-jupyter-notebook-panel--render (panel)
  "Render PANEL contents, preserving reading positions and pending reveals."
  (with-current-buffer panel
    ;; This is retained as the explicit synchronous diagnostic/test hook.
    ;; Ordinary timer-driven full renders go through `--start-sliced-render'.
    (emacs-jupyter-notebook-panel--capture-navigation)
    (emacs-jupyter-notebook-panel--cancel-sliced-render)
    (let ((inhibit-read-only t)
          (entries (emacs-jupyter-notebook-panel--visible-entries)))
      (setq emacs-jupyter-notebook-panel--dirty-entry-ids nil)
      (setq emacs-jupyter-notebook-panel--force-full-render nil)
      (emacs-jupyter-notebook-panel--set-inline-specs
       (emacs-jupyter-notebook-panel--bounded-inline-specs entries))
      (erase-buffer)
      (cl-incf emacs-jupyter-notebook-panel--render-count)
      (insert (propertize
               (format "Output panel — view: %s   (H toggle, RET visit, q bury)\n\n"
                       emacs-jupyter-notebook-panel--view)
               'face 'emacs-jupyter-notebook-result-header-face))
      (when (and (eq emacs-jupyter-notebook-panel--view 'history)
                 emacs-jupyter-notebook-panel--history-evicted-p)
        (insert (propertize "[older output evicted]\n\n"
                            'face 'emacs-jupyter-notebook-result-header-face)))
      (dolist (entry entries)
        (emacs-jupyter-notebook-panel--insert-entry
         entry emacs-jupyter-notebook-panel--inline-image-specs))
      (emacs-jupyter-notebook-panel--finish-navigation))))

;;; Public API

(defun emacs-jupyter-notebook-panel--ensure-image-directory (panel)
  "Return PANEL's capability-owned image directory, creating it when needed."
  (with-current-buffer panel
    (unless (and emacs-jupyter-notebook-panel--image-artifact-capability
                 (emacs-jupyter-notebook-artifacts-capability-valid-p
                  emacs-jupyter-notebook-panel--image-artifact-capability))
      (setq emacs-jupyter-notebook-panel--image-artifact-capability
            (emacs-jupyter-notebook-artifacts-create 'panel-images)
            emacs-jupyter-notebook-panel--image-directory
            (emacs-jupyter-notebook-artifacts-capability-root
             emacs-jupyter-notebook-panel--image-artifact-capability)))
    emacs-jupyter-notebook-panel--image-directory))

(defun emacs-jupyter-notebook-panel--image-suffix (image)
  "Return a file suffix appropriate for IMAGE's declared type."
  (pcase (plist-get (cdr image) :type)
    ((or 'jpeg 'jpg) ".jpg")
    ('png ".png")
    ('gif ".gif")
    ('webp ".webp")
    (_ ".img")))

(defun emacs-jupyter-notebook-panel--replace-image-data-with-file
    (image file capability identity)
  "Return a fresh IMAGE spec referring to FILE instead of inline data."
  (let ((props (cl-loop for (key value) on (cdr image) by #'cddr
                        unless (memq key '(:data :file))
                        collect key and collect value)))
    (cons 'image (append props (list :file file
                                    :ejn-artifact-capability capability
                                    :ejn-artifact-identity identity
                                    :ejn-artifact-bytes
                                    (string-bytes (plist-get (cdr image) :data)))))))

(defun emacs-jupyter-notebook-panel--materialize-image (panel image)
  "Move IMAGE's inline data to a private file owned by PANEL.
Specs already materialized by this panel, or without data/file payloads, are
returned unchanged.  Arbitrary file specs are rejected without consulting
file handlers.  A new private file is mode 0600 and written without coding."
  (let* ((props (and (consp image) (cdr image)))
         (data (and props (plist-get props :data)))
         (file (and props (plist-get props :file)))
         (data-bytes (and (stringp data) (string-bytes data))))
    (when (stringp file)
      ;; Arbitrary file specs are not part of the helper-only transport.  In
      ;; particular, never let a TRAMP-looking value reach a file handler from
      ;; this public presentation API.  Only a spec previously materialized by
      ;; this exact panel may be reused.
      (unless (and (plist-get props :ejn-artifact-identity)
                   (integerp (plist-get props :ejn-artifact-bytes))
                   (with-current-buffer panel
                     (eq (plist-get props :ejn-artifact-capability)
                         emacs-jupyter-notebook-panel--image-artifact-capability)))
        (error "direct image file specs are not permitted")))
    (when (and data-bytes
               (> data-bytes emacs-jupyter-notebook-panel--max-inline-image-data-bytes))
      (error "image data exceeds the %d-byte limit"
             emacs-jupyter-notebook-panel--max-inline-image-data-bytes))
    (if (not (stringp data))
        (if (plist-member (cdr image) :ejn-artifact-bytes)
            image
          (let ((copy (copy-sequence image)))
            (setcdr copy
                    (append (cdr copy)
                            (list :ejn-artifact-bytes
                                  (emacs-jupyter-notebook-panel--image-artifact-bytes
                                   image))))
            copy))
      (let* ((directory
              (emacs-jupyter-notebook-panel--ensure-image-directory panel))
             (capability
              (with-current-buffer panel
                emacs-jupyter-notebook-panel--image-artifact-capability))
             (file (make-temp-file
                    (expand-file-name "image-" directory) nil
                    (emacs-jupyter-notebook-panel--image-suffix image)))
             (attrs (and (not (file-symlink-p file))
                         (file-attributes file 'integer)))
             (identity (and attrs (file-attribute-file-identifier attrs)))
             (coding-system-for-write 'no-conversion))
        (condition-case err
            (progn
              (unless identity (error "EJN panel image identity unavailable"))
              (write-region data nil file nil 'silent)
              (set-file-modes file #o600)
              (emacs-jupyter-notebook-panel--replace-image-data-with-file
               image file capability identity))
          (error
           (ignore-errors
             (emacs-jupyter-notebook-artifacts-delete-leaf capability file identity))
           (signal (car err) (cdr err))))))))

(defconst emacs-jupyter-notebook-panel--ppm-header-read-limit 64
  "Maximum P6 header bytes read synchronously during preview admission.")

(defun emacs-jupyter-notebook-panel--canonical-ppm-header-metadata (prefix size)
  "Return canonical P6 metadata for unibyte PREFIX and total file SIZE.
Only the fixed worker grammar is accepted: one space between decimal
dimensions, max value 255, no comments, and exactly three payload bytes per
pixel.  PREFIX need only contain the complete header; image payload is never
read or hashed on the Emacs UI thread."
  (when (and (stringp prefix) (integerp size) (>= size 0)
             (string-match
              "\\`P6\n\\([1-9][0-9]*\\) \\([1-9][0-9]*\\)\n255\n"
              prefix))
    (let ((width (string-to-number (match-string 1 prefix)))
          (height (string-to-number (match-string 2 prefix)))
          (header-size (match-end 0)))
      (when (and (<= 1 width 1024) (<= 1 height 1024)
                 (= size (+ header-size (* width height 3))))
        (list :mime "image/x-portable-pixmap"
              :width width :height height)))))

(defun emacs-jupyter-notebook-panel--helper-artifact-capability
    (root root-identity)
  "Return this panel's shared live lease for helper ROOT.
Repeated redisplay and multiple artifacts from one helper root must not mint
unbounded lease files.  A panel owns one transferable local lease per root and
releases them together during clear/kill."
  (let* ((key (cons root root-identity))
         (table (or emacs-jupyter-notebook-panel--published-artifact-capabilities
                    (setq emacs-jupyter-notebook-panel--published-artifact-capabilities
                          (make-hash-table :test #'equal))))
         (existing (gethash key table)))
    (if (emacs-jupyter-notebook-artifacts-capability-valid-p existing)
        existing
      (let ((cap (emacs-jupyter-notebook-artifacts-capture
                  'helper root root-identity)))
        (when cap (puthash key cap table))
        cap))))

(defun emacs-jupyter-notebook-panel--admitted-artifact-current-p (metadata limit)
  "Return non-nil when admitted METADATA still names its pinned local leaf.
This bounded native-boundary check performs no hash or content read and
disables file-name handlers.  At most the hard inline-image count reaches it
per render, so retained history cannot amplify the filesystem work."
  (let ((root (plist-get metadata :root))
        (path (plist-get metadata :file))
        (size (plist-get metadata :size))
        (file-name-handler-alist nil))
    (and (eq (plist-get metadata :ejn-admitted)
             emacs-jupyter-notebook-panel--admitted-metadata-token)
         (stringp root) (file-name-absolute-p root)
         (stringp path) (file-name-absolute-p path)
         (integerp size) (<= 0 size limit)
         (not (file-symlink-p root))
         (not (file-symlink-p path))
         (let ((root-attrs (file-attributes root 'integer))
               (attrs (file-attributes path 'integer)))
           (and root-attrs attrs
                (eq (file-attribute-type root-attrs) t)
                (null (file-attribute-type attrs))
                (equal (file-attribute-user-id root-attrs) (user-uid))
                (equal (file-attribute-user-id attrs) (user-uid))
                (= (file-attribute-link-number attrs) 1)
                (= (file-attribute-size attrs) size)
                (equal (file-attribute-file-identifier root-attrs)
                       (plist-get metadata :root-identity))
                (equal (file-attribute-file-identifier attrs)
                       (plist-get metadata :identity))
                (equal (file-name-directory (directory-file-name path))
                       (file-name-as-directory
                        (directory-file-name (expand-file-name root))))
                (= (logand (file-modes root) #o7777) #o700)
                (= (logand (file-modes path) #o7777) #o600))))))

(defun emacs-jupyter-notebook-panel--published-artifact-metadata
    (root path sha256 size root-identity limit
          &optional ppm width height capability cached)
  "Validate one pinned publication and return metadata for later retirement.
When PPM is non-nil, only its bounded canonical header and declared total
length are checked before a native image spec is created.  The trusted local
helper parent already validated the complete worker output and SHA-256 before
publication.  Original compressed files deliberately skip content reads here;
they are copied and revalidated outside the UI thread before external opening.
When CACHED is an admitted metadata plist, return it without touching the
filesystem; this is used only by repeated native preview admission checks."
  (if (and cached (listp cached))
      (if (emacs-jupyter-notebook-panel--admitted-artifact-current-p
           cached limit)
          cached
        (error "published artifact changed after admission"))
    (unless (and (stringp root) (file-name-absolute-p root)
                 (stringp path) (file-name-absolute-p path)
                 (stringp sha256) (string-equal sha256 (downcase sha256))
                 (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256)
                 (integerp size) (<= 0 size limit) root-identity)
      (error "invalid published artifact metadata"))
    (let* ((root-name (directory-file-name (expand-file-name root)))
           (path-name (expand-file-name path))
           (capability (or capability
                           (emacs-jupyter-notebook-panel--helper-artifact-capability
                            root-name root-identity)))
           (root-attrs (and (not (file-symlink-p root-name))
                            (file-attributes root-name 'integer)))
           (attrs (and (not (file-symlink-p path-name))
                       (file-attributes path-name 'integer)))
           (identity (and attrs (file-attribute-file-identifier attrs))))
      (unless (and capability root-attrs attrs identity
                   (file-directory-p root-name)
                   (eq (file-attribute-type root-attrs) t)
                   (equal (file-attribute-user-id root-attrs) (user-uid))
                   (= (logand (file-modes root-name) #o7777) #o700)
                   (equal root-identity (file-attribute-file-identifier root-attrs))
                   (equal (file-name-directory (directory-file-name path-name))
                          (file-name-as-directory root-name))
                   (file-regular-p path-name) (null (file-attribute-type attrs))
                   (= (file-attribute-link-number attrs) 1)
                   (equal (file-attribute-user-id attrs) (user-uid))
                   (= (logand (file-modes path-name) #o7777) #o600)
                   (= (file-attribute-size attrs) size))
        (error "unsafe published artifact"))
      (when ppm
        (let* ((prefix
                (let ((file-name-handler-alist nil)
                      (coding-system-for-read 'no-conversion))
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally
                     path-name nil 0
                     (min size emacs-jupyter-notebook-panel--ppm-header-read-limit))
                    (buffer-string))))
               (metadata
                (emacs-jupyter-notebook-panel--canonical-ppm-header-metadata
                 prefix size)))
          (unless (and metadata
                       (= (plist-get metadata :width) width)
                       (= (plist-get metadata :height) height))
            (error "unsafe PPM preview"))))
      ;; Re-observe names after the optional bounded hash/read before ownership
      ;; transfer.  This captures each publication's own device/inode.
      (let ((post-root (and (not (file-symlink-p root-name))
                            (file-attributes root-name 'integer)))
            (post (and (not (file-symlink-p path-name))
                       (file-attributes path-name 'integer))))
        (unless (and post-root post
                     (equal root-identity (file-attribute-file-identifier post-root))
                     (equal identity (file-attribute-file-identifier post))
                     (= (file-attribute-size post) size)
                     (= (file-attribute-link-number post) 1)
                     (= (logand (file-modes path-name) #o7777) #o600))
          (error "published artifact changed during validation")))
      (list :root root-name :root-identity root-identity :file path-name
            :identity identity :sha256 sha256 :size size
            :artifact-capability capability
            :ejn-admitted emacs-jupyter-notebook-panel--admitted-metadata-token))))

(defun emacs-jupyter-notebook-panel--published-image-bundle-spec (image)
  "Validate nested IMAGE descriptor and construct its panel image spec.
The original is an external-only compressed file.  The optional preview is a
separate canonical PPM artifact; it is the only path that can reach Emacs's
native image machinery."
  (let* ((root (plist-get image :root))
         (root-identity (plist-get image :root-identity))
         (original-value (plist-get image :original))
         (preview-value (plist-get image :preview))
         (mime (plist-get image :mime)))
    (unless (and (member mime '("image/png" "image/jpeg" "image/gif" "image/webp"))
                 (listp original-value)
                 (plist-member original-value :path)
                 (plist-member original-value :size)
                 (plist-member original-value :sha256)
                 (plist-member image :preview)
                 (or (null preview-value) (listp preview-value)))
      (error "invalid published image bundle"))
    (let* ((capability (or (plist-get image :artifact-capability)
                           (emacs-jupyter-notebook-panel--helper-artifact-capability
                            root root-identity)))
           (original (emacs-jupyter-notebook-panel--published-artifact-metadata
                      root (plist-get original-value :path)
                      (plist-get original-value :sha256)
                      (plist-get original-value :size) root-identity
                      emacs-jupyter-notebook-panel--max-published-original-bytes
                      nil nil nil capability))
           (preview
            (and preview-value
                 (let ((preview-mime (plist-get preview-value :mime))
                       (width (plist-get preview-value :width))
                       (height (plist-get preview-value :height)))
                   (unless (and (equal preview-mime "image/x-portable-pixmap")
                                (integerp width) (integerp height))
                     (error "invalid published PPM metadata"))
                   (append
                    (emacs-jupyter-notebook-panel--published-artifact-metadata
                     root (plist-get preview-value :path)
                     (plist-get preview-value :sha256)
                     (plist-get preview-value :size) root-identity
                     emacs-jupyter-notebook-panel--max-published-preview-bytes
                     t width height capability)
                    (list :mime preview-mime :width width :height height)))))
           ;; Keeping :file at the original for no-preview entries preserves
           ;; placeholder and external-open ergonomics, but native admission
           ;; below requires :ejn-preview and will never decode it.
           (display-file (if preview (plist-get preview :file) (plist-get original :file)))
           (display-identity (if preview (plist-get preview :identity)
                             (plist-get original :identity))))
      (cons 'image
            (list :type (and preview 'pbm) :file display-file
                  :max-width emacs-jupyter-notebook-image-max-width
                  :max-height emacs-jupyter-notebook-image-max-height
                  :ejn-original original :ejn-preview preview
                  :ejn-artifact-bytes (+ (plist-get original :size)
                                         (or (plist-get preview :size) 0))
                  :ejn-publication-root (plist-get original :root)
                  :ejn-publication-root-identity (plist-get original :root-identity)
                  :ejn-publication-identity display-identity
                  :ejn-original-mime mime
                  :ejn-display-id (plist-get image :display-id)
                  :ejn-materialized nil :ejn-retired nil
                  :ejn-original-open-leases 0)))))

(defun emacs-jupyter-notebook-panel--published-pickle
    (root path sha256 size root-identity &optional capability)
  "Validate a published pickle and return its confined panel metadata.
The artifact is never read into Emacs.  The viewer verifies SHA-256 from the
same identity-pinned bytes it executes in its bounded worker."
  (unless (and (stringp root) (file-name-absolute-p root)
               (stringp path) (file-name-absolute-p path)
               (stringp sha256) (string-equal sha256 (downcase sha256))
               (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256)
               (integerp size) (>= size 0)
               (<= size emacs-jupyter-notebook-panel--max-published-pickle-bytes)
               root-identity)
    (error "invalid published pickle metadata"))
  (let* ((root-name (directory-file-name (expand-file-name root)))
         (path-name (expand-file-name path))
         (capability (or capability
                         (emacs-jupyter-notebook-panel--helper-artifact-capability
                          root-name root-identity)))
         (root-attrs (and (not (file-symlink-p root-name))
                          (file-attributes root-name 'integer)))
         (attrs (and (not (file-symlink-p path-name))
                     (file-attributes path-name 'integer)))
         (identity (and attrs (file-attribute-file-identifier attrs))))
    (unless (and capability root-attrs (file-directory-p root-name)
                 (eq (file-attribute-type root-attrs) t)
                 (equal (file-attribute-user-id root-attrs) (user-uid))
                 (= (logand (file-modes root-name) #o7777) #o700)
                 (equal root-identity (file-attribute-file-identifier root-attrs))
                 (equal (file-name-directory (directory-file-name path-name))
                        (file-name-as-directory root-name))
                 attrs identity (file-regular-p path-name)
                 (null (file-attribute-type attrs))
                 (string-match-p "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'"
                                 (file-name-nondirectory path-name))
                 (= (file-attribute-link-number attrs) 1)
                 (equal (file-attribute-user-id attrs) (user-uid))
                 (= (logand (file-modes path-name) #o7777) #o600)
                 (= (file-attribute-size attrs) size)
                 ;; Do not read/hash pickle bytes on Emacs's UI thread.  The
                 ;; viewer recomputes SHA-256 from its pinned descriptor in
                 ;; its bounded worker before any unpickle.
                 (let ((post-root (and (not (file-symlink-p root-name))
                                       (file-attributes root-name 'integer)))
                       (post (and (not (file-symlink-p path-name))
                                  (file-attributes path-name 'integer))))
                   (and post-root post (file-directory-p root-name)
                        (eq (file-attribute-type post-root) t)
                        (equal (file-attribute-user-id post-root) (user-uid))
                        (= (logand (file-modes root-name) #o7777) #o700)
                        (equal root-identity
                               (file-attribute-file-identifier post-root))
                        (file-regular-p path-name)
                        (null (file-attribute-type post))
                        (string-match-p "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'"
                                        (file-name-nondirectory path-name))
                        (= (file-attribute-link-number post) 1)
                        (equal (file-attribute-user-id post) (user-uid))
                        (= (logand (file-modes path-name) #o7777) #o600)
                        (= (file-attribute-size post) size)
                        (equal identity (file-attribute-file-identifier post)))))
      (error "unsafe published pickle"))
    (list :root root-name :root-identity root-identity :file path-name
          :identity identity :sha256 sha256 :size size
          :artifact-capability capability
          :leases 0 :retired nil :deleted nil)))

(defun emacs-jupyter-notebook-panel--retire-pickle (pickle)
  "Retire PICKLE, unlinking only after all viewer leases have released it."
  (when (and (listp pickle) (not (plist-get pickle :deleted)))
    (plist-put pickle :retired t)
    (when (<= (or (plist-get pickle :leases) 0) 0)
      (when (eq (emacs-jupyter-notebook-panel--delete-published-artifact pickle)
                t)
        (plist-put pickle :deleted t)))))

(defun emacs-jupyter-notebook-panel--set-pickle-metadata (handle pickle)
  "Install already validated PICKLE metadata on HANDLE."
  (when (ejn-panel-entry-live-p handle)
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (let ((old (plist-get entry :mpl-pickle)))
         (when old (emacs-jupyter-notebook-panel--retire-pickle old))
         (setq entry (plist-put entry :artifact-bytes
                                (+ (- (plist-get entry :artifact-bytes)
                                      (or (plist-get old :size) 0))
                                   (plist-get pickle :size))))
         (plist-put entry :mpl-pickle pickle)))
     t)
    (emacs-jupyter-notebook-panel--prune-pickles (plist-get handle :panel))
    (emacs-jupyter-notebook-panel--enforce-retention-budgets
     (plist-get handle :panel))
    t))

(defun ejn-panel-set-published-pickle (handle root path sha256 size root-identity)
  "Store one validated confined pickle metadata record on HANDLE."
  (when (ejn-panel-entry-live-p handle)
    (emacs-jupyter-notebook-panel--set-pickle-metadata
     handle
     (with-current-buffer (plist-get handle :panel)
       (emacs-jupyter-notebook-panel--published-pickle
        root path sha256 size root-identity)))))

(defun ejn-panel-set-published-bundle (handle image pickle update-p)
  "Atomically admit IMAGE and PICKLE descriptors, returning a boolean.
For UPDATE-P, resolve DISPLAY-ID once before mutating either artifact so the
pickle follows the image's existing cross-entry target."
  (when (ejn-panel-entry-live-p handle)
    (let* ((image-id (and image (plist-get image :display-id)))
           (pickle-id (and pickle (plist-get pickle :display-id)))
           (display-id (or image-id pickle-id))
           (target (and update-p display-id
                        (emacs-jupyter-notebook-panel--display-target
                         (plist-get handle :panel) display-id 'image)))
           (effective (or (car-safe target) handle)))
      (when (and (or image pickle)
                 (or (null image-id) (null pickle-id)
                     (equal image-id pickle-id))
                 (or (not update-p) target))
        ;; Validate both publications before changing the entry.  Descriptor
        ;; rejection therefore leaves the existing image/pickle bundle intact.
        (let* ((panel (plist-get effective :panel))
               (pickle-meta
                (and pickle
                     (with-current-buffer panel
                       (emacs-jupyter-notebook-panel--published-pickle
                        (plist-get pickle :root) (plist-get pickle :path)
                        (plist-get pickle :sha256) (plist-get pickle :size)
                        (plist-get pickle :root-identity)
                        (plist-get pickle :artifact-capability)))))
               (image-spec
                (and image
                     (with-current-buffer panel
                       (emacs-jupyter-notebook-panel--published-image-bundle-spec
                        image))))
               (old-entry (ejn-panel-entry-snapshot effective))
               old-images old-arrays old-image-replaced old-pickle old-timer
               dropped-image dropped-pickle segment-omitted
               replace-pickle-p new-entry committed)
          (when old-entry
            (setq old-pickle (plist-get old-entry :mpl-pickle)
                  old-timer (plist-get old-entry :pickle-open-timer))
            ;; Copy only mutable list structure.  Unchanged image specs keep
            ;; object identity so an outstanding external-viewer lease is
            ;; still released against the retained panel object.
            (let* ((pending-clear (plist-get old-entry :pending-clear))
                   (new (copy-sequence old-entry))
                   (outputs
                    (unless pending-clear
                      (mapcar (lambda (segment)
                                (cons (car segment) (cdr segment)))
                              (plist-get old-entry :outputs)))))
              (when pending-clear
                (setq old-images (ejn-panel-entry-images old-entry))
                (setq old-arrays (cl-remove-if-not
                                  (lambda (seg) (eq (car seg) 'array))
                                  (plist-get old-entry :outputs)))
                (setq new
                      (emacs-jupyter-notebook-panel--entry-reset-output-accounting
                       new)))
              (setq new (plist-put new :outputs outputs))
              (when image-spec
                (if update-p
                    (let ((matching
                           (and (not pending-clear)
                                (cl-find-if
                                 (lambda (segment)
                                   (and (eq (car segment) 'image)
                                        (equal
                                         (emacs-jupyter-notebook-panel--segment-display-id
                                          segment)
                                         display-id)))
                                 (reverse outputs)))))
                      (if matching
                          (progn
                            (setq old-image-replaced (cdr matching)
                                  old-images (list old-image-replaced))
                            (setcdr matching image-spec))
                        ;; clear_output(wait=True) deliberately turns the next
                        ;; update into the first new output segment.
                        (if (emacs-jupyter-notebook-panel--entry-output-room-p
                             new)
                            (setq outputs
                                  (append outputs
                                          (list (cons 'image image-spec))))
                          (setq dropped-image image-spec
                                dropped-pickle pickle-meta
                                image-spec nil
                                pickle-meta nil
                                segment-omitted t))))
                  (if (emacs-jupyter-notebook-panel--entry-output-room-p new)
                      (setq outputs
                            (append outputs (list (cons 'image image-spec))))
                    (setq dropped-image image-spec
                          dropped-pickle pickle-meta
                          image-spec nil
                          pickle-meta nil
                          segment-omitted t))))
              (setq new (plist-put new :outputs outputs))
              (when segment-omitted
                (setq new
                      (emacs-jupyter-notebook-panel--entry-note-segment-omission
                       new)))
              ;; A new image without a pickle clears the stale interactive
              ;; figure.  A pickle-only bundle leaves image output intact.
              (setq replace-pickle-p (or pending-clear pickle-meta image-spec))
              (when replace-pickle-p
                (setq new (plist-put new :mpl-pickle pickle-meta))
                (setq new (plist-put new :pickle-open-timer nil))
                (setq new (plist-put new :pickle-open-token nil)))
              (setq new (plist-put new :pending-clear nil))
              (setq new
                    (plist-put
                     new :artifact-bytes
                     (emacs-jupyter-notebook-panel--recompute-entry-artifact-bytes
                      new)))
              (setq new-entry new))
            ;; No callback, process wait, or file operation occurs between the
            ;; snapshot check and this single logical entry ownership swap.
            (when (and new-entry (ejn-panel-entry-live-p effective)
                       (eq old-entry (ejn-panel-entry-snapshot effective)))
              (with-current-buffer panel
                (cl-incf emacs-jupyter-notebook-panel--retained-text-bytes
                         (- (emacs-jupyter-notebook-panel--entry-text-bytes new-entry)
                            (emacs-jupyter-notebook-panel--entry-text-bytes old-entry)))
                (cl-incf emacs-jupyter-notebook-panel--retained-artifact-bytes
                         (- (emacs-jupyter-notebook-panel--entry-artifact-bytes new-entry)
                            (emacs-jupyter-notebook-panel--entry-artifact-bytes old-entry)))
                (cl-incf emacs-jupyter-notebook-panel--retained-output-segments
                         (- (length (plist-get new-entry :outputs))
                            (length (plist-get old-entry :outputs)))))
              (emacs-jupyter-notebook-panel--set-entry
               panel (plist-get effective :id) new-entry)
              (setq committed t)
              (condition-case err
                  (emacs-jupyter-notebook-panel--schedule-render
                   panel (plist-get effective :id)
                   (cond
                    ((not update-p) t)
                    ((null image-spec) nil)
                    ((null old-image-replaced) t)
                    (t
                     (emacs-jupyter-notebook-panel--image-update-needs-full-p
                      panel new-entry old-image-replaced image-spec))))
                (error
                 (message "emacs-jupyter-notebook: panel render scheduling failed: %s"
                          (error-message-string err)))))
            (when committed
              ;; Retirement is intentionally after the entry swap.  Any
              ;; validation or construction error above leaves these live.
              (dolist (old-image old-images)
                (emacs-jupyter-notebook-panel--retire-image panel old-image))
              (emacs-jupyter-notebook-panel--retire-outputs panel old-arrays)
              (when dropped-image
                (emacs-jupyter-notebook-panel--retire-image panel dropped-image))
              (when dropped-pickle
                (emacs-jupyter-notebook-panel--retire-pickle dropped-pickle))
              (when (and replace-pickle-p old-pickle)
                (when (timerp old-timer)
                  (cancel-timer old-timer))
                (emacs-jupyter-notebook-panel--retire-pickle old-pickle))
              (when (and replace-pickle-p (timerp old-timer) (null old-pickle))
                (cancel-timer old-timer))
              (emacs-jupyter-notebook-panel--prune-pickles panel)
              (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
              effective)))))))

(defun ejn-panel-acquire-pickle (handle)
  "Return HANDLE's pickle metadata with one viewer lifetime lease, or nil."
  (let (pickle)
    (when (emacs-jupyter-notebook-panel--mutate-live-entry
           handle
           (lambda (entry)
             (setq pickle (plist-get entry :mpl-pickle))
             (when pickle
               (plist-put pickle :leases (1+ (or (plist-get pickle :leases) 0))))
             entry))
      pickle)))

(defun ejn-panel-release-pickle (pickle)
  "Release one viewer lease on PICKLE and finish a deferred retirement."
  (when (listp pickle)
    (let ((leases (or (plist-get pickle :leases) 0)))
      (when (> leases 0)
        (plist-put pickle :leases (1- leases)))
      (when (and (plist-get pickle :retired)
                 (<= (or (plist-get pickle :leases) 0) 0))
        (emacs-jupyter-notebook-panel--retire-pickle pickle)))))

(defun emacs-jupyter-notebook-panel--delete-published-artifact (artifact)
  "Retire ARTIFACT through its identity-bound local capability.
Return t after immediate deletion, `queued' for a pending bulk deletion, and
nil when ARTIFACT could not be safely retired."
  (when (listp artifact)
    (let ((capability (plist-get artifact :artifact-capability)))
      (if (hash-table-p emacs-jupyter-notebook-panel--bulk-published-deletions)
          (let ((file (plist-get artifact :file))
                (identity (plist-get artifact :identity)))
            (when (and (stringp file) identity
                       (emacs-jupyter-notebook-artifacts-capability-valid-p capability))
              (let* ((key (cons (emacs-jupyter-notebook-artifacts-capability-root capability)
                                (emacs-jupyter-notebook-artifacts-capability-root-identity capability)))
                     (bucket (gethash key emacs-jupyter-notebook-panel--bulk-published-deletions)))
                (puthash key (list capability (cons artifact (cadr bucket)))
                         emacs-jupyter-notebook-panel--bulk-published-deletions)
                'queued)))
        (when (emacs-jupyter-notebook-artifacts-delete-leaf
               capability (plist-get artifact :file) (plist-get artifact :identity))
          (when (emacs-jupyter-notebook-artifacts-release-if-empty capability)
            (when (hash-table-p emacs-jupyter-notebook-panel--published-artifact-capabilities)
              (remhash
               (cons (emacs-jupyter-notebook-artifacts-capability-root capability)
                     (emacs-jupyter-notebook-artifacts-capability-root-identity capability))
               emacs-jupyter-notebook-panel--published-artifact-capabilities)))
          t)))))

(defun emacs-jupyter-notebook-panel--flush-bulk-published-deletions (table)
  "Perform every helper publication batch in TABLE once per root.
Mark metadata deleted only for paths the identity-pinned batch actually
removed, so a failed batch remains conservatively owned and retriable."
  (when (hash-table-p table)
    (maphash
     (lambda (_key bucket)
       (let* ((capability (car bucket))
              (artifacts (delete-dups (nreverse (cadr bucket))))
              (deleted
               (ignore-errors
                 (emacs-jupyter-notebook-artifacts-delete-leaves
                  capability
                  (mapcar (lambda (artifact)
                            (cons (plist-get artifact :file)
                                  (plist-get artifact :identity)))
                          artifacts)))))
         (dolist (artifact artifacts)
           (when (member (plist-get artifact :file) deleted)
             (plist-put artifact :deleted t)))))
     table)))

(defun emacs-jupyter-notebook-panel--retire-original-if-released (image)
  "Delete IMAGE's original after both entry retirement and opener release."
  (let* ((props (cdr image))
         (original (plist-get props :ejn-original)))
    (when (and original
               (not (plist-get original :deleted))
               (plist-get props :ejn-retired)
               (<= (or (plist-get props :ejn-original-open-leases) 0) 0))
      (when (eq (emacs-jupyter-notebook-panel--delete-published-artifact original)
                t)
        (plist-put original :deleted t)))))

(defun emacs-jupyter-notebook-panel--retire-image (panel image)
  "Flush materialized preview IMAGE and retire its owned artifact bundle."
  (ignore panel)
  (when (and (consp image) (eq (car image) 'image))
    (when (plist-get (cdr image) :ejn-materialized)
      (when-let ((preview (emacs-jupyter-notebook-panel--native-preview-spec image)))
        (ignore-errors (image-flush preview t)))
      (plist-put (cdr image) :ejn-materialized nil))
    (let* ((props (cdr image))
           (file (plist-get props :file))
           (preview (plist-get props :ejn-preview))
           (original (plist-get props :ejn-original)))
      (plist-put props :ejn-retired t)
      ;; A verifier owns one lifetime lease on ORIGINAL.  Clearing the entry
      ;; must not cancel that transfer: it can still publish a durable
      ;; snapshot after the panel no longer renders this image.  The normal
      ;; callback releases the original lease, while Emacs-exit cleanup owns
      ;; cancellation of genuinely pending verifier processes.
      (cond
       ((plist-get props :ejn-artifact-capability)
        (unless (eq (plist-get props :ejn-artifact-capability)
                    emacs-jupyter-notebook-panel--bulk-retiring-capability)
          (ignore-errors
            (emacs-jupyter-notebook-artifacts-delete-leaf
             (plist-get props :ejn-artifact-capability) file
             (plist-get props :ejn-artifact-identity)))))
       (preview
        (emacs-jupyter-notebook-panel--delete-published-artifact preview)))
      (when original
        (emacs-jupyter-notebook-panel--retire-original-if-released image)))))

(defun emacs-jupyter-notebook-panel--retire-outputs (panel outputs)
  "Retire every image and numerical publication in OUTPUTS owned by PANEL."
  (dolist (seg outputs)
    (pcase (car seg)
      ('image (emacs-jupyter-notebook-panel--retire-image panel (cdr seg)))
      ;; Numerical publications use the established confined binary lifetime
      ;; lease machinery; they never use Emacs's native image decoder.
      ('array (emacs-jupyter-notebook-panel--retire-pickle (cdr seg))))))

(defun emacs-jupyter-notebook-panel--entry-text-bytes (entry)
  "Return the retained source and output text byte count for ENTRY."
  (or (plist-get entry :retained-text-bytes) 0))

(defun emacs-jupyter-notebook-panel--image-artifact-bytes (image)
  "Return retained artifact bytes for IMAGE without consulting its file name."
  (let* ((props (cdr-safe image))
         (cached (plist-get props :ejn-artifact-bytes))
         (data (plist-get props :data)))
    (cond
     ((and (integerp cached) (>= cached 0)) cached)
     ((stringp data) (string-bytes data))
     (t 0))))

(defun emacs-jupyter-notebook-panel--entry-artifact-bytes (entry)
  "Return retained image and MIME artifact bytes for ENTRY."
  (or (plist-get entry :artifact-bytes) 0))

(defun emacs-jupyter-notebook-panel--recompute-entry-text-bytes (entry)
  "Recompute ENTRY's logical source and output bytes for test introspection."
  (+ (let ((code (plist-get entry :code)))
       (if (stringp code) (string-bytes code) 0))
     (cl-loop for segment in (plist-get entry :outputs)
              when (eq (car segment) 'text)
              sum (emacs-jupyter-notebook-panel--text-segment-bytes segment))))

(defun emacs-jupyter-notebook-panel--recompute-entry-artifact-bytes (entry)
  "Recompute ENTRY's artifact bytes for test introspection only."
  (+ (cl-loop for segment in (plist-get entry :outputs)
              sum (pcase (car segment)
                    ('image (or (plist-get (cdr (cdr segment)) :ejn-artifact-bytes) 0))
                    ('array (or (plist-get (cdr segment) :size) 0))
                    (_ 0)))
     (let ((pickle (plist-get entry :mpl-pickle)))
       (or (plist-get pickle :size) 0))))

(defun emacs-jupyter-notebook-panel--recompute-totals ()
  "Return recomputed text/artifact totals for test introspection."
  (list :text (cl-loop for cell in emacs-jupyter-notebook-panel--entries
                       sum (emacs-jupyter-notebook-panel--recompute-entry-text-bytes
                            (cdr cell)))
        :artifacts (cl-loop for cell in emacs-jupyter-notebook-panel--entries
                            sum (emacs-jupyter-notebook-panel--recompute-entry-artifact-bytes
                                 (cdr cell)))))

(defun emacs-jupyter-notebook-panel--recompute-output-segments ()
  "Return the recomputed output-segment count for test introspection."
  (cl-loop for cell in emacs-jupyter-notebook-panel--entries
           sum (length (plist-get (cdr cell) :outputs))))

(defun emacs-jupyter-notebook-panel--total-text-bytes ()
  "Return the total retained text byte count in the current panel."
  emacs-jupyter-notebook-panel--retained-text-bytes)

(defun emacs-jupyter-notebook-panel--total-artifact-bytes ()
  "Return the total retained image and MIME artifact bytes in this panel."
  emacs-jupyter-notebook-panel--retained-artifact-bytes)

(defun emacs-jupyter-notebook-panel--over-retention-budget-p ()
  "Return non-nil when the current panel exceeds any configured budget."
  (or (> (length emacs-jupyter-notebook-panel--entries)
         (emacs-jupyter-notebook-panel--positive-clamped
          emacs-jupyter-notebook-panel-max-history-entries
          emacs-jupyter-notebook-panel--hard-history-entries))
      (> (emacs-jupyter-notebook-panel--total-text-bytes)
         (emacs-jupyter-notebook-panel--positive-clamped
          emacs-jupyter-notebook-panel-max-total-text-bytes
          emacs-jupyter-notebook-panel--hard-total-text-bytes))
      (> (emacs-jupyter-notebook-panel--total-artifact-bytes)
         (emacs-jupyter-notebook-panel--positive-clamped
          emacs-jupyter-notebook-panel-max-total-artifact-bytes
          emacs-jupyter-notebook-panel--hard-total-artifact-bytes))
      (> emacs-jupyter-notebook-panel--retained-output-segments
         (emacs-jupyter-notebook-panel--output-segment-budget))))

(defun emacs-jupyter-notebook-panel--oldest-evictable-cell ()
  "Return the oldest cell that is not the latest result for its cell key.
When every retained entry is current, return the absolute oldest cell so
configured budgets remain hard limits."
  (let ((latest-ids (make-hash-table :test 'equal)))
    (dolist (cell (reverse emacs-jupyter-notebook-panel--entries))
      (let ((entry (cdr cell)))
        (when (and (plist-get entry :cell-key)
                   (not (gethash (plist-get entry :cell-key) latest-ids)))
          (puthash (plist-get entry :cell-key) (car cell) latest-ids))))
    (or (cl-find-if
         (lambda (cell)
           (let ((key (plist-get (cdr cell) :cell-key)))
             (or (null key)
                 (not (eql (car cell) (gethash key latest-ids))))))
         emacs-jupyter-notebook-panel--entries)
        (car emacs-jupyter-notebook-panel--entries))))

(defun emacs-jupyter-notebook-panel--retire-entry (panel cell)
  "Retire CELL's artifacts and remove it from PANEL's retained history."
  (let* ((entry (cdr cell))
         (images (ejn-panel-entry-images entry)))
    (cl-decf emacs-jupyter-notebook-panel--retained-text-bytes
             (emacs-jupyter-notebook-panel--entry-text-bytes entry))
    (cl-decf emacs-jupyter-notebook-panel--retained-artifact-bytes
             (emacs-jupyter-notebook-panel--entry-artifact-bytes entry))
    (cl-decf emacs-jupyter-notebook-panel--retained-output-segments
             (length (plist-get entry :outputs)))
    (emacs-jupyter-notebook-panel--retire-outputs panel
                                                   (plist-get entry :outputs))
    (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer entry))
    (setq entry (plist-put entry :outputs nil))
    (emacs-jupyter-notebook-panel--retire-pickle (plist-get entry :mpl-pickle))
    (setq entry (plist-put entry :mpl-pickle nil))
    (setcdr cell entry)
    (setq emacs-jupyter-notebook-panel--inline-image-specs
          (cl-set-difference emacs-jupyter-notebook-panel--inline-image-specs
                             images :test #'equal))
    (setq emacs-jupyter-notebook-panel--entries
          (delq cell emacs-jupyter-notebook-panel--entries))
    (when (eql (car cell) emacs-jupyter-notebook-panel--reveal-entry-id)
      (setq emacs-jupyter-notebook-panel--reveal-entry-id nil))))

(defun emacs-jupyter-notebook-panel--enforce-retention-budgets (panel)
  "Evict oldest history entries from PANEL until all retention budgets hold."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (let (evicted)
        (while (and emacs-jupyter-notebook-panel--entries
                    (emacs-jupyter-notebook-panel--over-retention-budget-p))
          (when-let ((cell (emacs-jupyter-notebook-panel--oldest-evictable-cell)))
            (emacs-jupyter-notebook-panel--retire-entry panel cell)
            (setq evicted t)))
        (when evicted
          (setq emacs-jupyter-notebook-panel--history-evicted-p t)
          (emacs-jupyter-notebook-panel--invalidate-structure panel))))))

(defun emacs-jupyter-notebook-panel--retire-all-artifacts (panel)
  "Flush caches and delete every panel-owned output artifact in PANEL.
This is local cleanup only.  Call it before discarding entries or during
normal Emacs exit; it never consults source, registry, SSH, or kernel state."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel--cleanup-external-image-opens-for-panel
       panel)
      ;; This root can contain up to the whole bounded panel history.  Retire
      ;; it once before walking entries: doing an ownership scan for every
      ;; image made clear/kill quadratic and visibly stalled Emacs.
      (when emacs-jupyter-notebook-panel--image-artifact-capability
        (ignore-errors
          (emacs-jupyter-notebook-artifacts-retire
           emacs-jupyter-notebook-panel--image-artifact-capability)))
      (let ((emacs-jupyter-notebook-panel--bulk-retiring-capability
             emacs-jupyter-notebook-panel--image-artifact-capability)
            (emacs-jupyter-notebook-panel--bulk-published-deletions
             (make-hash-table :test #'equal))
            ;; A pending verifier or pickle viewer owns a publication beyond
            ;; this panel entry.  Keep the shared artifact lease attached to
            ;; that metadata until its deferred identity-pinned retirement.
            (deferred-capabilities (make-hash-table :test #'eq))
            (retired-publications nil))
        (dolist (cell emacs-jupyter-notebook-panel--entries)
          (let ((outputs (plist-get (cdr cell) :outputs)))
            (emacs-jupyter-notebook-panel--retire-outputs panel outputs)
            (dolist (segment outputs)
              (when (eq (car segment) 'array)
                (let ((artifact (cdr segment)))
                  (push (cons artifact (> (or (plist-get artifact :leases) 0) 0))
                        retired-publications)))
              (when (eq (car segment) 'image)
                (let* ((image (cdr segment))
                       (props (cdr image)))
                  (when-let ((original (plist-get props :ejn-original)))
                    (push (cons original
                                (> (or (plist-get props
                                                  :ejn-original-open-leases)
                                       0)
                                   0))
                          retired-publications))))))
          (let ((entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                        (cdr cell))))
            (let ((pickle (plist-get entry :mpl-pickle)))
              (emacs-jupyter-notebook-panel--retire-pickle pickle)
              (when pickle
                (push (cons pickle (> (or (plist-get pickle :leases) 0) 0))
                      retired-publications)))
            (setcdr cell (plist-put entry :mpl-pickle nil))))
        (emacs-jupyter-notebook-panel--flush-bulk-published-deletions
         emacs-jupyter-notebook-panel--bulk-published-deletions)
        (dolist (publication retired-publications)
          (let ((artifact (car publication))
                (viewer-owned-p (cdr publication)))
            (when (and viewer-owned-p (not (plist-get artifact :deleted)))
              (when-let ((capability (plist-get artifact :artifact-capability)))
                (puthash capability t deferred-capabilities)))))
        (setq emacs-jupyter-notebook-panel--deferred-artifact-capabilities
              deferred-capabilities))
      (setq emacs-jupyter-notebook-panel--inline-image-specs nil)
      ;; Helper publications have one panel lease per root.  Output retirement
      ;; removed every identity-pinned file above; release leases afterwards so
      ;; a concurrent panel keeps its own root alive independently.
      (when (hash-table-p emacs-jupyter-notebook-panel--published-artifact-capabilities)
        (maphash (lambda (_key capability)
                   (unless (gethash
                            capability
                            emacs-jupyter-notebook-panel--deferred-artifact-capabilities)
                     (ignore-errors
                       (emacs-jupyter-notebook-artifacts-release capability))))
                 emacs-jupyter-notebook-panel--published-artifact-capabilities))
      (setq emacs-jupyter-notebook-panel--deferred-artifact-capabilities nil)
      (setq emacs-jupyter-notebook-panel--image-directory nil
            emacs-jupyter-notebook-panel--image-artifact-capability nil
            emacs-jupyter-notebook-panel--published-artifact-capabilities nil)
      (setq emacs-jupyter-notebook-panel--retained-text-bytes 0
            emacs-jupyter-notebook-panel--retained-artifact-bytes 0
            emacs-jupyter-notebook-panel--retained-output-segments 0))))

(defun ejn-panel-clear-all (panel)
  "Retire all PANEL artifacts and entries, invalidating their handles."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel--retire-all-artifacts panel)
      (setq emacs-jupyter-notebook-panel--entries nil)
      (setq emacs-jupyter-notebook-panel--hidden-cells nil)
      (setq emacs-jupyter-notebook-panel--restore-entry-id nil)
      (setq emacs-jupyter-notebook-panel--reveal-entry-id nil
            emacs-jupyter-notebook-panel--navigation-snapshot nil
            emacs-jupyter-notebook-panel--follow-empty nil)
      (emacs-jupyter-notebook-panel--track-duration panel)
      (setq emacs-jupyter-notebook-panel--retained-text-bytes 0
            emacs-jupyter-notebook-panel--retained-artifact-bytes 0
            emacs-jupyter-notebook-panel--retained-output-segments 0)
      (setq emacs-jupyter-notebook-panel--history-evicted-p nil)
      (cl-incf emacs-jupyter-notebook-panel--generation)
      (emacs-jupyter-notebook-panel--invalidate-structure panel))))

(defun ejn-panel-start-entry (panel cell-key code &optional title)
  "Begin a new output entry in PANEL associated with CELL-KEY for CODE.
Return an entry handle.  Optional TITLE supplies a short user-facing label
for generated inspection code; otherwise the source cell's marker title wins.

For latest-per-cell view, re-evaluating the same CELL-KEY replaces the
prior entry's slot.  The new entry takes its position so the running
state appears in place."
  (unless (buffer-live-p panel)
    (error "Panel buffer is not live"))
  (with-current-buffer panel
    ;; W2.13: keep every entry in the panel's append-only list so the
    ;; history-log view shows the full eval timeline.  Latest-per-cell view
    ;; dedupes by cell key at render time via `--latest-per-cell'.
    (let* ((id (cl-incf emacs-jupyter-notebook-panel--next-id))
           (entry (list :id id
                        :cell-key cell-key
                        :title (when title (emacs-jupyter-notebook-panel--short-line title))
                        :hidden (and cell-key
                                     emacs-jupyter-notebook-panel--hidden-cells
                                     (gethash cell-key
                                              emacs-jupyter-notebook-panel--hidden-cells))
                        :code (or code "")
                        :status 'running
                        :started-at (float-time)
                        :finished-at nil
                        :duration nil
                        :edited-since-run nil
                        :metadata-dirty-p nil
                        :exec-count "*"
                        :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S")
                        ;; W16: ordered output segments — `(text . STRING)'
                        ;; and `(image . SPEC)' conses, rendered interleaved
                        ;; in arrival order like a real notebook cell.
                        :outputs nil
                        :output-text-bytes 0
                        :retained-text-bytes (string-bytes (or code ""))
                        :artifact-bytes 0
                        :pickle-open-timer nil
                        :pickle-open-token nil
                        :pending-clear nil)))
      ;; A queued execution may reach dispatch after its cell was deleted.
      ;; Return an inert handle so late output cannot acquire a new entry.
      (unless (emacs-jupyter-notebook--cell-key-retired-p
               cell-key emacs-jupyter-notebook-panel--source-buffer)
        (setq emacs-jupyter-notebook-panel--entries
              (append emacs-jupyter-notebook-panel--entries
                      (list (cons id entry))))
        (cl-incf emacs-jupyter-notebook-panel--retained-text-bytes
                 (plist-get entry :retained-text-bytes))
        (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
        (emacs-jupyter-notebook-panel--schedule-render panel nil t))
      (emacs-jupyter-notebook-panel--handle panel id cell-key))))

(defun emacs-jupyter-notebook--apply-carriage-returns (text)
  "Resolve carriage returns in TEXT like a terminal / notebook cell.
`\\r\\n' collapses to `\\n'; within a line a bare `\\r' returns to column 0,
so only the text after the LAST `\\r' on that line survives.  This collapses
tqdm-style progress bars — which repaint a single line via `\\r' — to their
final frame instead of dumping every intermediate update into the panel.
Text properties (ANSI-coloured spans) are preserved."
  (if (not (string-search "\r" text))
      text
    (let ((text (replace-regexp-in-string "\r\n" "\n" text)))
      (mapconcat
       (lambda (line)
         (if (string-search "\r" line)
             (car (last (split-string line "\r")))
           line))
       (split-string text "\n")
       "\n"))))

(defun emacs-jupyter-notebook-panel--carriage-rewrites-current-line-p (text)
  "Return non-nil when TEXT's first logical line contains a bare carriage."
  (let ((index 0) found done)
    (while (and (< index (length text)) (not done))
      (pcase (aref text index)
        (?\n (setq done t))
        (?\r
         (if (and (< (1+ index) (length text))
                  (eq (aref text (1+ index)) ?\n))
             (setq done t)
           (setq found t done t))))
      (setq index (1+ index)))
    found))

(defun ejn-panel-entry-text (handle-or-entry)
  "Return the concatenated text of all text segments, or \"\" when none.
HANDLE-OR-ENTRY is an entry handle plist (with a `:panel' key) or a raw
entry plist."
  (let ((entry (if (plist-get handle-or-entry :panel)
                   (ejn-panel-entry-snapshot handle-or-entry)
                 handle-or-entry)))
    (mapconcat #'emacs-jupyter-notebook-panel--text-state-value
               (cl-remove-if-not (lambda (seg) (eq (car seg) 'text))
                                 (plist-get entry :outputs))
               "")))

(defun ejn-panel-entry-images (handle-or-entry)
  "Return the list of image specs on the entry, in display order."
  (let ((entry (if (plist-get handle-or-entry :panel)
                   (ejn-panel-entry-snapshot handle-or-entry)
                 handle-or-entry)))
    (mapcar #'cdr
            (cl-remove-if-not (lambda (seg) (eq (car seg) 'image))
                              (plist-get entry :outputs)))))

(defun emacs-jupyter-notebook-panel--entry-reset-output-accounting (entry)
  "Clear ENTRY's output accounting while preserving its source-code bytes."
  (setq entry (plist-put entry :output-text-bytes 0))
  (setq entry (plist-put entry :retained-text-bytes
                         (string-bytes (or (plist-get entry :code) ""))))
  (setq entry (plist-put entry :artifact-bytes 0))
  (plist-put entry :output-segments-truncated nil))

(defun emacs-jupyter-notebook-panel--entry-output-room-p (entry)
  "Return non-nil when ENTRY can retain one more ordinary output segment.
One final slot is reserved for the explicit omission marker."
  (and (not (plist-get entry :output-segments-truncated))
       (< (length (plist-get entry :outputs))
          (1- emacs-jupyter-notebook-panel--hard-entry-output-segments))))

(defun emacs-jupyter-notebook-panel--entry-note-segment-omission (entry)
  "Append ENTRY's one bounded output-omission marker and return ENTRY."
  (if (plist-get entry :output-segments-truncated)
      entry
    (let* ((text emacs-jupyter-notebook-panel--segment-omission-text)
           (bytes (string-bytes text))
           (outputs (plist-get entry :outputs)))
      (setq entry
            (plist-put entry :outputs
                       (append outputs
                               (list
                                (cons 'text
                                      (emacs-jupyter-notebook-panel--make-text-state
                                       text))))))
      (setq entry (plist-put entry :output-text-bytes
                             (+ (plist-get entry :output-text-bytes) bytes)))
      (setq entry (plist-put entry :retained-text-bytes
                             (+ (string-bytes (or (plist-get entry :code) ""))
                                (plist-get entry :output-text-bytes))))
      (plist-put entry :output-segments-truncated t))))

(defun emacs-jupyter-notebook-panel--entry-trim-text (entry)
  "Trim ENTRY's oldest text chunks to its per-entry byte budget."
  (let ((old-total (plist-get entry :output-text-bytes))
        (removed 0)
        (excess (- (plist-get entry :output-text-bytes)
                   (emacs-jupyter-notebook-panel--entry-text-budget))))
    (when (> excess 0)
      (dolist (segment (plist-get entry :outputs))
        (when (and (> excess 0) (eq (car segment) 'text))
          (let* ((before (emacs-jupyter-notebook-panel--text-segment-bytes segment))
                 (state (cdr segment))
                 (drop (min excess before)))
            (if (emacs-jupyter-notebook-panel--text-state-p state)
                (setcdr segment
                        (emacs-jupyter-notebook-panel--text-state-drop-front state drop))
              (setcdr segment (emacs-jupyter-notebook--last-bytes state (- before drop))))
            (cl-incf removed
                     (- before
                        (emacs-jupyter-notebook-panel--text-segment-bytes segment)))
            (setq excess (- excess drop)))))
      (setq entry (plist-put entry :output-text-bytes (- old-total removed)))
      (setq entry (plist-put entry :retained-text-bytes
                             (+ (string-bytes (or (plist-get entry :code) ""))
                                (plist-get entry :output-text-bytes)))))
    entry))

(defun emacs-jupyter-notebook-panel--entry-after-pending-clear (panel entry)
  "Return ENTRY after applying a pending clear_output(wait=True).
When the clear takes effect, retire its images and interactive pickle before
accepting the next output.  This also cancels a queued auto-viewer handoff."
  (if (plist-get entry :pending-clear)
      (progn
        (emacs-jupyter-notebook-panel--retire-outputs
         panel (plist-get entry :outputs))
        (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                     entry))
        (setq entry (plist-put entry :outputs nil))
        (emacs-jupyter-notebook-panel--retire-pickle (plist-get entry :mpl-pickle))
        (setq entry (plist-put entry :mpl-pickle nil))
        (setq entry (emacs-jupyter-notebook-panel--entry-reset-output-accounting
                     entry))
        (plist-put entry :pending-clear nil))
    entry))

(defun ejn-panel-append-text (handle text &optional face)
  "Append TEXT (optionally propertized with FACE) to HANDLE's entry.
W16: text and images now coexist as ordered segments — appending text
after a figure no longer erases the figure; it starts a new text segment
below it.  Consecutive text appends merge into the trailing text segment
so streaming output stays one block (and `\\r' progress repaints keep
collapsing within it).
When TEXT already carries `face' text-properties (e.g. from
`ansi-color-apply' on a Python traceback), FACE is composed via
`add-face-text-property' with append priority so per-character ANSI
colours are preserved and uncoloured spans still get the fallback FACE."
  (when (and handle text)
    (let* ((panel (plist-get handle :panel))
           (old-entry (ejn-panel-entry-snapshot handle))
           ;; Applying clear_output(wait=True) replaces the rendered entry,
           ;; even when it previously contained text only.
           (force-full (plist-get old-entry :pending-clear))
           (display-text (copy-sequence text)))
      (when face
        (add-face-text-property 0 (length display-text) face t display-text))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                      panel entry))
         (let* ((outputs (plist-get entry :outputs))
                (last-seg (car (last outputs)))
                (before (plist-get entry :output-text-bytes))
                (after (plist-get entry :output-text-bytes))
                (carriage-p (string-search "\r" display-text)))
           (if (and (not (plist-get entry :output-segments-truncated))
                    last-seg (eq (car last-seg) 'text)
                    ;; A display-id segment is replaceable independently of
                    ;; ordinary stream output; never merge later streams into it.
                    (not (and (emacs-jupyter-notebook-panel--text-state-p (cdr last-seg))
                              (plist-get (cdr last-seg) :display-id))))
               (if carriage-p
                   ;; Resolve only the bounded incoming frame.  Chunk metadata
                   ;; identifies the current terminal line, so a progress
                   ;; repaint never materializes megabytes of retained history.
                   (let* ((segment-before
                           (emacs-jupyter-notebook-panel--text-segment-bytes
                            last-seg))
                          (state (cdr last-seg))
                          (state
                           (if (emacs-jupyter-notebook-panel--text-state-p state)
                               state
                             (emacs-jupyter-notebook-panel--make-text-state state)))
                          (resolved
                           (emacs-jupyter-notebook--apply-carriage-returns
                            display-text)))
                     (when (emacs-jupyter-notebook-panel--carriage-rewrites-current-line-p
                            display-text)
                       (setq state
                             (emacs-jupyter-notebook-panel--text-state-drop-current-line
                              state)))
                     (setq state
                           (emacs-jupyter-notebook-panel--text-state-append
                            state resolved))
                     (setcdr last-seg state)
                     (setq after (+ (- before segment-before)
                                    (plist-get state :bytes)))
                     (setq force-full t))
                 (let ((state (cdr last-seg))
                       (segment-before
                        (emacs-jupyter-notebook-panel--text-segment-bytes
                         last-seg)))
                   (unless (emacs-jupyter-notebook-panel--text-state-p state)
                     (setq state (emacs-jupyter-notebook-panel--make-text-state state)))
                   (setq state
                         (emacs-jupyter-notebook-panel--text-state-append
                          state display-text))
                   (setcdr last-seg state)
                   (setq after (+ (- before segment-before)
                                  (plist-get state :bytes)))
                   (when (plist-get state :pending-overflow)
                     (setq force-full t))))
             (if (emacs-jupyter-notebook-panel--entry-output-room-p entry)
                 (let* ((resolved
                         (if carriage-p
                             (emacs-jupyter-notebook--apply-carriage-returns
                              display-text)
                           display-text))
                        (state
                         (emacs-jupyter-notebook-panel--make-text-state resolved)))
                   (setq outputs (nconc outputs (list (cons 'text state))))
                   (setq after (+ after (string-bytes resolved))))
               (unless (plist-get entry :output-segments-truncated)
                 (let ((marker emacs-jupyter-notebook-panel--segment-omission-text))
                   (setq outputs
                         (nconc outputs
                                (list
                                 (cons 'text
                                       (emacs-jupyter-notebook-panel--make-text-state
                                        marker)))))
                   (setq after (+ after (string-bytes marker)))
                   (setq entry (plist-put entry :output-segments-truncated t))
                   (setq force-full t)))))
           (setq entry (plist-put entry :outputs outputs))
           (setq entry (plist-put entry :output-text-bytes after))
           (setq entry (plist-put entry :retained-text-bytes
                                  (+ (string-bytes (or (plist-get entry :code) "")) after)))
           (when (> (plist-get entry :output-text-bytes)
                    (emacs-jupyter-notebook-panel--entry-text-budget))
             (setq entry (emacs-jupyter-notebook-panel--entry-trim-text entry))
             (setq force-full t))
           (setq entry (plist-put entry :pending-clear nil))
           (setq entry (plist-put entry :stream-dirty-p (not force-full)))
           entry))
       force-full)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

(defun emacs-jupyter-notebook-panel--segment-display-id (segment)
  "Return SEGMENT's display identity, or nil."
  (pcase (car-safe segment)
    ('text (and (emacs-jupyter-notebook-panel--text-state-p (cdr segment))
                (plist-get (cdr segment) :display-id)))
    ('array (plist-get (cdr segment) :display-id))
    ('image (plist-get (cdr (cdr segment)) :ejn-display-id))))

(defun emacs-jupyter-notebook-panel--display-target (panel display-id &optional kind)
  "Return `(HANDLE . SEGMENT)' for newest DISPLAY-ID in PANEL.
When KIND is non-nil, only a segment whose car is KIND can match."
  (when (and (buffer-live-p panel) (stringp display-id))
    (with-current-buffer panel
      (catch 'target
        (dolist (cell (reverse emacs-jupyter-notebook-panel--entries))
          (dolist (segment (reverse (plist-get (cdr cell) :outputs)))
            (when (and (or (null kind) (eq (car segment) kind))
                       (equal (emacs-jupyter-notebook-panel--segment-display-id segment)
                              display-id))
              (throw 'target
                     (cons (emacs-jupyter-notebook-panel--handle
                            panel (car cell) (plist-get (cdr cell) :cell-key))
                           segment)))))))))

(defun ejn-panel-set-display-text (handle text display-id)
  "Append TEXT as the independently replaceable DISPLAY-ID output segment."
  (when (and (ejn-panel-entry-live-p handle) (stringp text) (stringp display-id))
    (let ((panel (plist-get handle :panel))
          (text (copy-sequence text)))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear panel entry))
         (if (emacs-jupyter-notebook-panel--entry-output-room-p entry)
             (let ((outputs (plist-get entry :outputs)))
               (setq entry (plist-put entry :outputs
                                      (append outputs
                                              (list (cons 'text
                                                          (plist-put
                                                           (emacs-jupyter-notebook-panel--make-text-state text)
                                                           :display-id display-id))))))
               (setq entry (plist-put entry :output-text-bytes
                                      (+ (plist-get entry :output-text-bytes)
                                         (string-bytes text))))
               (setq entry (plist-put entry :retained-text-bytes
                                      (+ (string-bytes (or (plist-get entry :code) ""))
                                         (plist-get entry :output-text-bytes))))
               (plist-put entry :pending-clear nil))
           (emacs-jupyter-notebook-panel--entry-note-segment-omission entry)))
       t)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
      t)))

(defun ejn-panel-update-display-text (handle text display-id)
  "Replace the newest panel text output identified by DISPLAY-ID, or return nil."
  (when (and (ejn-panel-entry-live-p handle) (stringp text) (stringp display-id))
    (let* ((panel (plist-get handle :panel))
           (target (emacs-jupyter-notebook-panel--display-target
                    panel display-id 'text))
           (target-handle (car-safe target))
           (target-segment (cdr-safe target)))
      (when target-segment
        (let ((text (copy-sequence text)))
          (emacs-jupyter-notebook-panel--update-entry
           target-handle
           (lambda (entry)
             (let ((before (emacs-jupyter-notebook-panel--text-segment-bytes
                            target-segment)))
               (setcdr target-segment
                       (plist-put
                        (emacs-jupyter-notebook-panel--make-text-state text)
                        :display-id display-id))
               (setq entry (plist-put entry :output-text-bytes
                                      (+ (- (plist-get entry :output-text-bytes) before)
                                         (string-bytes text))))
               (setq entry (plist-put entry :retained-text-bytes
                                      (+ (string-bytes (or (plist-get entry :code) ""))
                                         (plist-get entry :output-text-bytes))))
               entry))
           t)
          (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
          t)))))

(defun ejn-panel-replace-text (handle text)
  "Replace ALL of HANDLE's entry output with TEXT.
W8.7(d): also drops any stashed matplotlib pickle, since text has
replaced whatever figure the entry previously showed."
  (when handle
    (let ((panel (plist-get handle :panel)))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (emacs-jupyter-notebook-panel--retire-outputs
          panel (plist-get entry :outputs))
         (setq entry (plist-put entry :outputs
                                (list (cons 'text
                                            (emacs-jupyter-notebook-panel--make-text-state
                                             (or text ""))))))
         (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                      entry))
         (emacs-jupyter-notebook-panel--retire-pickle (plist-get entry :mpl-pickle))
         (setq entry (plist-put entry :mpl-pickle nil))
         (setq entry (plist-put entry :output-text-bytes (string-bytes (or text ""))))
         (setq entry (plist-put entry :retained-text-bytes
                                (+ (string-bytes (or (plist-get entry :code) ""))
                                   (plist-get entry :output-text-bytes))))
         (setq entry (plist-put entry :artifact-bytes 0))
         (setq entry (plist-put entry :pending-clear nil))
         (setq entry (plist-put entry :output-segments-truncated nil))
         entry)
       t)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

(defun ejn-panel-set-image (handle image-spec)
  "Append IMAGE-SPEC as a new image segment on HANDLE's entry.
W16: no longer erases prior text — a cell that prints AND plots shows
both, in order, like a notebook.  Multiple figures in one execution each
get their own segment."
  (when (ejn-panel-entry-live-p handle)
    (let ((panel (plist-get handle :panel)))
      (when (ejn-panel-entry-live-p handle)
        (let ((stored (emacs-jupyter-notebook-panel--materialize-image
                       panel image-spec)))
          (emacs-jupyter-notebook-panel--update-entry
           handle
           (lambda (entry)
             (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                          panel entry))
             (if (emacs-jupyter-notebook-panel--entry-output-room-p entry)
                 (let ((outputs (plist-get entry :outputs)))
                   (setq entry (plist-put entry :outputs
                                          (append outputs
                                                  (list (cons 'image stored)))))
                   (setq entry (plist-put entry :artifact-bytes
                                          (+ (plist-get entry :artifact-bytes)
                                             (or (plist-get (cdr stored)
                                                            :ejn-artifact-bytes)
                                                 0))))
                   (setq entry (plist-put entry :pending-clear nil))
                   entry)
               (emacs-jupyter-notebook-panel--retire-image panel stored)
               (emacs-jupyter-notebook-panel--entry-note-segment-omission entry)))
           t)
          (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))))

(defun ejn-panel-update-image (handle image-spec &optional display-id)
  "Replace the newest matching panel image segment with IMAGE-SPEC.
Without DISPLAY-ID, append when the entry has no image yet.  With DISPLAY-ID,
an absent target is ignored.  W16: this is the
`update_display_data' semantic — the kernel is updating an existing
display in place (e.g. an animation frame), not adding a new output —
so text segments are left untouched and no new segment is created."
  (when (ejn-panel-entry-live-p handle)
    (let* ((panel (plist-get handle :panel))
           (target (and display-id
                        (emacs-jupyter-notebook-panel--display-target
                         panel display-id 'image)))
           (effective-handle (if target (car target) handle))
           (old-entry (and effective-handle
                           (ejn-panel-entry-snapshot effective-handle)))
           (old-image
            (and old-entry
                 (cdr (if display-id
                          (cl-find-if
                           (lambda (segment)
                             (and (eq (car segment) 'image)
                                  (equal
                                   (plist-get (cdr (cdr segment)) :ejn-display-id)
                                   display-id)))
                           (reverse (plist-get old-entry :outputs)))
                        (cl-find 'image (reverse (plist-get old-entry :outputs))
                                 :key #'car))))))
      (when (or (null display-id) target)
        (when (ejn-panel-entry-live-p effective-handle)
          (let ((stored (emacs-jupyter-notebook-panel--materialize-image
                         panel image-spec)))
            (emacs-jupyter-notebook-panel--update-entry
             effective-handle
             (lambda (entry)
               (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                            panel entry))
               (let* ((outputs (plist-get entry :outputs))
                      (last-image
                       (if display-id
                           (cl-find-if
                            (lambda (segment)
                              (and (eq (car segment) 'image)
                                   (equal (plist-get (cdr (cdr segment)) :ejn-display-id)
                                          display-id)))
                            (reverse outputs))
                         (cl-find 'image (reverse outputs) :key #'car)))
                      (old-image-bytes
                       (and last-image
                            (or (plist-get (cdr (cdr last-image))
                                           :ejn-artifact-bytes)
                                0))))
                 (cond
                  (last-image
                   (emacs-jupyter-notebook-panel--retire-image
                    panel (cdr last-image))
                   (setcdr last-image stored)
                   (setq entry (plist-put entry :outputs outputs))
                   (setq entry
                         (plist-put
                          entry :artifact-bytes
                          (+ (- (plist-get entry :artifact-bytes)
                                (or old-image-bytes 0))
                             (or (plist-get (cdr stored) :ejn-artifact-bytes) 0))))
                   (plist-put entry :pending-clear nil))
                  ((emacs-jupyter-notebook-panel--entry-output-room-p entry)
                   (setq outputs (append outputs (list (cons 'image stored))))
                   (setq entry (plist-put entry :outputs outputs))
                   (setq entry
                         (plist-put
                          entry :artifact-bytes
                          (+ (plist-get entry :artifact-bytes)
                             (or (plist-get (cdr stored) :ejn-artifact-bytes) 0))))
                   (plist-put entry :pending-clear nil))
                  (t
                   (emacs-jupyter-notebook-panel--retire-image panel stored)
                   (emacs-jupyter-notebook-panel--entry-note-segment-omission
                    entry)))))
             (lambda (_before after)
               (emacs-jupyter-notebook-panel--image-update-needs-full-p
                panel after old-image stored)))
            (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
            t))))))

(defun ejn-panel-finish-entry (handle status execution-count)
  "Mark HANDLE's entry as completed with STATUS and EXECUTION-COUNT."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (setq entry (emacs-jupyter-notebook-panel--entry-with-status
                    entry (or status 'ok)))
       (when execution-count
         (setq entry (plist-put entry :exec-count execution-count)))
       entry))
    (emacs-jupyter-notebook-panel--track-duration (plist-get handle :panel))))

(defun emacs-jupyter-notebook-panel--entry-with-status (entry status)
  "Set ENTRY's STATUS and record elapsed running time, excluding queue time."
  (pcase status
    ('queued
     (setq entry (plist-put entry :started-at nil)))
    ('running
     (unless (plist-get entry :started-at)
       (setq entry (plist-put entry :started-at (float-time)))))
    (_
     (unless (plist-get entry :finished-at)
       (let ((now (float-time)))
         (setq entry (plist-put entry :finished-at now))
         (when (plist-get entry :started-at)
           (setq entry (plist-put entry :duration
                                  (max 0 (- now (plist-get entry :started-at))))))))))
  (setq entry (plist-put entry :stream-dirty-p nil))
  (setq entry (plist-put entry :metadata-dirty-p t))
  (plist-put entry :status status))

(defun emacs-jupyter-notebook-panel--duration-tick (panel)
  "Refresh running durations in visible PANEL and retire an unused timer."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (setq emacs-jupyter-notebook-panel--duration-timer nil)
      (when (get-buffer-window panel t)
        ;; Duration updates must never restart a multi-megabyte body render.
        ;; A pending render already formats a fresh header when it reaches it.
        (unless (or emacs-jupyter-notebook-panel--dirty
                    emacs-jupyter-notebook-panel--sliced-render-job)
          (let ((inhibit-read-only t) (updated 0))
            (emacs-jupyter-notebook-panel--capture-navigation)
            (dolist (cell (reverse emacs-jupyter-notebook-panel--entries))
              (when (and (< updated 4)
                         (eq (plist-get (cdr cell) :status) 'running))
                (when-let ((bounds (emacs-jupyter-notebook-panel--entry-bounds (car cell))))
                  (emacs-jupyter-notebook-panel--replace-header (cdr cell) bounds)
                  (cl-incf updated))))
            (emacs-jupyter-notebook-panel--finish-navigation)))
        (emacs-jupyter-notebook-panel--track-duration panel)))))

(defun emacs-jupyter-notebook-panel--track-duration (panel)
  "Maintain one bounded-duration refresh timer while PANEL shows running work."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (if (and (get-buffer-window panel t)
               (cl-some (lambda (cell) (eq (plist-get (cdr cell) :status) 'running))
                        emacs-jupyter-notebook-panel--entries))
          (unless (timerp emacs-jupyter-notebook-panel--duration-timer)
            (setq emacs-jupyter-notebook-panel--duration-timer
                  (run-at-time 1 nil #'emacs-jupyter-notebook-panel--duration-tick panel)))
        (when (timerp emacs-jupyter-notebook-panel--duration-timer)
          (cancel-timer emacs-jupyter-notebook-panel--duration-timer))
        (setq emacs-jupyter-notebook-panel--duration-timer nil)))))

(defun ejn-panel-set-entry-status (handle status)
  "Set live HANDLE to nonterminal STATUS without fabricating an execution count.
Used by the serialized execution ledger to expose queued work before it is
actually dispatched to a kernel."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle (lambda (entry) (emacs-jupyter-notebook-panel--entry-with-status entry status)))
    (emacs-jupyter-notebook-panel--track-duration (plist-get handle :panel))))

(defun ejn-panel-clear-entry (handle &optional wait)
  "Clear HANDLE's entry content.
If WAIT is non-nil, defer the clear until the next text arrives
(matches Jupyter's clear_output :wait semantics)."
  (when handle
    (let ((panel (plist-get handle :panel)))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (if wait
             (plist-put entry :pending-clear t)
           (emacs-jupyter-notebook-panel--retire-outputs
            panel (plist-get entry :outputs))
           (setq entry (plist-put entry :outputs nil))
           ;; W8.7(d): clearing the entry drops the figure too.
           (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                        entry))
           (emacs-jupyter-notebook-panel--retire-pickle (plist-get entry :mpl-pickle))
           (setq entry (plist-put entry :mpl-pickle nil))
           (setq entry (emacs-jupyter-notebook-panel--entry-reset-output-accounting
                        entry))
           (setq entry (plist-put entry :pending-clear nil))
           entry))
       (not wait)))))

(defun emacs-jupyter-notebook-panel--prune-pickles (panel)
  "Drop the matplotlib pickle from all but the newest N entries in PANEL.
A5: `panel--entries' is append-only history and each `:mpl-pickle' owns a
potentially large artifact file.  Without bounding, an image-heavy session
(re-running an `imshow' cell many times) keeps every pickle reachable.  Only
the interactive artifact is dropped from older entries; their PNG thumbnail
and text are untouched.  A non-positive limit retains zero pickle artifacts."
  (let ((max (if (and (integerp emacs-jupyter-notebook-panel-max-pickles)
                      (> emacs-jupyter-notebook-panel-max-pickles 0))
                 emacs-jupyter-notebook-panel-max-pickles
               0)))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (let ((kept 0))
          ;; Newest entries are appended to the end; walk newest-first.
          (dolist (cell (reverse emacs-jupyter-notebook-panel--entries))
            (when (plist-get (cdr cell) :mpl-pickle)
              (if (< kept max)
                  (setq kept (1+ kept))
                (let ((entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                              (cdr cell))))
                  (let ((pickle (plist-get entry :mpl-pickle)))
                    (cl-decf emacs-jupyter-notebook-panel--retained-artifact-bytes
                             (or (plist-get pickle :size) 0))
                    (setq entry (plist-put entry :artifact-bytes
                                           (- (plist-get entry :artifact-bytes)
                                              (or (plist-get pickle :size) 0))))
                    (emacs-jupyter-notebook-panel--retire-pickle pickle)
                    (setcdr cell (plist-put entry :mpl-pickle nil))))))))))))

(defun ejn-panel-clear-pickle (handle)
  "Drop any stashed matplotlib pickle on HANDLE's entry (W8.7(d))."
  (when handle
    (let* ((panel (plist-get handle :panel))
           (old-entry (ejn-panel-entry-snapshot handle))
           (force-full (and (plist-get old-entry :pending-clear)
                            (cl-find 'image (plist-get old-entry :outputs)
                                     :key #'car))))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                      panel entry))
         (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                      entry))
         (let ((old-pickle (plist-get entry :mpl-pickle)))
           (setq entry (plist-put entry :artifact-bytes
                                  (- (plist-get entry :artifact-bytes)
                                     (or (plist-get old-pickle :size) 0))))
           (emacs-jupyter-notebook-panel--retire-pickle old-pickle)
           (plist-put entry :mpl-pickle nil)))
       force-full)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

(defun ejn-panel-entry-pickle (handle)
  "Return HANDLE's confined matplotlib pickle metadata, or nil."
  (plist-get (ejn-panel-entry-snapshot handle) :mpl-pickle))

(defun ejn-panel-entry-snapshot (handle)
  "Return the entry plist for HANDLE (debug/test introspection)."
  (and (ejn-panel-entry-live-p handle)
       (emacs-jupyter-notebook-panel--entry
        (plist-get handle :panel) (plist-get handle :id))))

;;; Cell key (W2.2 + W2.11)

;; Cell key is (FILE-NAME . STABLE-ID).  STABLE-ID is a small integer allocated
;; on first observation of a cell line and never reused.  The buffer-local
;; `--cell-key-markers' hash maps id → permanent-local marker pointing at the
;; cell line; the marker shifts naturally when text is inserted above, but the
;; id (and therefore the cell key) is stable across edits.  Looking up a cell
;; by its current point scans the hash for the marker whose CURRENT position
;; matches the line start at point.

(defvar-local emacs-jupyter-notebook--cell-key-markers nil
  "Hash table mapping integer cell id to a permanent-local marker.")

(defvar-local emacs-jupyter-notebook--cell-key-next-id 0
  "Next integer id to allocate for an observed cell line in this buffer.")

(defvar-local emacs-jupyter-notebook--cell-key-kinds nil
  "Hash table mapping cell IDs to `explicit' or `implicit' boundaries.")

(defvar-local emacs-jupyter-notebook--cell-deleted-ids nil
  "Cell IDs whose original boundary is removed by the current change.")

(defvar-local emacs-jupyter-notebook--cell-touched-ids nil
  "Alist of cells edited by the pending change and their boundary-insert flag.")

(defvar emacs-jupyter-notebook--cell-moving-p nil
  "Non-nil during an explicit cell move that transposes its markers intact.")

(defvar emacs-jupyter-notebook--fringe-overlays)

(defun emacs-jupyter-notebook--cell-key-retired-p (key &optional source)
  "Return non-nil if KEY was allocated and retired in SOURCE or this buffer.
Never reuse an allocated ID, even after mode disable.  The monotonic counter
and live marker table therefore reject late callbacks without tombstones."
  (when (buffer-live-p (or source (current-buffer)))
    (with-current-buffer (or source (current-buffer))
      (let* ((id (cdr-safe key))
             (marker (and emacs-jupyter-notebook--cell-key-markers
                          (gethash id emacs-jupyter-notebook--cell-key-markers))))
        (and (integerp id) (> id 0)
             (<= id emacs-jupyter-notebook--cell-key-next-id)
             (not (and (markerp marker)
                       (eq (marker-buffer marker) (current-buffer)))))))))

(defun emacs-jupyter-notebook--cell-retire-ids (ids)
  "Retire source cell IDS, their indicators, and all their panel entries.
Only local presentation state is released.  Pending executions may finish in
the kernel, but their handles and cell identities can no longer show output."
  (when ids
    (let ((retired (make-hash-table :test 'eql))
          (panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
      (dolist (id ids)
        (puthash id t retired)
        (when-let ((marker (and emacs-jupyter-notebook--cell-key-markers
                               (gethash id emacs-jupyter-notebook--cell-key-markers))))
          (set-marker marker nil)
          (remhash id emacs-jupyter-notebook--cell-key-markers))
        (when emacs-jupyter-notebook--cell-key-kinds
          (remhash id emacs-jupyter-notebook--cell-key-kinds)))
      (setq emacs-jupyter-notebook--fringe-overlays
            (cl-delete-if
             (lambda (cell)
               (when (gethash (cdr (car cell)) retired)
                 (delete-overlay (cdr cell))
                 t))
             emacs-jupyter-notebook--fringe-overlays))
      (when panel
        (with-current-buffer panel
          ;; Invalidate the sliced renderer before it can publish a snapshot
          ;; containing retired entries.  Use the existing retirement path so
          ;; artifact leases, timers, and byte/segment accounting stay exact.
          (emacs-jupyter-notebook-panel--invalidate-structure panel)
          (dolist (cell (copy-sequence emacs-jupyter-notebook-panel--entries))
            (when (gethash (cdr (plist-get (cdr cell) :cell-key)) retired)
              (emacs-jupyter-notebook-panel--retire-entry panel cell)))
          (when emacs-jupyter-notebook-panel--hidden-cells
            (let (keys)
              (maphash (lambda (key _hidden)
                         (when (gethash (cdr key) retired) (push key keys)))
                       emacs-jupyter-notebook-panel--hidden-cells)
              (dolist (key keys)
                (remhash key emacs-jupyter-notebook-panel--hidden-cells)))))))))

(defun emacs-jupyter-notebook--cell-before-change (beg end)
  "Remember boundaries wholly removed by the source change at BEG..END.
Markers alone cannot detect deletion: Emacs collapses a removed marker onto
the next cell, which would incorrectly inherit the removed cell's identity."
  (setq emacs-jupyter-notebook--cell-deleted-ids nil)
  (setq emacs-jupyter-notebook--cell-touched-ids nil)
  (when (and (not emacs-jupyter-notebook--cell-moving-p)
             emacs-jupyter-notebook--cell-key-markers
             ;; Edited-since-run labels are optional presentation metadata.
             ;; Do not scan a huge cell on every keystroke to update them.
             ;; The deletion/identity checks below always remain active.
             (<= (buffer-size) emacs-jupyter-notebook-cell--automatic-scan-limit)
             (emacs-jupyter-notebook-panel-buffer (current-buffer)))
    (save-restriction
      (widen)
      (save-excursion
        (save-match-data
          (goto-char beg)
          (let ((first (car (emacs-jupyter-notebook-cell-full-bounds))))
            (goto-char (if (> end beg) (1- end) end))
            (let ((last (car (emacs-jupyter-notebook-cell-full-bounds))))
              (maphash
               (lambda (id marker)
                 (when (and (eq (marker-buffer marker) (current-buffer))
                            (<= first (marker-position marker) last))
                   (push (cons id (and (= beg end (marker-position marker))
                                       (eq (gethash id emacs-jupyter-notebook--cell-key-kinds)
                                           'explicit)))
                         emacs-jupyter-notebook--cell-touched-ids)))
               emacs-jupyter-notebook--cell-key-markers)))))))
  (when (and (not emacs-jupyter-notebook--cell-moving-p)
             (< beg end) emacs-jupyter-notebook--cell-key-markers)
    (save-restriction
      (widen)
      (save-excursion
        (save-match-data
          (maphash
           (lambda (id marker)
             (when (eq (marker-buffer marker) (current-buffer))
               (goto-char marker)
               (let* ((start (point))
                      (kind (gethash id emacs-jupyter-notebook--cell-key-kinds))
                      (boundary-end
                       (when (<= beg start end)
                         (if (eq kind 'explicit)
                             (and (looking-at code-cells-boundary-regexp)
                                  (match-end 0))
                           ;; Search only the actual deletion.  A body edit
                           ;; must not scan the whole implicit leading cell.
                           (or (and (re-search-forward code-cells-boundary-regexp end t)
                                    (match-beginning 0))
                               (save-excursion
                                 (goto-char end)
                                 (beginning-of-line)
                                 (and (looking-at-p code-cells-boundary-regexp)
                                      (point)))
                               (and (= end (point-max)) end))))))
                 (when (and boundary-end (<= beg start) (>= end boundary-end))
                   (push id emacs-jupyter-notebook--cell-deleted-ids)))))
           emacs-jupyter-notebook--cell-key-markers))))))

(defun emacs-jupyter-notebook--cell-after-change (&optional beg _end _old-length)
  "Retire deleted or invalid boundaries after a source edit.
Normalize surviving anchors, preserving IDs when text is inserted above.
An explicit boundary merged into the preceding line is no longer a cell.
Ambiguous duplicate anchors are retired together instead of reassociated."
  (when emacs-jupyter-notebook--cell-key-markers
    (emacs-jupyter-notebook--cell-retire-ids
     (prog1 emacs-jupyter-notebook--cell-deleted-ids
       (setq emacs-jupyter-notebook--cell-deleted-ids nil)))
    (let ((positions (make-hash-table :test 'eql))
          invalid)
      (save-restriction
        (widen)
        (save-excursion
          (save-match-data
            (maphash
             (lambda (id marker)
               (let ((anchor (and (eq (marker-buffer marker) (current-buffer))
                                  (marker-position marker)))
                     position)
                 (when anchor
                   (goto-char anchor)
                   (if (eq (gethash id emacs-jupyter-notebook--cell-key-kinds) 'explicit)
                       (progn
                         (beginning-of-line)
                         (when (and (looking-at code-cells-boundary-regexp)
                                    (< anchor (match-end 0)))
                           (setq position (point))))
                     (goto-char (point-min))
                     (unless (or (looking-at-p code-cells-boundary-regexp)
                                 (re-search-forward code-cells-boundary-regexp anchor t))
                       (setq position (point-min)))))
                 (if position
                     (progn
                       (set-marker marker position)
                       (puthash position (cons id (gethash position positions)) positions))
                   (push id invalid))))
             emacs-jupyter-notebook--cell-key-markers))))
      (maphash (lambda (_position ids)
                 (when (cdr ids) (setq invalid (append ids invalid))))
               positions)
      (emacs-jupyter-notebook--cell-retire-ids invalid))
    (when-let ((panel (and emacs-jupyter-notebook--cell-touched-ids
                          (emacs-jupyter-notebook-panel-buffer (current-buffer)))))
      (let ((edited (make-hash-table :test 'eql)))
        (dolist (touched emacs-jupyter-notebook--cell-touched-ids)
          (when-let ((marker (gethash (car touched) emacs-jupyter-notebook--cell-key-markers)))
            ;; Inserting complete lines before an existing explicit marker
            ;; shifts its identity but does not change that cell's source.
            (unless (and (cdr touched) beg (> (marker-position marker) beg))
              (puthash (car touched) t edited))))
        (with-current-buffer panel
          (dolist (cell emacs-jupyter-notebook-panel--entries)
            (when (gethash (cdr (plist-get (cdr cell) :cell-key)) edited)
              (setcdr cell (plist-put (cdr cell) :edited-since-run t))
              (setcdr cell (plist-put (cdr cell) :metadata-dirty-p t))
              (setcdr cell (plist-put (cdr cell) :stream-dirty-p nil))
              (emacs-jupyter-notebook-panel--schedule-render panel (car cell)))))))
    (setq emacs-jupyter-notebook--cell-touched-ids nil)))

(defun emacs-jupyter-notebook-cell-tracking-enable ()
  "Track source-cell deletion using buffer-local change hooks."
  (add-hook 'before-change-functions #'emacs-jupyter-notebook--cell-before-change nil t)
  (add-hook 'after-change-functions #'emacs-jupyter-notebook--cell-after-change nil t)
  (add-hook 'post-command-hook #'emacs-jupyter-notebook-panel--source-post-command nil t))

(defun emacs-jupyter-notebook-cell-tracking-disable ()
  "Remove cell tracking and retire its disposable output identities."
  (remove-hook 'before-change-functions #'emacs-jupyter-notebook--cell-before-change t)
  (remove-hook 'after-change-functions #'emacs-jupyter-notebook--cell-after-change t)
  (remove-hook 'post-command-hook #'emacs-jupyter-notebook-panel--source-post-command t)
  (setq emacs-jupyter-notebook--cell-deleted-ids nil
        emacs-jupyter-notebook--cell-touched-ids nil
        emacs-jupyter-notebook-panel--last-source-cell nil)
  (when emacs-jupyter-notebook--cell-key-markers
    (emacs-jupyter-notebook--cell-retire-ids
     (hash-table-keys emacs-jupyter-notebook--cell-key-markers))))

(defun emacs-jupyter-notebook--cell-key-for (position &optional no-create)
  "Return a cell key for the cell whose marker line begins at POSITION.
The returned key is `(FILE-NAME . ID)' where ID is stable across edits to
this buffer: re-evaluating the same cell after inserting or deleting text
above it yields an `equal' key.  With NO-CREATE return nil for an unobserved
cell without allocating its marker or identity."
  (unless (or no-create emacs-jupyter-notebook--cell-key-markers)
    (setq emacs-jupyter-notebook--cell-key-markers
          (make-hash-table :test 'eq)))
  (unless (or no-create emacs-jupyter-notebook--cell-key-kinds)
    (setq emacs-jupyter-notebook--cell-key-kinds (make-hash-table :test 'eql)))
  (let* ((file (or (buffer-file-name) (buffer-name)))
         (line-start (save-excursion
                       (goto-char (max (point-min)
                                       (min (point-max) position)))
                       (line-beginning-position)))
         (existing-id nil))
    (when emacs-jupyter-notebook--cell-key-markers
      (maphash (lambda (id marker)
                 (when (and (null existing-id)
                            (markerp marker)
                            (eq (marker-buffer marker) (current-buffer))
                            (= (marker-position marker) line-start))
                   (setq existing-id id)))
               emacs-jupyter-notebook--cell-key-markers))
    (unless (or no-create existing-id)
      (setq existing-id (cl-incf emacs-jupyter-notebook--cell-key-next-id))
      (let ((m (copy-marker line-start t)))
        (set-marker-insertion-type m t)
        (puthash existing-id m emacs-jupyter-notebook--cell-key-markers)
        (puthash existing-id
                 (save-excursion
                   (goto-char line-start)
                   (if (looking-at-p code-cells-boundary-regexp) 'explicit 'implicit))
                 emacs-jupyter-notebook--cell-key-kinds)))
    (when existing-id (cons file existing-id))))

;;; View toggle / navigation (W2.3, W2.6)

(defun emacs-jupyter-notebook-panel--restore-entry-point ()
  "Return point to the toggled entry after rebuilding this panel's layout."
  (when emacs-jupyter-notebook-panel--restore-entry-id
    (when-let ((bounds (emacs-jupyter-notebook-panel--entry-bounds
                       emacs-jupyter-notebook-panel--restore-entry-id)))
      (goto-char (car bounds)))
    (setq emacs-jupyter-notebook-panel--restore-entry-id nil)))

(defun emacs-jupyter-notebook-toggle-cell-output ()
  "Hide or show output for the source cell or panel entry at point.
Cell output visibility is shared by its entries in latest and history views.
Region evaluations in history can be toggled individually.  Hidden output
continues to be retained and updated; only the header remains visible."
  (interactive)
  (let* ((in-panel (derived-mode-p 'emacs-jupyter-notebook-panel-mode))
         (panel (if in-panel (current-buffer)
                  (emacs-jupyter-notebook-panel-buffer (current-buffer))))
         (id (and in-panel (emacs-jupyter-notebook-panel--entry-id-at-point)))
         (key (unless in-panel
                (emacs-jupyter-notebook--cell-key-for
                 (car (emacs-jupyter-notebook-cell-full-bounds))))))
    (unless panel (user-error "This cell has no output"))
    (with-current-buffer panel
      (let* ((entry (if in-panel
                        (emacs-jupyter-notebook-panel--entry panel id)
                      (cdr (cl-find-if
                            (lambda (cell) (equal key (plist-get (cdr cell) :cell-key)))
                            (reverse emacs-jupyter-notebook-panel--entries)))))
             (key (if in-panel (plist-get entry :cell-key) key))
             (hidden (not (plist-get entry :hidden))))
        (unless entry (user-error "No output entry at point"))
        (when in-panel
          (setq emacs-jupyter-notebook-panel--restore-entry-id id))
        (when key
          (unless emacs-jupyter-notebook-panel--hidden-cells
            (setq emacs-jupyter-notebook-panel--hidden-cells
                  (make-hash-table :test 'equal)))
          (if hidden (puthash key t emacs-jupyter-notebook-panel--hidden-cells)
            (remhash key emacs-jupyter-notebook-panel--hidden-cells)))
        (dolist (cell emacs-jupyter-notebook-panel--entries)
          (when (if key (equal key (plist-get (cdr cell) :cell-key))
                  (eq (car cell) id))
            (setcdr cell (plist-put (cdr cell) :hidden hidden))))
        ;; Hiding can demote images and free another entry's preview slot.
        ;; Cancel any in-progress sliced render and recompute admission.
        (emacs-jupyter-notebook-panel--invalidate-structure panel)
        (message "Cell outputs %s" (if hidden "hidden" "shown"))))))

(defun emacs-jupyter-notebook-panel-toggle-view ()
  "Toggle the panel between latest-per-cell and history-log views."
  (interactive)
  (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (user-error "Not in an EJN output panel"))
  (setq emacs-jupyter-notebook-panel--view
        (if (eq emacs-jupyter-notebook-panel--view 'history) 'latest 'history))
  ;; A pending content update may name an entry that is absent from one view
  ;; or leave other entries unrendered in the newly selected view.
  (emacs-jupyter-notebook-panel--invalidate-structure (current-buffer))
  (message "EJN panel view: %s" emacs-jupyter-notebook-panel--view))

(defun emacs-jupyter-notebook-panel-quit ()
  "Bury the panel window."
  (interactive)
  (quit-window))

(defun emacs-jupyter-notebook-panel--header-positions ()
  "Return a list of buffer positions where entry headers begin."
  (let (positions
        (pos (point-min)))
    (save-excursion
      (while pos
        (when (get-text-property pos 'emacs-jupyter-notebook-entry-id)
          (push pos positions))
        (setq pos (next-single-property-change
                   pos 'emacs-jupyter-notebook-entry-id))))
    (nreverse positions)))

(defun emacs-jupyter-notebook-panel-next-entry ()
  "Move point to the next entry header in the panel."
  (interactive)
  (let* ((positions (emacs-jupyter-notebook-panel--header-positions))
         (after (cl-find-if (lambda (p) (> p (point))) positions)))
    (when after
      (goto-char after))))

(defun emacs-jupyter-notebook-panel-previous-entry ()
  "Move point to the previous entry header in the panel."
  (interactive)
  (let* ((positions (emacs-jupyter-notebook-panel--header-positions))
         (before (cl-find-if (lambda (p) (< p (point))) (reverse positions))))
    (when before
      (goto-char before))))

(defun emacs-jupyter-notebook-panel--scale-image-at-point (factor)
  "Scale the image of the panel entry at point by FACTOR (multiplicative).

W16: rebuilding the spec (rather than mutating the displayed one) is the
only reliable way to rescale.  Two defects made the zoom keys look dead:
- Entry images are created with `:max-width'/`:max-height', which CLAMP the
  rendered size — a growing `:scale' on a clamped image changes nothing.
  The rebuilt spec drops both keys: once the user zooms, their explicit
  intent overrides the default bounding box.
- Emacs caches rendered images per spec; in-place property mutation is not
  reliably picked up.  The rebuilt spec (a fresh object, plus
  `image-flush' on the old one) always re-renders.
The new spec is stored back on the ENTRY so the zoom level survives
subsequent panel re-renders.  The selected display property is refreshed in
place; the normal throttled renderer updates remaining image rows later.
Also coerces a non-numeric `:scale' (Emacs 29+ reports the symbol
`default' for unset) to 1.0 before multiplying."
  (let* ((id (emacs-jupyter-notebook-panel--entry-id-at-point))
         (entry (and id (emacs-jupyter-notebook-panel--entry (current-buffer) id)))
         (outputs (and entry (plist-get entry :outputs)))
         ;; W16: pick the image segment under point (each rendered image
         ;; carries its segment index); fall back to the entry's first image.
         (seg-index (or (get-text-property (point) 'emacs-jupyter-notebook-segment-index)
                        (cl-position 'image outputs :key #'car)))
         (seg (and seg-index (nth seg-index outputs)))
         (image (and seg (eq (car seg) 'image) (cdr seg))))
    (when (and image (consp image) (eq (car image) 'image))
      (unless (emacs-jupyter-notebook-panel--native-image-safe-p image)
        (user-error "Image is retained for external viewing only"))
      (let* ((raw (plist-get (cdr image) :scale))
             (scale (if (numberp raw) raw 1.0))
             (new-scale (emacs-jupyter-notebook-panel--bounded-image-scale
                         image (* scale factor)))
             (props (cl-loop for (k v) on (cdr image) by #'cddr
                             unless (memq k '(:scale :max-width :max-height))
                             collect k and collect v))
             (new-image (cons 'image (append props (list :scale new-scale)))))
        (when-let ((preview (emacs-jupyter-notebook-panel--native-preview-spec image)))
          (ignore-errors (image-flush preview)))
        ;; Mutate the segment in place; the entry list structure is shared
        ;; with the stored entry, so the new spec persists across renders.
        (setcdr seg new-image)
        (let ((panel (current-buffer))
              (pos (point))
              (inhibit-read-only t))
          ;; Do the visible selected image immediately, but never synchronously
          ;; rebuild a whole capped panel merely to zoom one figure.  A sliced
          ;; image may have several rows; the scheduled pass restores every
          ;; row from the durable segment spec without blocking this command.
          (when (get-text-property pos 'display)
            (put-text-property
             pos (next-single-property-change pos 'display nil (point-max))
             'display
             (or (emacs-jupyter-notebook-panel--native-preview-spec new-image)
                 new-image)))
          (emacs-jupyter-notebook-panel--schedule-render panel id nil))))))

(defun emacs-jupyter-notebook-panel-image-zoom-in ()
  "Zoom in the image at point in the panel."
  (interactive)
  (emacs-jupyter-notebook-panel--scale-image-at-point 1.2))

(defun emacs-jupyter-notebook-panel-image-zoom-out ()
  "Zoom out the image at point in the panel."
  (interactive)
  (emacs-jupyter-notebook-panel--scale-image-at-point (/ 1.0 1.2)))

(defun emacs-jupyter-notebook-panel-visit-source ()
  "Visit the source cell associated with the entry at point."
  (interactive)
  (let* ((id (emacs-jupyter-notebook-panel--entry-id-at-point))
         (entry (and id (emacs-jupyter-notebook-panel--entry (current-buffer) id)))
         (key (plist-get entry :cell-key))
         (source emacs-jupyter-notebook-panel--source-buffer))
    (unless id
      (user-error "Point is not on an entry"))
    (unless (and key (buffer-live-p source))
      (user-error "Entry has no source cell"))
    (let ((id (cdr key)))
      (pop-to-buffer source)
      (let* ((marker (and (integerp id)
                          emacs-jupyter-notebook--cell-key-markers
                          (gethash id emacs-jupyter-notebook--cell-key-markers)))
             (target (cond
                      ((and (markerp marker)
                            (eq (marker-buffer marker) (current-buffer)))
                       (marker-position marker))
                      ((integerp id) id)
                      (t nil))))
        (when target
          (goto-char (max (point-min)
                          (min (point-max) target))))))))

;;; Fringe indicator (W2.8)

;; Implementation choice: zero-width overlay anchored at the cell line's
;; beginning, carrying a `before-string' whose `display' property places the
;; glyph either in a fringe (the default) or a margin.  The overlay text is
;; a single space whose `display' property carries the actual content, so
;; nothing the user types or deletes around the cell line can move, edit, or
;; delete the indicator.  No `cursor-intangible' or `read-only' property is
;; placed adjacent to user text.  This passes the
;; "user-edits-do-not-interfere" test and avoids the wrap/jump-into-overlay
;; class of bugs that historically plagued inline result overlays.

(defvar-local emacs-jupyter-notebook--fringe-overlays nil
  "Alist of (CELL-KEY . OVERLAY) for source-buffer fringe indicators.")

(defun emacs-jupyter-notebook--fringe-glyph (state exec-count)
  "Return the indicator glyph string for STATE and EXEC-COUNT."
  (let* ((digit (cond
                 ((and (numberp exec-count) (>= exec-count 10))
                  (number-to-string (mod exec-count 10)))
                 ((numberp exec-count) (number-to-string exec-count))
                 (t ""))))
    (pcase state
      ('running "►")
      ('ok (concat "✓" digit))
      ('error "✗")
      ('cancelled "!")
      ('outcome-unknown "?")
      ('queued "…")
      (_ ""))))

(defun emacs-jupyter-notebook--fringe-face (state)
  "Return the face symbol for indicator STATE."
  (pcase state
    ('running 'emacs-jupyter-notebook-fringe-running-face)
    ('ok 'emacs-jupyter-notebook-fringe-ok-face)
    ('error 'emacs-jupyter-notebook-fringe-error-face)
    ((or 'cancelled 'outcome-unknown) 'emacs-jupyter-notebook-fringe-error-face)
    ('queued 'emacs-jupyter-notebook-fringe-queued-face)
    (_ 'default)))

(defun emacs-jupyter-notebook-fringe-set (cell-key state &optional exec-count)
  "Set the source-buffer fringe indicator for CELL-KEY to STATE.
EXEC-COUNT is the execution count (used by the `ok' state).
The cell key id is resolved against the buffer-local marker table so the
indicator follows the cell even after edits above it.  If no marker is
registered for the id and the cdr is a plain integer, that integer is
treated as a literal buffer position (test convenience)."
  (when (and cell-key (buffer-live-p (current-buffer))
             (not (emacs-jupyter-notebook--cell-key-retired-p cell-key)))
    (let* ((id (cdr cell-key))
           (existing (cdr (assoc cell-key
                                 emacs-jupyter-notebook--fringe-overlays)))
           (marker (and (integerp id)
                        emacs-jupyter-notebook--cell-key-markers
                        (gethash id emacs-jupyter-notebook--cell-key-markers)))
           (anchor-pos (cond
                        ((and (markerp marker)
                              (eq (marker-buffer marker) (current-buffer)))
                         (marker-position marker))
                        ((integerp id) id)
                        (t nil)))
           (line-pos (when anchor-pos
                       (save-excursion
                         (goto-char (max (point-min)
                                         (min (point-max) anchor-pos)))
                         (line-beginning-position))))
           (ov (or (and (overlayp existing) (overlay-buffer existing) existing)
                   (and line-pos
                        (make-overlay line-pos line-pos
                                      (current-buffer) t nil))))
           (glyph (emacs-jupyter-notebook--fringe-glyph state exec-count))
           (face (emacs-jupyter-notebook--fringe-face state))
           (side (emacs-jupyter-notebook--fringe-margin-side
                  emacs-jupyter-notebook-fringe-side)))
      (when ov
        (emacs-jupyter-notebook--fringe-ensure-margin-width side)
        (overlay-put ov 'emacs-jupyter-notebook-fringe t)
        (overlay-put ov 'emacs-jupyter-notebook-cell-key cell-key)
        (overlay-put ov 'emacs-jupyter-notebook-state state)
        (overlay-put ov 'emacs-jupyter-notebook-exec-count exec-count)
        ;; Emacs `display' margin syntax: `((margin SIDE) STRING)'.  The
        ;; outer overlay carries this on a 1-char `before-string' so the
        ;; glyph renders in the chosen margin without inserting source text.
        (overlay-put
         ov 'before-string
         (propertize " "
                     'display `((margin ,side)
                                ,(propertize glyph 'face face))))
        (setf (alist-get cell-key emacs-jupyter-notebook--fringe-overlays
                         nil nil #'equal)
              ov)
        ov))))

(defun emacs-jupyter-notebook--fringe-margin-side (side)
  "Map SIDE (any of the customization options) to a valid margin symbol.
The fringe values silently fall back to `left-margin'."
  (cond
   ((memq side '(left-margin right-margin)) side)
   (t 'left-margin)))

(defun emacs-jupyter-notebook--fringe-ensure-margin-width (side)
  "Ensure SIDE's margin in the current buffer is wide enough to render."
  (let ((var (if (eq side 'right-margin) 'right-margin-width 'left-margin-width)))
    (when (< (or (symbol-value var) 0)
             emacs-jupyter-notebook-fringe-margin-width)
      (set (make-local-variable var)
           emacs-jupyter-notebook-fringe-margin-width)
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (set-window-buffer window (current-buffer))))))

(defun emacs-jupyter-notebook-fringe-clear-all ()
  "Remove all fringe indicator overlays from the current buffer."
  (dolist (cell emacs-jupyter-notebook--fringe-overlays)
    (when (overlayp (cdr cell))
      (delete-overlay (cdr cell))))
  (setq emacs-jupyter-notebook--fringe-overlays nil))

(defun emacs-jupyter-notebook-fringe-state (cell-key)
  "Return the recorded state symbol for CELL-KEY, or nil."
  (let ((ov (cdr (assoc cell-key
                        emacs-jupyter-notebook--fringe-overlays))))
    (and (overlayp ov) (overlay-get ov 'emacs-jupyter-notebook-state))))

(defun emacs-jupyter-notebook-fringe-overlay (cell-key)
  "Return the fringe overlay for CELL-KEY, or nil."
  (cdr (assoc cell-key emacs-jupyter-notebook--fringe-overlays)))

;;; External/static and interactive figure open (W18/W8.5)

(declare-function emacs-jupyter-notebook-open-figure-pickle-lease
                  "emacs-jupyter-notebook" (pickle))

(defun emacs-jupyter-notebook-panel--entry-id-at-point ()
  "Return the id of the panel entry whose SECTION contains point.
The `entry-id' text property lives on the header line only, so a point on
the image or content below the header carries none.  Fall back to the
nearest header at or before point, so `v' / RET / navigation work anywhere
inside an entry's section — not only when point sits on the header line."
  (or (get-text-property (point) 'emacs-jupyter-notebook-entry-id)
      (let* ((positions (emacs-jupyter-notebook-panel--header-positions))
             (header (cl-find-if (lambda (p) (<= p (point)))
                                 (reverse positions))))
        (and header
             (get-text-property header 'emacs-jupyter-notebook-entry-id)))))

(defun emacs-jupyter-notebook-panel--image-at-point ()
  "Return the stored image spec for the panel image at point, or nil.
The segment-index property identifies both inline previews and lightweight
placeholders.  On an entry header, fall back to its first image segment."
  (let* ((id (emacs-jupyter-notebook-panel--entry-id-at-point))
         (entry (and id
                     (emacs-jupyter-notebook-panel--entry
                      (current-buffer) id)))
         (outputs (and entry (plist-get entry :outputs)))
         (index (get-text-property
                 (point) 'emacs-jupyter-notebook-segment-index))
         (segment (and (integerp index) (nth index outputs))))
    (cond
     ((and segment (eq (car segment) 'image)) (cdr segment))
     (t (cdr (cl-find 'image outputs :key #'car))))))

(declare-function w32-shell-execute "w32fns.c"
                  (operation document &optional parameters show-flag))

(defconst emacs-jupyter-notebook-panel--external-opener-timeout 30
  "Immutable maximum lifetime in seconds for one external opener child.
Platform launchers such as `xdg-open' and `open' normally exit immediately.
Keeping a direct configured viewer child indefinitely is a local process leak,
so this hard watchdog always owns only that exact child process.")

(defun emacs-jupyter-notebook-panel--spawn-external-opener (command file)
  "Start COMMAND asynchronously with FILE appended to its argv.
The returned child has an identity-bound watchdog.  Either its sentinel or the
watchdog disposes the process exactly once; a timer from an older invocation
cannot affect a later viewer process or its independently retained snapshot."
  (let ((program (car command)))
    (unless (and program
                 (or (and (file-name-absolute-p program)
                          (file-executable-p program))
                     (executable-find program)))
      (user-error
       "No external image opener found; customize `%s'"
       'emacs-jupyter-notebook-external-image-viewer-command))
    (let (process watchdog settled)
      (let ((token (list 'ejn-image-viewer)))
        (cl-labels
            ((settle (kill)
               (when (and (processp process)
                          (eq (process-get process
                                           'emacs-jupyter-notebook-panel--external-opener-token)
                              token)
                          (not settled))
                 ;; Mark settled before `delete-process': its sentinel may be
                 ;; invoked synchronously, and must not perform a second
                 ;; delete or cancel a watchdog belonging to another opener.
                 (setq settled t)
                 (when (timerp watchdog) (cancel-timer watchdog))
                 (process-put process
                              'emacs-jupyter-notebook-panel--external-opener-watchdog
                              nil)
                 (when (or kill (not (process-live-p process)))
                   (delete-process process)))))
          (setq process
                (make-process
                 :name (generate-new-buffer-name "ejn-image-viewer")
                 :buffer nil
                 :command (append command (list file))
                 :connection-type 'pipe
                 :noquery t
                 :sentinel (lambda (current _event)
                             (when (and (eq current process)
                                        (not (process-live-p current)))
                               (settle nil)))))
          (process-put process
                       'emacs-jupyter-notebook-panel--external-opener-token token)
          (condition-case err
              (setq watchdog
                    (run-at-time
                     emacs-jupyter-notebook-panel--external-opener-timeout nil
                     (lambda () (settle t))))
            ;; A failure to arm the watchdog must not leave this exact
            ;; configured opener child running without a deadline.
            (error
             (settle t)
             (signal (car err) (cdr err))))
          (cond
           ;; A very short-lived child may have reached its sentinel between
           ;; token attachment and timer setup.  Do not leave a no-op timer
           ;; retaining its closure until the hard deadline.
           (settled
            (cancel-timer watchdog))
           (t
            (process-put process
                         'emacs-jupyter-notebook-panel--external-opener-watchdog
                         watchdog)
            ;; A sentinel cannot claim an exit before the token is attached.
            ;; Recheck after both private properties exist and settle now if
            ;; the child died in that small setup window.
            (unless (process-live-p process)
              (settle nil))))
          process)))))

(defun emacs-jupyter-notebook-panel--external-open-default (file)
  "Open FILE asynchronously using the configured or platform image opener."
  (cond
   (emacs-jupyter-notebook-external-image-viewer-command
    (emacs-jupyter-notebook-panel--spawn-external-opener
     emacs-jupyter-notebook-external-image-viewer-command file))
   ((eq system-type 'windows-nt)
    (w32-shell-execute "open" file))
   (t
    (let ((command (cond
                    ((eq system-type 'darwin) '("open"))
                    ((memq system-type '(gnu gnu/linux gnu/kfreebsd
                                             berkeley-unix))
                     '("xdg-open"))
                    (t nil))))
      (emacs-jupyter-notebook-panel--spawn-external-opener command file)))))

(defvar emacs-jupyter-notebook-panel-external-open-function
  #'emacs-jupyter-notebook-panel--external-open-default
  "Function called with an image file path to open it externally.")

(defvar emacs-jupyter-notebook-panel--external-image-snapshots nil
  "Verified external-viewer snapshots retained until their handoff deadline.")

(defvar emacs-jupyter-notebook-panel--external-image-pending-count 0
  "Number of image snapshot verifier jobs currently in flight.")

(defvar emacs-jupyter-notebook-panel--external-image-pending-cancels nil
  "Cancellation functions for image snapshot verifier jobs in flight.")

(defun emacs-jupyter-notebook-panel--original-for-external-open (image)
  "Return IMAGE's identity-pinned original for asynchronous verification."
  (let* ((props (cdr image))
         (original (plist-get props :ejn-original)))
    (unless (listp original)
      (error "Image original is unavailable"))
    (emacs-jupyter-notebook-panel--published-artifact-metadata
     (plist-get original :root) (plist-get original :file)
     (plist-get original :sha256) (plist-get original :size)
     (plist-get original :root-identity)
     emacs-jupyter-notebook-panel--max-published-original-bytes
     nil nil nil (plist-get original :artifact-capability))
    original))

(defun emacs-jupyter-notebook-panel--artifact-verifier-script ()
  "Return the bundled asynchronous artifact verifier path, or nil."
  (let* ((base (or emacs-jupyter-notebook-result--load-file
                   (locate-library "emacs-jupyter-notebook-result")))
         (dirs
          (when base
            (let ((source (concat (file-name-sans-extension base) ".el")))
              (delq nil
                    (list (file-name-directory base)
                          (file-name-directory (file-truename base))
                          (and (file-exists-p source)
                               (file-name-directory (file-truename source)))))))))
    (cl-loop for directory in (delete-dups dirs)
             for script = (expand-file-name
                           "helper/ejn_helper/artifact_verify.py" directory)
             when (file-regular-p script) return script)))

(defun emacs-jupyter-notebook-panel--identity-parts (identity)
  "Return numeric device/inode parts from Emacs file IDENTITY."
  (let ((inode (car-safe identity))
        (device (cond
                 ((and (consp identity) (consp (cdr identity))
                       (null (cddr identity)))
                  (cadr identity))
                 ((and (consp identity) (integerp (cdr identity)))
                  (cdr identity)))))
    (unless (and (integerp device) (integerp inode)
                 (>= device 0) (>= inode 0))
      (error "Invalid artifact identity"))
    (list device inode)))

(defconst emacs-jupyter-notebook-panel--original-verify-timeout 10
  "Maximum seconds allowed for one local original-file verification.")

(defun emacs-jupyter-notebook-panel--original-verification-exit-reason (status)
  "Return the bounded verifier reason symbol for process exit STATUS."
  (or (alist-get status
                '((2 . invalid-request)
                  (3 . unsafe-path)
                  (4 . original-root)
                  (5 . snapshot-root)
                  (6 . original-file)
                  (7 . snapshot-create)
                  (8 . copy-io)
                  (9 . content-mismatch)
                  (10 . final-identity)))
      'verifier-failed))

(defun emacs-jupyter-notebook-panel--original-verification-reason (result)
  "Bound verifier callback RESULT to a safe public reason symbol."
  (if (memq result '(invalid-request unsafe-path original-root snapshot-root
                      original-file snapshot-create copy-io content-mismatch
                      final-identity timeout verifier-failed))
      result
    'verifier-failed))

(defun emacs-jupyter-notebook-panel--verify-original-async
    (original snapshot callback)
  "Verify ORIGINAL into SNAPSHOT asynchronously, then call CALLBACK.
CALLBACK receives t after an exact durable copy, or a bounded failure-reason
symbol.  Return a no-argument cancellation function."
  (let* ((python (and (stringp emacs-jupyter-notebook-local-python-command)
                      (if (file-name-absolute-p
                           emacs-jupyter-notebook-local-python-command)
                          (and (file-executable-p
                                emacs-jupyter-notebook-local-python-command)
                               emacs-jupyter-notebook-local-python-command)
                        (executable-find
                         emacs-jupyter-notebook-local-python-command))))
         (script (emacs-jupyter-notebook-panel--artifact-verifier-script))
         (root-id (emacs-jupyter-notebook-panel--identity-parts
                   (plist-get original :root-identity)))
         (file-id (emacs-jupyter-notebook-panel--identity-parts
                   (plist-get original :identity))))
    (unless python
      (error "Local Python command %S not found on `exec-path'"
             emacs-jupyter-notebook-local-python-command))
    (unless script
      (error "Bundled image artifact verifier is unavailable"))
    (let (process timer settled)
      (cl-labels
          ((finish (valid)
             (unless settled
               (setq settled t)
               (when (timerp timer) (cancel-timer timer))
               (when (and (processp process) (process-live-p process))
                 (delete-process process))
               (funcall callback valid))))
        (setq process
              (make-process
               :name (generate-new-buffer-name "ejn-image-verify")
               :buffer nil
               :command
               (list python "-I" script
                     (plist-get original :root) (plist-get original :file)
                     (number-to-string (nth 0 root-id))
                     (number-to-string (nth 1 root-id))
                     (number-to-string (nth 0 file-id))
                     (number-to-string (nth 1 file-id))
                     (number-to-string (plist-get original :size))
                     (plist-get original :sha256)
                     (plist-get snapshot :root)
                     (plist-get snapshot :file))
               :connection-type 'pipe
               :noquery t
               :sentinel
               (lambda (current _event)
                 (unless (process-live-p current)
                   (let ((status (and (eq (process-status current) 'exit)
                                      (process-exit-status current))))
                     (finish
                      (if (and status (= status 0))
                          t
                        (emacs-jupyter-notebook-panel--original-verification-exit-reason
                         status))))))))
        ;; The verifier is useful only while its hard deadline exists.  If
        ;; timer construction fails after process creation, retire that exact
        ;; child and settle the callback before propagating the setup error.
        ;; A very short-lived verifier may also run its sentinel from inside
        ;; `make-process'; do not retain a no-op timer in that case.
        (unless settled
          (condition-case err
              (setq timer
                    (run-at-time
                     emacs-jupyter-notebook-panel--original-verify-timeout nil
                     (lambda () (finish 'timeout))))
            (error
             (finish nil)
             (signal (car err) (cdr err)))))
        (lambda ()
          (unless settled
            (when (and (processp process) (process-live-p process))
              (delete-process process))
            (finish nil)))))))

(defvar emacs-jupyter-notebook-panel-original-verify-function
  #'emacs-jupyter-notebook-panel--verify-original-async
  "Function called with original, snapshot, and async result callback.
It returns a no-argument function which cancels the pending verification.")

(defun emacs-jupyter-notebook-panel--release-original-open (image)
  "Release one external-opener lease and finish deferred bundle retirement."
  (let ((props (cdr image)))
    (when (> (or (plist-get props :ejn-original-open-leases) 0) 0)
      (plist-put props :ejn-original-open-leases
                 (1- (plist-get props :ejn-original-open-leases))))
    (emacs-jupyter-notebook-panel--retire-original-if-released image)))

(defun emacs-jupyter-notebook-panel--external-image-suffix (mime)
  "Return the conventional file suffix for image MIME."
  (pcase mime
    ("image/png" ".png")
    ("image/jpeg" ".jpg")
    ("image/gif" ".gif")
    ("image/webp" ".webp")
    (_ ".img")))

(defun emacs-jupyter-notebook-panel--cleanup-external-image-snapshot (snapshot)
  "Retire the exact private SNAPSHOT through its local capability."
  (when (timerp (plist-get snapshot :timer))
    (cancel-timer (plist-get snapshot :timer)))
  (setq emacs-jupyter-notebook-panel--external-image-snapshots
        (delq snapshot emacs-jupyter-notebook-panel--external-image-snapshots))
  (let ((artifact (plist-get snapshot :artifact))
        (capability (plist-get snapshot :artifact-capability)))
    (if artifact
        (emacs-jupyter-notebook-panel--delete-published-artifact artifact)
      ;; A cancelled verifier may have left an unpublished destination.  Its
      ;; inode was never transferred back from the verifier, so leave it for
      ;; dead-lease stale pruning rather than guessing that an allowed name is
      ;; still ours.
      nil)
    (ignore-errors (emacs-jupyter-notebook-artifacts-release capability))))

(defun emacs-jupyter-notebook-panel--make-external-image-snapshot (mime)
  "Create and return an empty private snapshot descriptor for MIME."
  (let* ((capability (emacs-jupyter-notebook-artifacts-create 'image-open))
         (root (emacs-jupyter-notebook-artifacts-capability-root capability)))
    (list :panel (current-buffer)
          :artifact-capability capability
          :root root
          :root-identity
          (emacs-jupyter-notebook-artifacts-capability-root-identity capability)
          :file (expand-file-name
                 (concat "original"
                         (emacs-jupyter-notebook-panel--external-image-suffix mime))
                 root)
          :artifact nil :timer nil)))

(defun emacs-jupyter-notebook-panel--register-external-image-snapshot
    (snapshot original)
  "Admit verified SNAPSHOT for ORIGINAL and schedule its bounded retirement."
  (let ((artifact
         (emacs-jupyter-notebook-panel--published-artifact-metadata
          (plist-get snapshot :root) (plist-get snapshot :file)
          (plist-get original :sha256) (plist-get original :size)
          (plist-get snapshot :root-identity)
          emacs-jupyter-notebook-panel--max-published-original-bytes
          nil nil nil (plist-get snapshot :artifact-capability))))
    (plist-put snapshot :artifact artifact)
    ;; Arm expiry before publishing SNAPSHOT into the retained set.  A timer
    ;; setup error is then an ordinary failed handoff which the caller can
    ;; retire through SNAPSHOT's already-recorded artifact capability; no
    ;; immortal partially registered snapshot becomes globally reachable.
    (plist-put
     snapshot :timer
     (run-at-time
      (emacs-jupyter-notebook-panel--external-image-snapshot-ttl) nil
      #'emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot))
    (push snapshot emacs-jupyter-notebook-panel--external-image-snapshots)
    snapshot))

(defun emacs-jupyter-notebook-panel--owned-materialized-image-file (image)
  "Return IMAGE's exact panel-owned local file, or nil.
This check disables file handlers and pins the capability, inode, size, owner,
mode, link count, and direct-child spelling before an external process sees
the path."
  (let* ((props (and (consp image) (cdr image)))
         (file (and props (plist-get props :file)))
         (capability (and props (plist-get props :ejn-artifact-capability)))
         (identity (and props (plist-get props :ejn-artifact-identity)))
         (bytes (and props (plist-get props :ejn-artifact-bytes)))
         (file-name-handler-alist nil))
    (when (and (stringp file) identity
               (integerp bytes) (>= bytes 0)
               (eq capability
                   emacs-jupyter-notebook-panel--image-artifact-capability)
               (emacs-jupyter-notebook-artifacts-capability-valid-p capability))
      (let ((attrs
             (emacs-jupyter-notebook-artifacts--leaf-attributes
              capability file identity)))
        (when (and attrs (= (file-attribute-size attrs) bytes))
          file)))))

(defun emacs-jupyter-notebook-panel--cleanup-external-image-opens-on-exit ()
  "Cancel verifier jobs and remove retained external-viewer snapshots."
  (dolist (cancel (copy-sequence
                   emacs-jupyter-notebook-panel--external-image-pending-cancels))
    (ignore-errors (funcall cancel)))
  (dolist (snapshot (copy-sequence
                     emacs-jupyter-notebook-panel--external-image-snapshots))
    (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot)))

(defun emacs-jupyter-notebook-panel--cleanup-external-image-opens-for-panel (panel)
  "Cancel and retire external image handoffs owned by PANEL only."
  (dolist (snapshot (copy-sequence
                     emacs-jupyter-notebook-panel--external-image-snapshots))
    (when (eq (plist-get snapshot :panel) panel)
      (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot))))

(defun emacs-jupyter-notebook-panel--make-external-image-snapshot-room ()
  "Evict oldest completed handoffs until one snapshot slot is available.
Pending verifications are never evicted.  Return non-nil when a new verifier
can start within the configured hard bound."
  (let ((limit
         (emacs-jupyter-notebook-panel--external-image-snapshot-budget)))
    (when (> limit 0)
      (while (and emacs-jupyter-notebook-panel--external-image-snapshots
                  (>= (+ emacs-jupyter-notebook-panel--external-image-pending-count
                         (length
                          emacs-jupyter-notebook-panel--external-image-snapshots))
                      limit))
        (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
         (car (last emacs-jupyter-notebook-panel--external-image-snapshots))))
      (< (+ emacs-jupyter-notebook-panel--external-image-pending-count
            (length emacs-jupyter-notebook-panel--external-image-snapshots))
         limit))))

(add-hook 'kill-emacs-hook
          #'emacs-jupyter-notebook-panel--cleanup-external-image-opens-on-exit)

(defun emacs-jupyter-notebook-panel--start-external-image-open
    (image original snapshot)
  "Verify IMAGE's ORIGINAL into SNAPSHOT and launch its external viewer."
  (let* ((props (cdr image))
         (token (cons 'ejn-image-open nil))
         (settled nil)
         (lease-released nil)
         verifier-cancel cancel-function)
    (cl-labels
        ((release-original ()
           (unless lease-released
             (setq lease-released t)
             (emacs-jupyter-notebook-panel--release-original-open image)))
         (finish (result &optional quiet)
           (unless settled
             (setq settled t)
             (setq emacs-jupyter-notebook-panel--external-image-pending-cancels
                   (delq cancel-function
                         emacs-jupyter-notebook-panel--external-image-pending-cancels))
             (setq emacs-jupyter-notebook-panel--external-image-pending-count
                   (max 0 (1- emacs-jupyter-notebook-panel--external-image-pending-count)))
             (when (eq (plist-get props :ejn-original-open-pending) token)
               (plist-put props :ejn-original-open-pending nil)
               (plist-put props :ejn-original-open-cancel nil))
             (if (not (eq result t))
                 (progn
                   (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                    snapshot)
                   (release-original)
                   (unless quiet
                     (message
                      "emacs-jupyter-notebook: image original failed verification (%s)"
                      (emacs-jupyter-notebook-panel--original-verification-reason
                       result))))
               (condition-case err
                   (let ((registered
                          (emacs-jupyter-notebook-panel--register-external-image-snapshot
                           snapshot original)))
                     ;; The verifier's durable snapshot, rather than launcher
                     ;; process lifetime, now owns the external handoff.
                     (release-original)
                     (funcall emacs-jupyter-notebook-panel-external-open-function
                              (plist-get registered :file)))
                 (error
                  (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                   snapshot)
                  (release-original)
                  (message
                   "emacs-jupyter-notebook: external image opener failed: %s"
                   (error-message-string err)))))))
         (cancel ()
           (unless settled
             ;; Settle ownership before killing the process.  Its sentinel may
             ;; run synchronously from `delete-process', but the callback will
             ;; then observe SETTLED and cannot release anything twice.
             (finish nil t)
             (when (functionp verifier-cancel)
               (ignore-errors (funcall verifier-cancel))))))
      (setq cancel-function (lambda () (cancel)))
      (plist-put props :ejn-original-open-pending token)
      (plist-put props :ejn-original-open-cancel cancel-function)
      (plist-put props :ejn-original-open-leases
                 (1+ (or (plist-get props :ejn-original-open-leases) 0)))
      (cl-incf emacs-jupyter-notebook-panel--external-image-pending-count)
      (push cancel-function
            emacs-jupyter-notebook-panel--external-image-pending-cancels)
      (condition-case err
          (setq verifier-cancel
                (funcall emacs-jupyter-notebook-panel-original-verify-function
                         original snapshot (lambda (valid) (finish valid))))
        (error
         (cancel)
         (signal (car err) (cdr err))))
      cancel-function)))

(defun emacs-jupyter-notebook-panel-open-image-externally ()
  "Open the original static image at point in an external application.
A second invocation while its verifier is pending cancels that request."
  (interactive)
  (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (user-error "Not in an EJN output panel"))
  (let* ((image (emacs-jupyter-notebook-panel--image-at-point))
         (props (and image (cdr image))))
    (unless image
      (user-error "No image on this entry"))
    (if (not (plist-member props :ejn-publication-root))
        (let ((file
               (emacs-jupyter-notebook-panel--owned-materialized-image-file
                image)))
          (unless file (user-error "Image original is unavailable"))
          (funcall emacs-jupyter-notebook-panel-external-open-function file))
      (condition-case err
          (if-let ((cancel (plist-get props :ejn-original-open-cancel)))
              (progn
                (funcall cancel)
                (message "emacs-jupyter-notebook: cancelled pending image open"))
            (let ((limit
                   (emacs-jupyter-notebook-panel--external-image-snapshot-budget)))
              (unless (> limit 0)
                (user-error "External image snapshots are disabled"))
              (unless
                  (emacs-jupyter-notebook-panel--make-external-image-snapshot-room)
                (user-error "External image verification limit reached"))
              (let ((original
                     (emacs-jupyter-notebook-panel--original-for-external-open image))
                    (snapshot
                     (emacs-jupyter-notebook-panel--make-external-image-snapshot
                      (plist-get props :ejn-original-mime))))
                (condition-case start-error
                    (emacs-jupyter-notebook-panel--start-external-image-open
                     image original snapshot)
                  (error
                   (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                    snapshot)
                   (signal (car start-error) (cdr start-error)))))))
        (error (user-error "%s" (error-message-string err)))))))

(defun emacs-jupyter-notebook-panel--entry-pickle-at-point ()
  "Acquire the matplotlib pickle for the panel entry at point, or nil."
  (let ((id (emacs-jupyter-notebook-panel--entry-id-at-point)))
    (when id
      (ejn-panel-acquire-pickle
       (emacs-jupyter-notebook-panel--handle
        (current-buffer) id
        (plist-get (emacs-jupyter-notebook-panel--entry (current-buffer) id)
                   :cell-key))))))

(defun emacs-jupyter-notebook-panel-acquire-latest-pickle-for-cell (source-buffer cell-key)
  "Acquire the newest pickle for CELL-KEY in SOURCE-BUFFER's panel, or nil."
  (let ((panel (emacs-jupyter-notebook-panel-buffer source-buffer)))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (let (found)
          (dolist (cell emacs-jupyter-notebook-panel--entries)
            (let ((entry (cdr cell)))
              (when (and (equal (plist-get entry :cell-key) cell-key)
                         (plist-get entry :mpl-pickle))
                (setq found (emacs-jupyter-notebook-panel--handle
                             panel (car cell) (plist-get entry :cell-key))))))
          (and found (ejn-panel-acquire-pickle found)))))))

(defun emacs-jupyter-notebook-panel-open-figure ()
  "Open the figure of the panel entry at point interactively (W8.5).
Signals a `user-error' when point is not on an entry that carries a
matplotlib pickle artifact."
  (interactive)
  (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (user-error "Not in an EJN output panel"))
  (let ((pickle (emacs-jupyter-notebook-panel--entry-pickle-at-point)))
    (unless pickle
      (user-error "No interactive figure on this entry (no pickle artifact)"))
    (emacs-jupyter-notebook-open-figure-pickle-lease pickle)))

;;; Numerical publications (W21)

(declare-function emacs-jupyter-notebook-inspect-publication
                  "emacs-jupyter-notebook" (lease))

(defun emacs-jupyter-notebook-panel--array-card (artifact)
  "Return bounded display text for ARTIFACT's validated manifest."
  (let ((manifest (plist-get artifact :manifest)))
    (concat
     (format "Array %s · sample %s · full source resolution\n"
             (gethash "key" manifest) (gethash "sample_id" manifest))
     (mapconcat
      (lambda (plane)
        (let ((shape (gethash "shape" plane)))
          (format "  %s  %s × %s  %s%s\n"
                  (gethash "name" plane) (aref shape 0) (aref shape 1)
                  (gethash "dtype" plane)
                  (if-let ((units (gethash "units" plane)))
                      (format "  %s" units) ""))))
      (gethash "planes" manifest) ""))))

(defun emacs-jupyter-notebook-panel--insert-array (artifact index)
  "Insert ARTIFACT's card and an exact-publication Inspect action at INDEX."
  (let ((start (point))
        (text (emacs-jupyter-notebook-panel--array-card artifact))
        (handle (plist-get artifact :entry-handle))
        (output-id (plist-get artifact :output-id)))
    (insert text)
    (insert-text-button
     "[Inspect]" 'follow-link t
     'action (lambda (_button)
               (let ((lease (ejn-panel-acquire-array handle output-id)))
                 (unless lease (user-error "This numerical publication has retired"))
                 (condition-case err
                     (emacs-jupyter-notebook-inspect-publication lease)
                   (error
                    (funcall (plist-get lease :release))
                    (signal (car err) (cdr err)))))))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'emacs-jupyter-notebook-segment-index index
                               'emacs-jupyter-notebook-array-output-id output-id))
    (+ (string-bytes text) 10)))

(defun ejn-panel-set-published-array (handle publication &optional update-p)
  "Admit one numerical PUBLICATION on HANDLE; return its effective handle.
UPDATE-P targets the exact array display-id, including an earlier execution.
Validate only local file identity and bounded helper manifest metadata; never
read array bytes.  Nil means ownership was not accepted by this panel."
  (when (ejn-panel-entry-live-p handle)
    (let* ((panel (plist-get handle :panel))
           (display-id (plist-get publication :display-id))
           (target (and update-p display-id
                        (emacs-jupyter-notebook-panel--display-target
                         panel display-id 'array)))
           (effective (if update-p (car-safe target) handle))
           (manifest (plist-get publication :manifest)))
      (when (and effective (ejn-panel-entry-live-p effective))
        (unless (ejn-helper-protocol-array-manifest-p manifest (plist-get publication :size))
          (error "Invalid numerical publication manifest"))
        (unless (and (stringp (plist-get publication :path))
                     (string-match-p
                      "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'"
                      (file-name-nondirectory (plist-get publication :path))))
          (error "Invalid numerical artifact name"))
        (let* ((file-name-handler-alist nil)
               (metadata
                (with-current-buffer panel
                  (emacs-jupyter-notebook-panel--published-artifact-metadata
                   (plist-get publication :root) (plist-get publication :path)
                   (plist-get publication :sha256) (plist-get publication :size)
                   (plist-get publication :root-identity)
                   emacs-jupyter-notebook-panel--max-published-original-bytes)))
               (source (with-current-buffer panel
                         emacs-jupyter-notebook-panel--source-buffer))
               (workspace
                (when (buffer-live-p source)
                  (with-current-buffer source
                    (or emacs-jupyter-notebook--array-workspace-identity
                        (setq emacs-jupyter-notebook--array-workspace-identity
                              (format "ejn-%d-%d" (emacs-pid)
                                      (cl-incf emacs-jupyter-notebook-panel--next-array-identity)))))))
               (output-id (cl-incf emacs-jupyter-notebook-panel--next-array-identity))
               (artifact
                (append metadata
                        (list :manifest manifest :kind 'array-group
                              :publication-id (gethash "publication_id" manifest)
                              :output-id output-id :entry-handle effective
                              :generation (plist-get effective :generation)
                              :execution (format "%s/%s/%d" workspace
                                                 (plist-get metadata :root-identity)
                                                 (plist-get handle :id))
                              :source-buffer source :cell-key (plist-get effective :cell-key)
                              :workspace (format "%s/%s" workspace (gethash "key" manifest))
                              :display-id display-id :leases 0 :retired nil :deleted nil)))
               accepted)
          ;; A mock callback or a filesystem handler must not resurrect a
          ;; cleared entry during metadata admission.
          (when (ejn-panel-entry-live-p effective)
            (emacs-jupyter-notebook-panel--update-entry
             effective
             (lambda (entry)
               (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                            panel entry))
               (let ((segment (and target
                                   (memq (cdr target) (plist-get entry :outputs))
                                   (cdr target))))
                 (cond
                  (segment
                   (emacs-jupyter-notebook-panel--retire-pickle (cdr segment))
                   (setcdr segment artifact)
                   (setq accepted t))
                  ((emacs-jupyter-notebook-panel--entry-output-room-p entry)
                   (setq entry (plist-put entry :outputs
                                          (append (plist-get entry :outputs)
                                                  (list (cons 'array artifact)))))
                   (setq accepted t))
                  (t
                   ;; We accepted ownership even when bounded retention drops
                   ;; this output; retire it ourselves and emit one marker.
                   (emacs-jupyter-notebook-panel--retire-pickle artifact)
                   (setq entry (emacs-jupyter-notebook-panel--entry-note-segment-omission entry))
                   (setq accepted t)))
                 (setq entry (plist-put entry :artifact-bytes
                                        (emacs-jupyter-notebook-panel--recompute-entry-artifact-bytes entry)))
                 entry))
             t)
            (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
            (when (and accepted (ejn-panel-entry-live-p effective)
                       (not (plist-get artifact :retired)))
              ;; A consumer failure cannot undo committed artifact ownership
              ;; or make the helper dispose an already-owned publication.
              (condition-case err
                  (run-hook-with-args 'ejn-panel-array-published-hook effective output-id)
                (error
                 (message "emacs-jupyter-notebook: numerical publication hook failed: %s"
                          (error-message-string err))))))
          (and accepted effective))))))

(defun ejn-panel-acquire-array (handle &optional output-id)
  "Acquire HANDLE's exact OUTPUT-ID, or its newest numerical publication.
Return a metadata-only lease with an idempotent zero-argument :release callback.
The callback must run after viewer acknowledgement, cancellation or failure."
  (when (ejn-panel-entry-live-p handle)
    (let* ((entry (ejn-panel-entry-snapshot handle))
           (segment (cl-find-if
                     (lambda (seg)
                       (and (eq (car seg) 'array)
                            (or (null output-id)
                                (equal output-id (plist-get (cdr seg) :output-id)))))
                     (reverse (plist-get entry :outputs))))
           (artifact (cdr-safe segment)))
      (when (and artifact (not (plist-get artifact :retired))
                 (emacs-jupyter-notebook-panel--admitted-artifact-current-p
                  artifact emacs-jupyter-notebook-panel--max-published-original-bytes))
        (when (>= emacs-jupyter-notebook-panel--array-handoff-count
                  emacs-jupyter-notebook-panel--max-array-handoffs)
          (user-error "Numerical viewer handoff limit reached"))
        (let ((released nil)
              ;; Eviction can remove an entry before panel kill's deferred
              ;; scan.  A bounded handoff therefore owns its own existing
              ;; root capability lease, independently of that panel scan.
              (handoff-capability
               (emacs-jupyter-notebook-artifacts-capture
                'helper (plist-get artifact :root) (plist-get artifact :root-identity))))
          (unless handoff-capability
            (user-error "Numerical publication ownership is unavailable"))
          (cl-incf emacs-jupyter-notebook-panel--array-handoff-count)
          (plist-put artifact :leases (1+ (plist-get artifact :leases)))
          (append (copy-sequence artifact)
                  (list :release
                        (lambda ()
                          (unless released
                            (setq released t)
                            (cl-decf emacs-jupyter-notebook-panel--array-handoff-count)
                            (unwind-protect
                                (progn
                                  (unless (emacs-jupyter-notebook-artifacts-capability-valid-p
                                           (plist-get artifact :artifact-capability))
                                    (plist-put artifact :artifact-capability handoff-capability))
                                  (ejn-panel-release-pickle artifact))
                              (emacs-jupyter-notebook-artifacts-release handoff-capability)))))))))))

(defun emacs-jupyter-notebook-panel-acquire-array-at-point ()
  "Acquire the selected numerical output, or the newest array on its header."
  (when (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (let ((id (emacs-jupyter-notebook-panel--entry-id-at-point)))
      (when id
        (let* ((entry (emacs-jupyter-notebook-panel--entry (current-buffer) id))
               (handle (emacs-jupyter-notebook-panel--handle
                        (current-buffer) id (plist-get entry :cell-key))))
          (ejn-panel-acquire-array
           handle (get-text-property (point) 'emacs-jupyter-notebook-array-output-id)))))))

(defun emacs-jupyter-notebook-panel-acquire-array-for-cell (source-buffer cell-key)
  "Acquire the newest array from CELL-KEY's latest execution only.
A new execution without numerical output never falls back to an older result."
  (when (and cell-key (buffer-live-p source-buffer))
    (let ((panel (emacs-jupyter-notebook-panel-buffer source-buffer)))
      (when (buffer-live-p panel)
        (with-current-buffer panel
          (when-let ((cell (cl-find-if
                           (lambda (cell) (equal cell-key (plist-get (cdr cell) :cell-key)))
                           (reverse emacs-jupyter-notebook-panel--entries))))
            (ejn-panel-acquire-array
             (emacs-jupyter-notebook-panel--handle panel (car cell) cell-key))))))))

;;; Panel cleanup (W2.9)

(defun emacs-jupyter-notebook--kill-panel ()
  "Kill the current buffer's output panel, if any."
  (let ((panel (and (boundp 'emacs-jupyter-notebook--panel-buffer)
                    emacs-jupyter-notebook--panel-buffer)))
    (when (buffer-live-p panel)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer panel)))
    (setq emacs-jupyter-notebook--panel-buffer nil)))

(provide 'emacs-jupyter-notebook-result)

;;; emacs-jupyter-notebook-result.el ends here
