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
;;   (:panel PANEL :id N :cell-key KEY)
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

(defun emacs-jupyter-notebook--select-mime-type (data)
  "Select the best MIME type from DATA plist.
Return (cons mime-type content) or nil."
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
  :status running|ok|error
  :exec-count INTEGER-or-\"*\"
  :timestamp ISO-string
  :content STRING
  :image IMAGE-SPEC-or-nil
  :pending-clear BOOL")

(defvar-local emacs-jupyter-notebook-panel--next-id 0
  "Monotonic id counter for new entries.")

(defvar-local emacs-jupyter-notebook-panel--view 'latest
  "Current view: `latest' or `history'.")

(defvar-local emacs-jupyter-notebook-panel--flush-timer nil
  "Pending flush timer for streaming throttle.")

(defvar-local emacs-jupyter-notebook-panel--dirty nil
  "Non-nil when the panel needs a redisplay.")

(defvar-local emacs-jupyter-notebook-panel--render-count 0
  "Counter incremented every time the panel re-renders.  Test instrument.")

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

(defun emacs-jupyter-notebook-panel--on-kill ()
  "Cancel any pending flush timer when the panel buffer is killed."
  (when (timerp emacs-jupyter-notebook-panel--flush-timer)
    (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
  (setq emacs-jupyter-notebook-panel--flush-timer nil))

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
  (list :panel panel :id id :cell-key key))

(defun emacs-jupyter-notebook-panel--update-entry (handle updater)
  "Apply UPDATER to the entry referenced by HANDLE and schedule a render.
UPDATER is called with the current entry plist and must return a new plist."
  (when handle
    (let ((panel (plist-get handle :panel))
          (id (plist-get handle :id)))
      (when (buffer-live-p panel)
        (let ((entry (emacs-jupyter-notebook-panel--entry panel id)))
          (when entry
            (let ((new (funcall updater entry)))
              (emacs-jupyter-notebook-panel--set-entry panel id new)
              (emacs-jupyter-notebook-panel--schedule-render panel))))))))

;;; Render scheduling (W2.4 throttle)

(defun emacs-jupyter-notebook-panel--schedule-render (panel)
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
      (unless (timerp emacs-jupyter-notebook-panel--flush-timer)
        (let ((delay (/ (max 0 emacs-jupyter-notebook-panel-stream-throttle-ms)
                        1000.0)))
          (setq emacs-jupyter-notebook-panel--flush-timer
                (run-at-time
                 delay nil
                 #'emacs-jupyter-notebook-panel--flush panel)))))))

(defun emacs-jupyter-notebook-panel--flush (panel)
  "Flush pending changes for PANEL by re-rendering."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (setq emacs-jupyter-notebook-panel--flush-timer nil)
      (when emacs-jupyter-notebook-panel--dirty
        (setq emacs-jupyter-notebook-panel--dirty nil)
        (emacs-jupyter-notebook-panel--render panel)))))

(defun emacs-jupyter-notebook-panel-flush-now (panel)
  "Force PANEL to render immediately, cancelling any pending throttle timer."
  (when (buffer-live-p panel)
    (with-current-buffer panel
      (when (timerp emacs-jupyter-notebook-panel--flush-timer)
        (cancel-timer emacs-jupyter-notebook-panel--flush-timer))
      (setq emacs-jupyter-notebook-panel--flush-timer nil)
      (setq emacs-jupyter-notebook-panel--dirty nil)
      (emacs-jupyter-notebook-panel--render panel))))

;;; Rendering

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

(defun emacs-jupyter-notebook-panel--render (panel)
  "Render PANEL contents according to current view.
History view auto-scrolls to the bottom of the buffer so the newest
entry is visible; latest-per-cell view goes to the top."
  (with-current-buffer panel
    (let ((inhibit-read-only t)
          (entries (emacs-jupyter-notebook-panel--visible-entries)))
      (erase-buffer)
      (cl-incf emacs-jupyter-notebook-panel--render-count)
      (insert (propertize
               (format "Output panel — view: %s   (H toggle, RET visit, q bury)\n\n"
                       emacs-jupyter-notebook-panel--view)
               'face 'emacs-jupyter-notebook-result-header-face))
      (dolist (e entries)
        (insert (emacs-jupyter-notebook-panel--format-header e))
        (let ((image (plist-get e :image))
              (content (or (plist-get e :content) "")))
          (cond
           (image
            (insert (propertize " " 'display image))
            (insert "\n"))
           ((not (string-empty-p content))
            (let ((c (copy-sequence content)))
              (add-face-text-property
               0 (length c) 'emacs-jupyter-notebook-result-face 'append c)
              (insert c)
              (unless (string-suffix-p "\n" c)
                (insert "\n"))))
           (t nil)))
        (insert "\n"))
      (if (eq emacs-jupyter-notebook-panel--view 'history)
          (goto-char (point-max))
        (goto-char (point-min))))))

;;; Public API

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
                        :content ""
                        :image nil
                        :pending-clear nil)))
      (setq emacs-jupyter-notebook-panel--entries
            (append emacs-jupyter-notebook-panel--entries
                    (list (cons id entry))))
      (emacs-jupyter-notebook-panel--schedule-render panel)
      (emacs-jupyter-notebook-panel--handle panel id cell-key))))

(defun ejn-panel-append-text (handle text &optional face)
  "Append TEXT (optionally propertized with FACE) to HANDLE's entry.
When TEXT already carries `face' text-properties (e.g. from
`ansi-color-apply' on a Python traceback), FACE is composed via
`add-face-text-property' with append priority so per-character ANSI
colours are preserved and uncoloured spans still get the fallback FACE."
  (when (and handle text)
    (let ((display-text (copy-sequence text)))
      (when face
        (add-face-text-property 0 (length display-text) face t display-text))
      (emacs-jupyter-notebook-panel--update-entry
       handle
       (lambda (entry)
         (let* ((pending (plist-get entry :pending-clear))
                (current (or (plist-get entry :content) ""))
                (new (if pending display-text (concat current display-text)))
                (max-bytes emacs-jupyter-notebook-result-max-bytes))
           (when (> (string-bytes new) max-bytes)
             (setq new (emacs-jupyter-notebook--last-bytes new max-bytes)))
           (setq entry (plist-put entry :content new))
           (setq entry (plist-put entry :image nil))
           (setq entry (plist-put entry :pending-clear nil))
           entry))))))

(defun ejn-panel-replace-text (handle text)
  "Replace HANDLE's entry content with TEXT."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (setq entry (plist-put entry :content (or text "")))
       (setq entry (plist-put entry :image nil))
       (setq entry (plist-put entry :pending-clear nil))
       entry))))

(defun ejn-panel-set-image (handle image-spec)
  "Set HANDLE's entry to display IMAGE-SPEC and clear text content."
  (when handle
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (setq entry (plist-put entry :image image-spec))
       (setq entry (plist-put entry :content ""))
       (setq entry (plist-put entry :pending-clear nil))
       entry))))

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
    (emacs-jupyter-notebook-panel--update-entry
     handle
     (lambda (entry)
       (if wait
           (plist-put entry :pending-clear t)
         (setq entry (plist-put entry :content ""))
         (setq entry (plist-put entry :image nil))
         (setq entry (plist-put entry :pending-clear nil))
         entry)))))

(defun ejn-panel-entry-snapshot (handle)
  "Return the entry plist for HANDLE (debug/test introspection)."
  (and handle
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

(defun emacs-jupyter-notebook-panel--image-at-point ()
  "Return the image spec on display at point, or nil."
  (or (get-text-property (point) 'display)
      (let ((next (next-single-property-change (point) 'display)))
        (when next (get-text-property next 'display)))))

(defun emacs-jupyter-notebook-panel--scale-image-at-point (factor)
  "Scale the image at point in the panel by FACTOR (multiplicative)."
  (let ((image (emacs-jupyter-notebook-panel--image-at-point)))
    (when (and image (consp image) (eq (car image) 'image))
      (let* ((scale (or (image-property image :scale) 1.0))
             (new-scale (max 0.05 (* scale factor))))
        (setf (image-property image :scale) new-scale)
        (force-window-update (current-buffer))))))

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
  (let* ((id (get-text-property (point) 'emacs-jupyter-notebook-entry-id))
         (key (get-text-property (point) 'emacs-jupyter-notebook-cell-key))
         (source emacs-jupyter-notebook-panel--source-buffer))
    (unless id
      (user-error "Point is not on an entry header"))
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
