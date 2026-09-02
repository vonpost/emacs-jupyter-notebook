;;; emacs-jupyter-notebook-panel-stress.el --- AG3 panel stress -*- lexical-binding: t; -*-

;;; Commentary:
;; Deterministic Gate 6 coverage.  This file intentionally has no Jupyter or
;; helper-process dependency: it feeds the panel's real publication admission
;; API and observes the resulting ownership/retirement state.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'emacs-jupyter-notebook-result)
(require 'emacs-jupyter-notebook-artifacts)
(require 'emacs-jupyter-notebook-viewer)

(defvar ejn-ag3--started-at)
(defvar ejn-ag3-panel--started-at nil)

(defconst ejn-ag3-panel--final-viewport-round-trips 8
  "Extra newest-to-oldest viewport movements after the publication loop.")

(defun ejn-ag3-panel--sha256 (file)
  (secure-hash 'sha256 file))

(defun ejn-ag3-panel--write (root name bytes)
  (let ((file (expand-file-name name root)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region bytes nil file nil 'silent))
    (set-file-modes file #o600)
    file))

(defun ejn-ag3-panel--artifact-name (number)
  "Return the canonical helper artifact leaf name for NUMBER."
  (format "ejn-artifact-%032x" number))

(defun ejn-ag3-panel--png (width height)
  "Return a tiny PNG carrying WIDTH and HEIGHT in its IHDR."
  (let ((header (concat "\x89PNG\r\n\x1a\n"
                        "\x00\x00\x00\x0dIHDR"
                        (string (logand (ash width -24) 255)
                                (logand (ash width -16) 255)
                                (logand (ash width -8) 255) (logand width 255)
                                (logand (ash height -24) 255)
                                (logand (ash height -16) 255)
                                (logand (ash height -8) 255) (logand height 255)
                                8 2)
                        "\x00\x00\x00\x00")))
    header))

(defun ejn-ag3-panel--ppm ()
  "Return a canonical one-pixel P6 preview."
  (concat "P6\n1 1\n255\n" "\xff\x00\x00"))

(defun ejn-ag3-panel--jpeg-bomb ()
  "Return a minimal JPEG with a 4097x1024 SOF dimension header."
  (concat "\xff\xd8\xff\xc0\x00\x11\x08"
          (string 4 0 16 1 0 1 1 1 17 0 2 17 0 3 17 0) "\xff\xd9"))

(defun ejn-ag3-panel--display-count (panel)
  "Return the number of distinct display-property runs in PANEL."
  (with-current-buffer panel
    (let ((position (point-min))
          (limit (point-max))
          (count 0))
      (while (< position limit)
        (when (get-text-property position 'display)
          (cl-incf count))
        (setq position
              (next-single-property-change position 'display nil limit)))
      count)))

(defun ejn-ag3-panel--placeholder-count (panel)
  "Return the number of image placeholder labels rendered in PANEL."
  (with-current-buffer panel
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (re-search-forward "\\[pbm image," nil t)
          (cl-incf count))
        count))))

(defun ejn-ag3-panel--image-cache-size ()
  "Return graphical image-cache bytes, or nil when unavailable."
  (when (and (display-graphic-p) (fboundp 'image-cache-size))
    (let ((size (image-cache-size)))
      (and (integerp size) size))))

(defun ejn-ag3-panel--newest-inline-display-position (panel)
  "Return PANEL's last inline image display position, or its end.

The stress path deliberately targets the newest admitted preview rather than
merely moving point to the end of the panel, where a trailing newline can make
redisplay skip image decoding."
  (with-current-buffer panel
    (let ((position (point-min))
          (limit (point-max))
          newest)
      (while (< position limit)
        (when (get-text-property position 'display)
          (setq newest position))
        (setq position
              (next-single-property-change position 'display nil limit)))
      (or newest (point-max)))))

(defun ejn-ag3-panel--graphical-churn-viewport (panel &optional round-trips)
  "Display PANEL and repeatedly move from its newest preview back to the top.

This is intentionally graphical-only: headless ERT validates panel ownership
and retention, while this path forces native image decoding and exercises the
Emacs cache keys created by repeated viewport movement.  Return non-nil only
when the path ran on a live graphical window."
  (when (display-graphic-p)
    (save-window-excursion
      (let* ((window (selected-window))
             (top (with-current-buffer panel (point-min)))
             (passes (or round-trips 1)))
        (set-window-buffer window panel)
        (dotimes (_ passes)
          (let ((newest (ejn-ag3-panel--newest-inline-display-position panel)))
            (set-window-point window newest)
            (set-window-start window newest)
            (redisplay t)
            (set-window-point window top)
            (set-window-start window top)
            (redisplay t)))
        t))))

(defun ejn-ag3-panel--exercise-window-cycle (panel)
  "Move PANEL's viewport, detach it, and attach it again in a live window."
  (save-window-excursion
    (let* ((window (selected-window))
           (detached-buffer (window-buffer window))
           (top (with-current-buffer panel (point-min)))
           (bottom (with-current-buffer panel
                     (save-excursion
                       (goto-char (point-max))
                       (line-beginning-position)))))
      (set-window-buffer window panel)
      (set-window-start window top)
      (set-window-point window top)
      (redisplay t)
      (let ((initial-start (window-start window)))
        (set-window-point window (with-current-buffer panel (point-max)))
        (set-window-start window bottom)
        (set-window-vscroll window 1)
        (redisplay t)
        (should (or (> (window-start window) initial-start)
                    (> (window-vscroll window) 0))))
      (set-window-buffer window detached-buffer)
      (redisplay t)
      (set-window-buffer window panel)
      (set-window-start window top)
      (set-window-point window top)
      (set-window-vscroll window 0)
      (redisplay t)
      (should (eq (window-buffer window) panel)))))

(defun ejn-ag3-panel--descriptor
    (root root-id file mime &optional width height preview)
  (list :root root :root-identity root-id :mime mime
        :original (list :path file :size (file-attribute-size (file-attributes file 'integer))
                        :sha256 (ejn-ag3-panel--sha256 file))
        :preview (when preview
                   (list :path preview :size (file-attribute-size (file-attributes preview 'integer))
                         :sha256 (ejn-ag3-panel--sha256 preview)
                         :mime "image/x-portable-pixmap" :width 1 :height 1))
        :width width :height height))

(defun ejn-ag3-panel--metric (name &rest facts)
  (let ((metric (append (list (cons "name" name)
                              (cons "elapsed"
                                    (- (float-time)
                                       (or ejn-ag3-panel--started-at
                                           (float-time)))))
                        facts))
        (file (getenv "EJN_AG3_METRICS")))
    (when (fboundp 'ejn-ag3--metric)
      (apply #'ejn-ag3--metric name facts))
    (when (and (stringp file) (not (fboundp 'ejn-ag3--metric)))
      (with-temp-file file
        (insert (json-encode (vector metric)))))))

(cl-defmacro ejn-ag3-panel--with-panel ((panel source) &body body)
  (declare (indent 1))
  `(let ((,panel nil) (,source (generate-new-buffer " *ejn-ag3-source*"))
         (root nil) (capability nil))
     (unwind-protect
         (with-current-buffer ,source
           (insert "# %%\nresult = 1\n")
           (set-buffer-modified-p nil)
           (setq ,panel (ejn-panel-ensure (current-buffer)))
           (setq capability (emacs-jupyter-notebook-artifacts-create 'helper)
                 root (emacs-jupyter-notebook-artifacts-capability-root capability))
           ,@body)
       (when (buffer-live-p ,panel)
         (ejn-panel-clear-all ,panel)
         (kill-buffer ,panel))
       (when (buffer-live-p ,source) (kill-buffer ,source))
       (when (and capability
                  (emacs-jupyter-notebook-artifacts-capability-valid-p capability))
         (ignore-errors (emacs-jupyter-notebook-artifacts-retire capability))))))

(ert-deftest ejn-ag3-panel-100-publications-retire-with-bounded-state ()
  "One hundred unique publications stay within budgets and retire exactly."
  (setq ejn-ag3-panel--started-at (float-time))
  (when (boundp 'ejn-ag3--started-at)
    (setq ejn-ag3--started-at ejn-ag3-panel--started-at))
  (ejn-ag3-panel--with-panel (panel source)
    (let ((emacs-jupyter-notebook-panel-max-history-entries 7)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 10000)
          (emacs-jupyter-notebook-panel-max-inline-images 2)
          (baseline (buffer-string))
          (modified (buffer-modified-p))
          (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity capability))
          (paths nil)
          (panel-capability nil)
          (peak-artifact-bytes 0)
          (peak-artifact-files 0)
          (graphical-cache-before (ejn-ag3-panel--image-cache-size))
          (graphical-viewport-passes 0)
          graphical-cache-after
          graphical-cache-warm
          graphical-cache-post-warm-min
          graphical-cache-post-warm-max
          (graphical-cache-post-warm-samples 0))
      (dotimes (index 100)
        (let* ((file (ejn-ag3-panel--write
                      root (ejn-ag3-panel--artifact-name (* 2 index))
                      (ejn-ag3-panel--png 1 1)))
               (preview (ejn-ag3-panel--write
                         root (ejn-ag3-panel--artifact-name (1+ (* 2 index)))
                         (ejn-ag3-panel--ppm)))
               (descriptor (ejn-ag3-panel--descriptor root root-id file "image/png"
                                                      1 1 preview))
               (handle (ejn-panel-start-entry panel (cons "stress.py" index) "display()")))
          (setq paths (append paths (list file preview)))
          (should (ejn-panel-set-published-bundle handle descriptor nil nil))
          (ejn-panel-finish-entry handle 'ok (1+ index))
          (with-current-buffer panel
            (unless panel-capability
              (setq panel-capability
                    (car (hash-table-values
                          emacs-jupyter-notebook-panel--published-artifact-capabilities))))
            (emacs-jupyter-notebook-panel-flush-now panel)
            (when (>= index 6)
              (should (= (length emacs-jupyter-notebook-panel--entries) 7))
              (should (= (length emacs-jupyter-notebook-panel--inline-image-specs) 2))
              (should (= (ejn-ag3-panel--display-count panel) 2))
              (should (= (ejn-ag3-panel--placeholder-count panel) 5)))
            (should (<= (emacs-jupyter-notebook-panel--total-artifact-bytes)
                        emacs-jupyter-notebook-panel-max-total-artifact-bytes))
            (setq peak-artifact-bytes
                  (max peak-artifact-bytes
                       (emacs-jupyter-notebook-panel--total-artifact-bytes)))
            (let ((artifact-files
                   (length (directory-files root nil "\\`ejn-artifact-" t))))
              (setq peak-artifact-files (max peak-artifact-files artifact-files))
              (should (= artifact-files (* 2 (min 7 (1+ index))))))
            (dolist (cell emacs-jupyter-notebook-panel--entries)
              (dolist (image (ejn-panel-entry-images (cdr cell)))
                (should-not (plist-member (cdr image) :data))))
            (should-not (string-match-p ";base64," (prin1-to-string
                                                    emacs-jupyter-notebook-panel--entries))))
          ;; In graphical Emacs, display every successive admitted preview and
          ;; scroll away again.  This is the path that used to grow image-cache
          ;; state as the user revisited panel history.
          (when (ejn-ag3-panel--graphical-churn-viewport panel)
            (cl-incf graphical-viewport-passes))
          (let ((cache-size (ejn-ag3-panel--image-cache-size)))
            ;; The seventh publication fills the seven-entry retention budget
            ;; and the preceding viewport pass has decoded its two admitted
            ;; previews.  From the eighth publication onward each replacement
            ;; must reuse that native-cache footprint rather than accumulating
            ;; one object per historical image.
            (cond
             ((= index 6)
              (setq graphical-cache-warm cache-size
                    graphical-cache-post-warm-min cache-size
                    graphical-cache-post-warm-max cache-size))
             ((and graphical-cache-warm cache-size (> index 6))
              (setq graphical-cache-post-warm-min
                    (min graphical-cache-post-warm-min cache-size)
                    graphical-cache-post-warm-max
                    (max graphical-cache-post-warm-max cache-size))
              (cl-incf graphical-cache-post-warm-samples))))
          (with-current-buffer source
            (should (equal (buffer-string) baseline))
            (should (eq (buffer-modified-p) modified)))
          (when (>= index 7)
            (should-not (file-exists-p (nth (* 2 (- index 7)) paths)))
            (should-not (file-exists-p (nth (1+ (* 2 (- index 7))) paths))))))
      (should panel-capability)
      (should (emacs-jupyter-notebook-artifacts-capability-valid-p panel-capability))
      (let ((retired (cl-subseq paths 0 (- (length paths) 14)))
            (retained (last paths 14)))
        (should (cl-every (lambda (path) (not (file-exists-p path))) retired))
        (should (cl-every #'file-exists-p retained))
        (with-current-buffer panel
          (emacs-jupyter-notebook-panel-toggle-view)
          (emacs-jupyter-notebook-panel--render panel)
          (should (= (length emacs-jupyter-notebook-panel--entries) 7))
          (should (= (ejn-ag3-panel--display-count panel) 2))
          (should (= (ejn-ag3-panel--placeholder-count panel) 5))
          (emacs-jupyter-notebook-panel-toggle-view)
          (emacs-jupyter-notebook-panel--render panel)
          (should (= (length emacs-jupyter-notebook-panel--entries) 7))
          (should (= (ejn-ag3-panel--display-count panel) 2))
          (should (= (ejn-ag3-panel--placeholder-count panel) 5)))
        (ejn-ag3-panel--exercise-window-cycle panel)
        (when (ejn-ag3-panel--graphical-churn-viewport
               panel ejn-ag3-panel--final-viewport-round-trips)
          (cl-incf graphical-viewport-passes
                   ejn-ag3-panel--final-viewport-round-trips))
        (with-current-buffer panel
          (should (= (length emacs-jupyter-notebook-panel--entries) 7))
          (should (= (length emacs-jupyter-notebook-panel--inline-image-specs) 2))
          (should (= (ejn-ag3-panel--display-count panel) 2))
          (should (= (ejn-ag3-panel--placeholder-count panel) 5))
          (should-not (string-match-p ";base64," (buffer-string))))
        (setq graphical-cache-after (ejn-ag3-panel--image-cache-size))
        (when graphical-cache-warm
          ;; Include the final repeated back/forth churn in the sampled steady
          ;; state.  No payload-size guess or implementation-specific overhead
          ;; allowance is needed: the fully populated cache must plateau.
          (should (integerp graphical-cache-after))
          (setq graphical-cache-post-warm-min
                (min graphical-cache-post-warm-min graphical-cache-after)
                graphical-cache-post-warm-max
                (max graphical-cache-post-warm-max graphical-cache-after))
          (cl-incf graphical-cache-post-warm-samples)
          (should (= graphical-cache-post-warm-min graphical-cache-warm))
          (should (= graphical-cache-post-warm-max graphical-cache-warm)))
        (should (cl-every (lambda (path) (not (file-exists-p path))) retired))
        (should (cl-every #'file-exists-p retained)))
      (with-current-buffer source
        (should (equal (buffer-string) baseline))
        (should (eq (buffer-modified-p) modified)))
      (ejn-panel-clear-all panel)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (should (cl-every (lambda (path) (not (file-exists-p path))) paths))
      (should-not (directory-files root nil "\\`ejn-artifact-" t))
      (should-not
       (emacs-jupyter-notebook-artifacts-capability-valid-p panel-capability))
      (should (emacs-jupyter-notebook-artifacts-capability-valid-p capability))
      (with-current-buffer source
        (should (equal (buffer-string) baseline))
        (should (eq (buffer-modified-p) modified)))
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--entries)
        (should (= (emacs-jupyter-notebook-panel--total-artifact-bytes) 0))
        (should-not emacs-jupyter-notebook-panel--published-artifact-capabilities)
        (should-not (timerp emacs-jupyter-notebook-panel--flush-timer)))
      (ejn-panel-clear-all panel)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (should-not (directory-files root nil "\\`ejn-artifact-" t))
      (ejn-ag3-panel--metric "panel-100-publications"
                             (cons "published" 100)
                             (cons "peak_artifact_bytes" peak-artifact-bytes)
                             (cons "peak_artifact_files" peak-artifact-files)
                             (cons "graphical_viewport_passes"
                                   graphical-viewport-passes)
                             (cons "image_cache_before" graphical-cache-before)
                             (cons "image_cache_after" graphical-cache-after)
                             (cons "image_cache_growth"
                                   (and graphical-cache-before graphical-cache-after
                                        (- graphical-cache-after graphical-cache-before)))
                             (cons "image_cache_warm" graphical-cache-warm)
                             (cons "image_cache_post_warm_min"
                                   graphical-cache-post-warm-min)
                             (cons "image_cache_post_warm_max"
                                   graphical-cache-post-warm-max)
                             (cons "image_cache_post_warm_variation"
                                   (and graphical-cache-post-warm-min
                                        graphical-cache-post-warm-max
                                        (- graphical-cache-post-warm-max
                                           graphical-cache-post-warm-min)))
                             (cons "image_cache_post_warm_samples"
                                   graphical-cache-post-warm-samples)
                             (cons "retained_entries" 0)
                             (cons "retained_artifacts" 0)))))

(ert-deftest ejn-ag3-panel-unsafe-large-dimensions-never-hit-native-apis ()
  "Oversized PNG/JPEG originals remain placeholders through all panel paths."
  (ejn-ag3-panel--with-panel (panel source)
    (let ((emacs-jupyter-notebook-panel-max-inline-images 8)
          (native-calls nil)
          (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity capability))
          (baseline (buffer-string))
          (modified (buffer-modified-p))
          (files nil))
      (cl-letf (((symbol-function 'image-size)
                 (lambda (&rest _) (push 'image-size native-calls)))
                ((symbol-function 'create-image)
                 (lambda (&rest _) (push 'create-image native-calls)))
                ((symbol-function 'insert-sliced-image)
                 (lambda (&rest _) (push 'insert-sliced-image native-calls)))
                ((symbol-function 'image-flush)
                 (lambda (&rest _) (push 'image-flush native-calls)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cl-loop for mime in '("image/png" "image/jpeg")
                 for number from 1000
                 do
                 (let* ((bytes (if (equal mime "image/png")
                                   (ejn-ag3-panel--png 4097 1024)
                                 (ejn-ag3-panel--jpeg-bomb)))
                        (file (ejn-ag3-panel--write
                               root (ejn-ag3-panel--artifact-name number) bytes))
                        (descriptor (ejn-ag3-panel--descriptor
                                     root root-id file mime 4097 1024))
                        (handle (ejn-panel-start-entry
                                 panel (cons "unsafe.py" mime) "plot()")))
                   (if (equal mime "image/png")
                       (should (equal (mapcar (lambda (offset) (aref bytes offset))
                                              '(16 17 18 19 20 21 22 23))
                                      '(0 0 16 1 0 0 4 0)))
                     (should (equal (mapcar (lambda (offset) (aref bytes offset))
                                            '(7 8 9 10))
                                    '(4 0 16 1))))
                   (push file files)
                   (should (ejn-panel-set-published-bundle handle descriptor nil nil))
                   (ejn-panel-finish-entry handle 'ok number)
                   (let ((spec (car (ejn-panel-entry-images handle))))
                     (should-not (emacs-jupyter-notebook-panel--native-image-safe-p spec))
                     (with-temp-buffer
                       (emacs-jupyter-notebook-panel--insert-image spec 0 t)
                       (should-not (get-text-property (point-min) 'display)))
                     (with-current-buffer panel
                       (emacs-jupyter-notebook-panel--render panel)
                       (emacs-jupyter-notebook-panel-toggle-view)
                       (emacs-jupyter-notebook-panel--render panel)
                       (emacs-jupyter-notebook-panel-toggle-view)
                       (emacs-jupyter-notebook-panel--render panel))
                     (emacs-jupyter-notebook-panel--retire-image panel spec)))))
      (should-not native-calls)
      (should (cl-every (lambda (path) (not (file-exists-p path))) files))
      (with-current-buffer source
        (should (equal (buffer-string) baseline))
        (should (eq (buffer-modified-p) modified)))
      (ejn-panel-clear-all panel)
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--published-artifact-capabilities)
        (should-not (timerp emacs-jupyter-notebook-panel--flush-timer)))
      (should-not native-calls))))

(ert-deftest ejn-ag3-panel-slicing-uses-admitted-preview-geometry ()
  "Slicing multiple/offscreen panel images never asks a native decoder for size."
  (ejn-ag3-panel--with-panel (panel source)
    (let ((emacs-jupyter-notebook-panel-max-inline-images 8)
          (emacs-jupyter-notebook-panel-slice-images t)
          (image-size-calls 0)
          (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity capability)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'image-size)
                 (lambda (&rest _)
                   (cl-incf image-size-calls)
                   (error "image-size must not run during panel slicing")))
                ((symbol-function 'insert-sliced-image)
                 (lambda (&rest _) (insert " "))))
        (dotimes (index 6)
          (let* ((file (ejn-ag3-panel--write
                        root (ejn-ag3-panel--artifact-name (+ 2000 (* 2 index)))
                        (ejn-ag3-panel--png 2 3)))
                 (preview (ejn-ag3-panel--write
                           root (ejn-ag3-panel--artifact-name (+ 2001 (* 2 index)))
                           (ejn-ag3-panel--ppm)))
                 (descriptor (ejn-ag3-panel--descriptor
                              root root-id file "image/png" 2 3 preview))
                 (handle (ejn-panel-start-entry
                          panel (cons "slice.py" index) "plot()")))
            (should (ejn-panel-set-published-bundle handle descriptor nil nil))
            (ejn-panel-finish-entry handle 'ok (1+ index))))
        ;; Render after the newest entries have pushed earlier images outside
        ;; the inline tail.  The bounded geometry path remains decoder-free.
        (with-current-buffer panel
          (emacs-jupyter-notebook-panel-flush-now panel)))
      (should (= image-size-calls 0)))))

(ert-deftest ejn-ag3-panel-same-display-image-update-is-incremental ()
  "Repeated same-display-id image frames do not rebuild the whole panel."
  (ejn-ag3-panel--with-panel (panel source)
    (let ((emacs-jupyter-notebook-panel-max-inline-images 8)
          (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity capability))
          (full-renders 0)
          (real-render (symbol-function 'emacs-jupyter-notebook-panel--render)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--render)
                 (lambda (buffer)
                   (cl-incf full-renders)
                   (funcall real-render buffer))))
        (let* ((first-file (ejn-ag3-panel--write
                            root "ejn-artifact-00000000000000000000000000002000"
                            (ejn-ag3-panel--png 2 3)))
               (first-preview (ejn-ag3-panel--write
                               root "ejn-artifact-00000000000000000000000000002001"
                               (ejn-ag3-panel--ppm)))
               (first (plist-put
                       (ejn-ag3-panel--descriptor
                        root root-id first-file "image/png" 2 3 first-preview)
                       :display-id "animated"))
               (handle (ejn-panel-start-entry panel '("frames.py" . 1) "plot()")))
          (should (ejn-panel-set-published-bundle handle first nil nil))
          (ejn-panel-finish-entry handle 'ok 1)
          (with-current-buffer panel
            (emacs-jupyter-notebook-panel-flush-now panel))
          (let ((baseline full-renders))
            (dotimes (frame 5)
              (let* ((file (ejn-ag3-panel--write
                            root (format "ejn-artifact-%032x" (+ 2100 (* 2 frame)))
                            (ejn-ag3-panel--png 2 3)))
                     (preview (ejn-ag3-panel--write
                               root (format "ejn-artifact-%032x" (+ 2101 (* 2 frame)))
                               (ejn-ag3-panel--ppm)))
                     (descriptor (plist-put
                                  (ejn-ag3-panel--descriptor
                                   root root-id file "image/png" 2 3 preview)
                                  :display-id "animated")))
                (should (ejn-panel-set-published-bundle
                         handle descriptor nil t))
                (with-current-buffer panel
                  (emacs-jupyter-notebook-panel-flush-now panel))))
            (should (= full-renders baseline))))))))

(ert-deftest ejn-ag3-panel-direct-unsafe-images-never-hit-native-apis ()
  "Direct legacy data/files are bounded and presentation-only on graphics."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("unsafe.py" . 1) "plot()"))
           (native-calls nil))
      (unwind-protect
          (progn
            (let ((emacs-jupyter-notebook-panel--max-inline-image-data-bytes 8))
              (should-error
               (ejn-panel-set-image handle '(image :type png :data "123456789")))
              (with-current-buffer panel
                (should-not emacs-jupyter-notebook-panel--image-directory)))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                      ((symbol-function 'create-image)
                       (lambda (&rest _) (push 'create-image native-calls)))
                      ((symbol-function 'image-size)
                       (lambda (&rest _) (push 'image-size native-calls)))
                      ((symbol-function 'insert-sliced-image)
                       (lambda (&rest _) (push 'insert-sliced-image native-calls)))
                      ((symbol-function 'image-flush)
                       (lambda (&rest _) (push 'image-flush native-calls)))
                      ((symbol-function 'file-attributes)
                       (lambda (&rest _) (push 'file-attributes native-calls))))
              (with-temp-buffer
                (emacs-jupyter-notebook-panel--insert-image
                 '(image :type png :data "malformed") 0 t)
                (emacs-jupyter-notebook-panel--insert-image
                 '(image :type png :file "/tmp/possibly-bomb.png") 1 t))
              (should-not native-calls))
            (ejn-panel-clear-all panel))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest ejn-ag3-viewer-output-tail-is-bounded-and-reaped ()
  "Multi-megabyte viewer diagnostics stay bounded and reap disposes buffers."
  (let* ((stdout (generate-new-buffer " *ejn-ag3-viewer-stdout*"))
         (stderr (generate-new-buffer " *ejn-ag3-viewer-stderr*"))
         (main (make-pipe-process :name "ejn-ag3-viewer-main" :buffer nil :noquery t))
         (stderr-process (make-pipe-process :name "ejn-ag3-viewer-stderr-pipe"
                                            :buffer nil :noquery t)))
    (unwind-protect
        (progn
          (with-current-buffer stdout (set-buffer-multibyte nil))
          (with-current-buffer stderr (set-buffer-multibyte nil))
          (process-put main 'emacs-jupyter-notebook-viewer-output-buffer stdout)
          (process-put main 'emacs-jupyter-notebook-viewer-output-bytes 0)
          (process-put main 'emacs-jupyter-notebook-viewer-stderr-buffer stderr)
          (process-put main 'emacs-jupyter-notebook-viewer-stderr-process stderr-process)
          (process-put stderr-process 'emacs-jupyter-notebook-viewer-output-buffer stderr)
          (process-put stderr-process 'emacs-jupyter-notebook-viewer-output-bytes 0)
          (emacs-jupyter-notebook-viewer--output-filter
           main (make-string (* 3 1024 1024) ?x))
          (emacs-jupyter-notebook-viewer--output-filter
           stderr-process (make-string (* 3 1024 1024) ?y))
          (should (= (with-current-buffer stdout (buffer-size))
                     emacs-jupyter-notebook-viewer--output-max-bytes))
          (should (= (with-current-buffer stderr (buffer-size))
                     emacs-jupyter-notebook-viewer--output-max-bytes))
          (setq emacs-jupyter-notebook-viewer--process main
                emacs-jupyter-notebook-viewer--stdout-buffer stdout
                emacs-jupyter-notebook-viewer--stderr-buffer stderr
                emacs-jupyter-notebook-viewer--stderr-process stderr-process)
          (emacs-jupyter-notebook-viewer-reap)
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr))
          (should-not (process-live-p stderr-process)))
      (ignore-errors (delete-process main))
      (ignore-errors (delete-process stderr-process))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(provide 'emacs-jupyter-notebook-panel-stress)
;;; emacs-jupyter-notebook-panel-stress.el ends here
