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
(require 'emacs-jupyter-notebook-artifacts)

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
`image/png'; helper-published pickle files are admitted through the panel
artifact API and never appear in this MIME plist."
  (cond
   ((plist-get data :image/png)
    (cons :image/png (plist-get data :image/png)))
   ((plist-get data :image/jpeg)
    (cons :image/jpeg (plist-get data :image/jpeg)))
   ((plist-get data :text/plain)
    (cons :text/plain (plist-get data :text/plain)))
   (t nil)))

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
  :status queued|running|ok|error|cancelled|outcome-unknown
  :exec-count INTEGER-or-\"*\"
  :timestamp ISO-string
  :outputs ordered text/image segments
  :mpl-pickle confined metadata plist or nil
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

(defconst emacs-jupyter-notebook-panel--max-published-original-bytes 67108864
  "Maximum bytes retained for one compressed external-viewer original.")

(defconst emacs-jupyter-notebook-panel--max-published-preview-bytes 4194304
  "Maximum byte length of a canonical helper-generated PPM preview.")

(defconst emacs-jupyter-notebook-panel--hard-image-pixels 4194304
  "Immutable helper protocol pixel ceiling for native image previews.")

(defconst emacs-jupyter-notebook-panel--max-published-pickle-bytes 67108864
  "Maximum bytes accepted for one helper-published matplotlib pickle.
This finite ceiling matches the helper's decoded artifact ceiling.")

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
            (let ((old-text (emacs-jupyter-notebook-panel--entry-text-bytes entry))
                  (old-artifacts (emacs-jupyter-notebook-panel--entry-artifact-bytes entry))
                  (new (funcall updater entry)))
              (with-current-buffer panel
                (cl-incf emacs-jupyter-notebook-panel--retained-text-bytes
                         (- (emacs-jupyter-notebook-panel--entry-text-bytes new) old-text))
                (cl-incf emacs-jupyter-notebook-panel--retained-artifact-bytes
                         (- (emacs-jupyter-notebook-panel--entry-artifact-bytes new)
                            old-artifacts)))
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

(defun emacs-jupyter-notebook-panel--native-image-safe-p (image)
  "Return non-nil when IMAGE may reach an Emacs native image API.
Legacy image specs have no helper publication root and retain their existing
rendering path.  A helper-published image is native-safe only through its
separate canonical PPM preview; its compressed original is never examined.
The PPM bytes and digest are checked once at admission.  This last-boundary
check revalidates only pinned identity, ownership, mode, and size so repeated
redisplay cannot turn into multi-megabyte file reads on Emacs's UI thread."
  (let ((props (and (consp image) (cdr image))))
    (if (not (plist-member props :ejn-publication-root))
        t
      (let* ((preview (plist-get props :ejn-preview))
             (path (plist-get props :file))
             (width (and preview (plist-get preview :width)))
             (height (and preview (plist-get preview :height))))
        (and (listp preview)
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
                         (plist-get preview :artifact-capability))))
                   (equal (plist-get checked :identity)
                          (plist-get preview :identity)))
               (error nil)))))))

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
             (list :scale (plist-get props :scale)))
           (when (plist-member props :max-width)
             (list :max-width (plist-get props :max-width)))
           (when (plist-member props :max-height)
             (list :max-height (plist-get props :max-height)))))))))

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
         (max emacs-jupyter-notebook-panel-max-inline-images))
    (if (and (integerp max) (> max 0))
        (let ((safe (cl-remove-if-not
                     #'emacs-jupyter-notebook-panel--inline-image-admitted-p specs)))
          (last safe (min max (length safe))))
      nil)))

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
          (if (and emacs-jupyter-notebook-panel-slice-images
                   (display-graphic-p))
              (condition-case nil
                  (let* ((height (cdr (image-size native t)))
                         (rows (max 1 (ceiling height (frame-char-height)))))
                    (insert-sliced-image native " " nil rows 1))
                (error (insert (propertize " " 'display native))))
            (insert (propertize " " 'display native))))))
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
                     ('cancelled "cancelled")
                     ('outcome-unknown "outcome unknown")
                     (_ (format "%s" status)))))
    (propertize
     (format "[%s] %s [%s] %s\n" count ts status-s title)
     'face 'emacs-jupyter-notebook-result-header-face
     'emacs-jupyter-notebook-entry-id (plist-get entry :id)
     'emacs-jupyter-notebook-cell-key (plist-get entry :cell-key))))

(defun emacs-jupyter-notebook-panel--text-state-p (value)
  "Return non-nil when VALUE is the internal streamed text representation."
  (and (listp value) (plist-member value :chunks)))

(defun emacs-jupyter-notebook-panel--make-text-state (text)
  "Return a chunked text state initialized with TEXT."
  (let* ((chunk (or text ""))
         (chunks (and (not (string-empty-p chunk)) (list chunk))))
    (list :chunks chunks
          :tail chunks
          :bytes (string-bytes chunk)
          :cache nil
          :pending (and (not (string-empty-p chunk)) (list chunk))
          :ends-newline (string-suffix-p "\n" chunk)
          :rendered-ends-newline nil)))

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
  "Append TEXT to STATE in amortized constant time and return STATE."
  (unless (string-empty-p text)
    (let ((cell (list text)))
      (if-let ((tail (plist-get state :tail)))
          (setcdr tail cell)
        (setq state (plist-put state :chunks cell)))
      (setq state (plist-put state :tail cell))
      (setq state (plist-put state :pending
                             (cons text (plist-get state :pending))))
      (setq state (plist-put state :bytes
                             (+ (plist-get state :bytes) (string-bytes text))))
      (setq state (plist-put state :cache nil))
      (setq state (plist-put state :ends-newline (string-suffix-p "\n" text))))
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
            (setq state (plist-put state :chunks (cdr chunks)))
            (setq state (plist-put state :bytes (- (plist-get state :bytes)
                                                    chunk-bytes)))
            (setq bytes (- bytes chunk-bytes))
            (when (null (cdr chunks))
              (setq state (plist-put state :tail nil))))
        (let ((kept (emacs-jupyter-notebook--last-bytes
                     chunk (- chunk-bytes bytes))))
          (setcar chunks kept)
          (setq state (plist-put state :bytes
                                 (- (plist-get state :bytes)
                                    (- chunk-bytes (string-bytes kept)))))
          (setq bytes 0)))))
  (setq state (plist-put state :cache nil))
  ;; Trimming always schedules a structural render, so stale incremental
  ;; chunks must not keep pre-cap stream strings alive until that render.
  (setq state (plist-put state :pending nil))
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
        (setq state (plist-put state :rendered-ends-newline
                               (plist-get state :ends-newline)))
        (setcdr segment state)))))

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
         (emacs-jupyter-notebook-panel--insert-text-segment seg index)))))
  (insert "\n")
  (plist-put entry :stream-dirty-p nil))

(defun emacs-jupyter-notebook-panel--render-stream-suffix (entry bounds)
  "Insert ENTRY's pending trailing text chunks at BOUNDS without rebuilding it.
Return non-nil when the existing rendered text segment could be extended."
  (let* ((segments (plist-get entry :outputs))
         (index (1- (length segments)))
         (segment (car (last segments)))
         (state (and segment (cdr segment))))
    (when (and (eq (car-safe segment) 'text)
               (emacs-jupyter-notebook-panel--text-state-p state)
               (plist-get state :pending))
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
            (setq state (plist-put state :rendered-ends-newline new-ends-newline))
            (setcdr segment state)
            (plist-put entry :stream-dirty-p nil)
            t))))))

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
Specs that already refer to a file, or do not contain string data, are
returned unchanged.  The file is mode 0600 and written without coding."
  (let ((data (and (consp image) (plist-get (cdr image) :data))))
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

(defun emacs-jupyter-notebook-panel--published-artifact-metadata
    (root path sha256 size root-identity limit &optional ppm width height capability)
  "Validate one pinned publication and return metadata for later retirement.
When PPM is non-nil, only its bounded canonical header and declared total
length are checked before a native image spec is created.  The trusted local
helper parent already validated the complete worker output and SHA-256 before
publication.  Original compressed files deliberately skip content reads here;
they are copied and revalidated outside the UI thread before external opening."
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
          :artifact-capability capability)))

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
      (when (emacs-jupyter-notebook-panel--delete-published-artifact pickle)
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
     handle (emacs-jupyter-notebook-panel--published-pickle
             root path sha256 size root-identity))))

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
        (let ((pickle-meta
               (and pickle
                    (emacs-jupyter-notebook-panel--published-pickle
                     (plist-get pickle :root) (plist-get pickle :path)
                     (plist-get pickle :sha256) (plist-get pickle :size)
                     (plist-get pickle :root-identity)
                     (plist-get pickle :artifact-capability))))
              (image-spec
               (and image
                    (emacs-jupyter-notebook-panel--published-image-bundle-spec
                     image)))
              (panel (plist-get effective :panel))
              (old-entry (ejn-panel-entry-snapshot effective))
              old-images old-pickle old-timer replace-pickle-p new-entry committed)
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
                (setq new
                      (emacs-jupyter-notebook-panel--entry-reset-output-accounting
                       new)))
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
                            (setq old-images (list (cdr matching)))
                            (setcdr matching image-spec))
                        ;; clear_output(wait=True) deliberately turns the next
                        ;; update into the first new output segment.
                        (setq outputs
                              (append outputs (list (cons 'image image-spec))))))
                  (setq outputs
                        (append outputs (list (cons 'image image-spec))))))
              (setq new (plist-put new :outputs outputs))
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
                            (emacs-jupyter-notebook-panel--entry-artifact-bytes old-entry))))
              (emacs-jupyter-notebook-panel--set-entry
               panel (plist-get effective :id) new-entry)
              (setq committed t)
              (condition-case err
                  (emacs-jupyter-notebook-panel--schedule-render
                   panel (plist-get effective :id) t)
                (error
                 (message "emacs-jupyter-notebook: panel render scheduling failed: %s"
                          (error-message-string err)))))
            (when committed
              ;; Retirement is intentionally after the entry swap.  Any
              ;; validation or construction error above leaves these live.
              (dolist (old-image old-images)
                (emacs-jupyter-notebook-panel--retire-image panel old-image))
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
  "Retire ARTIFACT through its identity-bound local capability."
  (when (listp artifact)
    (let ((capability (plist-get artifact :artifact-capability)))
      (if (hash-table-p emacs-jupyter-notebook-panel--bulk-published-deletions)
          (let ((file (plist-get artifact :file))
                (identity (plist-get artifact :identity)))
            (when (and identity
                       (emacs-jupyter-notebook-artifacts-capability-valid-p capability))
              (let* ((key (cons (emacs-jupyter-notebook-artifacts-capability-root capability)
                                (emacs-jupyter-notebook-artifacts-capability-root-identity capability)))
                     (bucket (gethash key emacs-jupyter-notebook-panel--bulk-published-deletions)))
                (puthash key (list capability (cons (cons file identity) (cadr bucket)))
                         emacs-jupyter-notebook-panel--bulk-published-deletions)
                t)))
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
  "Perform every helper publication batch in TABLE once per root."
  (when (hash-table-p table)
    (maphash
     (lambda (_key bucket)
       (ignore-errors
         (emacs-jupyter-notebook-artifacts-delete-leaves
          (car bucket) (delete-dups (nreverse (cadr bucket))))))
     table)))

(defun emacs-jupyter-notebook-panel--retire-original-if-released (image)
  "Delete IMAGE's original after both entry retirement and opener release."
  (let ((props (cdr image)))
    (when (and (plist-get props :ejn-retired)
               (<= (or (plist-get props :ejn-original-open-leases) 0) 0))
      (emacs-jupyter-notebook-panel--delete-published-artifact
       (plist-get props :ejn-original)))))

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
  "Retire every image spec in OUTPUTS owned by PANEL."
  (dolist (seg outputs)
    (when (eq (car seg) 'image)
      (emacs-jupyter-notebook-panel--retire-image panel (cdr seg)))))

(defun emacs-jupyter-notebook-panel--entry-text-bytes (entry)
  "Return the retained source and output text byte count for ENTRY."
  (or (plist-get entry :retained-text-bytes) 0))

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
              when (eq (car segment) 'image)
              ;; Image segments are `(image . IMAGE-SPEC)', so the image
              ;; symbol in IMAGE-SPEC precedes its property list.
              sum (or (plist-get (cdr (cdr segment)) :ejn-artifact-bytes) 0))
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

(defun emacs-jupyter-notebook-panel--total-text-bytes ()
  "Return the total retained text byte count in the current panel."
  emacs-jupyter-notebook-panel--retained-text-bytes)

(defun emacs-jupyter-notebook-panel--total-artifact-bytes ()
  "Return the total retained image and MIME artifact bytes in this panel."
  emacs-jupyter-notebook-panel--retained-artifact-bytes)

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
    (cl-decf emacs-jupyter-notebook-panel--retained-text-bytes
             (emacs-jupyter-notebook-panel--entry-text-bytes entry))
    (cl-decf emacs-jupyter-notebook-panel--retained-artifact-bytes
             (emacs-jupyter-notebook-panel--entry-artifact-bytes entry))
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
            (deferred-capabilities (make-hash-table :test #'eq)))
        (dolist (cell emacs-jupyter-notebook-panel--entries)
          (let ((outputs (plist-get (cdr cell) :outputs)))
            (emacs-jupyter-notebook-panel--retire-outputs panel outputs)
            (dolist (segment outputs)
              (when (eq (car segment) 'image)
                (when-let ((original (plist-get (cdr (cdr segment))
                                                 :ejn-original)))
                  (unless (plist-get original :deleted)
                    (when-let ((capability
                                (plist-get original :artifact-capability)))
                      (puthash capability t deferred-capabilities)))))))
          (let ((entry (emacs-jupyter-notebook-panel--cancel-pickle-open-timer
                        (cdr cell))))
            (let ((pickle (plist-get entry :mpl-pickle)))
              (emacs-jupyter-notebook-panel--retire-pickle pickle)
              (when (and pickle (not (plist-get pickle :deleted)))
                (when-let ((capability (plist-get pickle :artifact-capability)))
                  (puthash capability t deferred-capabilities))))
            (setcdr cell (plist-put entry :mpl-pickle nil))))
        (emacs-jupyter-notebook-panel--flush-bulk-published-deletions
         emacs-jupyter-notebook-panel--bulk-published-deletions)
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
            emacs-jupyter-notebook-panel--retained-artifact-bytes 0))))

(defun ejn-panel-clear-all (panel)
  "Retire all PANEL artifacts and entries, invalidating their handles."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (emacs-jupyter-notebook-panel--retire-all-artifacts panel)
      (setq emacs-jupyter-notebook-panel--entries nil)
      (setq emacs-jupyter-notebook-panel--retained-text-bytes 0
            emacs-jupyter-notebook-panel--retained-artifact-bytes 0)
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
                        :output-text-bytes 0
                        :retained-text-bytes (string-bytes (or code ""))
                        :artifact-bytes 0
                        :pickle-open-timer nil
                        :pickle-open-token nil
                        :pending-clear nil)))
      (setq emacs-jupyter-notebook-panel--entries
            (append emacs-jupyter-notebook-panel--entries
                    (list (cons id entry))))
      (cl-incf emacs-jupyter-notebook-panel--retained-text-bytes
               (plist-get entry :retained-text-bytes))
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
  (plist-put entry :artifact-bytes 0))

(defun emacs-jupyter-notebook-panel--entry-trim-text (entry)
  "Trim ENTRY's oldest text chunks to its per-entry byte budget."
  (let ((old-total (plist-get entry :output-text-bytes))
        (removed 0)
        (excess (- (plist-get entry :output-text-bytes)
                   emacs-jupyter-notebook-result-max-bytes)))
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
           (if (and last-seg (eq (car last-seg) 'text)
                    ;; A display-id segment is replaceable independently of
                    ;; ordinary stream output; never merge later streams into it.
                    (not (and (emacs-jupyter-notebook-panel--text-state-p (cdr last-seg))
                              (plist-get (cdr last-seg) :display-id))))
               (if carriage-p
                   ;; Carriage returns rewrite an existing terminal line.  They
                   ;; are uncommon; materialize once to preserve exact W14 semantics.
                   (let ((resolved (emacs-jupyter-notebook--apply-carriage-returns
                                    (concat (emacs-jupyter-notebook-panel--text-state-value
                                             last-seg)
                                            display-text))))
                     (setq after (+ (- before
                                       (emacs-jupyter-notebook-panel--text-segment-bytes
                                        last-seg))
                                    (string-bytes resolved)))
                     (setcdr last-seg (emacs-jupyter-notebook-panel--make-text-state resolved))
                     (setq force-full t))
                 (let ((state (cdr last-seg)))
                   (unless (emacs-jupyter-notebook-panel--text-state-p state)
                     (setq state (emacs-jupyter-notebook-panel--make-text-state state)))
                   (setcdr last-seg
                           (emacs-jupyter-notebook-panel--text-state-append
                            state display-text))
                   (setq after (+ after (string-bytes display-text)))))
             (let ((state (emacs-jupyter-notebook-panel--make-text-state
                           (if carriage-p
                               (emacs-jupyter-notebook--apply-carriage-returns display-text)
                             display-text))))
               (setq outputs (nconc outputs (list (cons 'text state))))
               (setq after (+ after (string-bytes (if carriage-p
                                                        (emacs-jupyter-notebook--apply-carriage-returns display-text)
                                                      display-text))))))
           (setq entry (plist-put entry :outputs outputs))
           (setq entry (plist-put entry :output-text-bytes after))
           (setq entry (plist-put entry :retained-text-bytes
                                  (+ (string-bytes (or (plist-get entry :code) "")) after)))
           (when (> (plist-get entry :output-text-bytes)
                    emacs-jupyter-notebook-result-max-bytes)
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
         (let ((outputs (plist-get entry :outputs)))
           (setq entry (plist-put entry :outputs
                                  (append outputs
                                          (list (cons 'text
                                                      (plist-put
                                                       (emacs-jupyter-notebook-panel--make-text-state text)
                                                       :display-id display-id))))))
           (setq entry (plist-put entry :output-text-bytes
                                  (+ (plist-get entry :output-text-bytes) (string-bytes text))))
           (setq entry (plist-put entry :retained-text-bytes
                                  (+ (string-bytes (or (plist-get entry :code) ""))
                                     (plist-get entry :output-text-bytes))))
           (plist-put entry :pending-clear nil)))
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
               (setq entry (plist-put entry :artifact-bytes
                                      (+ (plist-get entry :artifact-bytes)
                                         (or (plist-get (cdr stored) :ejn-artifact-bytes) 0))))
               (setq entry (plist-put entry :pending-clear nil))
               entry))
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
           (effective-handle (if target (car target) handle)))
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
                 (if last-image
                     (progn
                       (emacs-jupyter-notebook-panel--retire-image
                        panel (cdr last-image))
                       (setcdr last-image stored))
                   (setq outputs (append outputs (list (cons 'image stored)))))
                 (setq entry (plist-put entry :outputs outputs))
                 (setq entry
                       (plist-put
                        entry :artifact-bytes
                        (+ (- (plist-get entry :artifact-bytes)
                              (or old-image-bytes 0))
                           (or (plist-get (cdr stored) :ejn-artifact-bytes) 0))))
                 (setq entry (plist-put entry :pending-clear nil))
                 entry))
             t)
            (emacs-jupyter-notebook-panel--enforce-retention-budgets panel)
            t))))))

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

(defun ejn-panel-set-entry-status (handle status)
  "Set live HANDLE to nonterminal STATUS without fabricating an execution count.
Used by the serialized execution ledger to expose queued work before it is
actually dispatched to a kernel."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle (lambda (entry) (plist-put entry :status status)))))

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
      (unless (emacs-jupyter-notebook-panel--native-image-safe-p image)
        (user-error "Image is retained for external viewing only"))
      (let* ((raw (plist-get (cdr image) :scale))
             (scale (if (numberp raw) raw 1.0))
             (new-scale (max 0.05 (* scale factor)))
             (props (cl-loop for (k v) on (cdr image) by #'cddr
                             unless (memq k '(:scale :max-width :max-height))
                             collect k and collect v))
             (new-image (cons 'image (append props (list :scale new-scale)))))
        (when-let ((preview (emacs-jupyter-notebook-panel--native-preview-spec image)))
          (ignore-errors (image-flush preview)))
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

(defun emacs-jupyter-notebook-panel--verify-original-async
    (original snapshot callback)
  "Verify ORIGINAL into SNAPSHOT asynchronously, then call CALLBACK.
CALLBACK receives non-nil only after the exact verified bytes have been
durably copied into SNAPSHOT.  Return a no-argument cancellation function."
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
                   (finish (and (eq (process-status current) 'exit)
                                (= (process-exit-status current) 0)))))))
        (setq timer
              (run-at-time
               emacs-jupyter-notebook-panel--original-verify-timeout nil
               (lambda () (finish nil))))
        (lambda ()
          (unless settled
            (when (and (processp process) (process-live-p process))
              (delete-process process))
            (finish nil)))))))

(defvar emacs-jupyter-notebook-panel-original-verify-function
  #'emacs-jupyter-notebook-panel--verify-original-async
  "Function called with original, snapshot, and async boolean callback.
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
    (push snapshot emacs-jupyter-notebook-panel--external-image-snapshots)
    (plist-put
     snapshot :timer
     (run-at-time
      (max 1 emacs-jupyter-notebook-external-image-snapshot-ttl) nil
      #'emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot))
    snapshot))

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
         (finish (valid &optional quiet)
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
             (if (not valid)
                 (progn
                   (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                    snapshot)
                   (release-original)
                   (unless quiet
                     (message
                      "emacs-jupyter-notebook: image original failed verification")))
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
        ;; Legacy/local images are already ordinary local files and never carry
        ;; helper publication metadata.  Keep that non-blocking opener path.
        (let ((file (plist-get props :file)))
          (unless (and (stringp file) (file-readable-p file))
            (user-error "Image original is unavailable"))
          (funcall emacs-jupyter-notebook-panel-external-open-function file))
      (condition-case err
          (if-let ((cancel (plist-get props :ejn-original-open-cancel)))
              (progn
                (funcall cancel)
                (message "emacs-jupyter-notebook: cancelled pending image open"))
            (let ((limit emacs-jupyter-notebook-external-image-max-snapshots))
              (unless (and (integerp limit) (> limit 0))
                (user-error "External image snapshots are disabled"))
              (when (>= (+ emacs-jupyter-notebook-panel--external-image-pending-count
                           (length emacs-jupyter-notebook-panel--external-image-snapshots))
                        limit)
                (user-error "External image snapshot limit reached"))
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
