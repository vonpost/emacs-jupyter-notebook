;;; emacs-jupyter-notebook-result.el --- Inline result overlays  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: emacs-jupyter-notebook contributors
;; Keywords: tools, languages

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Package-owned result overlays.  These never alter visited source text.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

(defface emacs-jupyter-notebook-result-face
  '((t :inherit font-lock-doc-face))
  "Face used for inline text results."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-result-header-face
  '((t :inherit shadow))
  "Face used for inline result headers and scroll hints."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-result-error-face
  '((t :inherit error))
  "Face used for inline error results."
  :group 'emacs-jupyter-notebook)

(defface emacs-jupyter-notebook-execution-count-face
  '((t :inherit font-lock-comment-face))
  "Face used for execution count overlays."
  :group 'emacs-jupyter-notebook)

(defvar-local emacs-jupyter-notebook-result--overlays nil
  "Package-owned result overlays in the current buffer.")

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

(defun emacs-jupyter-notebook-result-set-image (ov image-spec)
  "Display IMAGE-SPEC in result overlay OV."
  (when (overlayp ov)
    (overlay-put ov 'emacs-jupyter-notebook-image image-spec)
    (overlay-put ov 'emacs-jupyter-notebook-content "")
    (overlay-put ov 'emacs-jupyter-notebook-scroll-offset 0)
    (overlay-put ov 'emacs-jupyter-notebook-running nil)
    (overlay-put ov 'emacs-jupyter-notebook-pending-clear nil)
    (emacs-jupyter-notebook-result--render ov)))

(defun emacs-jupyter-notebook-result--text (result)
  "Return a display string for RESULT."
  (let ((text (cond
               ((stringp result) result)
               ((and (listp result) (plist-get result :text/plain))
                (plist-get result :text/plain))
               ((and (listp result)
                     (plist-get result :data)
                     (plist-get (plist-get result :data) :text/plain))
                (plist-get (plist-get result :data) :text/plain))
               ((and (listp result) (plist-get result :ename))
                (format "%s: %s"
                        (plist-get result :ename)
                        (or (plist-get result :evalue) "")))
               (t (format "%S" result)))))
    text))

(defun emacs-jupyter-notebook-result--line-count (text)
  "Return the number of display lines in TEXT."
  (if (string-empty-p text)
      0
    (let ((count 1)
          (pos 0))
      (while (setq pos (string-match "\n" text pos))
        (setq count (1+ count)
              pos (1+ pos)))
      count)))

(defun emacs-jupyter-notebook-result--slice-lines (text offset limit)
  "Return TEXT lines from OFFSET up to LIMIT lines."
  (let* ((lines (split-string text "\n"))
         (slice (seq-take (nthcdr offset lines) limit)))
    (string-join slice "\n")))

(defun emacs-jupyter-notebook-result--last-lines (text limit)
  "Return the last LIMIT lines of TEXT."
  (let ((lines (split-string text "\n")))
    (string-join (last lines (min limit (length lines))) "\n")))

(defun emacs-jupyter-notebook-result--last-bytes (text max-bytes)
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

(defun emacs-jupyter-notebook-result--header-string (text)
  "Return propertized result header TEXT."
  (propertize text 'face 'emacs-jupyter-notebook-result-header-face))

(defun emacs-jupyter-notebook-result--put-display (ov display)
  "Set OV display string to DISPLAY according to its anchor placement."
  (overlay-put ov 'before-string nil)
  (overlay-put ov 'after-string nil)
  (if (eq (overlay-get ov 'emacs-jupyter-notebook-display-placement)
          'before-newline)
      ;; The real buffer newline covered by OV terminates the output display and
      ;; gives text below the output its own logical line.
      (overlay-put ov 'before-string (string-remove-suffix "\n" display))
    (overlay-put ov 'after-string display)))

(defun emacs-jupyter-notebook-result--render (ov)
  "Render result overlay OV from its stored content."
  (let* ((image (overlay-get ov 'emacs-jupyter-notebook-image))
         (content (or (overlay-get ov 'emacs-jupyter-notebook-content) ""))
         (running (overlay-get ov 'emacs-jupyter-notebook-running))
         (collapsed (overlay-get ov 'emacs-jupyter-notebook-collapsed))
         (count (or (overlay-get ov 'emacs-jupyter-notebook-execution-count) "")))
    (overlay-put ov 'emacs-jupyter-notebook-result-full-content content)
    (if image
        (let ((header (format "\n[%s] [%s]\n" count (if running "running" "output"))))
          (emacs-jupyter-notebook-result--put-display
           ov
           (if collapsed
               (emacs-jupyter-notebook-result--header-string
                (format "\n[%s] [output: image, hidden]\n" count))
             (concat (emacs-jupyter-notebook-result--header-string header)
                     (propertize " " 'display image)
                     "\n"))))
      (let* ((inline-lines (max 1 emacs-jupyter-notebook-result-inline-lines))
             (inline-max-bytes emacs-jupyter-notebook-result-inline-max-bytes)
             (line-count (emacs-jupyter-notebook-result--line-count content))
             (byte-truncated (and (not (string-empty-p content))
                                  (> (string-bytes content) inline-max-bytes)))
             (visible (cond
                       ((string-empty-p content)
                        (if running "Running..." "Done"))
                       (byte-truncated "")
                       (t (emacs-jupyter-notebook-result--slice-lines
                           content 0 inline-lines))))
             (header (format "\n[%s] [%s]\n"
                             count (if running "running" "output")))
             (visible (copy-sequence visible))
              (_ (unless (string-empty-p visible)
                   (add-face-text-property
                    0 (length visible) 'emacs-jupyter-notebook-result-face 'append visible)))
              (display (if collapsed
                           (emacs-jupyter-notebook-result--header-string
                            (format "\n[%s] [output: %d lines, hidden]\n" count line-count))
                         (concat
                          (emacs-jupyter-notebook-result--header-string header)
                          visible
                          (unless (or (string-empty-p visible)
                                      (string-suffix-p "\n" visible))
                            "\n")
                          (cond
                           (byte-truncated
                            (propertize
                             (format "[output: %d bytes, C-c C-o to view]\n"
                                     (string-bytes content))
                             'face 'emacs-jupyter-notebook-result-header-face))
                           ((> line-count inline-lines)
                            (propertize
                             (format "... (%d more lines, C-c C-o to view)\n"
                                     (- line-count inline-lines))
                             'face 'emacs-jupyter-notebook-result-header-face)))))))
        (emacs-jupyter-notebook-result--put-display ov display)))))

(defun emacs-jupyter-notebook-result--all-overlays ()
  "Return all package-owned result overlays in the current buffer."
  (setq emacs-jupyter-notebook-result--overlays
        (cl-remove-if-not
         (lambda (ov)
           (and (overlayp ov)
                (eq (overlay-buffer ov) (current-buffer))
                (overlay-get ov 'emacs-jupyter-notebook-result)))
         emacs-jupyter-notebook-result--overlays)))

(defun emacs-jupyter-notebook-result--set-execution-count (ov count)
  "Set execution count on result overlay OV to COUNT."
  (when (overlayp ov)
    (overlay-put ov 'emacs-jupyter-notebook-execution-count count)
    (emacs-jupyter-notebook-result--render ov)))

(defun emacs-jupyter-notebook-result--set-busy-indicator (ov)
  "Set busy indicator on result overlay OV."
  (emacs-jupyter-notebook-result--set-execution-count ov "*"))

(defun emacs-jupyter-notebook-result-clear-region (beg end)
  "Clear result overlays whose source range intersects BEG and END."
  (dolist (ov (emacs-jupyter-notebook-result--all-overlays))
    (let ((source-beg (overlay-get ov 'emacs-jupyter-notebook-source-begin))
          (source-end (overlay-get ov 'emacs-jupyter-notebook-source-end)))
      (when (and source-beg source-end
                 (<= beg source-end)
                 (<= source-beg end))
        (delete-overlay ov)))))

(defun emacs-jupyter-notebook-result-clear-all ()
  "Clear all package-owned result overlays in the current buffer."
  (mapc #'delete-overlay (emacs-jupyter-notebook-result--all-overlays))
  (setq emacs-jupyter-notebook-result--overlays nil))

(defun emacs-jupyter-notebook-result-start (beg end)
  "Create an empty running result overlay attached to BEG and END."
  (emacs-jupyter-notebook-result-clear-region beg end)
  (let* ((before-newline (and (> end beg)
                              (eq (char-before end) ?\n)))
         (ov (if before-newline
                 (make-overlay (1- end) end (current-buffer) nil nil)
               (make-overlay end end (current-buffer) nil nil))))
    (overlay-put ov 'emacs-jupyter-notebook-result t)
    (overlay-put ov 'emacs-jupyter-notebook-display-placement
                 (if before-newline 'before-newline 'after-anchor))
    (overlay-put ov 'emacs-jupyter-notebook-source-begin beg)
    (overlay-put ov 'emacs-jupyter-notebook-source-end end)
    (overlay-put ov 'emacs-jupyter-notebook-content "")
    (overlay-put ov 'emacs-jupyter-notebook-running t)
    (overlay-put ov 'priority 1000)
    (push ov emacs-jupyter-notebook-result--overlays)
    (emacs-jupyter-notebook-result--render ov)
    ov))

(defun emacs-jupyter-notebook-result-append (ov text &optional face)
  "Append TEXT to result overlay OV.
When FACE is non-nil, apply it to TEXT before storing it.
If OV has a pending-clear flag, replace content instead of appending."
  (when (overlayp ov)
    (let* ((text (if face (propertize text 'face face) text))
           (pending-clear (overlay-get ov 'emacs-jupyter-notebook-pending-clear))
           (content (if pending-clear
                        text
                      (concat (or (overlay-get ov 'emacs-jupyter-notebook-content) "")
                              text)))
           (max-lines (max 1 emacs-jupyter-notebook-result-max-lines))
           (max-bytes emacs-jupyter-notebook-result-max-bytes))
      (when pending-clear
        (overlay-put ov 'emacs-jupyter-notebook-pending-clear nil))
      (overlay-put ov 'emacs-jupyter-notebook-image nil)
      (when (> (emacs-jupyter-notebook-result--line-count content) max-lines)
        (setq content (emacs-jupyter-notebook-result--last-lines content max-lines)))
      (when (> (string-bytes content) max-bytes)
        (setq content (emacs-jupyter-notebook-result--last-bytes content max-bytes)))
      (overlay-put ov 'emacs-jupyter-notebook-content content)
      (emacs-jupyter-notebook-result--render ov))))

(defun emacs-jupyter-notebook-result-clear (ov)
  "Reset result overlay OV content to empty."
  (when (overlayp ov)
    (overlay-put ov 'emacs-jupyter-notebook-image nil)
    (overlay-put ov 'emacs-jupyter-notebook-content "")
    (overlay-put ov 'emacs-jupyter-notebook-pending-clear nil)
    (emacs-jupyter-notebook-result--render ov)))

(defun emacs-jupyter-notebook-result-replace (ov text &optional face)
  "Replace result overlay OV content with TEXT.
When FACE is non-nil, apply it to TEXT before storing it."
  (when (overlayp ov)
    (let* ((text (if face (propertize text 'face face) text))
           (max-lines (max 1 emacs-jupyter-notebook-result-max-lines))
           (max-bytes emacs-jupyter-notebook-result-max-bytes))
      (overlay-put ov 'emacs-jupyter-notebook-image nil)
      (when (> (emacs-jupyter-notebook-result--line-count text) max-lines)
        (setq text (emacs-jupyter-notebook-result--last-lines text max-lines)))
      (when (> (string-bytes text) max-bytes)
        (setq text (emacs-jupyter-notebook-result--last-bytes text max-bytes)))
      (overlay-put ov 'emacs-jupyter-notebook-content text)
      (emacs-jupyter-notebook-result--render ov))))

(defun emacs-jupyter-notebook-result-finish (ov)
  "Mark result overlay OV as no longer running."
  (when (overlayp ov)
    (overlay-put ov 'emacs-jupyter-notebook-running nil)
    (emacs-jupyter-notebook-result--render ov)))

(defun emacs-jupyter-notebook-result-create (beg end result)
  "Display RESULT after END as an overlay attached to source BEG and END."
  (let ((ov (emacs-jupyter-notebook-result-start beg end)))
    (emacs-jupyter-notebook-result-append
     ov (emacs-jupyter-notebook-result--text result))
    (emacs-jupyter-notebook-result-finish ov)
    ov))

(defun emacs-jupyter-notebook-result--at-point ()
  "Return the package-owned result overlay for source at point."
  (cl-find-if
   (lambda (ov)
     (and (overlay-get ov 'emacs-jupyter-notebook-result)
          (<= (or (overlay-get ov 'emacs-jupyter-notebook-source-begin) 0)
              (point))
          (<= (point)
              (or (overlay-get ov 'emacs-jupyter-notebook-source-end) 0))))
   (emacs-jupyter-notebook-result--all-overlays)))

(defun emacs-jupyter-notebook-result--nearest-overlay ()
  "Return the result overlay at or nearest above point in the current buffer."
  (catch 'found
    (let ((overlays (emacs-jupyter-notebook-result--all-overlays))
          (best nil)
          (best-dist most-positive-fixnum))
      (dolist (ov overlays)
        (let ((src-beg (overlay-get ov 'emacs-jupyter-notebook-source-begin))
              (src-end (overlay-get ov 'emacs-jupyter-notebook-source-end)))
          (when (and src-beg src-end)
            (cond
             ((and (<= src-beg (point)) (<= (point) src-end))
              (throw 'found ov))
             ((< (point) src-beg)
              (let ((dist (- src-beg (point))))
                (when (< dist best-dist)
                  (setq best ov)
                  (setq best-dist dist))))
             (t
              (let ((dist (- (point) src-end)))
                (when (< dist best-dist)
                  (setq best ov)
                  (setq best-dist dist))))))))
      best)))

(defun emacs-jupyter-notebook-toggle-output ()
  "Toggle visibility of the result overlay at or nearest above point."
  (interactive)
  (let ((ov (emacs-jupyter-notebook-result--nearest-overlay)))
    (unless ov
      (user-error "No result overlay at or near point"))
    (overlay-put ov 'emacs-jupyter-notebook-collapsed
                 (not (overlay-get ov 'emacs-jupyter-notebook-collapsed)))
    (emacs-jupyter-notebook-result--render ov)))

(provide 'emacs-jupyter-notebook-result)

;;; emacs-jupyter-notebook-result.el ends here
