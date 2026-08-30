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
;; Public API used by `emacs-jupyter-notebook-jupyter.el' callbacks:
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
;; A KEY for cell-bound evaluation is a cons of (file-name . line-start-pos)
;; produced by the source buffer's cell tracking.  Region/paragraph/defun
;; evaluation uses KEY = nil; those entries flow only to the history-log
;; view.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

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

;;; MIME helpers (still used by callbacks)

(defconst emacs-jupyter-notebook-mpl-pickle-mime-type
  :application/x-ejn-mpl-pickle
  "Keyword MIME key for the W8 matplotlib figure pickle payload.
Emitted alongside `image/png' by the injected remote formatter (W8.1).")

(defun emacs-jupyter-notebook--select-mime-type (data)
  "Select the best DISPLAYABLE MIME type from DATA plist.
Return (cons mime-type content) or nil.

W8.2: the custom `application/x-ejn-mpl-pickle' MIME is deliberately NOT
selected here — it is not a renderable thumbnail.  It rides alongside
`image/png' and is stashed separately via
`emacs-jupyter-notebook--select-mpl-pickle', so the PNG thumbnail path is
completely unchanged whether or not a pickle is present."
  (cond
   ((plist-get data :image/png)
    (cons :image/png (plist-get data :image/png)))
   ((plist-get data :image/jpeg)
    (cons :image/jpeg (plist-get data :image/jpeg)))
   ((plist-get data :text/plain)
    (cons :text/plain (plist-get data :text/plain)))
   (t nil)))

(defun emacs-jupyter-notebook--select-mpl-pickle (data)
  "Return the base64 matplotlib-pickle payload from DATA plist, or nil.
W8.2: recognizes the custom `application/x-ejn-mpl-pickle' MIME key so the
interactive viewer (W8.5) can reopen the figure locally.  Only accepts a
non-empty string payload."
  (let ((payload (plist-get data emacs-jupyter-notebook-mpl-pickle-mime-type)))
    (and (stringp payload)
         (not (string-empty-p payload))
         payload)))

(declare-function emacs-jupyter-notebook-viewer-open-pickle "emacs-jupyter-notebook-viewer" (base64))

(defun emacs-jupyter-notebook--maybe-stash-pickle (buffer handle data)
  "Stash any matplotlib pickle in DATA onto HANDLE's entry.
W8.2: extracts the `application/x-ejn-mpl-pickle' payload and stores it on
the panel entry, leaving the PNG thumbnail path untouched.  W8.6: when
`emacs-jupyter-notebook-viewer-auto-open' is non-nil and a pickle is
present, also hand it to the local viewer.  BUFFER is the source buffer;
best-effort, never raises out of a callback.  A retired HANDLE is ignored
before inspecting DATA, so callers cannot accidentally retain or schedule a
late pickle payload."
  (when (ejn-panel-entry-live-p handle)
    (let ((base64 (emacs-jupyter-notebook--select-mpl-pickle data)))
    (if base64
        (progn
          (ejn-panel-set-pickle handle base64)
          (when (and (bound-and-true-p emacs-jupyter-notebook-viewer-auto-open)
                     (fboundp 'emacs-jupyter-notebook-viewer-open-pickle))
            ;; W8.7(a): NEVER decode base64 + write the temp file on the
            ;; IOPub callback thread — a large figure pickle would freeze
            ;; Emacs during ordinary result streaming.  Coalesce it on the
            ;; panel entry: rapid display updates produce one latest-payload
            ;; handoff, and the closure holds no pickle bytes.
            (ejn-panel-schedule-pickle-open
             handle
             (lambda (current-pickle)
               (ignore-errors
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (emacs-jupyter-notebook-viewer-open-pickle
                      current-pickle))))))))
      ;; W8.7(d): a display with no pickle key replaces any prior figure on
      ;; this entry — drop the stale pickle so `v'/`C-c j I' can't reopen a
      ;; no-longer-visible figure.
        (ejn-panel-clear-pickle handle)))))

(defun emacs-jupyter-notebook--render-image-data (base64-data)
  "Decode BASE64-DATA and return an image spec."
  (let* ((decoded (base64-decode-string base64-data))
         (image (create-image decoded nil t
                              :max-width emacs-jupyter-notebook-image-max-width
                              :max-height emacs-jupyter-notebook-image-max-height)))
    (unless image
      (error "Image type not supported"))
    image))

(defun emacs-jupyter-notebook--render-mime-result (data)
  "Render DATA plist into a displayable result.
Return a string for text or a propertized string with display property
for images.  Return nil if no suitable MIME type is found."
  (let ((selected (emacs-jupyter-notebook--select-mime-type data)))
    (when selected
      (let ((mime (car selected))
            (content (cdr selected)))
        (if (memq mime '(:image/png :image/jpeg))
            (condition-case nil
                (propertize " " 'display
                            (emacs-jupyter-notebook--render-image-data content))
              (error (plist-get data :text/plain)))
          content)))))

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
  :status running|ok|error
  :exec-count INTEGER-or-\"*\"
  :timestamp ISO-string
  :outputs ordered text/image segments
  :mpl-pickle BASE64-or-nil
  :pickle-open-timer TIMER-or-nil
  :pickle-open-token TOKEN-or-nil
  :pending-clear BOOL")

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

(defvar-local emacs-jupyter-notebook-panel--dirty nil
  "Non-nil when the panel needs a redisplay.")

(defvar-local emacs-jupyter-notebook-panel--render-count 0
  "Counter incremented every time the panel re-renders.  Test instrument.")

(defvar-local emacs-jupyter-notebook-panel--image-directory nil
  "Private temporary directory holding this panel's original images.")

(defvar-local emacs-jupyter-notebook-panel--inline-image-specs nil
  "Image specs materialized by the most recent panel render.")

(defvar-local emacs-jupyter-notebook-panel--dirty-entry-ids nil
  "Entry ids eligible for an incremental render on the next flush.")

(defvar-local emacs-jupyter-notebook-panel--force-full-render nil
  "Non-nil when the next flush must rebuild the complete panel view.")

(defvar-local emacs-jupyter-notebook-panel--history-evicted-p nil
  "Non-nil once this panel has evicted retained history entries.")

;;; Panel mode

(defvar emacs-jupyter-notebook-panel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'emacs-jupyter-notebook-panel-quit)
    (define-key map (kbd "H") #'emacs-jupyter-notebook-panel-toggle-view)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-panel-visit-source)
    (define-key map (kbd "n") #'emacs-jupyter-notebook-panel-next-entry)
    (define-key map (kbd "p") #'emacs-jupyter-notebook-panel-previous-entry)
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
  (setq truncate-lines nil)
  (add-hook 'kill-buffer-hook
            #'emacs-jupyter-notebook-panel--on-kill nil t))

;; W16: under evil (Doom, Spacemacs, ...) special-mode buffers land in
;; motion/normal state, whose maps SHADOW the panel's single-key commands —
;; `H' becomes move-to-window-top, `v' starts visual selection, `+'/`-' are
;; line motions — so toggle/zoom/open-figure silently never ran.  Put the
;; panel in emacs state so its keymap works exactly as designed.
(declare-function evil-set-initial-state "evil-core" (mode state))
(with-eval-after-load 'evil
  (evil-set-initial-state 'emacs-jupyter-notebook-panel-mode 'emacs))

(defun emacs-jupyter-notebook-panel--on-kill ()
  "Release timers, cached images, and private files owned by this panel."
  (when (timerp emacs-jupyter-notebook-panel--flush-timer)
    (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
  (setq emacs-jupyter-notebook-panel--flush-timer nil)
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
  (display-buffer
   panel
   `((display-buffer-in-side-window)
     (side . ,emacs-jupyter-notebook-panel-side)
     (window-width . ,emacs-jupyter-notebook-panel-width))))

(defun emacs-jupyter-notebook-show-output-panel ()
  "Open or pop up the current source buffer's output panel."
  (interactive)
  (let ((panel (ejn-panel-ensure (current-buffer))))
    (emacs-jupyter-notebook-panel--display panel)))

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
membership or entry ordering may have changed."
  (when (ejn-panel-entry-live-p handle)
    (let ((panel (plist-get handle :panel))
          (id (plist-get handle :id)))
      (when (buffer-live-p panel)
        (let ((entry (emacs-jupyter-notebook-panel--entry panel id)))
          (when entry
            (let ((new (funcall updater entry)))
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
               (setq entry (plist-put entry :pickle-open-timer nil))
               (setq entry (plist-put entry :pickle-open-token nil)))
             entry))
      pickle)))

(defun ejn-panel-schedule-pickle-open (handle opener)
  "Coalesce HANDLE's deferred pickle open and call OPENER with its live payload.
Only one idle timer may be pending per entry.  Neither the timer nor OPENER
captures the pickle bytes; the callback revalidates HANDLE and reads the
entry payload only after claiming its current timer slot."
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
      (setq emacs-jupyter-notebook-panel--dirty t)
      (when entry-id
        (cl-pushnew entry-id emacs-jupyter-notebook-panel--dirty-entry-ids))
      (when force-full
        (setq emacs-jupyter-notebook-panel--force-full-render t))
      (unless (timerp emacs-jupyter-notebook-panel--flush-timer)
        (let ((delay (/ (max 0 emacs-jupyter-notebook-panel-stream-throttle-ms)
                        1000.0)))
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
            (emacs-jupyter-notebook-panel--render panel)
          (emacs-jupyter-notebook-panel--render-dirty-entries panel))))))

(defun emacs-jupyter-notebook-panel-flush-now (panel)
  "Force PANEL to render immediately, cancelling any pending throttle timer."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (when (timerp emacs-jupyter-notebook-panel--flush-timer)
        (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
      (setq emacs-jupyter-notebook-panel--flush-timer nil)
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
           append (cl-loop for seg in (plist-get entry :outputs)
                           when (eq (car seg) 'image)
                           collect (cdr seg))))

(defun emacs-jupyter-notebook-panel--bounded-inline-specs (entries)
  "Return the newest bounded subset of image specs visible in ENTRIES.
Newness follows entry creation ids, rather than source-position display order."
  (let* ((creation-order
          (sort (copy-sequence entries)
                (lambda (a b) (< (plist-get a :id) (plist-get b :id)))))
         (specs (emacs-jupyter-notebook-panel--image-specs creation-order))
         (max emacs-jupyter-notebook-panel-max-inline-images))
    (if (and (integerp max) (> max 0))
        (last specs (min max (length specs)))
      nil)))

(defun emacs-jupyter-notebook-panel--set-inline-specs (specs)
  "Install SPECS as the inline set, flushing previews that were demoted."
  (dolist (old emacs-jupyter-notebook-panel--inline-image-specs)
    (unless (member old specs)
      (ignore-errors (image-flush old t))))
  (setq emacs-jupyter-notebook-panel--inline-image-specs specs))

(defun emacs-jupyter-notebook-panel--insert-image-placeholder (image index)
  "Insert a lightweight placeholder for IMAGE tagged with segment INDEX."
  (let* ((type (or (plist-get (cdr image) :type) 'image))
         (file (plist-get (cdr image) :file))
         (bytes (and (stringp file)
                     (file-exists-p file)
                     (file-attribute-size (file-attributes file))))
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
    (if (not inline-p)
        (emacs-jupyter-notebook-panel--insert-image-placeholder image index)
      (if (and emacs-jupyter-notebook-panel-slice-images
               (display-graphic-p))
          (condition-case nil
              (let* ((height (cdr (image-size image t)))
                     (rows (max 1 (ceiling height (frame-char-height)))))
                (insert-sliced-image image " " nil rows 1))
            (error (insert (propertize " " 'display image))))
        (insert (propertize " " 'display image))))
    (add-text-properties
     start (point) (list 'emacs-jupyter-notebook-segment-index index))))

(defun emacs-jupyter-notebook-panel--format-header (entry)
  "Return the propertized header string for ENTRY."
  (let* ((count (or (plist-get entry :exec-count) "*"))
         (status (or (plist-get entry :status) 'running))
         (ts (or (plist-get entry :timestamp) ""))
         (code (or (plist-get entry :code) ""))
         (first-line (car (split-string code "\n" t)))
         (title (if first-line
                    (substring first-line 0
                               (min (length first-line) 60))
                  ""))
         (status-s (pcase status
                     ('running "running")
                     ('ok "ok")
                     ('error "error")
                     (_ (format "%s" status)))))
    (propertize
     (format "[%s] %s [%s] %s\n" count ts status-s title)
     'face 'emacs-jupyter-notebook-result-header-face
     'emacs-jupyter-notebook-entry-id (plist-get entry :id)
     'emacs-jupyter-notebook-cell-key (plist-get entry :cell-key))))

(defun emacs-jupyter-notebook-panel--insert-entry (entry inline-specs)
  "Insert ENTRY, materializing only images present in INLINE-SPECS."
  (insert (emacs-jupyter-notebook-panel--format-header entry))
  (let ((index -1))
    (dolist (seg (plist-get entry :outputs))
      (cl-incf index)
      (pcase (car seg)
        ('image
         (emacs-jupyter-notebook-panel--insert-image
          (cdr seg) index (member (cdr seg) inline-specs))
         (unless (bolp) (insert "\n")))
        ('text
         (let ((content (copy-sequence (cdr seg))))
           (unless (string-empty-p content)
             (add-face-text-property
              0 (length content) 'emacs-jupyter-notebook-result-face
              'append content)
             (insert content)
             (unless (string-suffix-p "\n" content)
               (insert "\n"))))))))
  (insert "\n"))

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

(defun emacs-jupyter-notebook-panel--render-dirty-entries (panel)
  "Incrementally re-render dirty entries in PANEL.
Falls back to a full render if an affected visible entry has no existing
section, which means ordering or view membership changed unexpectedly."
  (with-current-buffer panel
    (let* ((ids (prog1 emacs-jupyter-notebook-panel--dirty-entry-ids
                  (setq emacs-jupyter-notebook-panel--dirty-entry-ids nil)))
           (visible (emacs-jupyter-notebook-panel--visible-entries))
           (inline emacs-jupyter-notebook-panel--inline-image-specs)
           (was-at-end (= (point) (point-max)))
           (fallback nil)
           (inhibit-read-only t))
      (setq emacs-jupyter-notebook-panel--force-full-render nil)
      (dolist (id ids)
        (let ((entry (cl-find id visible :key (lambda (e) (plist-get e :id))))
              (bounds (emacs-jupyter-notebook-panel--entry-bounds id)))
          (cond
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

(defun emacs-jupyter-notebook-panel--render (panel)
  "Render PANEL contents according to current view.
History view auto-scrolls to the bottom of the buffer so the newest
entry is visible; latest-per-cell view goes to the top."
  (with-current-buffer panel
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
      (if (eq emacs-jupyter-notebook-panel--view 'history)
          (goto-char (point-max))
        (goto-char (point-min))))))

;;; Public API

(defun emacs-jupyter-notebook-panel--ensure-image-directory (panel)
  "Return PANEL's private image directory, creating it with mode 0700."
  (with-current-buffer panel
    (unless (and (stringp emacs-jupyter-notebook-panel--image-directory)
                 (file-directory-p emacs-jupyter-notebook-panel--image-directory))
      (setq emacs-jupyter-notebook-panel--image-directory
            (make-temp-file "ejn-panel-images-" t))
      (set-file-modes emacs-jupyter-notebook-panel--image-directory #o700))
    emacs-jupyter-notebook-panel--image-directory))

(defun emacs-jupyter-notebook-panel--image-suffix (image)
  "Return a file suffix appropriate for IMAGE's declared type."
  (pcase (plist-get (cdr image) :type)
    ((or 'jpeg 'jpg) ".jpg")
    ('png ".png")
    ('gif ".gif")
    ('webp ".webp")
    (_ ".img")))

(defun emacs-jupyter-notebook-panel--replace-image-data-with-file (image file)
  "Return a fresh IMAGE spec referring to FILE instead of inline data."
  (let ((props (cl-loop for (key value) on (cdr image) by #'cddr
                        unless (memq key '(:data :file))
                        collect key and collect value)))
    (cons 'image (append props (list :file file)))))

(defun emacs-jupyter-notebook-panel--materialize-image (panel image)
  "Move IMAGE's inline data to a private file owned by PANEL.
Specs that already refer to a file, or do not contain string data, are
returned unchanged.  The file is mode 0600 and written without coding."
  (let ((data (and (consp image) (plist-get (cdr image) :data))))
    (if (not (stringp data))
        image
      (let* ((directory
              (emacs-jupyter-notebook-panel--ensure-image-directory panel))
             (file (make-temp-file
                    (expand-file-name "image-" directory) nil
                    (emacs-jupyter-notebook-panel--image-suffix image)))
             (coding-system-for-write 'no-conversion))
        (condition-case err
            (progn
              (write-region data nil file nil 'silent)
              (set-file-modes file #o600)
              (emacs-jupyter-notebook-panel--replace-image-data-with-file
               image file))
          (error
           (ignore-errors (delete-file file))
           (signal (car err) (cdr err))))))))

(defun emacs-jupyter-notebook-panel--owned-image-file-p (panel file)
  "Return non-nil when FILE belongs to PANEL's private image directory."
  (and (stringp file)
       (buffer-live-p panel)
       (with-current-buffer panel
         (and (stringp emacs-jupyter-notebook-panel--image-directory)
              (file-directory-p emacs-jupyter-notebook-panel--image-directory)
              (file-exists-p file)
              (file-in-directory-p
               file emacs-jupyter-notebook-panel--image-directory)))))

(defun emacs-jupyter-notebook-panel--retire-image (panel image)
  "Flush IMAGE and delete its private PANEL-owned backing file."
  (when (and (consp image) (eq (car image) 'image))
    (ignore-errors (image-flush image t))
    (let ((file (plist-get (cdr image) :file)))
      (when (emacs-jupyter-notebook-panel--owned-image-file-p panel file)
        (ignore-errors (delete-file file))))))

(defun emacs-jupyter-notebook-panel--retire-outputs (panel outputs)
  "Retire every image spec in OUTPUTS owned by PANEL."
  (dolist (seg outputs)
    (when (eq (car seg) 'image)
      (emacs-jupyter-notebook-panel--retire-image panel (cdr seg)))))

(defun emacs-jupyter-notebook-panel--entry-text-bytes (entry)
  "Return the retained source and output text byte count for ENTRY."
  (+ (let ((code (plist-get entry :code)))
       (if (stringp code) (string-bytes code) 0))
     (cl-loop for segment in (plist-get entry :outputs)
              when (eq (car segment) 'text)
              sum (string-bytes (cdr segment)))))

(defun emacs-jupyter-notebook-panel--image-artifact-bytes (image)
  "Return retained artifact bytes for IMAGE, using its actual file size."
  (let* ((props (cdr-safe image))
         (file (plist-get props :file))
         (data (plist-get props :data)))
    (cond
     ((and (stringp file) (file-exists-p file))
      ;; Accounting must not expose a local cleanup race to an output callback.
      (condition-case nil
          (let ((size (file-attribute-size (file-attributes file))))
            (if (and (numberp size) (>= size 0)) size 0))
        (file-error 0)
        (error 0)))
     ((stringp data) (string-bytes data))
     (t 0))))

(defun emacs-jupyter-notebook-panel--entry-artifact-bytes (entry)
  "Return retained image and MIME artifact bytes for ENTRY."
  (+ (cl-loop for segment in (plist-get entry :outputs)
              when (eq (car segment) 'image)
              sum (emacs-jupyter-notebook-panel--image-artifact-bytes
                   (cdr segment)))
     (let ((pickle (plist-get entry :mpl-pickle)))
       (if (stringp pickle) (string-bytes pickle) 0))))

(defun emacs-jupyter-notebook-panel--total-text-bytes ()
  "Return the total retained text byte count in the current panel."
  (cl-loop for cell in emacs-jupyter-notebook-panel--entries
           sum (emacs-jupyter-notebook-panel--entry-text-bytes (cdr cell))))

(defun emacs-jupyter-notebook-panel--total-artifact-bytes ()
  "Return the total retained image and MIME artifact bytes in this panel."
  (cl-loop for cell in emacs-jupyter-notebook-panel--entries
           sum (emacs-jupyter-notebook-panel--entry-artifact-bytes (cdr cell))))

(defun emacs-jupyter-notebook-panel--over-retention-budget-p ()
  "Return non-nil when the current panel exceeds any configured budget."
  (or (> (length emacs-jupyter-notebook-panel--entries)
         emacs-jupyter-notebook-panel-max-history-entries)
      (> (emacs-jupyter-notebook-panel--total-text-bytes)
         emacs-jupyter-notebook-panel-max-total-text-bytes)
      (> (emacs-jupyter-notebook-panel--total-artifact-bytes)
         emacs-jupyter-notebook-panel-max-total-artifact-bytes)))

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
    (emacs-jupyter-notebook-panel--retire-outputs panel
                                                   (plist-get entry :outputs))
    (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer entry))
    (setq entry (plist-put entry :outputs nil))
    (setq entry (plist-put entry :mpl-pickle nil))
    (setcdr cell entry)
    (setq emacs-jupyter-notebook-panel--inline-image-specs
          (cl-set-difference emacs-jupyter-notebook-panel--inline-image-specs
                             images :test #'equal))
    (setq emacs-jupyter-notebook-panel--entries
          (delq cell emacs-jupyter-notebook-panel--entries))))

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
      (dolist (cell emacs-jupyter-notebook-panel--entries)
        (emacs-jupyter-notebook-panel--retire-outputs panel
                                                       (plist-get (cdr cell) :outputs))
        (let ((entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                      (cdr cell))))
          (setcdr cell (plist-put entry :mpl-pickle nil))))
      (dolist (spec emacs-jupyter-notebook-panel--inline-image-specs)
        (ignore-errors (image-flush spec t)))
      (setq emacs-jupyter-notebook-panel--inline-image-specs nil)
      ;; Removing the whole private directory also catches an orphan created
      ;; by a partially failed materialization.
      (when (and (stringp emacs-jupyter-notebook-panel--image-directory)
                 (file-directory-p emacs-jupyter-notebook-panel--image-directory))
        (ignore-errors
          (delete-directory emacs-jupyter-notebook-panel--image-directory t)))
      (setq emacs-jupyter-notebook-panel--image-directory nil))))

(defun ejn-panel-clear-all (panel)
  "Retire all PANEL artifacts and entries, invalidating their handles."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel--retire-all-artifacts panel)
      (setq emacs-jupyter-notebook-panel--entries nil)
      (setq emacs-jupyter-notebook-panel--history-evicted-p nil)
      (cl-incf emacs-jupyter-notebook-panel--generation)
      (emacs-jupyter-notebook-panel--invalidate-structure panel))))

(defun ejn-panel-start-entry (panel cell-key code)
  "Begin a new output entry in PANEL associated with CELL-KEY for CODE.
Return an entry handle.

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
                        :code (or code "")
                        :status 'running
                        :exec-count "*"
                        :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S")
                        ;; W16: ordered output segments — `(text . STRING)'
                        ;; and `(image . SPEC)' conses, rendered interleaved
                        ;; in arrival order like a real notebook cell.
                        :outputs nil
                        :pickle-open-timer nil
                        :pickle-open-token nil
                        :pending-clear nil)))
      (setq emacs-jupyter-notebook-panel--entries
            (append emacs-jupyter-notebook-panel--entries
                    (list (cons id entry))))
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
      (emacs-jupyter-notebook-panel--schedule-render panel nil t)
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

(defun ejn-panel-entry-text (handle-or-entry)
  "Return the concatenated text of all text segments, or \"\" when none.
HANDLE-OR-ENTRY is an entry handle plist (with a `:panel' key) or a raw
entry plist."
  (let ((entry (if (plist-get handle-or-entry :panel)
                   (ejn-panel-entry-snapshot handle-or-entry)
                 handle-or-entry)))
    (mapconcat #'cdr
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

(defun emacs-jupyter-notebook-panel--trim-outputs (outputs)
  "Return OUTPUTS with total text bounded by `...-result-max-bytes'.
Trims the OLDEST text first (drops leading segments, then truncates the
front of the first survivor) so the newest output is always retained.
Image segments are never dropped by the byte cap."
  (let ((max-bytes emacs-jupyter-notebook-result-max-bytes))
    (let ((total (cl-loop for seg in outputs
                          when (eq (car seg) 'text)
                          sum (string-bytes (cdr seg)))))
      (if (<= total max-bytes)
          outputs
        (let ((excess (- total max-bytes))
              keep)
          (dolist (seg outputs)
            (if (or (not (eq (car seg) 'text)) (<= excess 0))
                (push seg keep)
              (let ((bytes (string-bytes (cdr seg))))
                (cond
                 ((>= excess bytes) (cl-decf excess bytes)) ; drop whole segment
                 (t (push (cons 'text (emacs-jupyter-notebook--last-bytes
                                       (cdr seg) (- bytes excess)))
                          keep)
                    (setq excess 0))))))
          (nreverse keep))))))

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
        (setq entry (plist-put entry :mpl-pickle nil))
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
           (force-full (and (plist-get old-entry :pending-clear)
                            (cl-find 'image (plist-get old-entry :outputs)
                                     :key #'car)))
           (display-text (copy-sequence text)))
      (when face
        (add-face-text-property 0 (length display-text) face t display-text))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (setq entry (emacs-jupyter-notebook-panel--entry-after-pending-clear
                      panel entry))
         (let* ((outputs (plist-get entry :outputs))
                (last-seg (car (last outputs))))
           (if (and last-seg (eq (car last-seg) 'text))
               ;; Merge into the trailing text segment.
               (let ((new (concat (cdr last-seg) display-text)))
                 ;; Collapse carriage-return progress repaints (tqdm) so the
                 ;; panel shows the latest frame, not every intermediate one.
                 (when (string-search "\r" display-text)
                   (setq new (emacs-jupyter-notebook--apply-carriage-returns new)))
                 (setcdr last-seg new))
             (setq outputs
                   (append outputs
                           (list (cons 'text
                                       (if (string-search "\r" display-text)
                                           (emacs-jupyter-notebook--apply-carriage-returns
                                            display-text)
                                         display-text))))))
           (setq entry (plist-put entry :outputs
                                  (emacs-jupyter-notebook-panel--trim-outputs
                                   outputs)))
           (setq entry (plist-put entry :pending-clear nil))
           entry))
       force-full)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

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
                                (list (cons 'text (or text "")))))
         (setq entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                      entry))
         (setq entry (plist-put entry :mpl-pickle nil))
         (setq entry (plist-put entry :pending-clear nil))
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
             (let ((outputs (plist-get entry :outputs)))
               (setq entry (plist-put entry :outputs
                                      (append outputs
                                              (list (cons 'image stored)))))
               (setq entry (plist-put entry :pending-clear nil))
               entry))
           t)
          (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))))

(defun ejn-panel-update-image (handle image-spec)
  "Replace the LAST image segment on HANDLE's entry with IMAGE-SPEC.
Appends when the entry has no image yet.  W16: this is the
`update_display_data' semantic — the kernel is updating an existing
display in place (e.g. an animation frame), not adding a new output —
so text segments are left untouched and no new segment is created."
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
             (let* ((outputs (plist-get entry :outputs))
                    (last-image (cl-find 'image (reverse outputs) :key #'car)))
               (if last-image
                   (progn
                     (emacs-jupyter-notebook-panel--retire-image
                      panel (cdr last-image))
                     (setcdr last-image stored))
                 (setq outputs (append outputs (list (cons 'image stored)))))
               (setq entry (plist-put entry :outputs outputs))
               (setq entry (plist-put entry :pending-clear nil))
               entry))
           t)
          (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))))

(defun ejn-panel-finish-entry (handle status execution-count)
  "Mark HANDLE's entry as completed with STATUS and EXECUTION-COUNT."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (setq entry (plist-put entry :status (or status 'ok)))
       (when execution-count
         (setq entry (plist-put entry :exec-count execution-count)))
       entry))
    (emacs-jupyter-notebook-panel-flush-now (plist-get handle :panel))))

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
           (setq entry (plist-put entry :mpl-pickle nil))
           (setq entry (plist-put entry :pending-clear nil))
           entry))
       (not wait)))))

(defun emacs-jupyter-notebook-panel--prune-pickles (panel)
  "Drop the matplotlib pickle from all but the newest N entries in PANEL.
A5: `panel--entries' is append-only history and each `:mpl-pickle' is a
multi-MB base64 string, so without bounding, an image-heavy session (re-run
an `imshow' cell many times) retains every pickle and grows Emacs's heap
without limit.  Only the interactive payload is dropped from older entries;
their PNG thumbnail and text are untouched.  A non-positive
`emacs-jupyter-notebook-panel-max-pickles' disables pruning."
  (let ((max emacs-jupyter-notebook-panel-max-pickles))
    (when (and (buffer-live-p panel) (integerp max) (> max 0))
      (with-current-buffer panel
        (let ((kept 0))
          ;; Newest entries are appended to the end; walk newest-first.
          (dolist (cell (reverse emacs-jupyter-notebook-panel--entries))
            (when (plist-get (cdr cell) :mpl-pickle)
              (if (< kept max)
                  (setq kept (1+ kept))
                (let ((entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                              (cdr cell))))
                  (setcdr cell (plist-put entry :mpl-pickle nil)))))))))))

(defun ejn-panel-set-pickle (handle base64)
  "Stash BASE64 matplotlib-pickle payload on HANDLE's entry.
W8.2: stored under `:mpl-pickle' independently of the rendered content or
image, so the PNG thumbnail path is untouched.  The interactive viewer
(W8.5) reads this field to reopen the figure locally.  A nil BASE64 is a
no-op.  A5: after stashing, prune pickles beyond the newest N entries."
  (when (and (ejn-panel-entry-live-p handle) base64)
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
         (plist-put entry :mpl-pickle base64))
       force-full)
      (emacs-jupyter-notebook-panel--prune-pickles panel)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

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
         (plist-put entry :mpl-pickle nil))
       force-full)
      (emacs-jupyter-notebook-panel--enforce-retention-budgets panel))))

(defun ejn-panel-entry-pickle (handle)
  "Return the base64 matplotlib-pickle payload stashed on HANDLE's entry, or nil."
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

(defun emacs-jupyter-notebook--cell-key-for (position)
  "Return a cell key for the cell whose marker line begins at POSITION.
The returned key is `(FILE-NAME . ID)' where ID is stable across edits to
this buffer: re-evaluating the same cell after inserting or deleting text
above it yields an `equal' key."
  (unless emacs-jupyter-notebook--cell-key-markers
    (setq emacs-jupyter-notebook--cell-key-markers
          (make-hash-table :test 'eq)))
  (let* ((file (or (buffer-file-name) (buffer-name)))
         (line-start (save-excursion
                       (goto-char (max (point-min)
                                       (min (point-max) position)))
                       (line-beginning-position)))
         (existing-id nil))
    (maphash (lambda (id marker)
               (when (and (null existing-id)
                          (markerp marker)
                          (eq (marker-buffer marker) (current-buffer))
                          (= (marker-position marker) line-start))
                 (setq existing-id id)))
             emacs-jupyter-notebook--cell-key-markers)
    (unless existing-id
      (setq existing-id (cl-incf emacs-jupyter-notebook--cell-key-next-id))
      (let ((m (copy-marker line-start t)))
        (set-marker-insertion-type m t)
        (puthash existing-id m emacs-jupyter-notebook--cell-key-markers)))
    (cons file existing-id)))

;;; View toggle / navigation (W2.3, W2.6)

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
  (emacs-jupyter-notebook-panel-flush-now (current-buffer))
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
subsequent panel re-renders, and point is restored after the re-render.
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
      (let* ((raw (plist-get (cdr image) :scale))
             (scale (if (numberp raw) raw 1.0))
             (new-scale (max 0.05 (* scale factor)))
             (props (cl-loop for (k v) on (cdr image) by #'cddr
                             unless (memq k '(:scale :max-width :max-height))
                             collect k and collect v))
             (new-image (cons 'image (append props (list :scale new-scale)))))
        (ignore-errors (image-flush image))
        ;; Mutate the segment in place; the entry list structure is shared
        ;; with the stored entry, so the new spec persists across renders.
        (setcdr seg new-image)
        (let ((pos (point)))
          (emacs-jupyter-notebook-panel--render (current-buffer))
          (goto-char (min pos (point-max))))))))

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
      ('queued "…")
      (_ ""))))

(defun emacs-jupyter-notebook--fringe-face (state)
  "Return the face symbol for indicator STATE."
  (pcase state
    ('running 'emacs-jupyter-notebook-fringe-running-face)
    ('ok 'emacs-jupyter-notebook-fringe-ok-face)
    ('error 'emacs-jupyter-notebook-fringe-error-face)
    ('queued 'emacs-jupyter-notebook-fringe-queued-face)
    (_ 'default)))

(defun emacs-jupyter-notebook-fringe-set (cell-key state &optional exec-count)
  "Set the source-buffer fringe indicator for CELL-KEY to STATE.
EXEC-COUNT is the execution count (used by the `ok' state).
The cell key id is resolved against the buffer-local marker table so the
indicator follows the cell even after edits above it.  If no marker is
registered for the id and the cdr is a plain integer, that integer is
treated as a literal buffer position (test convenience)."
  (when (and cell-key (buffer-live-p (current-buffer)))
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

(declare-function emacs-jupyter-notebook-open-figure-with-pickle
                  "emacs-jupyter-notebook" (base64))

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

(defun emacs-jupyter-notebook-panel--spawn-external-opener (command file)
  "Start COMMAND asynchronously with FILE appended to its argv."
  (let ((program (car command)))
    (unless (and program
                 (or (and (file-name-absolute-p program)
                          (file-executable-p program))
                     (executable-find program)))
      (user-error
       "No external image opener found; customize `%s'"
       'emacs-jupyter-notebook-external-image-viewer-command))
    (make-process
     :name (generate-new-buffer-name "ejn-image-viewer")
     :buffer nil
     :command (append command (list file))
     :connection-type 'pipe
     :noquery t
     :sentinel (lambda (process _event)
                 (unless (process-live-p process)
                   (delete-process process))))))

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

(defun emacs-jupyter-notebook-panel-open-image-externally ()
  "Open the original static image at point in an external application."
  (interactive)
  (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (user-error "Not in an EJN output panel"))
  (let* ((image (emacs-jupyter-notebook-panel--image-at-point))
         (file (and image (plist-get (cdr image) :file))))
    (unless image
      (user-error "No image on this entry"))
    (unless (and (stringp file) (file-readable-p file))
      (user-error "Image original is unavailable"))
    (funcall emacs-jupyter-notebook-panel-external-open-function file)))

(defun emacs-jupyter-notebook-panel--entry-pickle-at-point ()
  "Return the matplotlib pickle stashed on the panel entry at point, or nil."
  (let ((id (emacs-jupyter-notebook-panel--entry-id-at-point)))
    (when id
      (plist-get (emacs-jupyter-notebook-panel--entry (current-buffer) id)
                 :mpl-pickle))))

(defun emacs-jupyter-notebook-panel-latest-pickle-for-cell (source-buffer cell-key)
  "Return the newest pickle stashed for CELL-KEY in SOURCE-BUFFER's panel.
Returns nil when no matching entry carries a pickle payload."
  (let ((panel (emacs-jupyter-notebook-panel-buffer source-buffer)))
    (when (buffer-live-p panel)
      (with-current-buffer panel
        (let (found)
          (dolist (cell emacs-jupyter-notebook-panel--entries)
            (let ((entry (cdr cell)))
              (when (and (equal (plist-get entry :cell-key) cell-key)
                         (plist-get entry :mpl-pickle))
                (setq found (plist-get entry :mpl-pickle)))))
          found)))))

(defun emacs-jupyter-notebook-panel-open-figure ()
  "Open the figure of the panel entry at point interactively (W8.5).
Signals a `user-error' when point is not on an entry that carries a
matplotlib pickle payload."
  (interactive)
  (unless (derived-mode-p 'emacs-jupyter-notebook-panel-mode)
    (user-error "Not in an EJN output panel"))
  (let ((base64 (emacs-jupyter-notebook-panel--entry-pickle-at-point)))
    (unless base64
      (user-error "No interactive figure on this entry (no pickle payload)"))
    (emacs-jupyter-notebook-open-figure-with-pickle base64)))

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
