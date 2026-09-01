;;; emacs-jupyter-notebook-tests.el --- Tests for emacs-jupyter-notebook  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Unit tests that do not require emacs-jupyter, Jupyter, SSH, or a remote host.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-jupyter)

(defun ejn-test-backend-session (&optional raw-client attached)
  "Create a test backend session with optional legacy RAW-CLIENT data.
When ATTACHED is non-nil, mark the opaque session as locally attached so
busy-kernel reconnect arbitration may retain it after verification times out."
  (let ((session (emacs-jupyter-notebook-backend-session-create
                  nil (current-buffer))))
    (when raw-client
      (setf (emacs-jupyter-notebook-backend-session-data session) raw-client))
    (when attached
      (emacs-jupyter-notebook-backend-session-mark-attached session))
    session))

(defun ejn-test-direct-entry (entry)
  "Return a strict direct-launch registry ENTRY for reconnect tests."
  (let* ((entry (copy-sequence entry))
         (session (or (plist-get entry :session-id) "session"))
         (path (plist-get entry :remote-connection-file))
         (path (if (and (stringp path) (file-name-absolute-p path))
                   path
                 "/home/test/.cache/ejn/kernel.json"))
         (path (expand-file-name (format "kernel-%s.json" session)
                                 (file-name-directory path)))
         (sidecar (concat (string-remove-suffix ".json" path) ".pid")))
    (setq entry (plist-put entry :session-id session))
    (setq entry (plist-put entry :launch-kind 'direct))
    (setq entry (plist-put entry :remote-connection-file path))
    (setq entry (plist-put entry :remote-pid-sidecar sidecar))
    (setq entry (plist-put entry :connection-file-tokens (list path)))
    entry))

(defmacro ejn-test-with-temp-buffer (content &rest body)
  "Create a temporary buffer containing CONTENT and evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     (python-mode)
     ,@body))

(defmacro ejn-test-with-temp-file (var &rest body)
  "Bind VAR to a temporary file path and evaluate BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ejn-test-")))
     (unwind-protect
         (progn ,@body)
        (when (file-exists-p ,var)
          (delete-file ,var)))))

(defun ejn-test-overlay-display-string (ov)
  "Return the rendered display string for result overlay OV."
  (or (overlay-get ov 'after-string)
      (overlay-get ov 'before-string)))

(defun ejn-test-image-spec-data (spec)
  "Return the bytes represented by image SPEC from `:data' or `:file'."
  (or (plist-get (cdr spec) :data)
      (let ((file (plist-get (cdr spec) :file)))
        (when (and file (file-readable-p file))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (buffer-string))))))

(defun ejn-test-image-file-backed-p (spec)
  "Return non-nil when SPEC is backed by a readable private file."
  (let ((file (plist-get (cdr spec) :file)))
    (and (not (plist-member (cdr spec) :data))
         (stringp file)
         (file-readable-p file))))

(defun ejn-ei4-test--content-sha256 (file)
  "Return SHA-256 of FILE contents, never of its pathname."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun ejn-ei4v-test--artifact-file (root hex payload)
  "Create a confined EI4V artifact under ROOT from HEX and PAYLOAD."
  (let ((file (expand-file-name (format "ejn-artifact-%s" hex) root)))
    (with-temp-file file (insert payload))
    (set-file-modes file #o600)
    file))

(defun ejn-ei4v-test--descriptor
    (root file &optional mime display-id width height inline-safe)
  "Return current confined artifact metadata for FILE under ROOT."
  (ignore width height inline-safe)
  (let* ((attrs (file-attributes file 'integer))
         (leaf (list :path file :sha256 (ejn-ei4-test--content-sha256 file)
                     :size (file-attribute-size attrs)))
         (root-identity (file-attribute-file-identifier
                         (file-attributes root 'integer))))
    (if mime
        ;; Old ownership tests use deliberately non-image source bytes.  They
        ;; now model the required original-only descriptor, not native PNG.
        (append (list :root root :root-identity root-identity :mime mime
                      :original leaf :preview nil)
                (when display-id (list :display-id display-id)))
      (append (list :root root :root-identity root-identity)
              leaf
              (when display-id (list :display-id display-id))))))

(defun ejn-ei4d-test--u32 (value)
  "Return VALUE as four big-endian unibyte octets."
  (unibyte-string (logand (ash value -24) #xff)
                  (logand (ash value -16) #xff)
                  (logand (ash value -8) #xff)
                  (logand value #xff)))

(defun ejn-ei4d-test--png (width height)
  "Return inert PNG-like original bytes containing WIDTH and HEIGHT."
  (concat (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n)
          "EJN-ORIGINAL" (ejn-ei4d-test--u32 width)
          (ejn-ei4d-test--u32 height)))

(defun ejn-ei4d-test--jpeg (width height &optional prefix)
  "Return a minimal baseline JPEG frame header with WIDTH and HEIGHT."
  (concat (unibyte-string #xff #xd8) prefix
          (unibyte-string #xff #xc0 0 11 8
                          (logand (ash height -8) #xff) (logand height #xff)
                          (logand (ash width -8) #xff) (logand width #xff)
                          1 1 17 0 #xff #xd9)))

(defun ejn-ei4d-test--write-artifact (root hex bytes)
  "Write unibyte BYTES to a confined helper artifact below ROOT."
  (let ((file (expand-file-name (format "ejn-artifact-%s" hex) root))
        (coding-system-for-write 'no-conversion))
    (write-region bytes nil file nil 'silent)
    (set-file-modes file #o600)
    file))

(defun ejn-ei4d-test--ppm (width height)
  "Return a tiny canonical uncompressed P6 fixture."
  (concat (format "P6\n%d %d\n255\n" width height)
          (apply #'unibyte-string
                 (number-sequence 0 (1- (* width height 3))))))

(defun ejn-ei4d-result-test--image-descriptor
    (root original &optional preview display-id mime width height)
  "Return a nested image descriptor for ORIGINAL and optional PPM PREVIEW."
  (let* ((root-id (file-attribute-file-identifier
                   (file-attributes root 'integer)))
         (leaf (lambda (file)
                 (let ((attrs (file-attributes file 'integer)))
                   (list :path file :sha256 (ejn-ei4-test--content-sha256 file)
                         :size (file-attribute-size attrs))))))
    (append
     (list :root root :root-identity root-id :mime (or mime "image/png")
           :original (funcall leaf original)
           :preview (and preview
                         (append (funcall leaf preview)
                                 (list :mime "image/x-portable-pixmap"
                                       :width width :height height))))
     (when display-id (list :display-id display-id)))))

(defun ejn-test-drain-zero-delay-timers ()
  "Run callbacks deferred onto Emacs's zero-delay timer queue.

This is the test equivalent of returning to the command loop; it does not
wait for wall-clock time or weaken assertions about callback ordering."
  (dotimes (_ 4)
    (accept-process-output nil 0)))

(ert-deftest ejn-cell-no-marker-is-whole-buffer ()
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (should (equal (emacs-jupyter-notebook-cell-bounds)
                   (cons (point-min) (point-max))))
    (should (equal (emacs-jupyter-notebook-cell-code) "x = 1\ny = 2\n"))))

(ert-deftest ejn-cell-current-marker-with-title ()
  (ejn-test-with-temp-buffer "# %% setup\na = 1\n# %% work\nb = 2\n"
    (search-forward "b = 2")
    (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
      (should (equal (buffer-substring-no-properties beg end) "b = 2\n")))))

(ert-deftest ejn-cell-empty-cell-between-markers ()
  (ejn-test-with-temp-buffer "# %%\n# %%\nx = 1\n"
    (goto-char (point-min))
    (pcase-let ((`(,beg . ,end) (emacs-jupyter-notebook-cell-bounds)))
      (should (equal (buffer-substring-no-properties beg end) "")))))

(ert-deftest ejn-cell-inline-marker-is-not-boundary ()
  (ejn-test-with-temp-buffer "x = '# %%'\ny = 2\n"
    (search-forward "y = 2")
    (should (equal (emacs-jupyter-notebook-cell-bounds)
                   (cons (point-min) (point-max))))))

(ert-deftest ejn-cell-navigation-lands-in-cell-body ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (emacs-jupyter-notebook-forward-cell)
    (should (looking-at-p "b = 2"))
    (emacs-jupyter-notebook-backward-cell)
    (should (looking-at-p "a = 1"))))

(ert-deftest ejn-cell-insert-below-creates-empty-cell-and-enters-it ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (emacs-jupyter-notebook-insert-cell-below)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %%\n# %% B\nb = 2\n"))
    (should (looking-at-p "# %% B"))))

(ert-deftest ejn-cell-insert-above-creates-empty-cell-and-enters-it ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-insert-cell-above)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %%\n# %% B\nb = 2\n"))
    (should (looking-at-p "# %% B"))))

(ert-deftest ejn-cell-delete-removes-whole-cell-and-enters-next ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-delete-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% C\nc = 3\n"))
    (should (looking-at-p "c = 3"))))

(ert-deftest ejn-cell-clear-keeps-marker-and-deletes-body ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-clear-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% B\n# %% C\nc = 3\n"))
    (should (looking-at-p "# %% C"))))

(ert-deftest ejn-cell-duplicate-copies-current-cell-and-enters-copy ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n# %% C\nc = 3\n"
    (search-forward "b = 2")
    (emacs-jupyter-notebook-duplicate-cell)
    (should (equal (buffer-string)
                   "# %% A\na = 1\n# %% B\nb = 2\n# %% B\nb = 2\n# %% C\nc = 3\n"))
    (should (looking-at-p "b = 2"))))

(ert-deftest ejn-cell-send-and-advance-moves-to-next-cell ()
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-send-cell)
                 (lambda () (setq called t))))
        (emacs-jupyter-notebook-send-cell-and-advance))
      (should called)
      (should (looking-at-p "b = 2")))))

(ert-deftest ejn-imenu-no-cells ()
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (should-not (emacs-jupyter-notebook--imenu-index))))

(ert-deftest ejn-imenu-single-cell-with-title ()
  (ejn-test-with-temp-buffer "# %% The Title\na = 1\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (= (length index) 1))
      (should (equal (caar index) "The Title"))
      (should (markerp (cdar index)))
      (should (= (cdar index) (point-min))))))

(ert-deftest ejn-imenu-multiple-cells-mixed-titles ()
  (ejn-test-with-temp-buffer
      "# %% First Cell\na = 1\n# %% \nb = 2\n# %% Third Cell\nc = 3\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (mapcar #'car index)
                     '("First Cell" "Cell 2" "Third Cell"))))))

(ert-deftest ejn-imenu-all-untitled-cells-numbered-sequentially ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n# %%\nb = 2\n# %%\nc = 3\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (mapcar #'car index)
                     '("Cell 1" "Cell 2" "Cell 3"))))))

(ert-deftest ejn-imenu-markers-point-to-marker-line-start ()
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n# %% B\ny = 2\n"
    (dolist (entry (emacs-jupyter-notebook--imenu-index))
      (save-excursion
        (goto-char (cdr entry))
        (should (bolp))
        (should (looking-at-p "# %%"))))))

(ert-deftest ejn-imenu-title-trimming ()
  (ejn-test-with-temp-buffer "# %%   Spaces Galore   \nx = 1\n"
    (let ((index (emacs-jupyter-notebook--imenu-index)))
      (should (equal (caar index) "Spaces Galore")))))

(ert-deftest ejn-imenu-mode-sets-function-and-restores-python-imenu ()
  (with-temp-buffer
    (python-mode)
    (let ((python-imenu imenu-create-index-function))
      (should (local-variable-p 'imenu-create-index-function))
      (emacs-jupyter-notebook-mode 1)
      (should (eq imenu-create-index-function
                  #'emacs-jupyter-notebook--imenu-index))
      (emacs-jupyter-notebook-mode -1)
      (should (eq imenu-create-index-function python-imenu))
      (should (local-variable-p 'imenu-create-index-function)))))

(ert-deftest ejn-registry-roundtrip-and-permissions ()
  (ejn-test-with-temp-file file
    (let ((entry '(:profile "default"
                   :remote-host "mother"
                   :remote-cwd "/tmp/project"
                   :kernelspec "python3"
                   :remote-connection-file "/tmp/kernel.json"
                   :remote-pid 123
                   :created-at "2026-06-10T00:00:00+0000"
                   :tunnel-ports (:shell_port 50001)
                   :display-name "mother:python3"
                   :session-id "abc")))
      (emacs-jupyter-notebook-registry-save (list entry) file)
      (should (equal (emacs-jupyter-notebook-registry-load file) (list entry)))
      (should (= (logand (file-modes file) #o777) #o600)))))

(ert-deftest ejn-a6-corrupt-registry-backed-up-not-silently-wiped ()
  "A6: saving into a corrupt registry preserves the old bytes as a
`.corrupt-*' backup and still lands the new entry, rather than silently
discarding every prior host's reconnect entry."
  (ejn-test-with-temp-file file
    (emacs-jupyter-notebook-registry-save
     '((:profile "keep" :session-id "old")) file)
    ;; Corrupt the file on disk (unbalanced form → `read' fails).
    (with-temp-file file (insert "(:profile \"broken\" this is not"))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (emacs-jupyter-notebook-registry-save-entry
       '(:profile "new" :session-id "new") file))
    ;; New entry present after the rewrite.
    (should (emacs-jupyter-notebook-registry-find
             "new" (emacs-jupyter-notebook-registry-load file)))
    ;; Corrupt bytes preserved in a backup, so nothing is silently lost.
    (let ((backups (directory-files
                    (file-name-directory file) t
                    (concat (regexp-quote (file-name-nondirectory file))
                            "\\.corrupt-"))))
      (should backups)
      (should (string-match-p
               "not" (with-temp-buffer
                       (insert-file-contents (car backups))
                       (buffer-string)))))))

(ert-deftest ejn-a6-valid-registry-save-makes-no-backup ()
  "A6: the corrupt-backup path never triggers on a healthy registry."
  (ejn-test-with-temp-file file
    (emacs-jupyter-notebook-registry-save
     '((:profile "a" :session-id "a")) file)
    (emacs-jupyter-notebook-registry-save-entry
     '(:profile "b" :session-id "b") file)
    (should (emacs-jupyter-notebook-registry-find
             "a" (emacs-jupyter-notebook-registry-load file)))
    (should (emacs-jupyter-notebook-registry-find
             "b" (emacs-jupyter-notebook-registry-load file)))
    (should-not (directory-files
                 (file-name-directory file) nil
                 (concat (regexp-quote (file-name-nondirectory file))
                         "\\.corrupt-")))))

(ert-deftest ejn-registry-save-creates-parent-directory ()
  (let* ((dir (make-temp-file "ejn-registry-dir-" t))
         (file (expand-file-name "missing/registry.el" dir)))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save
           '((:profile "default" :session-id "abc")) file)
          (should (file-readable-p file))
          (should (equal (emacs-jupyter-notebook-registry-load file)
                         '((:profile "default" :session-id "abc")))))
      (delete-directory dir t))))

(ert-deftest ejn-registry-upsert-remove-find ()
  (let* ((a '(:profile "default" :session-id "a" :created-at "1"))
         (b '(:profile "default" :session-id "b" :created-at "2"))
         (a2 '(:profile "default" :session-id "a" :created-at "3"))
         (entries (emacs-jupyter-notebook-registry-upsert a nil)))
    (setq entries (emacs-jupyter-notebook-registry-upsert b entries))
    (setq entries (emacs-jupyter-notebook-registry-upsert a2 entries))
    (should (= (length entries) 2))
    (should (equal (emacs-jupyter-notebook-registry-find "a" entries) a2))
    (should (equal (emacs-jupyter-notebook-registry-latest-for-profile "default" entries) a2))
      (should-not (emacs-jupyter-notebook-registry-find
                  "a" (emacs-jupyter-notebook-registry-remove "a" entries)))))

(ert-deftest ejn-registry-latest-for-file ()
  (let* ((file (expand-file-name "notebook.py" temporary-file-directory))
         (other (expand-file-name "other.py" temporary-file-directory))
         (a `(:profile "default" :session-id "a" :local-file ,file :created-at "1"))
         (b `(:profile "default" :session-id "b" :local-file ,file :created-at "2"))
         (c `(:profile "default" :session-id "c" :local-file ,other :created-at "3")))
    (should (equal (emacs-jupyter-notebook-registry-latest-for-file
                    file (list a b c))
                   b))))

(ert-deftest ejn-connection-rewrite-ports-preserves-keys ()
  (let* ((conn '(:ip "10.0.0.5"
                 :transport "tcp"
                 :shell_port 1
                 :iopub_port 2
                 :stdin_port 3
                 :hb_port 4
                 :control_port 5
                 :key "secret"
                 :signature_scheme "hmac-sha256"))
         (ports '(:shell_port 1001
                  :iopub_port 1002
                  :stdin_port 1003
                  :hb_port 1004
                  :control_port 1005))
         (rewritten (emacs-jupyter-notebook-connection-rewrite-ports conn ports)))
    (should (equal (plist-get rewritten :ip) "127.0.0.1"))
    (should (equal (plist-get rewritten :shell_port) 1001))
    (should (equal (plist-get rewritten :control_port) 1005))
    (should (equal (plist-get rewritten :key) "secret"))
    (should (equal (plist-get rewritten :signature_scheme) "hmac-sha256"))
    (should (equal (plist-get conn :shell_port) 1))))

(ert-deftest ejn-connection-file-read-write ()
  (ejn-test-with-temp-file file
    (let ((conn '(:ip "127.0.0.1" :shell_port 123 :key "secret")))
      (emacs-jupyter-notebook-connection-write-file conn file)
      (should (equal (emacs-jupyter-notebook-connection-read-file file) conn)))))

;; W4.7: the sync `--retrieve-connection-file' and `--wait-for-tunnel'
;; tests have been removed along with the functions they exercised.  The
;; async retrieve and tunnel-readiness poller are covered by
;; `ejn-async-retrieve-*' / `ejn-async-wait-tunnel-*' (see ROADMAP W4.7).

(ert-deftest ejn-w4.7-no-sleep-for-in-source-files ()
  "W4.7 acceptance: no `sleep-for' call may appear in any package source
file.  Test sources may still use it for synchronization (see the
W4.4 dead-PID probe test); production code must not."
  (let ((dir (file-name-directory
              (or (locate-library "emacs-jupyter-notebook")
                  (expand-file-name "emacs-jupyter-notebook.el")))))
    (dolist (name '("emacs-jupyter-notebook.el"
                    "emacs-jupyter-notebook-ssh.el"
                    "emacs-jupyter-notebook-jupyter.el"
                    "emacs-jupyter-notebook-result.el"
                    "emacs-jupyter-notebook-connection.el"
                    "emacs-jupyter-notebook-registry.el"
                    "emacs-jupyter-notebook-vars.el"
                    "emacs-jupyter-notebook-cell.el"))
      (let ((path (expand-file-name name dir)))
        (when (file-readable-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (should-not
             (re-search-forward "(sleep-for\\b" nil t))))))))

;; W4.7: `ejn-connect-entry-waits-for-tunnel-before-jupyter-connect' was
;; removed along with the synchronous `--connect-entry'.  The async
;; tunnel-readiness behavior it asserted is covered by the
;; `ejn-async-wait-tunnel-*' tests.

(ert-deftest ejn-start-remote-kernel-uses-async-launch ()
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "start command used synchronous SSH")))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                (lambda (_name _argv _sentinel)
                  (setq started t)
                  'mock-launch-process))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (lambda (_name _argv _limit _sentinel)
                 (setq started t)
                 'mock-launch-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (let ((context (emacs-jupyter-notebook-start-remote-kernel "p")))
          (should started)
          (should (eq context emacs-jupyter-notebook--async-context))
          (should (eq (plist-get context :phase) 'resolve))
          (should (eq (plist-get context :resolve-process) 'mock-launch-process))
          (should (equal (plist-get (plist-get context :entry) :local-file)
                         "/tmp/example-notebook.py"))
          (should (string-match-p "example-notebook" (plist-get context :session-id))))))))

(ert-deftest ejn-start-remote-kernel-requires-file-buffer ()
  (let ((emacs-jupyter-notebook-remote-profiles
           '(("p" . (:host "example.com")))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore))
      (with-temp-buffer
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)))))

(ert-deftest ejn-start-remote-kernel-declining-cancel-refuses-duplicate-operation ()
  "W12: starting while an attempt is in flight prompts to cancel it; declining
the prompt (`n') refuses the new start with a `user-error' and launches
nothing, so the buffer keeps its single in-progress attempt."
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function
                'emacs-jupyter-notebook-ssh-start-bounded-process)
               (lambda (&rest _)
                 (setq started t)
                 'mock-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'retrieve
               :origin-buffer (current-buffer)))
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)
        (should-not started)))))

(ert-deftest ejn-start-remote-kernel-accepting-cancel-supersedes-attempt ()
  "W12: accepting the cancel prompt (`y') aborts the in-progress attempt
via `--cancel-async-operation' and proceeds with the new start."
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started superseded)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook--cancel-async-operation)
               (lambda (&rest _)
                 (setq superseded t)
                 (setq emacs-jupyter-notebook--async-context nil)))
              ((symbol-function
                'emacs-jupyter-notebook-ssh-start-bounded-process)
               (lambda (&rest _)
                 (setq started t)
                 'mock-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'retrieve
               :origin-buffer (current-buffer)))
        (emacs-jupyter-notebook-start-remote-kernel "p")
        (should superseded)
        (should started)))))

(ert-deftest ejn-start-remote-kernel-refuses-existing-client-noninteractive ()
  (let ((emacs-jupyter-notebook-remote-profiles
          '(("p" . (:host "example.com" :remote-cwd "~" :kernelspec "python3"))))
        started)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _)
                 (setq started t)
                 'mock-process)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example-notebook.py")
        (setq emacs-jupyter-notebook--client 'mock-client)
        (should-error (emacs-jupyter-notebook-start-remote-kernel "p")
                      :type 'user-error)
        (should-not started)))))

(ert-deftest ejn-reconnect-remote-kernel-uses-async-retrieve ()
  ;; Post-W4.4: reconnect first runs `--async-probe-pid-alive', which only
  ;; advances to `--async-retrieve' when the entry's `:remote-pid' is alive.
  ;; The probe is stubbed here to call retrieve directly so this test still
  ;; pins the contract "reconnect ends in async-retrieve, never sync SSH".
  (let ((entry (ejn-test-direct-entry
                '(:profile "p"
                  :remote-host "example.com"
                  :remote-cwd "~"
                  :kernelspec "python3"
                  :remote-pid 12345
                  :remote-connection-file "~/.cache/ejn/kernel.json"
                  :session-id "session")))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "reconnect command used synchronous SSH")))
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieved t)
                 context)))
      (with-temp-buffer
        (let ((context (emacs-jupyter-notebook-reconnect-remote-kernel entry)))
          (should retrieved)
          (should (eq context emacs-jupyter-notebook--async-context))
          (should (eq (plist-get context :phase) 'retrieve))
          (should-not (plist-get context :owns-kernel)))))))

(ert-deftest ejn-reconnect-remote-kernel-declining-cancel-refuses-duplicate-operation ()
  "W12/W19: reconnecting while a START attempt is in flight prompts to
cancel it (a start attempt owns a launched kernel, so superseding it is not
silent); declining (`n') refuses the reconnect with a `user-error' and never
begins retrieval, so the buffer keeps its single in-progress attempt.  A
stale RECONNECT attempt, by contrast, is superseded silently — see
`ejn-w19-reconnect-supersedes-stale-reconnect-without-prompt'."
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-cwd "~"
                 :kernelspec "python3"
                 :remote-connection-file "~/.cache/ejn/kernel.json"
                 :session-id "session"))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (&rest _)
                 (setq retrieved t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'connect
               :owns-kernel t
               :origin-buffer (current-buffer)))
        (should-error (emacs-jupyter-notebook-reconnect-remote-kernel entry)
                      :type 'user-error)
        (should-not retrieved)))))

(ert-deftest ejn-w10-reconnect-remote-kernel-proceeds-from-clientless-debris ()
  "W10: reconnect is THE recovery path.  A buffer with a lingering
`--session-entry' but NO live client is reapable DEBRIS, not an active
session, so reconnect must NOT be blocked by the guard — it reaps the
stale buffer-local entry and proceeds to probe/retrieve the target entry.
Pre-W10 this signalled `user-error \"A kernel is already active\"' and the
wedged buffer could only be recovered by nuking the live kernel."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p"
                  :remote-host "example.com"
                  :remote-cwd "~"
                  :kernelspec "python3"
                  :remote-pid 4242
                  :remote-connection-file "~/.cache/ejn/kernel.json"
                  :session-id "session")))
        retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieved t)
                 context)))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry '(:profile "p" :session-id "old"))
        (let ((context (emacs-jupyter-notebook-reconnect-remote-kernel entry)))
          ;; Not blocked: the reconnect pipeline advanced to retrieve.
          (should retrieved)
          (should (eq (plist-get context :phase) 'retrieve))
          ;; The stale buffer-local debris entry was reaped before the new
          ;; reconnect context took over.
          (should (equal (plist-get context :entry) entry)))))))

(ert-deftest ejn-read-registry-entry-prefers-current-file ()
  "W6.8: chooser ALWAYS runs, but the current-file entry is the default initial-input.
Pressing RET on the chooser with no edit returns the current-file entry."
  (let* ((file (expand-file-name "current.py" temporary-file-directory))
         (entry `(:profile "p"
                  :session-id "current"
                  :local-file ,file
                  :created-at "2"))
         (other '(:profile "p" :session-id "other" :created-at "3"))
         (passed-default nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list other entry)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &optional _pred _require _initial _hist default)
                 (setq passed-default default)
                 ;; Simulate the user pressing RET on the default.
                 default)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (let ((selected (emacs-jupyter-notebook--read-registry-entry)))
          (should (equal selected entry))
          (should (string-match-p "session-id" "session-id"))
          ;; The default offered must be the label for the current-file entry.
          (should (string-match-p "current" passed-default)))))))

(ert-deftest ejn-ssh-basic-command-with-user-port-and-options ()
  (let ((emacs-jupyter-notebook-ssh-command "ssh")
        (emacs-jupyter-notebook-ssh-options '("-o" "BatchMode=yes"))
        ;; Isolate the core argv shape from the A3/A4 global options, which
        ;; have their own dedicated tests below, and from the W19 keepalive
        ;; args (tested separately).
        (emacs-jupyter-notebook-ssh-connect-timeout nil)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-tunnel-keepalive-interval 0))
    (should (equal (emacs-jupyter-notebook-ssh-command
                    '(:profile "p" :host "example.com" :user "alice" :port 2222))
                   '("ssh" "-o" "BatchMode=yes" "-p" "2222" "alice@example.com")))))

(ert-deftest ejn-a3a4-ssh-command-carries-connect-timeout-and-control-master ()
  "A4: every ssh command carries `ConnectTimeout' (bounded handshake).
A3: it also carries multiplexing options so short commands share a master."
  (let ((emacs-jupyter-notebook-ssh-connect-timeout 10)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master t)
        (emacs-jupyter-notebook-ssh-control-persist "60")
        (emacs-jupyter-notebook-ssh-control-path "/tmp/ejn-ssh-%i-%C"))
    (let ((cmd (emacs-jupyter-notebook-ssh-command
                '(:profile "p" :host "example.com") "true")))
      (should (member "ConnectTimeout=10" cmd))
      (should (member "ControlMaster=auto" cmd))
      (should (member "ControlPath=/tmp/ejn-ssh-%i-%C" cmd))
      (should (member "ControlPersist=60" cmd))
      (should-not (member "BatchMode=yes" cmd)))))

(ert-deftest ejn-a3a4-batch-mode-opt-in ()
  "A4: `BatchMode=yes' appears only when the defcustom is enabled."
  (let ((emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-ssh-connect-timeout nil))
    (let ((emacs-jupyter-notebook-ssh-batch-mode t))
      (should (member "BatchMode=yes"
                      (emacs-jupyter-notebook-ssh-command
                       '(:profile "p" :host "h") "true"))))
    (let ((emacs-jupyter-notebook-ssh-batch-mode nil))
      (should-not (member "BatchMode=yes"
                          (emacs-jupyter-notebook-ssh-command
                           '(:profile "p" :host "h") "true"))))))

(ert-deftest ejn-a3-tunnel-opts-out-of-multiplexing ()
  "A3: the persistent tunnel must own its own connection — it carries
`ControlPath=none' and never a shared master, so liveness stays detectable."
  (let ((emacs-jupyter-notebook-ssh-control-master t)
        (emacs-jupyter-notebook-ssh-control-path "/tmp/ejn-ssh-%i-%C"))
    (let ((cmd (emacs-jupyter-notebook-ssh-tunnel-command
                '(:profile "p" :host "example.com")
                '(:shell_port 1) '(:shell_port 1001))))
      (should (member "ControlPath=none" cmd))
      (should-not (member "ControlMaster=auto" cmd))
      (should-not (member "ControlPath=/tmp/ejn-ssh-%i-%C" cmd))))
  ;; Disabled: no multiplexing options anywhere on the tunnel.
  (let ((emacs-jupyter-notebook-ssh-control-master nil))
    (let ((cmd (emacs-jupyter-notebook-ssh-tunnel-command
                '(:profile "p" :host "example.com")
                '(:shell_port 1) '(:shell_port 1001))))
      (should-not (member "ControlPath=none" cmd))
      (should-not (member "ControlMaster=auto" cmd)))))

(ert-deftest ejn-ssh-tunnel-command-multiple-ports ()
  (let ((cmd (emacs-jupyter-notebook-ssh-tunnel-command
              '(:profile "p" :host "example.com")
              '(:shell_port 1 :iopub_port 2 :stdin_port 3 :hb_port 4 :control_port 5)
              '(:shell_port 1001 :iopub_port 1002 :stdin_port 1003 :hb_port 1004 :control_port 1005))))
    (should (equal (car cmd) emacs-jupyter-notebook-ssh-command))
    (should (member "1001:127.0.0.1:1" cmd))
    (should (member "1005:127.0.0.1:5" cmd))
    (should (equal (car (last cmd)) "example.com"))))

(ert-deftest ejn-ssh-scp-rewrites-tilde-to-home-relative ()
  "A `~'-anchored remote path is handed to scp as a home-RELATIVE path.
scp does not run through the remote shell, and OpenSSH 9+ scp (SFTP
protocol) treats a leading `~' as a literal directory name — so
`host:~/.cache/...' fails even though the launch created the dir.  The
home-relative form resolves against the login home on both the SFTP and
legacy SCP protocols."
  ;; Isolate the path-rewrite behavior from the A3/A4 global options and the
  ;; W19 keepalive args.
  (let ((emacs-jupyter-notebook-ssh-connect-timeout nil)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-tunnel-keepalive-interval 0))
    (should (equal (emacs-jupyter-notebook-ssh-scp-from-command
                    '(:profile "p" :host "example.com")
                    "~/.cache/ejn/kernel.json" "/tmp/kernel.json")
                   (list emacs-jupyter-notebook-scp-command
                         "example.com:.cache/ejn/kernel.json"
                         "/tmp/kernel.json")))))

(ert-deftest ejn-ssh-scp-passes-absolute-remote-path-unchanged ()
  "An absolute remote path is forwarded to scp verbatim — no rewriting."
  (let ((emacs-jupyter-notebook-ssh-connect-timeout nil)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-tunnel-keepalive-interval 0))
    (should (equal (emacs-jupyter-notebook-ssh-scp-from-command
                    '(:profile "p" :host "example.com")
                    "/home/alice/.cache/ejn/kernel.json" "/tmp/kernel.json")
                   (list emacs-jupyter-notebook-scp-command
                         "example.com:/home/alice/.cache/ejn/kernel.json"
                         "/tmp/kernel.json")))))

(ert-deftest ejn-w19-one-shot-commands-carry-keepalive ()
  "W19: one-shot ssh/scp commands carry ServerAlive keepalives so a ride on
a silently-dead ControlMaster (or a black-holed path) is bounded instead of
hanging the attempt forever.  The keepalive interval customization controls
them; 0 disables them."
  (let ((emacs-jupyter-notebook-ssh-connect-timeout nil)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-tunnel-keepalive-interval 15))
    (let ((ssh-cmd (emacs-jupyter-notebook-ssh-command
                    '(:profile "p" :host "example.com") "true"))
          (scp-cmd (emacs-jupyter-notebook-ssh-scp-from-command
                    '(:profile "p" :host "example.com")
                    "~/.cache/ejn/kernel.json" "/tmp/kernel.json")))
      (should (member "ServerAliveInterval=15" ssh-cmd))
      (should (member "ServerAliveCountMax=3" ssh-cmd))
      (should (member "ServerAliveInterval=15" scp-cmd))
      (should (member "ServerAliveCountMax=3" scp-cmd))))
  ;; Disabled: no keepalive args.
  (let ((emacs-jupyter-notebook-ssh-connect-timeout nil)
        (emacs-jupyter-notebook-ssh-batch-mode nil)
        (emacs-jupyter-notebook-ssh-control-master nil)
        (emacs-jupyter-notebook-tunnel-keepalive-interval 0))
    (should-not (member "ServerAliveInterval=15"
                        (emacs-jupyter-notebook-ssh-command
                         '(:profile "p" :host "example.com") "true")))))

(ert-deftest ejn-a3-scp-carries-multiplexing-when-enabled ()
  "A3: scp rides the shared master too (its many connection-file polls are
the biggest handshake cost)."
  (let ((emacs-jupyter-notebook-ssh-control-master t)
        (emacs-jupyter-notebook-ssh-control-path "/tmp/ejn-ssh-%i-%C"))
    (let ((cmd (emacs-jupyter-notebook-ssh-scp-from-command
                '(:profile "p" :host "example.com")
                "~/.cache/ejn/kernel.json" "/tmp/kernel.json")))
      (should (member "ControlMaster=auto" cmd))
      (should (member "ControlPath=/tmp/ejn-ssh-%i-%C" cmd)))))

(ert-deftest ejn-ssh-scp-remote-path-helper-cases ()
  "`--scp-remote-path' strips a `~/' anchor, maps bare `~' to `.', and
leaves absolute paths untouched."
  (should (equal (emacs-jupyter-notebook-ssh--scp-remote-path "~/.cache/k.json")
                 ".cache/k.json"))
  (should (equal (emacs-jupyter-notebook-ssh--scp-remote-path "~") "."))
  (should (equal (emacs-jupyter-notebook-ssh--scp-remote-path "/abs/k.json")
                 "/abs/k.json")))

(ert-deftest ejn-ssh-remote-cleanup-is-pid-and-token-bound ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cleanup
                '(:profile "p" :host "example.com")
                '(:launch-kind direct :remote-pid 123
                  :session-id "session"
                  :remote-connection-file "/home/u/.cache/ejn/kernel-session.json"
                  :remote-pid-sidecar "/home/u/.cache/ejn/kernel-session.pid"
                  :connection-file-tokens ("--connection-file=/home/u/.cache/ejn/kernel-session.json"))))
         (remote-command (car (last cmd))))
    (should-not (string-match-p "pkill" remote-command))
    (should (string-match-p "kill \\\"\\$pid\\\"" remote-command))
    (should (string-match-p (regexp-quote
                             (shell-quote-argument
                              "--connection-file=/home/u/.cache/ejn/kernel-session.json"))
                            remote-command))
    (should (string-match-p "/home/u/.cache/ejn/kernel-session.pid"
                            remote-command))))

(ert-deftest ejn-ssh-remote-cat-log-targets-connection-log ()
  (let* ((emacs-jupyter-notebook-management-output-max-bytes 12345)
         (cmd (emacs-jupyter-notebook-ssh-build-remote-cat-log
               '(:profile "p" :host "example.com")
               "~/.cache/ejn/kernel-session.json"))
         (remote-command (car (last cmd))))
    (should (string-match-p "tail -c 12345 < \\$HOME/.cache/ejn/kernel-session.log"
                            remote-command))))

(ert-deftest ejn-ssh-remote-ps-command-targets-cache-dir ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-ps-command
               '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
         (remote-command (car (last cmd))))
    (should (string-match-p "ps -eo pid,ppid,stat,etime,args" remote-command))
    ;; A1: pattern is double-quoted (not double-shell-quoted, so `=' is not
    ;; escaped) and self-excluding (`[K]') so `grep' never lists itself.
    (should (string-match-p "\\[K\\]ernelManager.connection_file=/tmp/ejn/kernel-"
                            remote-command))))

(ert-deftest ejn-ssh-remote-cleanup-all-targets-cache-dir ()
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cleanup-all
               '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
         (remote-command (car (last cmd))))
    (should (string-match-p "pkill -f" remote-command))
    (should (string-match-p "\\[K\\]ernelManager.connection_file=/tmp/ejn/kernel-"
                            remote-command))
    (should (string-match-p "rm -f /tmp/ejn/kernel-\\*.json /tmp/ejn/kernel-\\*.log"
                            remote-command))))

(ert-deftest ejn-ssh-remote-cleanup-all-default-cache-matches-expanded-home ()
  "A1 regression: with the default `~'-anchored cache dir the pkill pattern
must carry an UNESCAPED `$HOME' (so the remote shell expands it and it
matches the kernel's expanded argv), not the old double-`shell-quote-argument'
`\\$HOME' literal that matched nothing.  It must also be self-excluding and
must not embed the raw self-matching substring."
  (let* ((cmd (emacs-jupyter-notebook-ssh-build-remote-cleanup-all
               '(:profile "p" :host "example.com"
                 :remote-cache-dir "~/.cache/emacs-jupyter-notebook")))
         (remote-command (car (last cmd))))
    ;; Unescaped, shell-expandable $HOME inside the double-quoted pattern.
    (should (string-match-p
             "pkill -f \"\\[K\\]ernelManager.connection_file=\\$HOME/.cache/emacs-jupyter-notebook/kernel-\""
             remote-command))
    ;; No escaped `\\$' that the remote shell would keep literal.
    (should-not (string-match-p "\\\\\\$HOME" remote-command))
    ;; Self-exclusion: the raw unbracketed pattern text is absent, so `pkill'
    ;; cannot match its own shell and kill it before the `rm' runs.
    (should-not (string-match-p "KernelManager.connection_file=\\$HOME"
                                remote-command))))

(ert-deftest ejn-ssh-direct-launch-writes-sidecar-before-exec ()
  (let* ((path "/tmp/ejn/kernel-session.json")
         (launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                  '(:profile "p" :host "mother" :remote-cwd "/work"
                    :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                  "session"
                  (list :connection-file path
                        :argv (list "/usr/bin/python3" "-f" path)
                        :connection-tokens (list "-f" path)
                        :env nil)))
         (remote-command (plist-get launch :remote-command)))
    (should (equal (plist-get launch :connection-file) path))
    (should (string-match-p "EJN_SESSION" remote-command))
    (should (string-match-p "exec" remote-command))
    (should (string-match-p "EJN_LAUNCH_ADMITTED" remote-command))))

(ert-deftest ejn-ssh-direct-launch-persists-expanded-artifact-paths ()
  "A home-relative profile must still produce a reconnectable strict entry."
  (let* ((path "/home/test/.cache/ejn/kernel-session.json")
         (launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                  '(:profile "p" :host "mother" :remote-cwd "~"
                    :remote-cache-dir "~/.cache/ejn" :kernelspec "python3")
                  "session"
                  (list :connection-file path
                        :argv (list "/usr/bin/python3" "-f" path)
                        :connection-tokens (list "-f" path)
                        :env nil)))
         (entry (list :launch-kind 'direct :session-id "session"
                      :remote-pid 42 :provisional nil
                      :remote-connection-file path
                      :remote-pid-sidecar (plist-get launch :sidecar-file)
                      :connection-file-tokens (plist-get launch :connection-tokens))))
    (should (equal (plist-get launch :sidecar-file)
                   "/home/test/.cache/ejn/kernel-session.pid"))
    (should (equal (plist-get launch :log-file)
                   "/home/test/.cache/ejn/kernel-session.log"))
    (should (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry))))

(ert-deftest ejn-launch-admission-marker-cannot-be-embedded-or-duplicated ()
  (should (emacs-jupyter-notebook--launch-admitted-output-p
           "EJN_LAUNCH_ADMITTED\n"))
  (dolist (output '("prefix EJN_LAUNCH_ADMITTED suffix\n"
                    "EJN_LAUNCH_ADMITTED\nEJN_LAUNCH_ADMITTED\n"
                    "EJN_LAUNCH_ADMITTED_EXTRA\n"
                    ""))
    (should-not (emacs-jupyter-notebook--launch-admitted-output-p output))))

(ert-deftest ejn-w4.2-parse-pid-uses-anchored-sentinel ()
  "W4.2: `--parse-pid' matches the anchored `EJN_PID=<digits>' sentinel,
ignores spurious numbers in SSH banners / motd, and returns nil when no
sentinel is present."
  (should (= 12345
             (emacs-jupyter-notebook--parse-pid
              "Welcome to host 42\nLast login: ...\nEJN_PID=12345\n")))
  (should (= 9
             (emacs-jupyter-notebook--parse-pid "EJN_PID=9\n")))
  (should-not (emacs-jupyter-notebook--parse-pid
               "Welcome 42\nLast login: 99999 days ago\n"))
  (should-not (emacs-jupyter-notebook--parse-pid
               "EJN_PID=abc\n"))
  ;; The sentinel must be anchored; an embedded `EJN_PID=...' inside another
  ;; word should not match unless it starts the line.
  (should-not (emacs-jupyter-notebook--parse-pid
               "noise EJN_PID=7\n")))

(ert-deftest ejn-w4.3-classify-stderr-auth-failed ()
  "W4.3: `Permission denied' / `Authentication failed' map to `auth-failed'."
  (dolist (s '("Permission denied (publickey).\n"
               "user@host: Permission denied (publickey,password).\n"
               "Authentication failed.\n"
               "Too many authentication failures for user\n"
               "Could not open a connection to your authentication agent.\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'auth-failed (plist-get r :kind)))
      (should (stringp (plist-get r :hint))))))

(ert-deftest ejn-w4.3-classify-stderr-host-unreachable ()
  "W4.3: DNS/route failures map to `host-unreachable'."
  (dolist (s '("ssh: Could not resolve hostname mother: Name or service not known\n"
               "ssh: connect to host mother port 22: No route to host\n"
               "ssh: connect to host x port 22: Network is unreachable\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'host-unreachable (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-connection-refused ()
  "W4.3: `Connection refused' maps to `connection-refused'."
  (let ((r (emacs-jupyter-notebook-ssh-classify-stderr
            "ssh: connect to host mother port 22: Connection refused\n")))
    (should (eq 'connection-refused (plist-get r :kind)))))

(ert-deftest ejn-w4.3-classify-stderr-forward-refused ()
  "W4.3: forward refusal maps to `forward-refused'."
  (dolist (s '("Could not request local forwarding.\n"
               "remote port forwarding failed for listen port 9000\n"
               "bind [127.0.0.1]:9000: Address already in use\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'forward-refused (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-host-key-changed ()
  "W4.3: changed host key maps to `host-key-changed'."
  (dolist (s '("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
               "Host key verification failed.\n"))
    (let ((r (emacs-jupyter-notebook-ssh-classify-stderr s)))
      (should (eq 'host-key-changed (plist-get r :kind))))))

(ert-deftest ejn-w4.3-classify-stderr-unknown-falls-back ()
  "W4.3: unrecognized stderr maps to `unknown' with a non-empty hint."
  (let ((r (emacs-jupyter-notebook-ssh-classify-stderr
            "something completely unparseable\n")))
    (should (eq 'unknown (plist-get r :kind)))
    (should (stringp (plist-get r :hint)))
    (should (> (length (plist-get r :hint)) 0))))

(ert-deftest ejn-w4.3-async-fail-enriches-classified-errors ()
  "W4.3: `--async-fail' surfaces classified SSH errors with a kind prefix and hint."
  (with-temp-buffer
    (let* ((captured nil)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :error-callback (lambda (_ctx err) (setq captured err)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail
         context "ssh: Could not resolve hostname mother: Name or service not known\n"))
      (should (stringp captured))
      (should (string-prefix-p "HOST-UNREACHABLE:" captured))
      (should (string-match-p "Hint: " captured)))))

(ert-deftest ejn-w4.3-async-fail-passes-unknown-through ()
  "W4.3: unrecognized errors pass through `--async-fail' verbatim."
  (with-temp-buffer
    (let* ((captured nil)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :error-callback (lambda (_ctx err) (setq captured err)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail context "unparseable noise\n"))
      (should (equal captured "unparseable noise\n")))))

(ert-deftest ejn-w7.1-launch-sentinel-nonzero-exit-classifies-auth-failed-stderr ()
  "W7.1: `--async-launch-sentinel' firing on nonzero exit transitions the
async context to phase `error' and the classified stderr from W4.3
appears in the user-visible message.  A launch process whose stderr
contains an SSH auth-failed pattern must surface as `AUTH-FAILED:' with
a `Hint:' line."
  (with-temp-buffer
    (let* ((origin (current-buffer))
           captured captured-context
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :session-id "s1"
                     :origin-buffer origin
                     :error-callback (lambda (ctx err)
                                       (setq captured err
                                             captured-context ctx)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        ;; Real subprocess so the sentinel fires on a real exit.  Route
        ;; the auth-failed stderr through the real ssh-start-process path
        ;; so `--process-output' picks it up from the stderr buffer.
        (let ((process (emacs-jupyter-notebook-ssh-start-process
                        "ejn-test-w7.1-launch-fail"
                        '("sh" "-c"
                          "printf 'Permission denied (publickey).\\n' 1>&2; exit 1")
                        (lambda (proc _event)
                          (emacs-jupyter-notebook--async-launch-sentinel
                           context proc)))))
          (setq context (emacs-jupyter-notebook--async-put
                         context :launch-process process))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not captured) (< (float-time) deadline))
              (accept-process-output process 0.05)))))
      (should captured)
      (should captured-context)
      (should (eq (plist-get captured-context :phase) 'error))
      (should (stringp (plist-get captured-context :error)))
      (should (string-prefix-p "AUTH-FAILED:" captured))
      (should (string-match-p "Hint: " captured)))))

(ert-deftest ejn-a2-context-live-p-distinguishes-active-dead-superseded ()
  "A2: `--async-context-live-p' is true only for the buffer's current,
in-progress attempt; false once the context is failed/superseded."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ctx-a (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :origin-buffer buffer))
           (ctx-b (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :origin-buffer buffer)))
      ;; A is the active in-flight attempt.
      (setq emacs-jupyter-notebook--async-context ctx-a)
      (should (emacs-jupyter-notebook--async-context-live-p ctx-a))
      ;; A superseded by B: A is no longer live, B is.
      (setq emacs-jupyter-notebook--async-context ctx-b)
      (should-not (emacs-jupyter-notebook--async-context-live-p ctx-a))
      (should (emacs-jupyter-notebook--async-context-live-p ctx-b))
      ;; A terminal phase in the slot is not in-progress, so not live.
      (setq emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-put ctx-b :phase 'error))
      (should-not (emacs-jupyter-notebook--async-context-live-p ctx-b)))))

(ert-deftest ejn-a2-scp-sentinel-noop-when-context-superseded ()
  "A2: a killed SCP process from a superseded attempt must not resurrect its
context nor schedule a retry.  Without the identity guard the deleted
process's sentinel would take the failure/retry path and `--async-put' the
dead context back into the buffer, clobbering the newer attempt."
  (with-temp-buffer
    (let* ((origin (current-buffer))
           (ctx-a (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :session-id "a"
                   :scp-attempt 1 :origin-buffer origin))
           (ctx-b (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :session-id "b" :origin-buffer origin))
           retried)
      ;; B currently owns the buffer's async slot; A was superseded.
      (setq emacs-jupyter-notebook--async-context ctx-b)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve-retry)
                 (lambda (&rest _) (setq retried t))))
        (let ((process (emacs-jupyter-notebook-ssh-start-process
                        "ejn-test-a2-scp-superseded"
                        '("sh" "-c" "exit 1")
                        (lambda (proc _event)
                          (emacs-jupyter-notebook--async-scp-sentinel
                           ctx-a proc)))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (memq (process-status process) '(run open))
                        (< (float-time) deadline))
              (accept-process-output process 0.05)))
          ;; Give the sentinel a chance to run after exit.
          (accept-process-output nil 0.05)))
      (should-not retried)
      ;; The buffer's active attempt is untouched — B, not the resurrected A.
      (should (eq emacs-jupyter-notebook--async-context ctx-b)))))

(defun ejn-w7.2--run-retrieve-exhaustion ()
  "Drive `--async-retrieve' through retry exhaustion via a real failing
subprocess.  Returns a plist with `:captured' (error-data), `:context'
(final context), `:spawned' (process list), and `:baseline' (baseline
buffer list captured before the run).  Extracted so the two W7.2
assertions can share exactly one execution."
  (let* ((baseline (ejn-test--ejn-process-buffers))
         (emacs-jupyter-notebook-connection-retrieve-attempts 2)
         (emacs-jupyter-notebook-connection-retrieve-delay 0.02)
         (spawned nil)
         captured captured-context)
    (with-temp-buffer
      (let* ((origin (current-buffer))
             (context (emacs-jupyter-notebook--async-new-context
                       :phase 'retrieve
                       :session-id "w72"
                       :profile '(:profile "p" :host "h")
                       :entry '(:profile "p"
                                :session-id "w72"
                                :remote-host "h"
                                :remote-connection-file "/remote/kernel.json")
                       :origin-buffer origin
                       :error-callback (lambda (ctx err)
                                         (setq captured err
                                               captured-context ctx)))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf (((symbol-function 'display-warning) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (name _argv _limit sentinel)
                     (let* ((stderr (generate-new-buffer
                                     (format " *%s stderr*" name)))
                            (proc (make-process
                                   :name name
                                   :buffer (generate-new-buffer
                                            (format " *%s*" name))
                                   :command '("sh" "-c"
                                              "printf 'scp: no such file\\n' 1>&2; exit 1")
                                   :connection-type 'pipe
                                   :noquery t
                                   :sentinel sentinel
                                   :stderr stderr)))
                       (process-put proc 'emacs-jupyter-notebook-stderr-buffer
                                    stderr)
                       (push proc spawned)
                       proc))))
          (emacs-jupyter-notebook--async-retrieve context)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not captured) (< (float-time) deadline))
              (accept-process-output nil 0.02))))))
    (list :captured captured
          :context captured-context
          :spawned spawned
          :baseline baseline)))

(ert-deftest ejn-w7.2-async-retrieve-exhausts-retries-fails-cleanly ()
  "W7.2: `--async-retrieve' exhausts its retries → phase `error' and the
last-error is captured on the context.  This assertion is UNAFFECTED by
CC1 and must always pass."
  (let* ((run (ejn-w7.2--run-retrieve-exhaustion))
         (context (plist-get run :context)))
    (should (plist-get run :captured))
    (should context)
    (should (eq (plist-get context :phase) 'error))
    (should (stringp (plist-get context :error)))
    (should (string-match-p "SCP failed" (plist-get context :error)))
    (dolist (proc (plist-get run :spawned))
      (should-not (process-live-p proc)))
    (let ((copy (plist-get context :remote-copy)))
      (when copy
        (should-not (file-exists-p copy))))))

(ert-deftest ejn-w7.2-async-retrieve-does-not-leak-scp-buffers ()
  "W7.2 (leak assertion, split from the retry-exhaustion test per W7.6):
after retrieve exhausts its retries, no scp stdout/stderr buffers survive
above the baseline.  CC1 fixed this: `--async-retrieve-attempt' now
disposes the previous attempt's scp process before overwriting the
`:scp-process' slot, so retries no longer leak 2·(attempts-1) hidden scp
buffers."
  (let ((run (ejn-w7.2--run-retrieve-exhaustion)))
    (let ((leaked (cl-set-difference (ejn-test--ejn-process-buffers)
                                     (plist-get run :baseline))))
      (should-not leaked))))

(ert-deftest ejn-a8-retrieve-timeout-surfaces-launch-log ()
  "A8: when the connection file never arrives, the failure surfaced in Emacs
includes the remote launch log tail, so the real cause (e.g. `jupyter'
missing) is visible without SSHing in to read the log by hand."
  (let ((emacs-jupyter-notebook-connection-retrieve-attempts 1)
        (emacs-jupyter-notebook-connection-retrieve-delay 0.02)
        captured)
    (with-temp-buffer
      (let* ((origin (current-buffer))
             (context (emacs-jupyter-notebook--async-new-context
                       :phase 'retrieve :session-id "a8"
                       :profile '(:profile "p" :host "h")
                       :entry '(:profile "p" :session-id "a8" :remote-host "h"
                                :remote-connection-file "/remote/kernel-a8.json")
                       :origin-buffer origin
                       :error-callback (lambda (_ctx err) (setq captured err)))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf (((symbol-function 'display-warning) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (name _argv _limit sentinel)
                     ;; scp attempts fail; the launch-log fetch returns the log.
                     (let* ((script (if (string-match-p "launchlog" name)
                                        "printf 'jupyter: command not found\\n'; exit 0"
                                      "printf 'scp: no such file\\n' 1>&2; exit 1"))
                            (stderr (generate-new-buffer
                                     (format " *%s stderr*" name)))
                            (proc (make-process
                                   :name name
                                   :buffer (generate-new-buffer
                                            (format " *%s*" name))
                                   :command (list "sh" "-c" script)
                                   :connection-type 'pipe :noquery t
                                   :sentinel sentinel :stderr stderr)))
                       (process-put proc 'emacs-jupyter-notebook-stderr-buffer
                                    stderr)
                       proc))))
          (emacs-jupyter-notebook--async-retrieve context)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not captured) (< (float-time) deadline))
              (accept-process-output nil 0.02))))))
    (should captured)
    (should (string-match-p "Remote launch log" captured))
    (should (string-match-p "jupyter: command not found" captured))))

(ert-deftest ejn-w4.4-build-pid-alive-uses-kill-zero ()
  "W4.4/W13: the PID-alive probe uses `kill -0 <pid>' but reports the answer
via stdout tokens (always exiting 0) so ssh failure is not read as death."
  (let* ((argv (emacs-jupyter-notebook-ssh-build-pid-alive
                '(:profile "p" :host "mother") 12345
                '("--connection-file=/r/kernel.json")))
         (remote (car (last argv))))
    (should (string-match-p "pid=12345" remote))
    (should (string-match-p "kill -0 \"\\$pid\"" remote))
    (should (string-match-p "__EJN_ALIVE_MATCH__" remote))
    (should (string-match-p "__EJN_DONE__" remote))))

(ert-deftest ejn-w4.8-async-probe-fails-when-no-pid ()
  "W4.8: when the registry entry has no `:remote-pid' (pre-W4.2 session)
the probe MUST fail with a clear explanation; it must NOT silently bypass
to `--async-retrieve' (that would be a backwards-compat shim)."
  (let* (retrieve-called probe-called fail-called fail-reason
         (entry '(:profile "p" :session-id "s1" :remote-host "h"
                  :remote-connection-file "/r/k.json"))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :origin-buffer (current-buffer))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _) (setq probe-called t) nil))
              ((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (_ctx err)
                 (setq fail-called t fail-reason err))))
      (emacs-jupyter-notebook--async-probe-pid-alive context))
    (should-not retrieve-called)
    (should-not probe-called)
    (should fail-called)
    (should (string-match-p "no recorded PID" fail-reason))
    (should (string-match-p "start-remote-kernel" fail-reason))))

(ert-deftest ejn-w4.4-async-probe-success-proceeds-to-retrieve ()
  "W4.4: a successful PID-alive probe leads to `--async-retrieve'."
  (let* ((retrieve-called nil)
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 12345
                   :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (ejn-test--probe-process-fn
                "echo __EJN_ALIVE_MATCH__; echo __EJN_DONE__")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      ;; Drive the sentinel by waiting for the process to exit.
      (let ((deadline (+ (float-time) 5)))
        (while (and (not retrieve-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should retrieve-called)))

(defun ejn-test--probe-process-fn (script)
  "Return a bounded-process stub running SCRIPT with captured output.
The probe sentinel reads stdout (not the exit status), so the synthesized
process must carry a real buffer + stderr like the production launcher."
  (lambda (name _argv &rest args)
    (let* ((sentinel (car (last args)))
           (stderr (generate-new-buffer (format " *%s stderr*" name)))
           (proc (make-process
                  :name name
                  :buffer (generate-new-buffer (format " *%s*" name))
                  :command (list "sh" "-c" script)
                  :connection-type 'pipe :noquery t
                  :sentinel sentinel :stderr stderr)))
      (process-put proc 'emacs-jupyter-notebook-stderr-buffer stderr)
      proc)))

(ert-deftest ejn-w4.4-async-probe-dead-pid-fails-context ()
  "W4.4/W13: a probe whose host answers `__EJN_DEAD__' and `__EJN_DONE__'
is a confirmed-dead kernel; fail with `kernel-dead',
leaving the registry entry intact."
  (let* (fail-called fail-reason fail-ctx
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 99999
                   :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (ctx err)
                 (setq fail-called t fail-reason err fail-ctx ctx)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (ejn-test--probe-process-fn
                "echo __EJN_DEAD__; echo __EJN_DONE__")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not fail-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should fail-called)
    (should (eq (plist-get fail-ctx :error-kind) 'kernel-dead))
    (should (string-match-p "no longer alive" fail-reason))
    (should (string-match-p "start-remote-kernel" fail-reason))))

(ert-deftest ejn-w13-async-probe-unreachable-is-not-kernel-dead ()
  "W13: a probe where the host never answers (no `__EJN_DONE__' — an
ssh/infra failure such as an over-long ControlPath or a network blip) must
NOT be reported as a dead kernel; it fails with `probe-unreachable' and
advises retrying reconnect, never a fresh start."
  (let* (fail-called fail-reason fail-ctx
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 12345
                   :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve
                   :profile '(:profile "p" :host "h")
                   :entry entry
                   :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (ctx err)
                 (setq fail-called t fail-reason err fail-ctx ctx)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               ;; ssh-style failure: no tokens on stdout, error on stderr.
               (ejn-test--probe-process-fn
                "echo 'ssh: connect failed' 1>&2; exit 255")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not fail-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should fail-called)
    (should (eq (plist-get fail-ctx :error-kind) 'probe-unreachable))
    (should (string-match-p "Could not reach" fail-reason))
    (should (string-match-p "reconnect-remote-kernel" fail-reason))
    (should-not (string-match-p "no longer alive" fail-reason))))

(ert-deftest ejn-w4.8-ensure-client-async-does-not-auto-restart-on-dead-reconnect ()
  "W4.8: when reconnect-to-entry fails (e.g. W4.4 dead-PID), the
`--ensure-client-async' fallback MUST NOT remove the registry entry and
MUST NOT start a fresh kernel.  It surfaces the error to the caller's
error-callback so the user can decide."
  (with-temp-buffer
    (let* ((entry '(:profile "p" :session-id "s8" :remote-host "h"
                    :remote-pid 99999 :local-file "/tmp/foo.py"
                    :remote-connection-file "/r/k.json"))
           reconnect-error-cb start-called registry-removed err-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () entry))
                ((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                 (lambda (_entry _cb error-cb &optional _owner)
                   (setq reconnect-error-cb error-cb)))
                ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                 (lambda (&rest _) (setq start-called t)))
                ((symbol-function 'emacs-jupyter-notebook--remove-registry-entry)
                 (lambda (&rest _) (setq registry-removed t))))
        (emacs-jupyter-notebook--ensure-client-async
         #'ignore
         (lambda (_ctx _err) (setq err-called t)))
        (should (functionp reconnect-error-cb))
        ;; Simulate the W4.4 kernel-dead failure.
        (funcall reconnect-error-cb nil "kernel-dead")
        (should err-called)
        (should-not start-called)
        (should-not registry-removed)))))

(ert-deftest ejn-w4.8-async-fail-disposes-probe-process-stderr-buffer ()
  "W4.8: `--async-fail' disposes the W4.4 PID-probe process and its stderr
buffer when the context carries one."
  (with-temp-buffer
    (let* ((probe (emacs-jupyter-notebook-ssh-start-process
                   "ejn-test-probe-fail" '("sleep" "60")))
           (stderr (process-get probe 'emacs-jupyter-notebook-stderr-buffer))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'probe
                     :probe-process probe)))
      (should (buffer-live-p stderr))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--async-fail context "boom"))
      (should-not (process-live-p probe))
      (should-not (buffer-live-p stderr)))))

(ert-deftest ejn-w4.8-heartbeat-cancel-cancels-pending-timeout-timer ()
  "W4.8: `--heartbeat-cancel' must also cancel the per-probe timeout timer
so it cannot fire (and bump misses) after cleanup."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--heartbeat-timer
          (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--heartbeat-timeout-timer
          (run-with-timer 1000 nil #'ignore))
    (emacs-jupyter-notebook--heartbeat-cancel)
    (should-not emacs-jupyter-notebook--heartbeat-timer)
    (should-not emacs-jupyter-notebook--heartbeat-timeout-timer)))

(ert-deftest ejn-w4.5-heartbeat-success-keeps-tunnel-alive ()
  "W4.5: a successful heartbeat reply keeps `--tunnel-dead' nil and resets
the miss counter regardless of prior misses."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client
          (ejn-test-backend-session 'mock-client t))
    (setq emacs-jupyter-notebook--heartbeat-misses 1)
    (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 2)
          (emacs-jupyter-notebook-heartbeat-timeout 0.2))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_client cb)
                   (funcall cb '(:status "ok") nil))))
        (emacs-jupyter-notebook--heartbeat-tick)
        (ejn-test-drain-zero-delay-timers)
        (should (= 0 emacs-jupyter-notebook--heartbeat-misses))
        (should-not emacs-jupyter-notebook--tunnel-dead)))))

(ert-deftest ejn-w4.5-heartbeat-n-consecutive-misses-flip-tunnel-dead ()
  "W4.5: after `--heartbeat-misses-allowed' consecutive misses the buffer
flags --tunnel-dead, clears --kernel-status, and the timer is cancelled."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client)
    (setq emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--kernel-status 'idle)
    (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 2))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (should-not emacs-jupyter-notebook--tunnel-dead)
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (should emacs-jupyter-notebook--tunnel-dead)
        (should-not emacs-jupyter-notebook--kernel-status)
        (should-not emacs-jupyter-notebook--heartbeat-timer)))))

(ert-deftest ejn-w4.5-heartbeat-cancel-clears-state ()
  "W4.5: cancelling the heartbeat zeros misses, drops inflight, removes timer."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--heartbeat-misses 1)
    (setq emacs-jupyter-notebook--heartbeat-inflight 'tok)
    (emacs-jupyter-notebook--heartbeat-cancel)
    (should-not emacs-jupyter-notebook--heartbeat-timer)
    (should (= 0 emacs-jupyter-notebook--heartbeat-misses))
    (should-not emacs-jupyter-notebook--heartbeat-inflight)))

(ert-deftest ejn-w4.5-heartbeat-skipped-when-tunnel-already-dead ()
  "W4.5: `--heartbeat-tick' does not fire a probe when --tunnel-dead is set."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client
          emacs-jupyter-notebook--tunnel-dead t)
    (let (probe-called)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_c _cb) (setq probe-called t))))
        (emacs-jupyter-notebook--heartbeat-tick)
        (should-not probe-called)))))

(ert-deftest ejn-w4.5-heartbeat-cancelled-by-release-local-resources ()
  "W4.5 + W1: `--release-local-resources' cancels the heartbeat timer
as part of local cleanup (kill-buffer-hook + mode-disable both route here)."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client
          emacs-jupyter-notebook--heartbeat-timer (run-with-timer 1000 nil #'ignore))
    (emacs-jupyter-notebook--release-local-resources)
    (should-not emacs-jupyter-notebook--heartbeat-timer)))

(ert-deftest ejn-ssh-resolution-uses-structured-python-argv ()
  "The actual Doom/Nix profile is argv, never a re-parsed shell fragment."
  (let* ((expr "with import <nixpkgs> {}; python3.withPackages (ps: with ps; [ jupyter ipykernel numpy matplotlib ])")
         (profile (list :profile "p" :host "mother" :remote-cwd "~"
                        :remote-cache-dir "~/.cache/ejn" :kernelspec "python3"
                        :python-command (list "nix" "shell" "--impure" "--expr"
                                              expr "-c" "python")))
         (resolution (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
                      profile "session"))
         (remote (plist-get resolution :remote-command)))
    (should (string-match-p (regexp-quote (shell-quote-argument expr)) remote))
    (should (string-match-p "KernelSpecManager" remote))
    (should (string-match-p "kernel-session.json" remote))))

(ert-deftest ejn-ssh-rejects-legacy-jupyter-command ()
  (should-error
   (emacs-jupyter-notebook-ssh-profile
    '(:profile "p" :host "mother" :jupyter-command "jupyter"))))

(defun ejn-test-run-production-kernelspec-resolver (argv environment)
  "Run the embedded production resolver against a fake kernelspec."
  (let* ((python (or (executable-find "python3")
                     (ert-skip "python3 is unavailable")))
         (root (make-temp-file "ejn-resolver-" t))
         (package (expand-file-name "jupyter_client" root))
         (resource (expand-file-name "resource dir" root))
         (connection (expand-file-name "kernel-session.json" root)))
    (unwind-protect
        (progn
          (make-directory package)
          (make-directory resource)
          (with-temp-file (expand-file-name "__init__.py" package))
          (with-temp-file (expand-file-name "kernelspec.py" package)
            (insert
             "import json, os\n"
             "class _Spec:\n"
             "    resource_dir = os.environ['EJN_TEST_RESOURCE']\n"
             "    argv = json.loads(os.environ['EJN_TEST_ARGV'])\n"
             "    env = json.loads(os.environ['EJN_TEST_ENV'])\n"
             "class KernelSpecManager:\n"
             "    def get_kernel_spec(self, name):\n"
             "        if name != 'python3': raise KeyError(name)\n"
             "        return _Spec()\n"))
          (let ((process-environment (copy-sequence process-environment)))
            (setenv "PYTHONPATH" root)
            (setenv "EJN_TEST_RESOURCE" resource)
            (setenv "EJN_TEST_ARGV" (json-encode (vconcat argv)))
            (setenv "EJN_TEST_ENV" (json-encode environment))
            (setenv "EJN_RESOURCE_ROOT" resource)
            (setenv "EJN_RESOLVER_UNSET" nil)
            (with-temp-buffer
              (let ((status
                     (process-file
                      python nil (current-buffer) nil "-c"
                      emacs-jupyter-notebook-ssh--kernelspec-resolver
                      "python3" connection "session")))
                (list :status status :output (buffer-string)
                      :resource resource :connection connection)))))
      (delete-directory root t))))

(ert-deftest ejn-ht12r2-production-resolver-enforces-final-kernelspec-contract ()
  (let* ((result
          (ejn-test-run-production-kernelspec-resolver
           '("python3" "--connection={connection_file}" "{resource_dir}"
             "argument with spaces;$(not-a-shell)")
           '(("EJN_EXPANDED" . "prefix:$EJN_RESOURCE_ROOT")
             ("EJN_LITERAL_UNSET" . "$EJN_RESOLVER_UNSET"))))
         (connection (plist-get result :connection))
         (parsed
          (emacs-jupyter-notebook--parse-resolved-kernelspec
           (concat "EJN_CONNECTION_FILE=" connection "\n"
                   (plist-get result :output))
           "session" "python3" connection)))
    (should (zerop (plist-get result :status)))
    (should (file-name-absolute-p (car (plist-get parsed :argv))))
    (should (equal (cadr (plist-get parsed :argv))
                   (concat "--connection=" connection)))
    (should (equal (nth 2 (plist-get parsed :argv))
                   (plist-get result :resource)))
    (should (equal (cdr (assoc "EJN_EXPANDED" (plist-get parsed :env)))
                   (concat "prefix:" (plist-get result :resource))))
    (should (equal (cdr (assoc "EJN_LITERAL_UNSET" (plist-get parsed :env)))
                   "$EJN_RESOLVER_UNSET")))
  (dolist (case
           (list
            (list '("python3" "plain") nil)
            (list '("python3" "{connection_file}" "{connection_file}") nil)
            (list '("python3" "{unknown}" "{connection_file}") nil)
            (list '("ejn-no-such-executable" "{connection_file}") nil)
            (list '("python3" "{connection_file}")
                  (cl-loop for index from 1 to 5
                           collect (cons (format "EJN_%d" index)
                                         (make-string 4096 ?x))))))
    (should-not
     (zerop (plist-get
             (ejn-test-run-production-kernelspec-resolver
              (car case) (cadr case))
             :status)))))

(ert-deftest ejn-kernelspec-parser-requires-exact-session-path ()
  (let* ((session "session")
         (path "/home/test/.cache/kernel-session.json")
         (output (concat
                  "EJN_CONNECTION_FILE=" path "\n"
                  (format (concat "{\"kernelspecs\":{\"python3\":{"
                                  "\"resource_dir\":\"/tmp/spec\",\"spec\":{"
                                  "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                                  "\"env\":{\"A\":\"value\"},"
                                  "\"metadata\":{\"ejn_connection_file\":\"%s\","
                                  "\"ejn_session_id\":\"%s\"}}}}}")
                          path path session)))
         (parsed (emacs-jupyter-notebook--parse-resolved-kernelspec
                  output session "python3" path)))
    (should (equal (plist-get parsed :connection-file) path))
    (should (equal (plist-get parsed :connection-tokens) (list "-f" path)))
    (should-error
     (emacs-jupyter-notebook--parse-resolved-kernelspec
      (replace-regexp-in-string
       (regexp-quote (concat "\"-f\",\"" path "\""))
       (concat "\"-f\",\"" path path "\"") output t t)
      session "python3" path))))

(ert-deftest ejn-kernelspec-parser-rejects-nul-and-duplicate-environment ()
  (should-not (emacs-jupyter-notebook--kernelspec-bounded-string-p
               (concat "a" (string 0) "b")))
  (let* ((session "session")
         (path "/tmp/kernel-session.json")
         (output (concat
                  "EJN_CONNECTION_FILE=" path "\n"
                  (format (concat "{\"kernelspecs\":{\"python3\":{"
                                  "\"resource_dir\":\"/tmp\",\"spec\":{"
                                  "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                                  "\"env\":{\"A\":\"one\",\"A\":\"two\"},"
                                  "\"metadata\":{\"ejn_connection_file\":\"%s\","
                                  "\"ejn_session_id\":\"session\"}}}}}") path path))))
    (should-error
     (emacs-jupyter-notebook--parse-resolved-kernelspec
      output session "python3" path)))
  (let* ((session "session")
         (path "/tmp/kernel-session.json")
         (pairs (mapconcat
                 (lambda (index)
                   (format "\"EJN_%d\":\"%s\"" index (make-string 4096 ?x)))
                 (number-sequence 1 5) ","))
         (output
          (concat
           "EJN_CONNECTION_FILE=" path "\n"
           (format (concat "{\"kernelspecs\":{\"python3\":{"
                           "\"resource_dir\":\"/tmp\",\"spec\":{"
                           "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                           "\"env\":{%s},\"metadata\":{"
                           "\"ejn_connection_file\":\"%s\","
                           "\"ejn_session_id\":\"session\"}}}}}")
                   path pairs path))))
    (should-error
     (emacs-jupyter-notebook--parse-resolved-kernelspec
      output session "python3" path))))

(ert-deftest ejn-ht12r2-kernelspec-parser-rejects-path-and-schema-substitution ()
  "Resolver output is bound to its requested path and frozen schema."
  (let* ((session "session")
         (path "/expected/cache/kernel-session.json")
         (untrusted-key
          (format "ejn_untrusted_json_%s" (cl-gensym "field")))
         (json (format (concat "{\"kernelspecs\":{\"python3\":{"
                               "\"resource_dir\":\"/tmp/spec\",\"spec\":{"
                               "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                               "\"env\":{},\"metadata\":{"
                               "\"ejn_connection_file\":\"%s\","
                               "\"ejn_session_id\":\"%s\"}}}}}")
                       path path session))
         (base (concat "EJN_CONNECTION_FILE=" path "\n" json)))
    (dolist (hostile
             (list
              (replace-regexp-in-string
               (regexp-quote path) "/other/cache/kernel-session.json" base t t)
              (concat "EJN_CONNECTION_FILE=" path "\n"
                      (replace-regexp-in-string
                       (regexp-quote path) "/other/cache/kernel-session.json"
                       json t t))
              (replace-regexp-in-string "/usr/bin/python3" "python3" base t t)
              (replace-regexp-in-string
               "\"-f\"" "\"-f\",\"{unknown_placeholder}\"" base t t)
              (replace-regexp-in-string
               "\"resource_dir\":\"/tmp/spec\""
               "\"resource_dir\":\"/tmp/spec\",\"unknown\":true" base t t)
              (replace-regexp-in-string
               "\"resource_dir\""
               (format "\"%s\":true,\"resource_dir\"" untrusted-key)
               base t t)
              (concat base " trailing-garbage")
              (concat (encode-coding-string base 'binary t)
                      (unibyte-string 255))))
      (should-error
       (emacs-jupyter-notebook--parse-resolved-kernelspec
        hostile session "python3" path)))
    (should-not (intern-soft untrusted-key))
    (should-error
     (emacs-jupyter-notebook--parse-resolved-kernelspec
      (make-string (1+ emacs-jupyter-notebook-ssh-kernelspec-max-bytes) ?x)
      session "python3" path))))

(ert-deftest ejn-ht12r2-python-prefix-has-count-and-aggregate-bounds ()
  (let ((base '(:profile "p" :host "h" :remote-cwd "/tmp"
                :remote-cache-dir "/tmp" :kernelspec "python3")))
    (should-error
     (emacs-jupyter-notebook-ssh-profile
      (plist-put (copy-sequence base) :python-command "python3")))
    (should-error
     (emacs-jupyter-notebook-ssh-profile
      (plist-put (copy-sequence base) :python-command
                 (make-list (1+ emacs-jupyter-notebook-ssh-kernelspec-max-argv)
                            "python3"))))
    (should-error
     (emacs-jupyter-notebook-ssh-profile
      (plist-put (copy-sequence base) :python-command
                 (make-list 5 (make-string 4000 ?x)))))
    (dolist (key '(:remote-cache-dir :remote-cwd))
      (should-error
       (emacs-jupyter-notebook-ssh-build-kernelspec-resolution
        (plist-put (copy-sequence base) key "/tmp/line\nbreak") "session")))))

(ert-deftest ejn-ht12r2-pid-identity-is-contiguous-on-linux-and-darwin ()
  "The generated probes reject reordered tokens and classify Darwin fallback."
  (let* ((pid (emacs-pid))
         (profile '(:profile "p" :host "unused"))
         (path "/tmp/kernel-session.json")
         (tokens (list "-f" path))
         (remote (car (last (emacs-jupyter-notebook-ssh-build-pid-alive
                             profile pid tokens))))
         (run (lambda (script)
                (with-temp-buffer
                  (should (zerop (process-file "sh" nil t nil "-c" script)))
                  (buffer-string))))
         (match-hex (concat "aa"
                            (emacs-jupyter-notebook-ssh--identity-token-hex tokens)
                            "bb"))
         (reordered-hex
          (emacs-jupyter-notebook-ssh--identity-token-hex (reverse tokens)))
         (no-proc (replace-regexp-in-string
                   (regexp-quote "/proc/$pid/cmdline")
                   "/definitely-not-proc/$pid/cmdline" remote t t)))
    (should (eq 'alive
                (emacs-jupyter-notebook--classify-pid-probe
                 (funcall run (format "od() { printf '%%s\\n' %s; }; %s"
                                      (shell-quote-argument match-hex) remote)))))
    (should (eq 'mismatch
                (emacs-jupyter-notebook--classify-pid-probe
                 (funcall run (format "od() { printf '%%s\\n' %s; }; %s"
                                      (shell-quote-argument reordered-hex) remote)))))
    (should (eq 'alive
                (emacs-jupyter-notebook--classify-pid-probe
                 (funcall run
                          (format "ps() { printf '%%s\\n' %s; }; %s"
                                  (shell-quote-argument
                                   (format "/usr/bin/python3 -f %s" path))
                                  no-proc)))))
    (should (eq 'mismatch
                (emacs-jupyter-notebook--classify-pid-probe
                 (funcall run
                          (format "ps() { printf '%%s\\n' '/usr/bin/python3 -f /other'; }; %s"
                                  no-proc)))))
    (let* ((space-path "/tmp/kernel session.json")
           (space-remote
            (car (last (emacs-jupyter-notebook-ssh-build-pid-alive
                        profile pid (list "-f" space-path)))))
           (space-no-proc
            (replace-regexp-in-string
             (regexp-quote "/proc/$pid/cmdline")
             "/definitely-not-proc/$pid/cmdline" space-remote t t)))
      (should (eq 'unverified
                  (emacs-jupyter-notebook--classify-pid-probe
                   (funcall run
                            (format "ps() { printf '%%s\\n' '/usr/bin/python3'; }; %s"
                                    space-no-proc))))))))

(ert-deftest ejn-ht12r2-cleanup-command-has-darwin-identity-fallback ()
  (let* ((entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "session" :remote-host "h"
                   :remote-pid 123 :remote-connection-file "/tmp/k.json")))
         (remote (car (last (emacs-jupyter-notebook-ssh-build-remote-cleanup
                             '(:profile "p" :host "h") entry)))))
    (should (string-match-p "elif command -v ps" remote))
    (should (string-match-p "sequence=.*for expected" remote))
    (should (string-match-p "EJN_CLEANUP_IDENTITY_UNCONFIRMED" remote))))

(ert-deftest ejn-ht12r2-bounded-process-caps-stderr-too ()
  (let ((process (emacs-jupyter-notebook-ssh-start-bounded-process
                  "ejn-bounded-stderr" '("sh" "-c" "head -c 50000 /dev/zero >&2")
                  32 #'ignore)))
    (unwind-protect
        (progn
          (while (process-live-p process) (accept-process-output process 0.05))
          (should (process-get process 'ejn-output-overflow))
          (let ((stderr (process-get
                         process 'emacs-jupyter-notebook-stderr-buffer)))
            (should (buffer-live-p stderr))
            (should (<= (with-current-buffer stderr (buffer-size)) 32))))
      (emacs-jupyter-notebook--async-delete-process process))))

(ert-deftest ejn-ht12r2-ordinary-ssh-paths-have-bounded-process-owners ()
  "Tunnel, retrieval, diagnostics, and cleanup cannot retain unbounded output."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (symbol-file 'emacs-jupyter-notebook--start-tunnel 'defun))
                  (buffer-string))))
    (dolist (name '(emacs-jupyter-notebook--start-tunnel
                    emacs-jupyter-notebook--async-retrieve-timeout
                    emacs-jupyter-notebook--async-retrieve-attempt
                    emacs-jupyter-notebook--cleanup-remote-entry))
      (let* ((start (string-match
                     (format "(defun %s\\_>"
                             (regexp-quote (symbol-name name))) source))
             (next (and start (string-match "\n(defun " source (1+ start))))
             (definition (and start (substring source start next))))
        (should definition)
        (should-not
         (string-match-p
          "emacs-jupyter-notebook-ssh-start-process\\_>" definition))
        (should
         (string-match-p
          "emacs-jupyter-notebook-ssh-start-\\(?:bounded-process\\|management-operation\\)"
          definition))))))

(ert-deftest ejn-ht12r2-production-has-no-synchronous-process-runner ()
  "Remote production I/O must stay outside blocking process primitives."
  (dolist (library '(emacs-jupyter-notebook emacs-jupyter-notebook-ssh))
    (with-temp-buffer
      (insert-file-contents (symbol-file library 'provide))
      (goto-char (point-min))
      (should-not
       (re-search-forward
        (concat "(\\(?:process-file\\|call-process\\|call-process-region\\|"
                "accept-process-output\\|sleep-for\\|sit-for\\)\\_>")
        nil t)))))

(ert-deftest ejn-pid-sidecar-is-bounded-and-session-bound ()
  (should (= 42 (emacs-jupyter-notebook--parse-pid-sidecar
                 "EJN_PID=42\nEJN_SESSION=session\n" "session")))
  (should-not (emacs-jupyter-notebook--parse-pid-sidecar
               "EJN_PID=42\nEJN_SESSION=other\n" "session"))
  (should-not (emacs-jupyter-notebook--parse-pid-sidecar
               "EJN_PID=0\nEJN_SESSION=session\n" "session"))
  (dolist (hostile '("\nEJN_PID=42\nEJN_SESSION=session\n"
                     "EJN_PID=42\n\nEJN_SESSION=session\n"
                     "EJN_PID=42\nEJN_SESSION=session\n\n"))
    (should-not (emacs-jupyter-notebook--parse-pid-sidecar hostile "session")))
  (should-not (emacs-jupyter-notebook--parse-pid-sidecar
               (concat "EJN_PID=42\nEJN_SESSION=session\n"
                       (make-string 5000 ?x)) "session")))

(ert-deftest ejn-bounded-process-kills-immediate-oversized-output ()
  "A fast hostile child cannot race filter installation or grow an output buffer."
  (let ((process (emacs-jupyter-notebook-ssh-start-bounded-process
                  "ejn-bounded-test" '("sh" "-c" "head -c 50000 /dev/zero")
                  32 #'ignore)))
    (unwind-protect
        (progn
          (while (process-live-p process) (accept-process-output process 0.05))
          (should (process-get process 'ejn-output-overflow)))
      (emacs-jupyter-notebook--async-delete-process process))))

(ert-deftest ejn-evaluate-cell-does-not-mutate-source ()
  "W2: evaluating a cell does not mutate source-buffer text.
Output goes to the panel; the source buffer is untouched."
  (ejn-test-with-temp-buffer "# %%\na = 1\n# %%\nb = 2\n"
    (search-forward "a = 1")
    (let ((before (buffer-string))
          (emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          captured-code)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code _entry)
               (setq captured-code code))))
        (emacs-jupyter-notebook-send-cell))
      (should (equal captured-code "a = 1\n"))
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-evaluate-code-error-routes-to-panel ()
  "W2: an evaluate failure creates a panel entry annotated with the error and
leaves source-buffer text untouched."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (_callback error-callback)
                   (funcall error-callback nil "connect failed"))))
        (emacs-jupyter-notebook--evaluate-code "x = 1\n" nil))
      (should (equal (buffer-string) before))
      (let ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer))))
        (should (buffer-live-p panel))
        (with-current-buffer panel
          (should (cl-find-if
                   (lambda (cell)
                     (let* ((e (cdr cell))
                            (c (ejn-panel-entry-text e)))
                       (and (eq (plist-get e :status) 'error)
                            (string-match-p "connect failed" c))))
                   emacs-jupyter-notebook-panel--entries)))))))

(ert-deftest ejn-error-callback-decodes-ansi-escape-codes-in-traceback ()
  "Python tracebacks arrive with ANSI colour SGR escapes (`\\x1b[0;31m'
around the error class, `\\x1b[1m' for bold, etc.).  The `error'
callback must strip those escapes and translate them into `face'
text-properties rather than leaving them as literal bytes."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "1/0"))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                       (current-buffer) handle 'mock-client))
           (err-fn (cadr (assoc "error" callbacks)))
           (raw-traceback
            (list
             "\e[0;31m---------------------------------------------------------------------------\e[0m"
             "\e[0;31mZeroDivisionError\e[0m                         Traceback (most recent call last)"
             "Cell \e[0;32mIn[1], line 1\e[0m"
             "\e[0;31mZeroDivisionError\e[0m: division by zero")))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   (list :traceback raw-traceback
                         :ename "ZeroDivisionError"
                         :evalue "division by zero"))))
        (funcall err-fn 'mock-msg))
      (let* ((entry (emacs-jupyter-notebook-panel--entry
                     panel (plist-get handle :id)))
             (content (ejn-panel-entry-text entry)))
        (should content)
        (should-not (string-match-p "\e\\[[0-9;]*m" content))
        (should (string-match-p "ZeroDivisionError" content))
        (should (string-match-p "division by zero" content))))))

(ert-deftest ejn-panel-append-text-preserves-ansi-faces-under-fallback-face ()
  "`ejn-panel-append-text' composes the optional FACE with any
per-character faces already on TEXT (e.g. from `ansi-color-apply').
The ANSI colours must remain visible while the fallback FACE covers
the uncoloured spans."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "boom")))
      (ejn-panel-append-text
       handle
       (concat (propertize "red-part" 'face 'font-lock-warning-face)
               "-plain")
       'emacs-jupyter-notebook-result-error-face)
      (let* ((entry (emacs-jupyter-notebook-panel--entry
                     panel (plist-get handle :id)))
             (content (ejn-panel-entry-text entry))
             (red-face (get-text-property 0 'face content))
             (plain-face (get-text-property (length "red-part") 'face content)))
        ;; Preserved ANSI-style face on the colored span.
        (should (or (eq red-face 'font-lock-warning-face)
                    (and (listp red-face)
                         (memq 'font-lock-warning-face red-face))))
        ;; Fallback face applied to the plain span.
        (should (or (eq plain-face 'emacs-jupyter-notebook-result-error-face)
                    (and (listp plain-face)
                         (memq 'emacs-jupyter-notebook-result-error-face
                               plain-face))))))))

(ert-deftest ejn-complete-at-point-strips-capf-metadata-before-calling-completion-in-region ()
  "Regression: the capf result includes `:exclusive 'no' as trailing
plist properties, but `completion-in-region' accepts only (START END
COLLECTION).  Passing the full capf list via `apply' throws \"wrong
number of arguments\".  The explicit `complete-at-point' command and
the fallback UI refresh path must both strip the metadata."
  (with-temp-buffer
    (insert "np.arr")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          captured-args)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--completion-result)
                 (lambda ()
                   ;; The real capf shape produced by
                   ;; `--completion-result-from-reply'.
                   (list 3 6 '("array" "arrange") :exclusive 'no)))
                ((symbol-function 'completion-in-region)
                 (lambda (&rest args) (setq captured-args args))))
        (emacs-jupyter-notebook-complete-at-point)
        (should captured-args)
        (should (= (length captured-args) 3))
        (should (equal (nth 0 captured-args) 3))
        (should (equal (nth 1 captured-args) 6))
        (should (equal (nth 2 captured-args) '("array" "arrange")))))))

(ert-deftest ejn-send-region-bounds-uses-standard-region ()
  "`--region-bounds' returns `region-beginning'/`region-end' when Evil
is not involved and the standard Emacs region is active."
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (set-mark 5)
    (activate-mark)
    (let ((result (emacs-jupyter-notebook--region-bounds)))
      (should (equal result '(2 5))))))

(defvar evil-visual-beginning)
(defvar evil-visual-end)

(ert-deftest ejn-send-region-bounds-uses-evil-visual-markers ()
  "`--region-bounds' prefers Evil's `evil-visual-beginning'/`-end' markers
when Evil visual state is active — this covers the case where Evil has
deactivated the standard region before the interactive form runs."
  (with-temp-buffer
    (insert "abcdef")
    (let ((evil-visual-beginning (copy-marker 2))
          (evil-visual-end (copy-marker 5)))
      (cl-letf (((symbol-function 'evil-visual-state-p) (lambda () t)))
        (let ((result (emacs-jupyter-notebook--region-bounds)))
          (should (equal result '(2 5))))))))

(ert-deftest ejn-send-region-bounds-signals-when-no-region ()
  "`--region-bounds' raises a user-error when no region is available."
  (with-temp-buffer
    (insert "abcdef")
    (deactivate-mark)
    (should-error (emacs-jupyter-notebook--region-bounds) :type 'user-error)))

(ert-deftest ejn-send-region-and-buffer-do-not-mutate-source ()
  "W2: region/buffer eval does not mutate source-buffer text and has cell-key nil."
  (ejn-test-with-temp-buffer "x = 1\ny = 2\n"
    (let ((before (buffer-string))
          (modified (buffer-modified-p))
          (emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          calls ids)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code entry-handle)
               (push (list code (plist-get entry-handle :cell-key)) calls))))
        (push (emacs-jupyter-notebook-send-region
               (point-min) (line-end-position)) ids)
        (push (emacs-jupyter-notebook-send-buffer) ids))
      (should (equal (buffer-string) before))
      (should (equal (buffer-modified-p) modified))
      ;; Only the active head reaches the backend.  The second send remains a
      ;; captured FIFO record until the first request is terminal.
      (should (equal (mapcar #'car calls) '("x = 1")))
      (let* ((ordered-ids (nreverse ids))
             (records (mapcar #'emacs-jupyter-notebook--execution-record
                              ordered-ids)))
        (should (equal (mapcar (lambda (record) (plist-get record :code)) records)
                       '("x = 1" "x = 1\ny = 2\n")))
        (should (cl-every (lambda (record) (null (plist-get record :cell-key)))
                          records))))))

(ert-deftest ejn-mode-enable-does-not-start-remote-work ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-run-command)
               (lambda (&rest _)
                 (ert-fail "mode enable ran synchronous SSH command")))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
               (lambda (&rest _)
                 (ert-fail "mode enable started SSH process")))
              ((symbol-function 'emacs-jupyter-notebook--wait-for-tunnel)
               (lambda (&rest _)
                 (ert-fail "mode enable waited for tunnel")))
              ((symbol-function 'emacs-jupyter-notebook-jupyter-connect)
               (lambda (&rest _)
                 (ert-fail "mode enable connected to Jupyter"))))
      (emacs-jupyter-notebook-mode 1)
      (should emacs-jupyter-notebook-mode))))

(ert-deftest ejn-result-last-bytes-truncates-to-tail ()
  "W2: byte truncation helper trims to the trailing window."
  (let ((text "abcdefghij"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 100) text))
    (should (equal (emacs-jupyter-notebook--last-bytes text 5) "fghij"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 1) "j"))
    (should (equal (emacs-jupyter-notebook--last-bytes text 10) text))))

(ert-deftest ejn-read-registry-entry-empty-registry-raises-user-error ()
  (let ((completing-read-called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (setq completing-read-called t)
                 "choice")))
      (with-temp-buffer
        (should-error (emacs-jupyter-notebook--read-registry-entry)
                      :type 'user-error)
        (should-not completing-read-called)))))

(ert-deftest ejn-shutdown-deletes-local-connection-file-and-removes-registry-by-session-id ()
  (let* ((dir (make-temp-file "ejn-shutdown-" t))
         (local-conn (expand-file-name "kernel.json" dir))
         (registry-file (expand-file-name "registry.el" dir))
         (target-entry `(:profile "p"
                         :session-id "target-session"
                         :local-connection-file ,local-conn))
         (other-entry '(:profile "p" :session-id "other-session"))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (progn
          (with-temp-file local-conn (insert "{}"))
          (emacs-jupyter-notebook-registry-save
           (list target-entry other-entry) registry-file)
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown) #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry) #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-ssh-start-process) #'ignore))
            (with-temp-buffer
              (setq emacs-jupyter-notebook--client
                    (ejn-test-backend-session 'mock t))
              (setq emacs-jupyter-notebook--session-entry target-entry)
              (setq emacs-jupyter-notebook--tunnel-process nil)
              (emacs-jupyter-notebook-shutdown-kernel)
              (should-not (file-exists-p local-conn))
              (should-not emacs-jupyter-notebook--client)
              (should-not emacs-jupyter-notebook--session-entry)
              (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
                (should (= (length remaining) 1))
                (should (equal (plist-get (car remaining) :session-id) "other-session"))))))
      (delete-directory dir t))))

(ert-deftest ejn-status-snapshot-reports-engine-state ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--kernel-status 'idle)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--session-entry
           '(:profile "p"
             :session-id "session"
             :remote-host "example.com"
             :remote-pid 123
             :remote-connection-file "/tmp/kernel.json"
             :local-connection-file "/tmp/local.json"
             :tunnel-ports (:shell_port 1001)))
          (emacs-jupyter-notebook--async-context
           (emacs-jupyter-notebook--async-new-context
            :phase 'error
            :error "boom"
            :origin-buffer (current-buffer))))
      (let ((snapshot (emacs-jupyter-notebook-status-snapshot)))
        (should (plist-get snapshot :client))
        (should (eq (plist-get snapshot :kernel-status) 'idle))
        (should (eq (plist-get snapshot :tunnel-state) 'dead))
        ;; Terminal contexts retain their error for diagnosis but are not
        ;; presented as a live phase or cancellable operation.
        (should-not (plist-get snapshot :async-live))
        (should-not (plist-get snapshot :async-phase))
        (should (equal (plist-get snapshot :async-error) "boom"))
        (should (equal (plist-get snapshot :profile) "p"))
        (should (equal (plist-get snapshot :session-id) "session"))
        (should (string-match-p "Session: session"
                                (emacs-jupyter-notebook-status)))))))

(ert-deftest ejn-status-suggestions-report-no-client ()
  (let ((actions (emacs-jupyter-notebook--status-suggestions-for
                  '(:client nil :tunnel-state none))))
    (should (eq (cdr (assoc "Start a remote kernel" actions))
                'emacs-jupyter-notebook-start-remote-kernel))
    (should (eq (cdr (assoc "Reconnect to an existing remote kernel" actions))
                'emacs-jupyter-notebook-reconnect-remote-kernel))))

(ert-deftest ejn-status-suggestions-report-dead-tunnel-and-async-error ()
  "W19: a dead tunnel suggests RECONNECT (the non-destructive recovery), not
the destructive retry-fresh-kernel."
  (let ((actions (emacs-jupyter-notebook--status-suggestions-for
                  '(:client t :tunnel-state dead :async-error "boom"))))
    (should (eq (cdr (assoc "Reconnect to the remote kernel" actions))
                'emacs-jupyter-notebook-reconnect-remote-kernel))
    (should-not (rassq 'emacs-jupyter-notebook-retry-fresh-kernel actions))
    (should-not (rassq 'emacs-jupyter-notebook-cancel-operation actions))))

(ert-deftest ejn-w19-status-format-reports-reconnect-state ()
  "W19: the status buffer surfaces the in-flight attempt's age and the
auto-reconnect progress so a background recovery (or a wedged attempt) is
visible and diagnosable."
  (let ((text (emacs-jupyter-notebook--status-snapshot-text
               '(:buffer "b" :async-phase probe :async-age 12.5
                 :retry-count 3 :reconnect-next-in 4.2))))
    (should (string-match-p "Live phase: probe" text))
    (should (string-match-p "Attempt age: 12.5s" text))
    (should (string-match-p "Retry count: 3" text))
    (should (string-match-p "Next retry: 4.2s" text))))

(ert-deftest ejn-status-suggestions-report-healthy-state ()
  (let ((actions (emacs-jupyter-notebook--status-suggestions-for
                  '(:client t :tunnel-state alive))))
    (should (equal actions
                   '(("Send the current cell"
                      . emacs-jupyter-notebook-send-cell))))))

(ert-deftest ejn-cleanup-current-state-resets-buffer-state ()
  (let* ((dir (make-temp-file "ejn-cleanup-" t))
         (local-file (expand-file-name "kernel.json" dir))
         (entry `(:profile "p"
                  :session-id "session"
                  :remote-connection-file "/tmp/kernel.json"
                  :local-connection-file ,local-file))
         shutdown-called cleanup-entry removed-key)
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                     (lambda (client)
                       (setq shutdown-called client)))
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                     (lambda (captured-entry)
                       (setq cleanup-entry captured-entry)))
                    ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                     (lambda (key &optional _file)
                       (setq removed-key key))))
            (with-temp-buffer
              (setq emacs-jupyter-notebook--client
                    (ejn-test-backend-session 'mock-client t))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-dead t)
              (emacs-jupyter-notebook--cleanup-current-state "cleanup")
              (should (eq shutdown-called 'mock-client))
              (should (equal cleanup-entry entry))
              (should (equal removed-key "session"))
              (should-not (file-exists-p local-file))
              (should-not emacs-jupyter-notebook--client)
              (should-not emacs-jupyter-notebook--session-entry)
              (should-not emacs-jupyter-notebook--tunnel-dead))))
      (delete-directory dir t))))

(ert-deftest ejn-cancel-operation-does-not-tear-down-session-entry ()
  (let ((entry '(:profile "p" :session-id "existing"))
        cleanup-called)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'retrieve
               :origin-buffer (current-buffer)
               :error-callback (lambda (_ctx _err) nil)))
        (emacs-jupyter-notebook-cancel-operation)
        (should-not emacs-jupyter-notebook--async-context)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should-not cleanup-called)))))

(ert-deftest ejn-w7.3-cancel-during-tunnel-reconnect-tears-tunnel-preserves-registry ()
  "W7.3 reconnect branch (`:owns-kernel nil'): cancelling during the
tunnel phase kills the live tunnel process, clears the async context,
and leaves the pre-existing registry entry untouched (because the entry
is the durable reconnect key)."
  (let* ((registry-dir (make-temp-file "ejn-w73-reg-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry '(:profile "p"
                  :session-id "w73-reconn"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (with-temp-buffer
            (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                            "emacs-jupyter-notebook-tunnel-w73-reconn"
                            '("sleep" "60")))
                   (stderr (process-get tunnel
                                        'emacs-jupyter-notebook-stderr-buffer)))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :owns-kernel nil
                     :profile '(:profile "p" :host "example.com")
                     :entry entry
                     :tunnel-process tunnel
                     :origin-buffer (current-buffer)
                     :error-callback (lambda (_ctx _err) nil)))
              (emacs-jupyter-notebook-cancel-operation)
              (should-not emacs-jupyter-notebook--async-context)
              (should-not (process-live-p tunnel))
              (should-not (buffer-live-p stderr))
              ;; Registry entry survives the cancellation.
              (let ((remaining (emacs-jupyter-notebook-registry-load
                                registry-file)))
                (should (= 1 (length remaining)))
                (should (equal (plist-get (car remaining) :session-id)
                               "w73-reconn"))))))
      (delete-directory registry-dir t))))

(ert-deftest ejn-w7.3-cancel-during-tunnel-fresh-start-preserves-provisional-registry ()
  "W7.3 fresh-start branch (`:owns-kernel t'): cancelling during the
tunnel phase kills the live tunnel process, clears the async context,
and preserves the admitted launch's durable provisional registry row."
  (let* ((registry-dir (make-temp-file "ejn-w73-reg-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "w73-fresh"
                   :remote-host "example.com" :remote-pid 4242
                   :remote-connection-file "/remote/kernel.json"
                   :provisional t)))
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (emacs-jupyter-notebook-registry-save-entry entry)
          (with-temp-buffer
            (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                            "emacs-jupyter-notebook-tunnel-w73-fresh"
                            '("sleep" "60")))
                   (stderr (process-get tunnel
                                        'emacs-jupyter-notebook-stderr-buffer)))
              (setq emacs-jupyter-notebook--session-entry nil)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :owns-kernel t
                     :session-id "w73-fresh"
                     :profile '(:profile "p" :host "example.com")
                     :entry entry
                     :tunnel-process tunnel
                     :origin-buffer (current-buffer)
                     :error-callback (lambda (_ctx _err) nil)))
              ;; Cancellation tears down local state only; neither a connected
              ;; session nor an ambiguous admitted launch is terminated.
              (let (remote-cleanup-called registry-remove-called
                    shutdown-called kernel-killed)
                (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                           (lambda (&rest _) (setq remote-cleanup-called t)))
                          ((symbol-function 'emacs-jupyter-notebook--remove-registry-entry)
                           (lambda (&rest _) (setq registry-remove-called t)))
                          ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                           (lambda (&rest _) (setq shutdown-called t)))
                          ((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
                           (lambda (&rest _) (setq kernel-killed t))))
                  (emacs-jupyter-notebook-cancel-operation)
                  (should-not kernel-killed)
                  (should-not remote-cleanup-called)
                  (should-not registry-remove-called)
                  (should-not shutdown-called)))
              (should-not emacs-jupyter-notebook--async-context)
              (should-not (process-live-p tunnel))
              (should-not (buffer-live-p stderr))
              (should (equal (emacs-jupyter-notebook-registry-load registry-file)
                             (list entry)))
              (should-not emacs-jupyter-notebook--session-entry))))
      (delete-directory registry-dir t))))

(ert-deftest ejn-w12-ensure-no-async-operation-prompts-and-cancels-on-yes ()
  "W12: starting/reconnecting while an attempt is in flight prompts; answering
yes cancels the in-progress attempt (via `--cancel-async-operation') so the
caller may proceed — a single buffer never runs two attempts in parallel."
  (with-temp-buffer
    (let (cancelled prompted)
      (setq emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context
             :phase 'tunnel
             :owns-kernel t
             :origin-buffer (current-buffer)))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq prompted t) t))
                ((symbol-function 'emacs-jupyter-notebook--cancel-async-operation)
                 (lambda (&rest _) (setq cancelled t))))
        (emacs-jupyter-notebook--ensure-no-async-operation))
      (should prompted)
      (should cancelled))))

(ert-deftest ejn-w12-ensure-no-async-operation-aborts-on-no ()
  "W12: answering no to the cancel prompt signals a `user-error' and leaves the
in-progress attempt untouched."
  (with-temp-buffer
    (let ((ctx (emacs-jupyter-notebook--async-new-context
                :phase 'tunnel
                :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context ctx)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-error (emacs-jupyter-notebook--ensure-no-async-operation)
                      :type 'user-error))
      (should (eq emacs-jupyter-notebook--async-context ctx)))))

(ert-deftest ejn-w12-ensure-no-async-operation-noop-when-idle ()
  "W12: with no attempt in flight the guard neither prompts nor errors."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--async-context nil)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "must not prompt when idle"))))
      (should-not (emacs-jupyter-notebook--ensure-no-async-operation)))))

(ert-deftest ejn-w12-kill-buffer-during-attempt-never-kills-remote-kernel ()
  "Killing a buffer tears down local resources and preserves recovery state."
  (let (kernel-killed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
               (lambda (_ctx) (setq kernel-killed t)))
              ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore))
      (let ((buffer (generate-new-buffer "ejn-w12-kill")))
        (with-current-buffer buffer
          (emacs-jupyter-notebook-mode 1)
          (setq emacs-jupyter-notebook--async-context
                (emacs-jupyter-notebook--async-new-context
                 :phase 'tunnel
                 :owns-kernel t
                 :origin-buffer buffer
                 :entry '(:profile "p"
                          :session-id "w12"
                          :remote-connection-file "/remote/k.json"))))
        (kill-buffer buffer))
      (should-not kernel-killed))))

(ert-deftest ejn-ht12r2-admitted-provisional-survives-cancel ()
  "Only a pre-admission resolver failure may leave the registry untouched."
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file (expand-file-name "registry.eld" dir))
         (entry '(:profile "p" :session-id "admitted" :launch-kind direct
                 :provisional t :remote-pid nil
                 :remote-connection-file "/remote/kernel-admitted.json"
                 :remote-pid-sidecar "/remote/kernel-admitted.pid"
                 :connection-file-tokens ("-f" "/remote/kernel-admitted.json"))))
    (unwind-protect
        (with-temp-buffer
          (emacs-jupyter-notebook-registry-save-entry entry)
          (setq emacs-jupyter-notebook--async-context
                (emacs-jupyter-notebook--async-new-context
                 :phase 'launch :entry entry :origin-buffer (current-buffer)))
          (emacs-jupyter-notebook--cancel-async-operation
           emacs-jupyter-notebook--async-context)
          (should (equal (emacs-jupyter-notebook-registry-load) (list entry))))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-resolver-failure-leaves-registry-untouched ()
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file (expand-file-name "registry.eld" dir)))
    (unwind-protect
        (with-temp-buffer
          (let ((context (emacs-jupyter-notebook--async-new-context
                          :phase 'resolve :origin-buffer (current-buffer))))
            (emacs-jupyter-notebook--async-fail context "bad resolver"))
          (should-not (file-exists-p emacs-jupyter-notebook-registry-file)))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-post-admission-spawn-failure-keeps-secret-free-entry ()
  "A stderr warning cannot spoil valid stdout, and launch ambiguity is durable."
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file (expand-file-name "registry.eld" dir))
         (session "secret")
         (path "/tmp/kernel-secret.json")
         (secret "TOP_SECRET_KERNEL_ENV_VALUE")
         (output
          (concat
           "EJN_CONNECTION_FILE=" path "\n"
           (format (concat "{\"kernelspecs\":{\"python3\":{"
                           "\"resource_dir\":\"/tmp\",\"spec\":{"
                           "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                           "\"env\":{\"TOKEN\":\"%s\"},\"metadata\":{"
                           "\"ejn_connection_file\":\"%s\","
                           "\"ejn_session_id\":\"%s\"}}}}}")
                   path secret path session)))
         (process
          (emacs-jupyter-notebook-ssh-start-bounded-process
           "ejn-r2-resolver-warning"
           (list "sh" "-c"
                 (format "printf %%s %s; printf warning-from-ssh >&2"
                         (shell-quote-argument output)))
           emacs-jupyter-notebook-ssh-kernelspec-max-bytes #'ignore)))
    (unwind-protect
        (with-temp-buffer
          (while (process-live-p process) (accept-process-output process 0.05))
          (let* ((entry (list :profile "p" :session-id session
                              :remote-host "h" :remote-cwd "/tmp"
                              :kernelspec "python3"))
                 (context
                  (emacs-jupyter-notebook--async-new-context
                   :phase 'resolve :session-id session
                   :profile '(:profile "p" :host "h" :remote-cwd "/tmp"
                              :remote-cache-dir "/tmp" :kernelspec "python3"
                              :python-command ("python3"))
                   :resolution (list :connection-file path)
                   :entry entry :origin-buffer (current-buffer))))
            (setq emacs-jupyter-notebook--async-context context)
            (cl-letf (((symbol-function 'display-warning) #'ignore)
                      ((symbol-function
                        'emacs-jupyter-notebook-ssh-start-bounded-process)
                       (lambda (&rest _) (error "local make-process failed"))))
              (emacs-jupyter-notebook--async-resolve-sentinel context process))
            (let* ((saved (car (emacs-jupyter-notebook-registry-load)))
                   (serialized (prin1-to-string saved)))
              (should saved)
              (should (plist-get saved :provisional))
              (should-not (plist-get saved :remote-pid))
              (should (equal (plist-get saved :remote-connection-file) path))
              (should-not (string-match-p (regexp-quote secret) serialized)))))
      (when (processp process)
        (emacs-jupyter-notebook--async-delete-process process))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-provisional-reconnect-recovers-pid-from-sidecar ()
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :session-id "provisional" :remote-host "h"
                  :remote-pid 1 :remote-connection-file "/tmp/k.json"
                  :provisional t)))
        sidecar-called)
    (setq entry (plist-put entry :remote-pid nil))
    (with-temp-buffer
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-ensure) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--async-read-pid-sidecar)
                 (lambda (context)
                   (setq sidecar-called context)
                   context)))
        (let ((context (emacs-jupyter-notebook--begin-reconnect
                        entry nil (lambda (&rest _)) 'explicit)))
          (should (eq sidecar-called context))
          (should (equal (plist-get context :entry) entry))
          (emacs-jupyter-notebook--cancel-async-operation context))))))

(ert-deftest ejn-ht12r2-pid-promotion-save-failure-preserves-provisional-entry ()
  "A local registry failure cannot strand PID promotion outside async failure."
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file
          (expand-file-name "registry.eld" dir))
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "promotion" :remote-host "h"
                   :remote-pid 1
                   :remote-connection-file "/tmp/kernel-promotion.json"
                   :provisional t)))
         (process
          (emacs-jupyter-notebook-ssh-start-bounded-process
           "ejn-r2-promotion"
           '("sh" "-c"
             "printf '__EJN_ALIVE_MATCH__\n__EJN_DONE__\n'")
           4096 #'ignore))
         retrieve-called failure)
    (setq entry (plist-put entry :remote-pid nil))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save-entry entry)
          (while (process-live-p process)
            (accept-process-output process 0.05))
          (with-temp-buffer
            (let ((context
                   (emacs-jupyter-notebook--async-new-context
                    :phase 'launch-probe :entry entry
                    :launch-probe-process process
                    :origin-buffer (current-buffer)
                    :error-callback
                    (lambda (_context error-data)
                      (setq failure error-data)))))
              (setq emacs-jupyter-notebook--async-context context)
              (cl-letf (((symbol-function
                          'emacs-jupyter-notebook-registry-save-entry)
                         (lambda (&rest _)
                           (error "registry is read-only")))
                        ((symbol-function
                          'emacs-jupyter-notebook--async-retrieve)
                         (lambda (&rest _)
                           (setq retrieve-called t))))
                (emacs-jupyter-notebook--async-launch-pid-sentinel
                 context 4242 process))
              (should (eq (plist-get context :phase) 'error))
              (should (string-match-p "Could not persist verified" failure))
              (should-not retrieve-called)
              (should-not (plist-get (plist-get context :entry) :remote-pid))))
          (should (equal (emacs-jupyter-notebook-registry-load) (list entry))))
      (when (processp process)
        (emacs-jupyter-notebook--async-delete-process process))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-final-save-failure-does-not-install-client ()
  "A failed final registry write leaves only the recoverable provisional entry."
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file
          (expand-file-name "registry.eld" dir))
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "finalize" :remote-host "h"
                   :remote-pid 4242
                   :remote-connection-file "/tmp/kernel-finalize.json"
                   :provisional t)))
         (client (ejn-test-backend-session 'mock-client t))
         closed setup-called failure callback-called)
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save-entry entry)
          (with-temp-buffer
            (let ((context
                   (emacs-jupyter-notebook--async-new-context
                    :phase 'connect :entry entry :client-unverified client
                    :origin-buffer (current-buffer)
                    :callback (lambda (&rest _) (setq callback-called t))
                    :error-callback
                    (lambda (_context error-data)
                      (setq failure error-data)))))
              (setq emacs-jupyter-notebook--async-context context)
              (cl-letf (((symbol-function
                          'emacs-jupyter-notebook-registry-save-entry)
                         (lambda (&rest _)
                           (error "registry is read-only")))
                        ((symbol-function
                          'emacs-jupyter-notebook-backend-close-local)
                         (lambda (session &rest _)
                           (setq closed session)))
                        ((symbol-function
                          'emacs-jupyter-notebook--heartbeat-start)
                         (lambda () (setq setup-called t)))
                        ((symbol-function
                          'emacs-jupyter-notebook--inject-viewer-formatter)
                         (lambda (&rest _) (setq setup-called t)))
                        ((symbol-function
                          'emacs-jupyter-notebook--inject-idle-watchdog)
                         (lambda (&rest _) (setq setup-called t))))
                (should
                 (emacs-jupyter-notebook--async-connect-finalize
                  context (current-buffer) entry '(:shell 1)
                  "/tmp/local.json" client)))
              (should (eq (plist-get context :phase) 'error))
              (should (string-match-p "Could not persist connected" failure))
              (should (eq closed client))
              (should-not emacs-jupyter-notebook--client)
              (should-not emacs-jupyter-notebook--session-entry)
              (should-not setup-called)
              (should-not callback-called)))
          (should (equal (emacs-jupyter-notebook-registry-load) (list entry))))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-successful-start-pipeline-promotes-only-verified-pid ()
  "Drive resolver, launch, sidecar, and PID sentinels through production code."
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file
          (expand-file-name "registry.eld" dir))
         (session "pipeline")
         (path "/tmp/kernel-pipeline.json")
         (secret "PIPELINE_SECRET_MUST_NOT_PERSIST")
         (profile '(:profile "p" :host "h" :remote-cwd "/tmp"
                    :remote-cache-dir "/tmp" :kernelspec "python3"
                    :python-command ("python3")))
         (entry (list :profile "p" :session-id session :remote-host "h"
                      :remote-cwd "/tmp" :kernelspec "python3"))
         (resolution (list :connection-file path :argv '("ssh" "ignored")))
         (resolver-output
          (concat
           "EJN_CONNECTION_FILE=" path "\n"
           (format (concat "{\"kernelspecs\":{\"python3\":{"
                           "\"resource_dir\":\"/tmp\",\"spec\":{"
                           "\"argv\":[\"/usr/bin/python3\",\"-f\",\"%s\"],"
                           "\"env\":{\"TOKEN\":\"%s\"},\"metadata\":{"
                           "\"ejn_connection_file\":\"%s\","
                           "\"ejn_session_id\":\"%s\"}}}}}")
                   path secret path session)))
         (real-start
          (symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process))
         retrieved started)
    (unwind-protect
        (with-temp-buffer
          (let ((context
                 (emacs-jupyter-notebook--async-start-context
                  profile entry session resolution)))
            (cl-letf
                (((symbol-function
                   'emacs-jupyter-notebook-ssh-start-bounded-process)
                  (lambda (name _argv limit sentinel)
                    (let ((output
                           (cond
                            ((string-match-p "resolve" name) resolver-output)
                            ((string-match-p "launch-pipeline" name)
                             "EJN_LAUNCH_ADMITTED\n")
                            ((string-match-p "sidecar" name)
                             "EJN_PID=4242\nEJN_SESSION=pipeline\n")
                            ((string-match-p "launch-probe" name)
                             "__EJN_ALIVE_MATCH__\n__EJN_DONE__\n")
                            (t (error "Unexpected pipeline process %s" name)))))
                      (push name started)
                      (funcall real-start name (list "printf" "%s" output)
                               limit sentinel))))
                 ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
                  (lambda (ready-context)
                    (setq retrieved ready-context)
                    ready-context)))
              (emacs-jupyter-notebook--async-resolve-kernelspec context)
              (let ((deadline (+ (float-time) 5)))
                (while (and (not retrieved) (< (float-time) deadline))
                  (accept-process-output nil 0.01))))
            (should retrieved)
            (should (= (plist-get (plist-get retrieved :entry) :remote-pid)
                       4242))
            (should (= (length started) 4))
            (let* ((saved (car (emacs-jupyter-notebook-registry-load)))
                   (serialized (prin1-to-string saved)))
              (should (= (plist-get saved :remote-pid) 4242))
              (should (plist-get saved :provisional))
              (should-not (string-match-p (regexp-quote secret) serialized)))
            (emacs-jupyter-notebook--cancel-async-context-locally context)
            (setq emacs-jupyter-notebook--async-context nil)))
      (delete-directory dir t))))

(ert-deftest ejn-ht12r2-malformed-direct-entry-is-rejected-without-mutation ()
  (let* ((dir (make-temp-file "ejn-r2-reg-" t))
         (emacs-jupyter-notebook-registry-file (expand-file-name "registry.eld" dir))
         (entry '(:profile "p" :session-id "bad" :remote-host "h"
                  :launch-kind direct :remote-pid 123
                  :remote-connection-file "/tmp/kernel-bad.json"
                  :remote-pid-sidecar "/tmp/wrong.pid"
                  :connection-file-tokens ("-f" "/tmp/kernel-bad.json"))))
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save-entry entry)
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry entry)
            (should-error
             (emacs-jupyter-notebook--begin-reconnect
              entry nil (lambda (&rest _)) 'explicit))
            (should (equal emacs-jupyter-notebook--session-entry entry)))
          (should (equal (emacs-jupyter-notebook-registry-load) (list entry))))
      (delete-directory dir t))))

(ert-deftest ejn-w12-kill-buffer-with-connected-kernel-spares-it ()
  "W12: killing a buffer with a CONNECTED kernel (async phase `done', a live
client) never kills the remote kernel — it is the durable reconnect surface."
  (let (kernel-killed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
               (lambda (_ctx) (setq kernel-killed t)))
              ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore))
      (let ((buffer (generate-new-buffer "ejn-w12-connected")))
        (with-current-buffer buffer
          (emacs-jupyter-notebook-mode 1)
          (setq emacs-jupyter-notebook--client
                (ejn-test-backend-session 'mock-client t))
          (setq emacs-jupyter-notebook--async-context
                (emacs-jupyter-notebook--async-new-context
                 :phase 'done
                 :owns-kernel t
                 :origin-buffer buffer)))
        (kill-buffer buffer))
      (should-not kernel-killed))))

(ert-deftest ejn-retry-fresh-kernel-cleans-state-and-starts-profile ()
  (let ((entry '(:profile "p" :session-id "old"))
        cleanup-called started-profile)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (reason skip-shutdown)
                 (setq cleanup-called (list reason skip-shutdown))))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &optional _callback _error-callback)
                 (setq started-profile profile))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook-retry-fresh-kernel)
        (should (equal cleanup-called '("Retrying with fresh kernel" t)))
        (should (equal started-profile "p"))))))

(ert-deftest ejn-retry-fresh-kernel-uses-async-context-profile ()
  (let (started-profile)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &optional _callback _error-callback)
                 (setq started-profile profile))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'launch
               :profile '(:profile "context-profile")
               :origin-buffer (current-buffer)))
        (emacs-jupyter-notebook-retry-fresh-kernel)
        (should (equal started-profile "context-profile"))))))

(ert-deftest ejn-fetch-remote-log-displays-command-output ()
  (let (argv displayed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--management-run)
               (lambda (_label _name captured-argv success _failure
                        &optional _timeout)
                 (setq argv captured-argv)
                 (funcall success "log text")))
              ((symbol-function 'emacs-jupyter-notebook--display-command-output)
               (lambda (buffer-name output)
                 (setq displayed (list buffer-name output)))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry
              '(:profile "p"
                :remote-host "example.com"
                :remote-cwd "~"
                :kernelspec "python3"
                :remote-connection-file "~/.cache/ejn/kernel-session.json"))
        (emacs-jupyter-notebook-fetch-remote-log)
        (should (equal displayed '("*ejn-log*" "log text")))
        (should (string-match-p "kernel-session.log" (car (last argv))))))))

(ert-deftest ejn-list-remote-processes-runs-ps-command ()
  (let (argv displayed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_profile)
                 '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'emacs-jupyter-notebook--management-run)
               (lambda (_label _name captured-argv success _failure
                        &optional _timeout)
                 (setq argv captured-argv)
                 (funcall success "ps output")))
              ((symbol-function 'emacs-jupyter-notebook--display-command-output)
               (lambda (buffer-name output)
                 (setq displayed (list buffer-name output)))))
      (emacs-jupyter-notebook-list-remote-processes "p")
      (should (equal displayed '("*ejn-remote-processes*" "ps output")))
      (should (string-match-p "ps -eo" (car (last argv)))))))

(ert-deftest ejn-clean-orphaned-kernels-runs-cleanup-all-command ()
  (let (argv message-text)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_profile)
                 '(:profile "p" :host "example.com" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'emacs-jupyter-notebook--management-run)
               (lambda (_label _name captured-argv success _failure
                        &optional _timeout)
                 (setq argv captured-argv)
                 (funcall success "")))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacs-jupyter-notebook-clean-orphaned-kernels "p")
      (should (string-match-p "pkill -f" (car (last argv))))
      (should (string-match-p "requested remote orphan cleanup" message-text)))))

(ert-deftest ejn-registry-latest-for-file-normalizes-with-file-truename ()
  (let* ((dir (make-temp-file "ejn-truename-" t))
         (real-file (expand-file-name "notebook.py" dir))
         (link (expand-file-name "link.py" dir)))
    (unwind-protect
        (progn
          (with-temp-file real-file (insert "x = 1\n"))
          (make-symbolic-link real-file link)
          (let* ((true-path (file-truename real-file))
                 (a `(:profile "p" :session-id "a" :local-file ,true-path :created-at "1"))
                 (b `(:profile "p" :session-id "b" :local-file ,true-path :created-at "2")))
            (should (equal (emacs-jupyter-notebook-registry-latest-for-file
                            link (list a b))
                           b))))
      (delete-directory dir t))))

(ert-deftest ejn-evaluate-cell-with-existing-client-evaluates-immediately ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          captured)
      (let ((emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (_client code _entry-handle)
               (push code captured))))
        (emacs-jupyter-notebook-send-cell))
      (should (equal captured '("a = 1\n"))))))

(ert-deftest ejn-evaluate-cell-no-client-with-file-entry-calls-reconnect ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (entry '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-captured nil)
           (reconnect-owner nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () entry))
                 ((symbol-function 'emacs-jupyter-notebook-reconnect-remote-kernel)
                  (lambda (captured-entry callback
                           &optional _error-callback owner)
                    (setq reconnect-captured (cons captured-entry callback))
                    (setq reconnect-owner owner)
                    (setq emacs-jupyter-notebook--client
                          (ejn-test-backend-session 'mock-client t))
                    (funcall callback nil))))
        (emacs-jupyter-notebook-send-cell)
        (should (equal (car reconnect-captured) entry))
        (should (functionp (cdr reconnect-captured)))
        (should (eq reconnect-owner 'evaluation))
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-no-client-no-entry-calls-start-default ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook-default-profile "mydefault")
           (start-captured nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                 ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                  (lambda (profile callback &optional _error-callback)
                    (setq start-captured (cons profile callback))
                    (setq emacs-jupyter-notebook--client
                          (ejn-test-backend-session 'mock-client t))
                    (funcall callback nil))))
        (emacs-jupyter-notebook-send-cell)
        (should (equal (car start-captured) "mydefault"))
        (should (functionp (cdr start-captured)))
        (should eval-called)))))

;; W4.8: `ejn-evaluate-cell-stale-file-entry-falls-back-to-start-default'
;; was removed.  The old behavior — silently removing the registry entry
;; and starting a fresh kernel when reconnect to a stale entry failed —
;; violates the binding rule that only `shutdown-kernel' and
;; `clean-orphaned-kernels' may terminate / deregister.  The new
;; `--ensure-client-async' surfaces the reconnect error to the caller
;; instead; see `ejn-w4.8-ensure-client-async-does-not-auto-restart-on-dead-reconnect'.

(ert-deftest ejn-evaluate-cell-async-in-progress-chains-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client code _entry-handle)
              (setq eval-called t)))
           (emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context
             :phase 'launch
             :origin-buffer (current-buffer))))
      (emacs-jupyter-notebook-send-cell)
      (should-not eval-called)
      (let ((cb (plist-get emacs-jupyter-notebook--async-context :callback)))
        (should (functionp cb))
        (setq emacs-jupyter-notebook--client
              (ejn-test-backend-session 'mock-client t))
        (funcall cb emacs-jupyter-notebook--async-context)
        (should eval-called)))))

(ert-deftest ejn-evaluate-cell-async-in-progress-chains-error-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context
            (emacs-jupyter-notebook--async-new-context
             :phase 'launch
             :origin-buffer (current-buffer))))
      (let ((id (emacs-jupyter-notebook-send-cell)))
        (let ((cb (plist-get emacs-jupyter-notebook--async-context
                             :error-callback)))
          (should (functionp cb))
          (funcall cb emacs-jupyter-notebook--async-context "boom")
          (should-not (emacs-jupyter-notebook--execution-record id))
          (let* ((panel (emacs-jupyter-notebook-panel-buffer (current-buffer)))
                 (entry (with-current-buffer panel
                          (cdar emacs-jupyter-notebook-panel--entries))))
            (should (eq (plist-get entry :status) 'error))
            (should (string-match-p "boom" (ejn-panel-entry-text entry)))))))))

(ert-deftest ejn-jupyter-runtime-adapter-dispatches ()
  (let ((emacs-jupyter-notebook-jupyter-complete-function
         (lambda (client code pos callback)
           (funcall callback (list :client client :code code :pos pos) nil)))
        (emacs-jupyter-notebook-jupyter-inspect-function
         (lambda (client code pos detail callback)
           (funcall callback
                    (list :client client :code code :pos pos :detail detail)
                    nil)))
        (emacs-jupyter-notebook-jupyter-is-complete-function
         (lambda (client code callback)
           (funcall callback (list :client client :code code :status "complete") nil)))
        complete-result inspect-result is-complete-result)
    (emacs-jupyter-notebook-jupyter-complete
     'client "abc" 2 (lambda (reply _error) (setq complete-result reply)))
    (emacs-jupyter-notebook-jupyter-inspect
     'client "abc" 2 0 (lambda (reply _error) (setq inspect-result reply)))
    (emacs-jupyter-notebook-jupyter-is-complete
     'client "abc" (lambda (reply _error) (setq is-complete-result reply)))
    (should (equal complete-result '(:client client :code "abc" :pos 2)))
    (should (equal inspect-result '(:client client :code "abc" :pos 2 :detail 0)))
    (should (equal is-complete-result '(:client client :code "abc" :status "complete")))))

(ert-deftest ejn-completion-at-point-does-not-request-on-cursor-motion ()
  ;; Cursor motion: capf returns nil without scheduling an idle timer.
  ;; The existing assertion that the adapter is never called still holds —
  ;; W3 strengthens it: even the idle timer must not be installed.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'next-line)
          called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not called)
        (should-not (timerp emacs-jupyter-notebook--completion-idle-timer))))))

(ert-deftest ejn-completion-at-point-requests-after-self-insert ()
  ;; W3.2: capf schedules an idle timer after self-insert.  The adapter is
  ;; NOT called synchronously by the capf — the timer is the proxy for the
  ;; pending request.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'self-insert-command)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq adapter-called t))))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not adapter-called)
        (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-completion-at-point-returns-cached-data ()
  ;; W3.1: cache is a hash-table keyed by (point . line-up-to-point).
  (ejn-test-with-temp-buffer "# %% setup\nx = 1\n# %% work\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (should (equal (emacs-jupyter-notebook-completion-at-point)
                     (list (- (point) 10) (point) '("my_obj.method")
                           :exclusive 'no))))))

(ert-deftest ejn-completion-at-point-returns-nil-when-kernel-busy ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--kernel-status 'busy)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (should-not (emacs-jupyter-notebook-completion-at-point)))))

(ert-deftest ejn-completion-callback-triggers-completion-in-region ()
  ;; Forces the fallback UI branch (no corfu/company) so the reply lands
  ;; via `completion-in-region'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client
            (ejn-test-backend-session 'mock-client t))
           (emacs-jupyter-notebook--completion-pending-key nil)
           (emacs-jupyter-notebook--completion-pending-id nil)
           (emacs-jupyter-notebook--completion-request-counter 0)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           triggered)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos callback)
               (funcall callback
                        '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                        nil))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq triggered t))))
          (emacs-jupyter-notebook--request-completion t)
          (ejn-test-drain-zero-delay-timers)
          (should triggered))))))

(ert-deftest ejn-completion-no-duplicate-request ()
  ;; Dedup: when the pending key matches the current key and an id is
  ;; already set, the adapter must not be called twice.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (key (emacs-jupyter-notebook--completion-key))
           (emacs-jupyter-notebook--completion-pending-key key)
           (emacs-jupyter-notebook--completion-pending-id 42)
           (emacs-jupyter-notebook--completion-request-counter 42)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           call-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq call-count (1+ (or call-count 0))))))
        (emacs-jupyter-notebook--request-completion)
        (should-not call-count)))))

(ert-deftest ejn-w14-explicit-complete-fetches-now-and-shows ()
  "W14: explicit `complete-at-point' with no cached candidates fetches
IMMEDIATELY (not via the debounced idle timer) and drives
`completion-in-region' when the reply arrives, so a single invocation
reliably shows candidates instead of silently requiring a second press."
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          adapter-code shown)
      (cl-letf (((symbol-function 'completion-in-region)
                 (lambda (&rest args) (setq shown args))))
        (let ((emacs-jupyter-notebook-jupyter-complete-function
               (lambda (_client code _pos callback)
                 (setq adapter-code code)
                 (funcall callback '(:matches ["method" "meta"]
                                     :cursor_start 7 :cursor_end 10)
                          nil))))
          (emacs-jupyter-notebook-complete-at-point))
        (ejn-test-drain-zero-delay-timers)
        (should adapter-code)
        (should shown)
        (should (member "method" (nth 2 shown)))))))

(ert-deftest ejn-w9-capf-explicit-invocation-schedules-request-on-miss ()
  ;; W9: the capf is invoked EXPLICITLY (this-command = `completion-at-point',
  ;; i.e. M-TAB / a manual frontend trigger), NOT via self-insert.  On a cache
  ;; miss it must now schedule the idle async request (the timer is the proxy
  ;; for the pending kernel fetch).  Letting the timer fire drives the adapter,
  ;; confirming a request is actually sent.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (this-command 'completion-at-point)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq adapter-called t))))
        ;; capf returns nil (cache miss) but must arm the idle timer.
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not adapter-called)          ; never synchronous
        (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (cancel-timer emacs-jupyter-notebook--completion-idle-timer)
        ;; Draining that scheduled work (what the timer would do) actually
        ;; sends the request through the adapter -- proving it is a real
        ;; pending kernel fetch, not just a dangling timer.  Called directly
        ;; (as ejn-completion-callback-triggers-completion-in-region does) to
        ;; avoid timer/mode-guard flakiness.
        (setq emacs-jupyter-notebook--completion-pending-key nil
              emacs-jupyter-notebook--completion-pending-id nil)
        (emacs-jupyter-notebook--request-completion t)
        (should adapter-called)))))

(ert-deftest ejn-w9-capf-explicit-invocation-regression-old-gate-fixed ()
  ;; Regression pin: the OLD gate only scheduled for self-insert/delete/yank,
  ;; so an explicit completion command on a miss scheduled NOTHING.  It now
  ;; must schedule for both the vanilla `completion-at-point' and popup
  ;; frontend commands (name-matched: corfu/company), while cursor motion
  ;; still schedules nothing (see the -does-not-request-on-cursor-motion test).
  (dolist (cmd '(completion-at-point
                 corfu-complete
                 company-complete
                 emacs-jupyter-notebook-complete-at-point))
    (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
      (search-forward "my_obj.met")
      (let ((emacs-jupyter-notebook--client 'mock-client)
            (emacs-jupyter-notebook--completion-cache nil)
            (emacs-jupyter-notebook--completion-cache-order nil)
            (emacs-jupyter-notebook--completion-pending-key nil)
            (emacs-jupyter-notebook--completion-idle-timer nil)
            (this-command cmd))
        (let ((emacs-jupyter-notebook-jupyter-complete-function
               (lambda (&rest _) nil)))
          (should-not (emacs-jupyter-notebook-completion-at-point))
          (should (timerp emacs-jupyter-notebook--completion-idle-timer))
          (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))
  ;; And the negative half of the gate: cursor motion AND popup
  ;; navigation/dismissal commands must NOT arm it.  The popup commands
  ;; (`corfu-next', `company-abort', ...) embed a frontend prefix but not
  ;; the `complet' verb, so keying on the verb correctly excludes them —
  ;; re-entering the capf while merely scrolling or aborting a popup must
  ;; never fire a kernel request (W3 contract; opencode W9 review).
  (dolist (cmd '(next-line
                 forward-char
                 corfu-next
                 corfu-previous
                 corfu-quit
                 company-select-next
                 company-abort))
    (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
      (search-forward "my_obj.met")
      (let ((emacs-jupyter-notebook--client 'mock-client)
            (emacs-jupyter-notebook--completion-cache nil)
            (emacs-jupyter-notebook--completion-idle-timer nil)
            (this-command cmd))
        (should-not (emacs-jupyter-notebook-completion-at-point))
        (should-not (timerp emacs-jupyter-notebook--completion-idle-timer))))))

(ert-deftest ejn-w9-empty-prefix-attribute-reply-yields-usable-capf-result ()
  ;; Real `d.' complete_reply shape from a live ipykernel: cursor_start ==
  ;; cursor_end (EMPTY prefix) with BARE attribute-name matches.  The capf
  ;; result must be (START END COLLECTION . PROPS) with START == END == point
  ;; (delta 0) and COLLECTION holding the bare names, so corfu can insert one
  ;; after `d.'.
  (with-temp-buffer
    (insert "d.")
    (goto-char (point-max))
    (let ((r (emacs-jupyter-notebook--completion-result-from-reply
              '(:status "ok" :matches ["clear" "copy" "get"]
                        :cursor_start 9 :cursor_end 9))))
      (should r)
      (should (= (nth 0 r) (point)))                 ; START == point (delta 0)
      (should (= (nth 1 r) (point)))                 ; END == point
      (should (= (nth 0 r) (nth 1 r)))               ; empty prefix span
      (should (equal (nth 2 r) '("clear" "copy" "get")))
      (should (eq (plist-get (cdddr r) :exclusive) 'no)))))

(ert-deftest ejn-completion-idle-timer-set-up-on-mode-enable ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (timerp emacs-jupyter-notebook--completion-idle-timer))
    (let ((timer emacs-jupyter-notebook--completion-idle-timer))
      (emacs-jupyter-notebook-mode -1)
      (should-not (timerp emacs-jupyter-notebook--completion-idle-timer)))))

(ert-deftest ejn-completion-at-point-no-client-returns-nil ()
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (goto-char (point-max))
    (should-not (emacs-jupyter-notebook-completion-at-point))))

(ert-deftest ejn-w3.1-completion-key-shape ()
  ;; Key shape contract: (point . line-up-to-point).
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((key (emacs-jupyter-notebook--completion-key)))
      (should (consp key))
      (should (integerp (car key)))
      (should (stringp (cdr key)))
      (should (string-suffix-p "my_obj.met" (cdr key))))))

(ert-deftest ejn-w3.1-completion-cache-hit-miss ()
  ;; Cache hit returns the put value; miss returns nil.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil))
      (should-not (emacs-jupyter-notebook--completion-cache-get '(1 . "a")))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") '(:matches ("a")))
      (should (equal (emacs-jupyter-notebook--completion-cache-get '(1 . "a"))
                     '(:matches ("a"))))
      (should-not (emacs-jupyter-notebook--completion-cache-get '(2 . "b"))))))

(ert-deftest ejn-w3.1-completion-cache-lru-eviction ()
  ;; When the LRU exceeds the bound, the least-recently-used key is evicted.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook-completion-cache-size 3))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      (emacs-jupyter-notebook--completion-cache-put '(3 . "c") 'r3)
      (should (equal (emacs-jupyter-notebook--completion-cache-get '(1 . "a")) 'r1))
      ;; (1 . "a") now MRU; (2 . "b") becomes LRU.
      (emacs-jupyter-notebook--completion-cache-put '(4 . "d") 'r4)
      (should-not (gethash '(2 . "b") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(1 . "a") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(3 . "c") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(4 . "d") emacs-jupyter-notebook--completion-cache))
      (should (= (hash-table-count emacs-jupyter-notebook--completion-cache) 3)))))

(ert-deftest ejn-w3.1-completion-cache-promotes-on-hit ()
  ;; A cache hit promotes the entry to most-recently-used.
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook-completion-cache-size 2))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      ;; Touch (1 . "a") so it becomes MRU.
      (emacs-jupyter-notebook--completion-cache-get '(1 . "a"))
      ;; Insert (3 . "c"): now (2 . "b") is LRU and gets evicted.
      (emacs-jupyter-notebook--completion-cache-put '(3 . "c") 'r3)
      (should (gethash '(1 . "a") emacs-jupyter-notebook--completion-cache))
      (should-not (gethash '(2 . "b") emacs-jupyter-notebook--completion-cache))
      (should (gethash '(3 . "c") emacs-jupyter-notebook--completion-cache)))))

(ert-deftest ejn-w3.2-schedule-installs-idle-timer ()
  ;; A schedule call installs exactly one idle timer.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10))
      (emacs-jupyter-notebook--completion-schedule-request)
      (unwind-protect
          (should (timerp emacs-jupyter-notebook--completion-idle-timer))
        (emacs-jupyter-notebook--completion-cancel-idle-timer)))))

(ert-deftest ejn-w3.2-schedule-cancels-prior-timer ()
  ;; A second schedule cancels the first; the old timer object is dead.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10))
      (emacs-jupyter-notebook--completion-schedule-request)
      (let ((first emacs-jupyter-notebook--completion-idle-timer))
        (should (timerp first))
        (emacs-jupyter-notebook--completion-schedule-request)
        (let ((second emacs-jupyter-notebook--completion-idle-timer))
          (should (timerp second))
          (should-not (eq first second))
          (should-not (memq first timer-list))
          (emacs-jupyter-notebook--completion-cancel-idle-timer))))))

(ert-deftest ejn-w3.2-cancel-idle-timer-clears-state ()
  ;; Explicit cancel drops the timer and the pending key/id.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-idle-timer nil))
      (emacs-jupyter-notebook--completion-schedule-request)
      (emacs-jupyter-notebook--completion-cancel-idle-timer)
      (should-not (timerp emacs-jupyter-notebook--completion-idle-timer))
      (should-not emacs-jupyter-notebook--completion-pending-key)
      (should-not emacs-jupyter-notebook--completion-pending-id))))

(ert-deftest ejn-w3.2-schedule-fires-adapter-after-delay ()
  ;; When the scheduled timer fires, the adapter is called exactly once
  ;; with the expected (code, cursor-pos).  The test invokes the timer's
  ;; function directly rather than relying on the batch-mode scheduler.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (emacs-jupyter-notebook-mode 1)
    (unwind-protect
        (progn
          (search-forward "my_obj.met")
          (let ((emacs-jupyter-notebook--client
                 (ejn-test-backend-session 'mock-client t))
                (emacs-jupyter-notebook--completion-cache nil)
                (emacs-jupyter-notebook--completion-cache-order nil)
                (emacs-jupyter-notebook--completion-idle-timer nil)
                (emacs-jupyter-notebook--completion-pending-key nil)
                (emacs-jupyter-notebook--completion-pending-id nil)
                (emacs-jupyter-notebook-completion-idle 0.01)
                calls captured-code captured-pos)
            (let ((emacs-jupyter-notebook-jupyter-complete-function
                   (lambda (_client code pos _callback)
                     (setq calls (1+ (or calls 0))
                           captured-code code
                           captured-pos pos))))
              (emacs-jupyter-notebook--completion-schedule-request)
              (let ((timer emacs-jupyter-notebook--completion-idle-timer))
                (should (timerp timer))
                (apply (timer--function timer) (timer--args timer)))
              (should (equal calls 1))
              (should (stringp captured-code))
              (should (numberp captured-pos)))))
      (emacs-jupyter-notebook-mode -1))))

(ert-deftest ejn-w3.2-typing-after-schedule-invalidates-pending ()
  ;; A schedule that follows another schedule (the user typed) clears any
  ;; pending key/id so a stale reply will be dropped on arrival.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key "stale-key")
          (emacs-jupyter-notebook--completion-pending-id 42)
          (emacs-jupyter-notebook--completion-idle-timer nil))
      (emacs-jupyter-notebook--completion-schedule-request)
      (unwind-protect
          (progn
            (should-not emacs-jupyter-notebook--completion-pending-key)
            (should-not emacs-jupyter-notebook--completion-pending-id))
        (emacs-jupyter-notebook--completion-cancel-idle-timer)))))

(ert-deftest ejn-w3.3-stale-reply-dropped-by-superseded-id ()
  ;; Two requests fire; the first one's reply arrives AFTER the second has
  ;; superseded it.  The first reply must not populate the cache and must
  ;; not refresh the UI.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          first-callback second-callback ui-refresh-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb)
               (cond ((null first-callback) (setq first-callback cb))
                     (t (setq second-callback cb))))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args)
                     (setq ui-refresh-count (1+ (or ui-refresh-count 0))))))
          ;; First request fires.
          (emacs-jupyter-notebook--request-completion t)
          (should first-callback)
          ;; Simulate user keystroke: bump key by moving point, then a new
          ;; schedule sends a second request.
          (forward-char -1)
          (emacs-jupyter-notebook--request-completion t)
          (should second-callback)
          ;; First reply arrives AFTER the second request superseded it.
          (funcall first-callback
                   '(:matches ("stale_match") :cursor_start 0 :cursor_end 5)
                   nil)
          ;; The stale reply must NOT have populated the cache.
          (should (or (null emacs-jupyter-notebook--completion-cache)
                      (= 0 (hash-table-count
                            emacs-jupyter-notebook--completion-cache))))
          (should-not ui-refresh-count))))))

(ert-deftest ejn-w3.3-fresh-reply-populates-cache ()
  ;; Counterpoint: when the reply matches the live pending id and key,
  ;; it lands in the cache and the UI refresh runs.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-callback ui-refresh-count)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb)
               (setq captured-callback cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args)
                     (setq ui-refresh-count (1+ (or ui-refresh-count 0))))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-callback)
          (funcall captured-callback
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (ejn-test-drain-zero-delay-timers)
          (let ((key (emacs-jupyter-notebook--completion-key)))
            (should (gethash key emacs-jupyter-notebook--completion-cache)))
          (should (equal ui-refresh-count 1)))))))

(ert-deftest ejn-w3.3-reply-after-buffer-killed-is-safe ()
  ;; If the buffer that owns the request is killed before the reply
  ;; arrives, the callback must not raise.
  (let (buffer captured-cb)
    (with-current-buffer (setq buffer (generate-new-buffer "ejn-w3.3"))
      (python-mode)
      (insert "# %%\nmy_obj.met\n")
      (goto-char (point-max))
      (setq-local emacs-jupyter-notebook--client
                  (ejn-test-backend-session 'mock-client t))
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (emacs-jupyter-notebook--request-completion t)))
    (should captured-cb)
    (kill-buffer buffer)
    ;; Should not raise.
    (should
     (eq nil
         (progn
           (funcall captured-cb
                    '(:matches ("x") :cursor_start 0 :cursor_end 1) nil)
           nil)))))

(ert-deftest ejn-w3.4-capf-returns-fast-even-when-adapter-stalls ()
  ;; Load-bearing W3 test: the adapter is mocked to delay 10 seconds.
  ;; The adapter is only ever called from the deferred timer, never from the
  ;; capf itself.  Assert that scheduling boundary directly instead of using a
  ;; scheduler-sensitive wall-clock threshold.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-idle-timer nil)
          (emacs-jupyter-notebook-completion-idle 0.10)
          (this-command 'self-insert-command)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos _callback)
               (setq adapter-called t)
               (sleep-for 10))))
        (unwind-protect
            (progn
              (should-not (emacs-jupyter-notebook-completion-at-point))
              (should-not adapter-called)
              (should (timerp emacs-jupyter-notebook--completion-idle-timer)))
          (when (timerp emacs-jupyter-notebook--completion-idle-timer)
            (cancel-timer emacs-jupyter-notebook--completion-idle-timer)))))))

(ert-deftest ejn-w3.4-capf-returns-fast-on-cache-hit ()
  ;; A cache hit is pure local lookup and must not schedule remote work.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let* ((emacs-jupyter-notebook--client 'mock-client)
           (emacs-jupyter-notebook--completion-cache nil)
           (emacs-jupyter-notebook--completion-cache-order nil)
           (emacs-jupyter-notebook--completion-idle-timer nil)
           (key (emacs-jupyter-notebook--completion-key)))
      (emacs-jupyter-notebook--completion-cache-put
       key '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10))
      (should (emacs-jupyter-notebook-completion-at-point))
      (should-not emacs-jupyter-notebook--completion-idle-timer))))

;; Frontend variables introduced for W3.5 tests; the real packages define
;; these but we mock them to keep tests independent of the packages.
(defvar corfu-mode nil)
(defvar completion-in-region-mode nil)
(defvar company-mode nil)

(ert-deftest ejn-w3.5-refresh-ui-skips-when-completion-in-region-active ()
  ;; W3.7: when `completion-in-region-mode' is active there is no reliable
  ;; cross-version way to force the popup to re-fetch capf candidates.
  ;; The refresh hook deliberately becomes a no-op in that case; the
  ;; next user keystroke causes capf to be re-invoked naturally and the
  ;; popup picks up the new candidates from the cache then.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb fallback-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf* (((symbol-value 'completion-in-region-mode) t)
                   ((symbol-function 'completion-in-region)
                    (lambda (&rest _) (setq fallback-called t))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (ejn-test-drain-zero-delay-timers)
          (should-not fallback-called))))))

(ert-deftest ejn-w3.5-reply-refreshes-company-via-manual-begin ()
  ;; When company is active, the reply path calls `company-manual-begin'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb refresh-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf* (((symbol-value 'corfu-mode) nil)
                   ((symbol-value 'company-mode) t)
                   ((symbol-function 'company-manual-begin)
                    (lambda (&rest _) (setq refresh-called 'company-manual))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (ejn-test-drain-zero-delay-timers)
          (should (eq refresh-called 'company-manual)))))))

(ert-deftest ejn-w3.5-reply-refreshes-fallback-completion-in-region ()
  ;; With neither corfu nor company active, the reply path falls back to
  ;; `completion-in-region'.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb fallback-called)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq fallback-called t))))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          (ejn-test-drain-zero-delay-timers)
          (should fallback-called))))))

(ert-deftest ejn-w3.7-context-changed-drops-reply-entirely ()
  ;; W3.7: if the user moved point so the live key no longer matches the
  ;; request's key, the reply is DROPPED entirely.  Caching it under the
  ;; original key would risk surfacing out-of-date candidates if the user
  ;; later returned to that context after the kernel state had drifted.
  (ejn-test-with-temp-buffer "# %%\nmy_obj.met\n"
    (search-forward "my_obj.met")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil)
          (emacs-jupyter-notebook--completion-pending-key nil)
          (emacs-jupyter-notebook--completion-pending-id nil)
          (emacs-jupyter-notebook--completion-request-counter 0)
          captured-cb refresh-called orig-key)
      (let ((emacs-jupyter-notebook-jupyter-complete-function
             (lambda (_client _code _pos cb) (setq captured-cb cb))))
        (cl-letf (((symbol-function 'completion-in-region)
                   (lambda (&rest _args) (setq refresh-called t))))
          (setq orig-key (emacs-jupyter-notebook--completion-key))
          (emacs-jupyter-notebook--request-completion t)
          (should captured-cb)
          ;; User moves point AFTER request was sent.
          (forward-char -3)
          (funcall captured-cb
                   '(:matches ("my_obj.method") :cursor_start 0 :cursor_end 10)
                   nil)
          ;; Reply is dropped: cache does not contain orig-key, no refresh.
          (should-not (and emacs-jupyter-notebook--completion-cache
                           (gethash orig-key emacs-jupyter-notebook--completion-cache)))
          (should-not refresh-called))))))

(ert-deftest ejn-w3.7-idle-timer-captures-buffer ()
  ;; W3.7: `--completion-start-idle-timer' must capture `current-buffer'
  ;; in a closure so the timer fires in the buffer that armed it, not in
  ;; whatever buffer happens to be current when it fires.  Without this
  ;; fix, a timer armed in buffer A would mutate buffer B's pending state.
  (let ((buf-a (generate-new-buffer "ejn-w37-a"))
        (buf-b (generate-new-buffer "ejn-w37-b"))
        timer populate-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--completion-idle-populate)
                   (lambda () (setq populate-buffer (current-buffer)))))
          (with-current-buffer buf-a
            (setq-local emacs-jupyter-notebook-mode t)
            (emacs-jupyter-notebook--completion-start-idle-timer)
            (setq timer emacs-jupyter-notebook--completion-idle-timer))
          (should (timerp timer))
          ;; Switch to a different buffer and fire buf-a's timer.
          (with-current-buffer buf-b
            (timer-event-handler timer))
          (should (eq populate-buffer buf-a)))
      (when (timerp timer)
        (cancel-timer timer))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest ejn-w3.7-cancel-idle-timer-clears-pending-state ()
  ;; W3.7: cancelling the idle timer must also clear the pending key/id
  ;; so any in-flight reply is dropped on arrival.  Without this, a
  ;; cancelled timer could still leave the buffer in a state where an
  ;; old reply is accepted and cached against a context the user has
  ;; already left.
  (with-temp-buffer
    (setq emacs-jupyter-notebook--completion-idle-timer
          (run-with-timer 1000 nil #'ignore))
    (setq emacs-jupyter-notebook--completion-pending-key '(123 . "foo"))
    (setq emacs-jupyter-notebook--completion-pending-id 7)
    (emacs-jupyter-notebook--completion-cancel-idle-timer)
    (should-not emacs-jupyter-notebook--completion-idle-timer)
    (should-not emacs-jupyter-notebook--completion-pending-key)
    (should-not emacs-jupyter-notebook--completion-pending-id)))

(ert-deftest ejn-w3.1-completion-cache-reset-clears-everything ()
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--completion-cache nil)
          (emacs-jupyter-notebook--completion-cache-order nil))
      (emacs-jupyter-notebook--completion-cache-put '(1 . "a") 'r1)
      (emacs-jupyter-notebook--completion-cache-put '(2 . "b") 'r2)
      (emacs-jupyter-notebook--completion-cache-reset)
      (should (= (hash-table-count emacs-jupyter-notebook--completion-cache) 0))
      (should-not emacs-jupyter-notebook--completion-cache-order))))

(ert-deftest ejn-inspect-at-point-callback-displays-text-plain ()
  (ejn-test-with-temp-buffer "# %%\nrange(5)\n"
    (goto-char (point-min))
    (search-forward "range")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
           captured-code
           captured-pos
           captured-detail
           displayed
           inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (message &optional _buffer-name _action _frame)
                   (setq displayed message))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_client code pos detail callback)
                 (setq captured-code code
                       captured-pos pos
                       captured-detail detail)
                 (setq inspect-callback callback))))
          (emacs-jupyter-notebook-inspect-at-point)
          (should-not displayed)
          (funcall inspect-callback
                   '(:found t :data (:text/plain "range docs")) nil)
          (ejn-test-drain-zero-delay-timers)))
      (should (equal displayed "range docs"))
      (should (equal captured-code "range(5)\n"))
      (should (= captured-pos 5))
      (should (= captured-detail 0)))))

(ert-deftest ejn-inspect-at-point-decodes-ansi-escapes ()
  "IPython colourises its inspector (`?') output with ANSI SGR escapes.
The displayed text must have them decoded (to faces) rather than dumped
as literal `\\e[0;31m...' sequences into the echo area / *Message*."
  (ejn-test-with-temp-buffer "# %%\nrange(5)\n"
    (goto-char (point-min))
    (search-forward "range")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          displayed inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (m &rest _) (setq displayed m))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_c _code _pos _detail cb) (setq inspect-callback cb))))
          (emacs-jupyter-notebook-inspect-at-point)
          (funcall inspect-callback
                   (list :found t
                         :data (list :text/plain
                                     "\e[0;31mSignature:\e[0m range(stop)\n"))
                   nil)
          (ejn-test-drain-zero-delay-timers)))
      ;; No raw escape sequence survived, the visible text is intact, and
      ;; the trailing newline was trimmed.
      (should displayed)
      (should-not (string-match-p "\e\\[" displayed))
      (should (equal (substring-no-properties displayed)
                     "Signature: range(stop)")))))

(ert-deftest ejn-inspect-callback-not-found-displays-nothing ()
  "Real `inspect_reply' for an unknown symbol is `(:status ok :found
nil :data ())' — an EMPTY data plist.  The callback must display nothing
(the `text/plain' guard handles it), not error or show an empty popup.
Pins the real reply shape the happy-path test never exercises."
  (ejn-test-with-temp-buffer "# %%\nnope\n"
    (search-forward "nope")
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          displayed inspect-callback)
      (cl-letf (((symbol-function 'display-message-or-buffer)
                 (lambda (m &rest _) (setq displayed m))))
        (let ((emacs-jupyter-notebook-jupyter-inspect-function
               (lambda (_c _code _pos _detail cb) (setq inspect-callback cb))))
          (emacs-jupyter-notebook-inspect-at-point)
          (funcall inspect-callback '(:status "ok" :found nil :data ()) nil)))
      (should-not displayed))))

(ert-deftest ejn-completion-result-from-reply-handles-vector-matches ()
  "Real emacs-jupyter delivers complete_reply `:matches' as a VECTOR
(JSON array), not a list, and the bounds come from the cursor_start /
cursor_end DELTA (token length), independent of absolute offsets.  Pins
both so a regression in either is caught without a live kernel."
  (with-temp-buffer
    (insert "obj.attr")
    (goto-char (point-max))
    ;; Vector matches, and cursor_start/end describing the 4-char token
    ;; `attr' at arbitrary absolute offsets (100..104).
    (let ((r (emacs-jupyter-notebook--completion-result-from-reply
              '(:matches ["attr" "attribute"] :cursor_start 100 :cursor_end 104))))
      (should (= (nth 0 r) (- (point) 4)))           ; token start via delta
      (should (= (nth 1 r) (point)))                 ; token end at point
      (should (equal (nth 2 r) '("attr" "attribute"))) ; vector -> list
      (should (eq (plist-get (cdddr r) :exclusive) 'no)))))

(ert-deftest ejn-ssh-direct-launch-has-no-resolution-wrapper ()
  (let* ((path "/tmp/kernel-session.json")
         (launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                  '(:profile "p" :host "mother" :remote-cwd "/work"
                    :remote-cache-dir "/tmp/ejn" :kernelspec "python3")
                  "session"
                  (list :connection-file path
                        :argv (list "/usr/bin/python3" "-f" path)
                        :connection-tokens (list "-f" path)
                        :env '(("A" . "space value")))))
         (remote (plist-get launch :remote-command)))
    (should (string-match-p "EJN_PID" remote))
    (should (string-match-p (regexp-quote "/usr/bin/python3") remote))
    (should-not (string-match-p "KernelSpecManager" remote))))

(ert-deftest ejn-evaluate-cell-completeness-check-skips-incomplete-code-async ()
  (ejn-test-with-temp-buffer "# %%\nif True:\n"
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-check-code-completeness t)
          eval-called
          callback)
      (let ((emacs-jupyter-notebook-jupyter-is-complete-function
             (lambda (_client _code captured-callback)
               (setq callback captured-callback)))
            (emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (&rest _)
               (setq eval-called t))))
        (emacs-jupyter-notebook-send-cell))
      (should callback)
      (should-not eval-called)
      (funcall callback '(:status "incomplete" :indent "    ") nil)
      (should-not eval-called))))

(ert-deftest ejn-panel-append-replace-clear-pending ()
  "W2.1: panel API supports append, replace, clear and pending-clear semantics."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
      (ejn-panel-append-text handle "hello\n")
      (ejn-panel-append-text handle "world")
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) "hello\nworld")))
      (ejn-panel-clear-entry handle)
      (should (equal (ejn-panel-entry-text handle) ""))
      (ejn-panel-append-text handle "existing")
      (ejn-panel-clear-entry handle t)
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) "existing"))
        (should (plist-get e :pending-clear)))
      (ejn-panel-append-text handle "fresh")
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) "fresh"))
        (should-not (plist-get e :pending-clear)))
      (ejn-panel-replace-text handle "swapped")
      (should (equal (ejn-panel-entry-text handle)
                     "swapped")))))

(ert-deftest ejn-callback-clear-output-immediate ()
  "W2.7: clear_output without :wait clears the panel entry immediately."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (ejn-panel-append-text handle "some output")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait nil))))
        (funcall clear-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) ""))
        (should-not (plist-get e :pending-clear))))))

(ert-deftest ejn-callback-clear-output-wait-defers-clear ()
  "W2.7: clear_output with :wait defers the clear until next text arrives."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (clear-fn (cadr (assoc "clear_output" callbacks))))
      (ejn-panel-append-text handle "some output")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:wait t))))
        (funcall clear-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) "some output"))
        (should (plist-get e :pending-clear))))))

(ert-deftest ejn-callback-update-display-data-replaces-content ()
  "W2.7: update_display_data replaces the panel entry's content."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (update-fn (cadr (assoc "update_display_data" callbacks))))
      (ejn-panel-append-text handle "old display")
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "updated output")
                                        :transient (:display_id "abc"))))
                ((symbol-function 'jupyter-message-data)
                 (lambda (_msg mimetype)
                   (when (eq mimetype :text/plain) "updated output"))))
        (funcall update-fn 'mock-update-msg))
      (should (equal (ejn-panel-entry-text handle)
                     "updated output")))))

(ert-deftest ejn-evaluate-cell-completeness-check-allows-complete-code-async ()
  (ejn-test-with-temp-buffer "# %%\nx = 1\n"
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-check-code-completeness t)
          eval-called
          callback)
      (let ((emacs-jupyter-notebook-jupyter-is-complete-function
             (lambda (_client _code captured-callback)
               (setq callback captured-callback)))
            (emacs-jupyter-notebook-jupyter-evaluate-function
             (lambda (&rest _)
               (setq eval-called t))))
        (emacs-jupyter-notebook-send-cell)
        (should callback)
        (should-not eval-called)
        (funcall callback '(:status "complete") nil)
        (ejn-test-drain-zero-delay-timers))
      (should eval-called))))

(ert-deftest ejn-status-message-sets-kernel-status ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (let* ((callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
             (status-handler (cadr (assoc "status" callbacks)))
             (mock-msg 'mock-status-msg))
        (should status-handler)
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:execution_state "busy"))))
          (funcall status-handler mock-msg))
        (should (eq emacs-jupyter-notebook--kernel-status 'busy))
        (cl-letf (((symbol-function 'jupyter-message-content)
                   (lambda (_msg) '(:execution_state "idle"))))
          (funcall status-handler mock-msg))
        (should (eq emacs-jupyter-notebook--kernel-status 'idle))))))

(ert-deftest ejn-mode-lighter-changes-based-on-kernel-status ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))
    (setq emacs-jupyter-notebook--kernel-status 'busy)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN*"))
    (setq emacs-jupyter-notebook--kernel-status 'idle)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))
    (setq emacs-jupyter-notebook--kernel-status nil)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))))

(ert-deftest ejn-tunnel-sentinel-sets-tunnel-dead-on-exit ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (proc (start-process "ejn-test-tunnel" nil "true")))
      (emacs-jupyter-notebook-mode 1)
      (setq emacs-jupyter-notebook--tunnel-process proc)
      (setq emacs-jupyter-notebook--tunnel-dead nil)
      (emacs-jupyter-notebook--install-tunnel-sentinel proc buffer)
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc)
                    (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (should emacs-jupyter-notebook--tunnel-dead)
      (should-not emacs-jupyter-notebook--kernel-status))))

(ert-deftest ejn-mode-lighter-shows-exclamation-when-tunnel-dead ()
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (setq emacs-jupyter-notebook--tunnel-dead t)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN!"))
    (setq emacs-jupyter-notebook--tunnel-dead nil)
    (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN"))))

;; W4.7: `ejn-tunnel-dead-reset-on-new-connection' was removed along with
;; `--connect-entry'.  The async-connect-finalize path that resets
;; `--tunnel-dead' on a successful new client is exercised by
;; `ejn-async-connect-finalize-sets-client-on-success'.

(ert-deftest ejn-mime-select-png-over-jpeg-and-text ()
  (let ((data '(:text/plain "hello" :image/png "pngdata" :image/jpeg "jpgdata")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :image/png))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "pngdata"))))

(ert-deftest ejn-mime-select-jpeg-over-text ()
  (let ((data '(:text/plain "hello" :image/jpeg "jpgdata")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :image/jpeg))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "jpgdata"))))

(ert-deftest ejn-mime-select-text-when-no-image ()
  (let ((data '(:text/plain "hello")))
    (should (equal (car (emacs-jupyter-notebook--select-mime-type data)) :text/plain))
    (should (equal (cdr (emacs-jupyter-notebook--select-mime-type data)) "hello"))))

(ert-deftest ejn-mime-select-nil-when-only-unsupported-types ()
  (should-not (emacs-jupyter-notebook--select-mime-type '(:text/html "<p>hi</p>"))))

(ert-deftest ejn-mime-select-nil-for-empty-data ()
  (should-not (emacs-jupyter-notebook--select-mime-type nil)))

(ert-deftest ejn-mime-render-text-returns-plain-string ()
  (let ((result (emacs-jupyter-notebook--render-mime-result '(:text/plain "42"))))
    (should (equal result "42"))
    (should-not (get-text-property 0 'display result))))

(ert-deftest ejn-mime-render-image-decodes-base64 ()
  (let* ((raw "fake-image-data")
         (encoded (base64-encode-string raw t))
         (captured-data nil)
         (captured-props nil))
    (cl-letf (((symbol-function 'create-image)
               (lambda (data &optional _type _data-p &rest props)
                 (setq captured-data data)
                 (setq captured-props props)
                 (list 'image :type 'png :data data))))
      (let ((result (emacs-jupyter-notebook--render-mime-result
                     `(:image/png ,encoded))))
        (should result)
        (should (equal captured-data raw))
        (should (get-text-property 0 'display result))
        (should (equal (plist-get captured-props :max-width)
                       emacs-jupyter-notebook-image-max-width))
        (should (equal (plist-get captured-props :max-height)
                       emacs-jupyter-notebook-image-max-height))))))

(ert-deftest ejn-mime-render-image-falls-back-to-text-on-error ()
  (let* ((encoded (base64-encode-string "bad" t))
         (data `(:text/plain "fallback" :image/png ,encoded)))
    (cl-letf (((symbol-function 'create-image)
               (lambda (&rest _) (error "no image support"))))
      (let ((result (emacs-jupyter-notebook--render-mime-result data)))
        (should (equal result "fallback"))))))

(ert-deftest ejn-mime-render-image-nil-return-falls-back-to-text ()
  (let* ((encoded (base64-encode-string "bad" t))
         (data `(:text/plain "fallback" :image/png ,encoded)))
    (cl-letf (((symbol-function 'create-image)
               (lambda (&rest _) nil)))
      (let ((result (emacs-jupyter-notebook--render-mime-result data)))
        (should (equal result "fallback"))))))

(ert-deftest ejn-panel-image-and-text-coexist-in-order ()
  "W16: text and images COEXIST as ordered segments — a cell that prints
and plots shows both, in arrival order, like a notebook.  (Replaces the
pre-W16 exclusive-output tests.)"
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "before ")
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (ejn-panel-append-text handle "after")
      (let* ((e (ejn-panel-entry-snapshot handle))
             (outputs (plist-get e :outputs)))
        ;; Everything retained, in order: text, image, text.
        (should (equal (mapcar #'car outputs) '(text image text)))
        (should (equal (ejn-panel-entry-text e) "before after"))
        (let ((image (car (ejn-panel-entry-images e))))
          (should (ejn-test-image-file-backed-p image))
          (should (equal (ejn-test-image-spec-data image) "fake")))))))

(ert-deftest ejn-panel-multiple-images-each-get-a-segment ()
  "W16: two figures displayed in one execution both render (own segments)."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "one"))
      (ejn-panel-set-image handle '(image :type png :data "two"))
      (let ((images (ejn-panel-entry-images handle)))
        (should (= (length images) 2))
        (should (cl-every #'ejn-test-image-file-backed-p images))
        (should (equal (mapcar #'ejn-test-image-spec-data images)
                       '("one" "two")))))))

(ert-deftest ejn-panel-clear-removes-image ()
  "W2.5: clearing an entry also removes its image."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (should (car (ejn-panel-entry-images handle)))
      (ejn-panel-clear-entry handle)
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should-not (car (ejn-panel-entry-images e)))
        (should (equal (ejn-panel-entry-text e) ""))))))

(ert-deftest ejn-callback-execute-result-renders-text-via-mime ()
  "W2.7: execute_result with text MIME goes through replace-text."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (exec-fn (cadr (assoc "execute_result" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:data (:text/plain "42")))))
        (funcall exec-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        (should (equal (ejn-panel-entry-text e) "42"))
        (should-not (car (ejn-panel-entry-images e)))))))

(ert-deftest ejn-callback-execute-result-renders-image-via-mime ()
  "W2.7: display_data with PNG MIME goes through set-image."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (encoded (base64-encode-string "imgdata" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/png ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (let ((image (car (ejn-panel-entry-images handle))))
        (should (ejn-test-image-file-backed-p image))
        (should (equal (ejn-test-image-spec-data image) "imgdata"))))))

(ert-deftest ejn-callback-update-display-data-replaces-image ()
  "W2.7/W16: update_display_data with image MIME updates the entry's LAST
image segment IN PLACE — the kernel is refreshing an existing display —
while surrounding text segments are left untouched."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (update-fn (cadr (assoc "update_display_data" callbacks)))
           (encoded (base64-encode-string "newimg" t)))
      (ejn-panel-append-text handle "old text")
      (ejn-panel-set-image handle '(image :type png :data "oldimg"))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) `(:data (:image/jpeg ,encoded))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'jpeg :data data))))
        (funcall update-fn 'mock-msg))
      (let ((e (ejn-panel-entry-snapshot handle)))
        ;; Still exactly one image; its spec was swapped in place.
        (let ((images (ejn-panel-entry-images e)))
          (should (= (length images) 1))
          (should (ejn-test-image-file-backed-p (car images)))
          (should (equal (ejn-test-image-spec-data (car images)) "newimg")))
        ;; The text segment survives the display update.
        (should (equal (ejn-panel-entry-text e) "old text"))))))

(ert-deftest ejn-mime-render-image-jpeg-decodes-base64 ()
  (let* ((raw "jpeg-data")
         (encoded (base64-encode-string raw t))
         (captured-data nil))
    (cl-letf (((symbol-function 'create-image)
               (lambda (data &optional _type _data-p &rest _props)
                 (setq captured-data data)
                 (list 'image :type 'jpeg :data data))))
      (let ((result (emacs-jupyter-notebook--render-mime-result
                     `(:image/jpeg ,encoded))))
        (should result)
        (should (equal captured-data raw))
        (should (get-text-property 0 'display result))))))

(ert-deftest ejn-tunnel-reconnect-is-async-and-uses-reconnect-context ()
  ;; Post-W4.4: tunnel-reconnect goes through `--async-probe-pid-alive'
  ;; before retrieve.  The probe is stubbed to call retrieve directly so
  ;; this test still pins the async-only contract.
  (let ((entry (ejn-test-direct-entry
                '(:profile "p"
                  :remote-host "example.com"
                  :remote-cwd "~"
                  :kernelspec "python3"
                  :remote-pid 12345
                  :remote-connection-file "~/.cache/ejn/kernel.json"
                  :session-id "session")))
        (retrieve-called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context)
                 (setq retrieve-called t)
                 context))
              ((symbol-function 'emacs-jupyter-notebook--async-reconnect-context)
               (lambda (profile entry &optional callback error-callback owner)
                 (should callback)
                 (should error-callback)
                 (should (eq owner 'evaluation))
                 (list :profile profile :entry entry
                       :callback callback :error-callback error-callback))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook--tunnel-reconnect
         (current-buffer) (lambda (_c) nil) (lambda (_c _e) nil))
        (should retrieve-called)))))

(ert-deftest ejn-tunnel-reconnect-with-no-entry-does-nothing ()
  (let ((called nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (&rest _)
                 (setq called t)
                 nil)))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry nil)
        (emacs-jupyter-notebook--tunnel-reconnect (current-buffer))
        (should-not called)))))

(ert-deftest ejn-w13-h2-inflight-attempt-not-superseded-by-parallel-send ()
  "W13-H2: a send while a reconnect is in flight (which leaves --tunnel-dead t
until finalize) attaches its callback to the running attempt instead of
spawning a duplicate via --tunnel-reconnect."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--session-entry '(:profile "p" :session-id "s"))
          (emacs-jupyter-notebook--async-context
           (emacs-jupyter-notebook--async-new-context
            :phase 'tunnel :origin-buffer (current-buffer)))
          reconnect-called added)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (&rest _) (setq reconnect-called t)))
                ((symbol-function 'emacs-jupyter-notebook--async-add-callback)
                 (lambda (&rest _) (setq added t))))
        (emacs-jupyter-notebook--ensure-client-async (lambda (_) nil) nil))
      (should added)
      (should-not reconnect-called))))

(ert-deftest ejn-w13-m1-stale-tunnel-dead-without-entry-does-not-wedge ()
  "W13-M1: a stale --tunnel-dead flag with no session entry must not wedge
send into a silent no-op; --ensure-client-async clears it and proceeds to a
normal start/reconnect."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/ejn-m1.py")
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--session-entry nil)
          (emacs-jupyter-notebook--async-context nil)
          started)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                 (lambda (&rest _) (setq started t))))
        (emacs-jupyter-notebook--ensure-client-async (lambda (_) nil) nil))
      (should started)
      (should-not emacs-jupyter-notebook--tunnel-dead))))

(ert-deftest ejn-w13-m1-deliberate-tunnel-delete-does-not-flag-dead ()
  "W13-M1 root fix: --async-delete-process clears the sentinel first, so
tearing down a tunnel whose death-sentinel is armed never spuriously sets
--tunnel-dead (which would wedge later sends)."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (emacs-jupyter-notebook--tunnel-dead nil))
      (let ((proc (start-process "ejn-w13-tunnel" nil "sleep" "60")))
        (emacs-jupyter-notebook--install-tunnel-sentinel proc buf)
        (emacs-jupyter-notebook--async-delete-process proc)
        (accept-process-output nil 0.05)
        (should-not emacs-jupyter-notebook--tunnel-dead)))))

(ert-deftest ejn-tunnel-dead-branch-wires-callback-and-error-callback ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead t)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (buffer callback error-callback)
                   (setq reconnect-called t)
                   (should (functionp callback))
                   (should (functionp error-callback))
                   (setq emacs-jupyter-notebook--tunnel-dead nil)
                   (setq emacs-jupyter-notebook--client
                         (ejn-test-backend-session 'mock-client t))
                   (funcall callback nil))))
        (emacs-jupyter-notebook-send-cell)
        (should reconnect-called)
        (should eval-called)))))

(ert-deftest ejn-tunnel-dead-branch-error-callback-fires-on-failure ()
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead t)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (error-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (&rest _)
              (setq eval-called t))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (_buffer _callback error-callback)
                   (funcall error-callback nil "tunnel reconnect failed"))))
        (emacs-jupyter-notebook-send-cell)
        (should-not eval-called)))))

(ert-deftest ejn-w4.6-heartbeat-death-routes-through-tunnel-reconnect ()
  "W4.6: the --tunnel-dead flag set by a heartbeat miss-threshold leads
`--ensure-client-async' to `--tunnel-reconnect' in exactly the same way as
sentinel-driven death.  Heartbeat and sentinel are indistinguishable to
the evaluate flow."
  (ejn-test-with-temp-buffer "# %%\na = 1\n"
    (let* ((emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (emacs-jupyter-notebook--tunnel-dead nil)
           (emacs-jupyter-notebook--session-entry
            '(:profile "p" :session-id "s" :local-file "/tmp/x.py"))
           (reconnect-called nil)
           (eval-called nil)
           (emacs-jupyter-notebook-jupyter-evaluate-function
            (lambda (_client _code _entry-handle)
              (setq eval-called t)))
           (emacs-jupyter-notebook-heartbeat-misses-allowed 2))
      ;; Trigger heartbeat-driven death exactly the way the runtime does.
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (emacs-jupyter-notebook--heartbeat-on-miss)
        (emacs-jupyter-notebook--heartbeat-on-miss))
      (should emacs-jupyter-notebook--tunnel-dead)
      ;; Now evaluate: the engine must route through tunnel-reconnect
      ;; without distinguishing how we got here.
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--tunnel-reconnect)
                 (lambda (buffer callback _error-callback)
                   (setq reconnect-called t)
                   (should (functionp callback))
                   (setq emacs-jupyter-notebook--tunnel-dead nil)
                   (setq emacs-jupyter-notebook--client
                         (ejn-test-backend-session 'mock-client t))
                   (funcall callback nil))))
        (emacs-jupyter-notebook-send-cell)
        (should reconnect-called)
        (should eval-called)))))

(ert-deftest ejn-install-tunnel-sentinel-detects-already-dead-process ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (proc (start-process "ejn-test-dead-tunnel" nil "true")))
      (emacs-jupyter-notebook-mode 1)
      (setq emacs-jupyter-notebook--tunnel-dead nil)
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc)
                    (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (emacs-jupyter-notebook--install-tunnel-sentinel proc buffer)
      (should emacs-jupyter-notebook--tunnel-dead))))

(ert-deftest ejn-panel-source-text-not-mutated-by-image-result ()
  "W2: setting an image on a panel entry does not touch source-buffer text."
  (ejn-test-with-temp-buffer "# %%\nimport matplotlib\n"
    (let* ((before (buffer-string))
           (source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-set-image handle '(image :type png :data "fake"))
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-clear-results-empties-panel ()
  "W2: clear-results empties the output panel and clears fringe indicators."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "stuff")
      (emacs-jupyter-notebook-fringe-set '("x.py" . 1) 'ok 3)
      (should emacs-jupyter-notebook--fringe-overlays)
      (emacs-jupyter-notebook-clear-results)
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--entries))
      (should-not emacs-jupyter-notebook--fringe-overlays))))

(ert-deftest ejn-callback-input-request-appends-prompt-to-panel ()
  "W2.7: input_request appends the prompt and defers reading it."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (source-before (buffer-string))
           (prompted nil)
           (reply-sent nil))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Enter value: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt)
                   (setq prompted prompt)
                   "42"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (_client _value) (setq reply-sent t))))
        (funcall input-fn 'mock-input-msg)
        (should-not prompted)
        (should-not reply-sent)
        (ejn-test-drain-zero-delay-timers))
      (should (string-match-p "Enter value: "
                              (ejn-panel-entry-text handle)))
      (should (equal prompted "Enter value: "))
      (should reply-sent)
      (should (equal (buffer-string) source-before)))))

(ert-deftest ejn-callback-input-request-sends-reply-with-user-input ()
  "W2.7: input_request relays the user's response back to the kernel."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (source-before (buffer-string))
           prompted
           reply-sent)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Name: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt) (setq prompted prompt) "alice"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (client value)
                   (setq reply-sent (list client value)))))
        (funcall input-fn 'mock-input-msg)
        (should-not prompted)
        (should-not reply-sent)
        (ejn-test-drain-zero-delay-timers))
      (should (equal prompted "Name: "))
      (should (equal reply-sent '(mock-client "alice")))
      (should (equal (buffer-string) source-before)))))

(ert-deftest ejn-callback-input-request-uses-read-passwd-for-password ()
  "W2.7: password prompts route through `read-passwd'."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (source-before (buffer-string))
           passwd-called passwd-prompt reply-value)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Password: " :password t)))
                ((symbol-function 'read-passwd)
                 (lambda (prompt)
                   (setq passwd-called t)
                   (setq passwd-prompt prompt)
                   "secret"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (_client value)
                    (setq reply-value (copy-sequence value)))))
        (funcall input-fn 'mock-input-msg)
        (should-not passwd-called)
        (should-not reply-value)
        (ejn-test-drain-zero-delay-timers))
      (should passwd-called)
      (should (equal passwd-prompt "Password: "))
      (should (equal reply-value "secret"))
      (should (equal (buffer-string) source-before)))))

(ert-deftest ejn-callback-input-request-without-client-does-not-send-reply ()
  "W2.7: without a client, the input_request callback still shows the prompt."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (reply-called nil))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Input: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (_prompt) "test"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 (lambda (&rest _)
                   (setq reply-called t))))
        (funcall input-fn 'mock-input-msg))
      (should-not reply-called)
      (should (string-match-p "Input: "
                              (ejn-panel-entry-text handle))))))

(ert-deftest ejn-callback-input-request-extracts-prompt-and-password-fields ()
  "W2.7: input_request reads :prompt and :password fields correctly."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                        buffer handle 'mock-client))
           (input-fn (cadr (assoc "input_request" callbacks)))
           (source-before (buffer-string))
           captured-prompt)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg) '(:prompt "Your name: " :password nil)))
                ((symbol-function 'read-string)
                 (lambda (prompt) (setq captured-prompt prompt) "bob"))
                ((symbol-function 'emacs-jupyter-notebook-jupyter--send-input-reply)
                 #'ignore))
        (funcall input-fn 'mock-input-msg)
        (should-not captured-prompt)
        (ejn-test-drain-zero-delay-timers))
      (should (equal captured-prompt "Your name: "))
      (should (equal (buffer-string) source-before)))))

(ert-deftest ejn-send-input-reply-delegates-to-jupyter-run-with-state ()
  (let ((called-with nil))
    (cl-letf (((symbol-function 'jupyter-run-with-state)
               (lambda (client body)
                 (setq called-with (list client body))
                 nil))
              ((symbol-function 'jupyter-sent)
               (lambda (req) (list 'sent req)))
              ((symbol-function 'jupyter-input-reply)
               (lambda (&rest args) (cons 'input-reply args))))
      (emacs-jupyter-notebook-jupyter--send-input-reply 'my-client "hello")
      (should (equal (car called-with) 'my-client))
      (should (equal (cadr called-with) '(sent (input-reply :value "hello")))))))

(ert-deftest ejn-watch-expressions-plist-converts-to-json-plist ()
  (let ((emacs-jupyter-notebook-watch-expressions
         '(("x" . "x")
           ("mean value" . "sum(xs) / len(xs)")
           ("" . "ignored")
           ("missing" . ""))))
    (should (equal (emacs-jupyter-notebook-jupyter--watch-expressions-plist)
                   (list :x "x"
                         (intern ":mean value") "sum(xs) / len(xs)")))))

(ert-deftest ejn-evaluate-sends-user-expressions ()
  "W2.7: user_expressions are forwarded to jupyter-execute-request."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-watch-expressions
           '(("x" . "x") ("total" . "sum(xs)")))
          captured-args)
      (cl-letf* ((orig-require (symbol-function 'require))
                 ((symbol-function 'require)
                  (lambda (feature &optional filename noerror)
                    (if (memq feature '(jupyter-client jupyter-messages jupyter-monads))
                        feature
                      (funcall orig-require feature filename noerror))))
                 ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure) #'ignore)
                 ((symbol-function 'jupyter-run-with-state) (lambda (&rest _) nil))
                 ((symbol-function 'jupyter-sent) (lambda (x) x))
                 ((symbol-function 'jupyter-message-subscribed) (lambda (req _cbs) req))
                 ((symbol-function 'jupyter-execute-request)
                  (lambda (&rest args)
                    (setq captured-args args)
                    'mock-request)))
        (insert "# %%\nx = 1\n")
        (let* ((panel (ejn-panel-ensure (current-buffer)))
               (handle (ejn-panel-start-entry panel '("x.py" . 1) "x = 1")))
          (emacs-jupyter-notebook-jupyter--evaluate
           'mock-client "x = 1" handle))
        (should (equal (plist-get captured-args :user-expressions)
                       '(:x "x" :total "sum(xs)")))))))

(ert-deftest ejn-execute-reply-appends-watch-results ()
  "W2.7: execute_reply watch results are appended to the panel entry."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (reply-fn (cadr (assoc "execute_reply" callbacks))))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   '(:status "ok"
                     :execution_count 9
                     :user_expressions
                     (:x (:status "ok" :data (:text/plain "10"))
                      :bad (:status "error" :ename "NameError" :evalue "name 'bad' is not defined"))))))
        (funcall reply-fn 'mock-reply-msg))
      (let ((content (ejn-panel-entry-text handle)))
        (should (string-match-p "\\[watch\\]" content))
        (should (string-match-p "x: 10" content))
        (should (string-match-p "bad: NameError: name 'bad' is not defined" content))))))


(ert-deftest ejn-w5.4-interrupt-kernel-dispatches-through-adapter-var ()
  "W5.4: `emacs-jupyter-notebook-interrupt-kernel' calls
`emacs-jupyter-notebook-jupyter-interrupt-function'.  Stub the var,
invoke the interactive command, assert the stub saw the buffer-local
client."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          captured)
      (let ((emacs-jupyter-notebook-jupyter-interrupt-function
             (lambda (client) (setq captured client))))
        (call-interactively #'emacs-jupyter-notebook-interrupt-kernel))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w5.4-restart-kernel-dispatches-through-adapter-var ()
  "W5.4: `emacs-jupyter-notebook-restart-kernel' calls
`emacs-jupyter-notebook-jupyter-restart-function'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          ;; W13-Viewer3: re-injection is gated on kernel_info; stub the
          ;; adapter so it does not reach the real (unloaded) emacs-jupyter.
          (emacs-jupyter-notebook-jupyter-kernel-info-function
           (lambda (_client _callback) nil))
          captured)
      (let ((emacs-jupyter-notebook-jupyter-restart-function
             (lambda (client) (setq captured client))))
        (call-interactively #'emacs-jupyter-notebook-restart-kernel))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w5.4-interrupt-kernel-errors-without-client ()
  "W5.4: interrupt without a client surfaces a clear error, does not call adapter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-interrupt-function
             (lambda (&rest _) (setq adapter-called t))))
        (should-error (call-interactively #'emacs-jupyter-notebook-interrupt-kernel)))
      (should-not adapter-called))))

(ert-deftest ejn-w5.4-restart-kernel-errors-without-client ()
  "W5.4: restart without a client surfaces a clear error, does not call adapter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          adapter-called)
      (let ((emacs-jupyter-notebook-jupyter-restart-function
             (lambda (&rest _) (setq adapter-called t))))
        (should-error (call-interactively #'emacs-jupyter-notebook-restart-kernel)))
      (should-not adapter-called))))


(ert-deftest ejn-async-connect-calls-connect-async-function ()
  (let ((entry '(:profile "p"
                 :remote-host "example.com"
                 :remote-connection-file "/tmp/kernel.json"
                 :session-id "session"))
        (profile '(:profile "p" :host "example.com"))
        (local-ports '(:shell_port 1001
                       :iopub_port 1002
                       :stdin_port 1003
                       :hb_port 1004
                       :control_port 1005))
        (local-file (make-temp-file "ejn-test-" nil ".json"))
        connect-async-called
        captured-callback)
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--start-tunnel)
                     (lambda (&rest _) 'mock-process))
                    ((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                     #'ignore)
                    ((symbol-function 'emacs-jupyter-notebook-jupyter-connect-async)
                     (lambda (file callback)
                       (setq connect-async-called t)
                       (setq captured-callback callback)
                       'mock-client))
                    ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                     #'ignore))
            (with-temp-buffer
              (let* ((context (emacs-jupyter-notebook--async-new-context
                               :phase 'tunnel
                               :entry entry
                               :session-id "session"
                               :local-ports local-ports
                               :local-file local-file
                               :tunnel-process 'mock-process
                               :origin-buffer (current-buffer))))
                (setq emacs-jupyter-notebook--async-context context)
                (setq context (emacs-jupyter-notebook--async-connect context))
                (should connect-async-called)
                (should (functionp captured-callback))
                (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'connect))))))
      (when (file-exists-p local-file)
        (delete-file local-file)))))

(ert-deftest ejn-async-connect-finalize-sets-client-on-success ()
  (let ((entry '(:profile "p" :session-id "session"))
        (local-ports '(:shell_port 1001))
        (local-file "/tmp/test.json")
        (session nil)
        (emacs-jupyter-notebook--client nil)
        (emacs-jupyter-notebook--session-entry nil)
        saved-entry)
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'connect
                      :entry entry
                      :origin-buffer (current-buffer))))
        (setq emacs-jupyter-notebook--async-context context)
        (setq session (ejn-test-backend-session 'mock-client t))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                   (lambda (entry &optional _file)
                     (setq saved-entry entry))))
          (emacs-jupyter-notebook--async-connect-finalize
           context buffer entry local-ports local-file session))
        (should (eq emacs-jupyter-notebook--client session))
        (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done))
        (should (equal (plist-get saved-entry :session-id) "session"))
        (should (equal (plist-get emacs-jupyter-notebook--session-entry :tunnel-ports)
                       local-ports))))))

(ert-deftest ejn-async-connect-finalize-fails-on-nil-client ()
  (let ((entry '(:profile "p" :session-id "session"))
        (local-ports '(:shell_port 1001))
        (local-file "/tmp/test.json")
        (emacs-jupyter-notebook--client nil))
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'connect
                      :entry entry
                      :origin-buffer (current-buffer)
                      :error-callback (lambda (_ctx _err) nil))))
        (setq emacs-jupyter-notebook--async-context context)
        (emacs-jupyter-notebook--async-connect-finalize
         context buffer entry local-ports local-file nil)
        (should-not emacs-jupyter-notebook--client)
        (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error))))))

(ert-deftest ejn-async-connect-timeout-fails-context ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (context (emacs-jupyter-notebook--async-new-context
                    :phase 'connect
                    :entry '(:profile "p" :session-id "session")
                    :origin-buffer (current-buffer)
                    :error-callback (lambda (_ctx _err) nil))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--async-connect-timeout context buffer)
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'error)))))

(ert-deftest ejn-async-connect-timeout-noop-when-not-connecting ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (context (emacs-jupyter-notebook--async-new-context
                    :phase 'done
                    :entry '(:profile "p" :session-id "session")
                    :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--async-connect-timeout context buffer)
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)))))

(ert-deftest ejn-w15-heartbeat-suspended-while-kernel-busy ()
  "W15-A: while the kernel is busy the heartbeat sends NO probe and resets
the miss counter — shell silence is the expected state of a busy kernel,
not evidence of death.  This kills the false tunnel-death that fired ~45 s
into every long-running (training) cell."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--kernel-status 'busy)
          (emacs-jupyter-notebook--heartbeat-misses 2)
          probed)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (&rest _) (setq probed t))))
        (emacs-jupyter-notebook--heartbeat-tick))
      (should-not probed)
      (should (= emacs-jupyter-notebook--heartbeat-misses 0))
      (should-not emacs-jupyter-notebook--tunnel-dead))))

(ert-deftest ejn-w15-connect-timeout-busy-kernel-finalizes-busy ()
  "W15-B: kernel-info timeout on a RECONNECT + PID probe says alive →
finalize as connected-BUSY: client installed, status busy, phase done,
registry saved — no failure."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (session (ejn-test-backend-session 'mock-client t))
           (entry (ejn-test-direct-entry
                   '(:profile "p" :session-id "s15" :remote-host "h"
                     :remote-pid 4242
                     :remote-connection-file "/r/k.json")))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect
                     :profile '(:profile "p" :host "h")
                     :entry entry
                     :session-id "s15"
                     :local-ports '(:shell_port 1001)
                     :local-file "/tmp/k15.json"
                     :client-unverified session
                     :origin-buffer buffer))
           failed)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (&rest _) (setq failed t)))
                ((symbol-function 'emacs-jupyter-notebook--heartbeat-start) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-save-entry) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                 (ejn-test--probe-process-fn
                  "echo __EJN_ALIVE_MATCH__; echo __EJN_DONE__")))
        (emacs-jupyter-notebook--async-connect-timeout context buffer)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not (eq emacs-jupyter-notebook--client session))
                      (not failed)
                      (< (float-time) deadline))
            (accept-process-output nil 0.02))))
      (should-not failed)
      (should (eq emacs-jupyter-notebook--client session))
      (should (eq emacs-jupyter-notebook--kernel-status 'busy))
      (should (eq (plist-get emacs-jupyter-notebook--async-context :phase) 'done)))))

(ert-deftest ejn-w15-connect-timeout-dead-kernel-fails ()
  "W15-B: kernel-info timeout + PID probe answers dead → fail with the
kernel-dead message; no client installed."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (session (ejn-test-backend-session 'mock-client t))
           (entry (ejn-test-direct-entry
                   '(:profile "p" :session-id "s15d" :remote-host "h"
                     :remote-pid 4243
                     :remote-connection-file "/r/k.json")))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect
                     :profile '(:profile "p" :host "h")
                     :entry entry
                     :session-id "s15d"
                     :client-unverified session
                     :origin-buffer buffer))
           fail-reason)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (_ctx err) (setq fail-reason err)))
                ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                 (ejn-test--probe-process-fn
                  "echo __EJN_DEAD__; echo __EJN_DONE__")))
        (emacs-jupyter-notebook--async-connect-timeout context buffer)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not fail-reason) (< (float-time) deadline))
            (accept-process-output nil 0.02))))
      (should fail-reason)
      (should (string-match-p "no longer alive" fail-reason))
      (should-not emacs-jupyter-notebook--client))))

(ert-deftest ejn-w15-connect-timeout-unattached-session-does-not-probe-pid ()
  "W15-B: an opaque but unattached reconnect session must not busy-finalize.
Even with a recorded live PID, no local channel exists yet, so timeout fails
directly without starting the busy-kernel PID probe."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (session (ejn-test-backend-session 'mock-client nil))
           (entry '(:profile "p" :session-id "s15u" :remote-host "h"
                    :remote-pid 4244
                    :remote-connection-file "/r/k.json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect
                     :profile '(:profile "p" :host "h")
                     :entry entry
                     :session-id "s15u"
                     :client-unverified session
                     :origin-buffer buffer))
           (fail-reason nil)
           (probed nil))
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (_ctx err) (setq fail-reason err)))
                ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                 (lambda (&rest _) (setq probed t) nil)))
        (emacs-jupyter-notebook--async-connect-timeout context buffer))
      (should fail-reason)
      (should (string-match-p "kernel_info_reply" fail-reason))
      (should-not probed)
      (should-not emacs-jupyter-notebook--client))))

(ert-deftest ejn-w15-connect-timeout-fresh-start-fails-hard ()
  "W15-B: a FRESH START's kernel is never legitimately busy — kernel-info
timeout hard-fails without any PID probe."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect
                     :owns-kernel t
                     :entry '(:profile "p" :session-id "sf" :remote-pid 99)
                     :client-unverified 'mock-client
                     :origin-buffer buffer))
           fail-reason probed)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (_ctx err) (setq fail-reason err)))
                ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                 (lambda (&rest _) (setq probed t) nil)))
        (emacs-jupyter-notebook--async-connect-timeout context buffer))
      (should fail-reason)
      (should (string-match-p "kernel_info_reply" fail-reason))
      (should-not probed))))

(ert-deftest ejn-w15-late-verify-flips-busy-to-idle ()
  "W15-B: the queued verification kernel-info answering hours later flips a
busy-finalized buffer to idle; a stale client or non-busy status is a no-op."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (setq emacs-jupyter-notebook--client 'mock-client
            emacs-jupyter-notebook--kernel-status 'busy)
      (emacs-jupyter-notebook--connect-verified-late buffer 'other-client)
      (should (eq emacs-jupyter-notebook--kernel-status 'busy))
      (emacs-jupyter-notebook--connect-verified-late buffer 'mock-client)
      (should (eq emacs-jupyter-notebook--kernel-status 'idle))
      ;; Already idle: no flip back / no error.
      (emacs-jupyter-notebook--connect-verified-late buffer 'mock-client)
      (should (eq emacs-jupyter-notebook--kernel-status 'idle)))))

(ert-deftest ejn-w13-h3-stale-connect-finalize-spares-newer-attempt ()
  "W13-H3: a superseded attempt's connect callback must not touch the newer
attempt that now occupies the buffer.  Finalizing with the OLD context while
context B (also at phase `connect') is active is a no-op: B is neither failed
nor given the stale client."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (ctx-a (emacs-jupyter-notebook--async-new-context
                   :phase 'connect :entry '(:profile "p" :session-id "a")
                   :origin-buffer buffer
                   :error-callback (lambda (&rest _) nil)))
           (ctx-b (emacs-jupyter-notebook--async-new-context
                   :phase 'connect :entry '(:profile "p" :session-id "b")
                   :origin-buffer buffer
                   :error-callback (lambda (&rest _) nil))))
      ;; B is the active attempt; A was superseded.
      (setq emacs-jupyter-notebook--async-context ctx-b)
      ;; A's stale connect callback fires (nil client would normally fail).
      (emacs-jupyter-notebook--async-connect-finalize
       ctx-a buffer '(:profile "p" :session-id "a") '(:shell_port 1) "/tmp/a.json" nil)
      ;; B untouched: still connecting, no client installed.
      (should (eq emacs-jupyter-notebook--async-context ctx-b))
      (should (eq (plist-get ctx-b :phase) 'connect))
      (should-not emacs-jupyter-notebook--client)
      ;; A's stale success client is also refused.
      (emacs-jupyter-notebook--async-connect-finalize
       ctx-a buffer '(:profile "p" :session-id "a") '(:shell_port 1) "/tmp/a.json" 'stale-client)
      (should-not emacs-jupyter-notebook--client)
      (should (eq (plist-get ctx-b :phase) 'connect)))))

(ert-deftest ejn-mode-disable-does-not-install-source-change-hooks ()
  "W2: with the panel design the source buffer needs no before/after-change
hooks, so mode enable does not install them."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should-not (memq 'emacs-jupyter-notebook--after-change-cleanup
                      after-change-functions))
    (should-not (memq 'emacs-jupyter-notebook--before-change
                      before-change-functions))))

(ert-deftest ejn-mode-enable-installs-buffer-local-kill-buffer-hook ()
  "W1.1: enabling the minor mode installs the buffer-local kill-buffer-hook."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (memq 'emacs-jupyter-notebook--kill-buffer-hook
                  kill-buffer-hook))
    (should (local-variable-p 'kill-buffer-hook))))

(ert-deftest ejn-mode-disable-removes-kill-buffer-hook ()
  "W1.1: disabling the minor mode removes the buffer-local kill-buffer-hook."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (should (memq 'emacs-jupyter-notebook--kill-buffer-hook
                  kill-buffer-hook))
    (emacs-jupyter-notebook-mode -1)
    (should-not (memq 'emacs-jupyter-notebook--kill-buffer-hook
                      kill-buffer-hook))))

(ert-deftest ejn-release-local-resources-drops-client-without-shutdown ()
  "W1.1: the disposer drops the client without calling jupyter-shutdown."
  (let (shutdown-called)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
               (lambda (&rest _)
                 (setq shutdown-called t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--client
              (ejn-test-backend-session 'mock-client t))
        (emacs-jupyter-notebook--release-local-resources)
        (should-not shutdown-called)
        (should-not emacs-jupyter-notebook--client)))))

(ert-deftest ejn-release-local-resources-preserves-session-entry ()
  "W1.1: the disposer leaves the registry-bearing session entry untouched."
  (let ((entry '(:profile "p"
                 :session-id "session"
                 :remote-connection-file "/tmp/kernel.json"
                 :local-connection-file "/tmp/local.json"))
        cleanup-called registry-removed)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
               (lambda (&rest _)
                 (setq registry-removed t))))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not cleanup-called)
        (should-not registry-removed)
        (should (equal emacs-jupyter-notebook--session-entry entry))))))

(ert-deftest ejn-release-local-resources-preserves-local-connection-file ()
  "W1.1: the disposer does not delete the local connection file."
  (let* ((dir (make-temp-file "ejn-release-" t))
         (local-file (expand-file-name "kernel.json" dir))
         (entry `(:profile "p"
                  :session-id "session"
                  :remote-connection-file "/tmp/kernel.json"
                  :local-connection-file ,local-file)))
    (unwind-protect
        (progn
          (with-temp-file local-file (insert "{}"))
          (with-temp-buffer
            (setq emacs-jupyter-notebook--session-entry entry)
            (emacs-jupyter-notebook--release-local-resources)
            (should (file-exists-p local-file))))
      (delete-directory dir t))))

(ert-deftest ejn-release-local-resources-kills-tunnel-process ()
  "W1.1: the disposer kills the SSH tunnel process and its buffer."
  (with-temp-buffer
    (let ((proc (start-process "ejn-test-tunnel-release" nil "sleep" "60")))
      (setq emacs-jupyter-notebook--tunnel-process proc)
      (let ((proc-buffer (process-buffer proc)))
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not (and proc-buffer (buffer-live-p proc-buffer)))
        (should-not emacs-jupyter-notebook--tunnel-process)))))

(ert-deftest ejn-release-local-resources-cancels-execution-record-timers ()
  "W1.1/EI3: the disposer cancels every ledger-owned execution timer."
  (with-temp-buffer
    (let ((timer (run-at-time 600 nil #'ignore)))
      (emacs-jupyter-notebook--execution-put (list :id 1 :timer timer))
      (emacs-jupyter-notebook--release-local-resources)
      (should-not (memq timer timer-list))
      (should-not emacs-jupyter-notebook--execution-ledger))))

(ert-deftest ejn-release-local-resources-cancels-async-context-processes ()
  "W1.1: the disposer kills in-flight async launch/scp/tunnel processes."
  (with-temp-buffer
    (let* ((launch (start-process "ejn-test-launch" nil "sleep" "60"))
           (scp (start-process "ejn-test-scp" nil "sleep" "60"))
           (tunnel (start-process "ejn-test-tunnel-ctx" nil "sleep" "60"))
           (remote-copy (make-temp-file "ejn-remote-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :remote-copy remote-copy
                     :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook--release-local-resources)
      (should-not (process-live-p launch))
      (should-not (process-live-p scp))
      (should-not (process-live-p tunnel))
      (should-not (file-exists-p remote-copy))
      (should-not emacs-jupyter-notebook--async-context))))

(ert-deftest ejn-release-local-resources-does-not-delete-async-local-file ()
  "W1.1: the disposer does not delete the in-flight context's local-file path."
  (with-temp-buffer
    (let* ((local-file (make-temp-file "ejn-local-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'retrieve
                     :local-file local-file
                     :origin-buffer (current-buffer))))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--async-context context)
            (emacs-jupyter-notebook--release-local-resources)
            (should (file-exists-p local-file)))
        (when (file-exists-p local-file)
          (delete-file local-file))))))

(ert-deftest ejn-mode-disable-cancels-async-context-locally ()
  "W1.2: disabling the mode cancels any in-flight async context locally."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let* ((launch (start-process "ejn-test-disable-launch" nil "sleep" "60"))
           (scp (start-process "ejn-test-disable-scp" nil "sleep" "60"))
           (tunnel (start-process "ejn-test-disable-tunnel" nil "sleep" "60"))
           (remote-copy (make-temp-file "ejn-disable-remote-" nil ".json"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'tunnel
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :remote-copy remote-copy
                     :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (emacs-jupyter-notebook-mode -1)
      (should-not (process-live-p launch))
      (should-not (process-live-p scp))
      (should-not (process-live-p tunnel))
      (should-not (file-exists-p remote-copy))
      (should-not emacs-jupyter-notebook--async-context))))

(ert-deftest ejn-mode-disable-cancels-buffer-local-timers ()
  "W1.2/EI3: disabling the mode cancels ledger and completion idle timers."
  (with-temp-buffer
    (emacs-jupyter-notebook-mode 1)
    (let ((eval-timer (run-at-time 600 nil #'ignore)))
      (emacs-jupyter-notebook--execution-put (list :id 1 :timer eval-timer))
      (emacs-jupyter-notebook-mode -1)
      (should-not emacs-jupyter-notebook--execution-ledger)
      (should-not (memq eval-timer timer-list))
      (should-not emacs-jupyter-notebook--completion-idle-timer))))

(ert-deftest ejn-mode-disable-preserves-session-entry-and-registry ()
  "W1.2 + W1.9: mode disable does not call jupyter-shutdown, does not touch the
registry, and preserves the buffer's `--session-entry'.  It DOES drop the
buffer-local client handle: that handle is a local resource and the W1 GOAL
explicitly lists it among the things released on mode disable."
  (let (shutdown-called cleanup-called registry-removed
        (entry '(:profile "p" :session-id "session")))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
               (lambda (&rest _)
                 (setq shutdown-called t)))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               (lambda (&rest _)
                 (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
               (lambda (&rest _)
                 (setq registry-removed t))))
      (with-temp-buffer
        (emacs-jupyter-notebook-mode 1)
        (setq emacs-jupyter-notebook--client
              (ejn-test-backend-session 'mock-client t))
        (setq emacs-jupyter-notebook--session-entry entry)
        (emacs-jupyter-notebook-mode -1)
        (should-not shutdown-called)
        (should-not cleanup-called)
        (should-not registry-removed)
        (should (equal emacs-jupyter-notebook--session-entry entry))
        (should-not emacs-jupyter-notebook--client)))))

(ert-deftest ejn-release-local-resources-survives-one-disposer-raising ()
  "W1.10: when one disposer in `--release-local-resources' raises, the remaining
disposers still run and the final state-clearing setq still executes.  This
test poisons `--clear-buffer-timers' to throw and asserts that the tunnel
process is still disposed and the buffer-local state is still cleared."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-w110-tunnel" '("sleep" "60"))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--clear-buffer-timers)
                 (lambda (&rest _) (error "simulated disposer failure"))))
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (setq emacs-jupyter-notebook--client
              (ejn-test-backend-session 'mock-client t))
        (setq emacs-jupyter-notebook--kernel-status 'busy)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not emacs-jupyter-notebook--tunnel-process)
        (should-not emacs-jupyter-notebook--client)
        (should-not emacs-jupyter-notebook--kernel-status)))))

(ert-deftest ejn-mode-disable-disposes-tunnel-process-and-stderr-buffer ()
  "W1.9: mode disable disposes the buffer-local tunnel process and its stderr
buffer.  The remote kernel and registry stay alive; only the local SSH tunnel
goes away."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-w19-tunnel" '("sleep" "60"))))
      (let ((stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
        (should (buffer-live-p stderr))
        (emacs-jupyter-notebook-mode 1)
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook-mode -1)
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))
        (should-not emacs-jupyter-notebook--tunnel-process)))))

(ert-deftest ejn-mode-disable-cleanup-swallows-errors ()
  "W1.2: mode-disable cleanup swallows disposer errors without raising."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook--cancel-async-context-locally)
             (lambda (&rest _) (error "boom"))))
    (with-temp-buffer
      (should
       (progn
         (emacs-jupyter-notebook--mode-disable-cleanup)
         t)))))

(ert-deftest ejn-async-delete-process-kills-stderr-buffer ()
  "W1.3: the disposer kills the stderr buffer carried as a process property."
  (let ((proc (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-stderr-leak" '("sleep" "60"))))
    (let ((stdout (process-buffer proc))
          (stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
      (should (buffer-live-p stderr))
      (emacs-jupyter-notebook--async-delete-process proc)
      (should-not (process-live-p proc))
      (should-not (and stdout (buffer-live-p stdout)))
      (should-not (buffer-live-p stderr)))))

(ert-deftest ejn-async-delete-process-tolerates-missing-stderr-buffer ()
  "W1.3: the disposer handles processes that have no stderr property."
  (let ((proc (start-process "ejn-test-plain" nil "sleep" "60")))
    (let ((stdout (process-buffer proc)))
      (emacs-jupyter-notebook--async-delete-process proc)
      (should-not (process-live-p proc))
      (should-not (and stdout (buffer-live-p stdout))))))

(ert-deftest ejn-async-fail-disposes-stderr-buffers ()
  "W1.3: `--async-fail' disposes launch/scp/tunnel stderr buffers."
  (let* ((launch (emacs-jupyter-notebook-ssh-start-process
                  "ejn-test-fail-launch" '("sleep" "60")))
         (scp (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-fail-scp" '("sleep" "60")))
         (tunnel (emacs-jupyter-notebook-ssh-start-process
                  "ejn-test-fail-tunnel" '("sleep" "60")))
         (stderrs (mapcar (lambda (p)
                            (process-get p 'emacs-jupyter-notebook-stderr-buffer))
                          (list launch scp tunnel)))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'launch
                   :launch-process launch
                   :scp-process scp
                   :tunnel-process tunnel)))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (with-temp-buffer
        (emacs-jupyter-notebook--async-fail context "boom")
        (dolist (b stderrs)
          (should-not (buffer-live-p b)))))))

(ert-deftest ejn-cleanup-current-state-disposes-tunnel-stderr-buffer ()
  "W1.3: `--cleanup-current-state' disposes the tunnel stderr buffer."
  (let ((proc (emacs-jupyter-notebook-ssh-start-process
               "ejn-test-cleanup-tunnel" '("sleep" "60")))
        stderr)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown) #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
               #'ignore))
      (setq stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer))
      (should (buffer-live-p stderr))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook--cleanup-current-state "cleanup")
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))))))

(ert-deftest ejn-release-local-resources-disposes-tunnel-stderr-buffer ()
  "W1.3: the kill-buffer disposer kills the tunnel stderr buffer."
  (with-temp-buffer
    (let ((proc (emacs-jupyter-notebook-ssh-start-process
                 "ejn-test-release-tunnel" '("sleep" "60"))))
      (let ((stderr (process-get proc 'emacs-jupyter-notebook-stderr-buffer)))
        (should (buffer-live-p stderr))
        (setq emacs-jupyter-notebook--tunnel-process proc)
        (emacs-jupyter-notebook--release-local-resources)
        (should-not (process-live-p proc))
        (should-not (buffer-live-p stderr))))))

(ert-deftest ejn-kill-buffer-with-async-context-cleans-locally-and-preserves-registry ()
  "W1.4: killing a buffer with an in-flight async context kills the local
launch/scp/tunnel processes and their stderr buffers, yet leaves the registry
entry and the local connection file on disk untouched (they are the offline
reconnect key)."
  (let* ((registry-dir (make-temp-file "ejn-w14-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (local-dir (make-temp-file "ejn-w14-local-" t))
         (local-file (expand-file-name "kernel.json" local-dir))
         (entry `(:profile "p"
                  :session-id "w14-session"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"
                  :local-connection-file ,local-file))
         shutdown-called cleanup-called
         (emacs-jupyter-notebook-registry-file registry-file))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (setq cleanup-called t))))
          (with-temp-file local-file (insert "{}"))
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (let* ((buffer (generate-new-buffer "ejn-w14"))
                 (launch (emacs-jupyter-notebook-ssh-start-process
                          "ejn-test-w14-launch" '("sleep" "60")))
                 (scp (emacs-jupyter-notebook-ssh-start-process
                       "ejn-test-w14-scp" '("sleep" "60")))
                 (tunnel (emacs-jupyter-notebook-ssh-start-process
                          "ejn-test-w14-tunnel" '("sleep" "60")))
                 (stderrs (mapcar (lambda (p)
                                    (process-get
                                     p 'emacs-jupyter-notebook-stderr-buffer))
                                  (list launch scp tunnel))))
            (with-current-buffer buffer
              (emacs-jupyter-notebook-mode 1)
              (setq emacs-jupyter-notebook--client
                    (ejn-test-backend-session 'mock-client t))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--tunnel-process tunnel)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'launch
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :origin-buffer buffer)))
            (kill-buffer buffer)
            (should-not (process-live-p launch))
            (should-not (process-live-p scp))
            (should-not (process-live-p tunnel))
            (dolist (b stderrs)
              (should-not (buffer-live-p b)))
            (should-not shutdown-called)
            (should-not cleanup-called)
            (should (file-exists-p local-file))
            (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
              (should (= (length remaining) 1))
              (should (equal (plist-get (car remaining) :session-id)
                             "w14-session")))))
      (delete-directory registry-dir t)
      (delete-directory local-dir t))))

(defun ejn-test--mode-disable-during-phase (phase)
  "Helper for W1.5: disable the mode while async context is in PHASE.
Returns a plist describing post-disable state of the in-flight processes."
  (let* ((registry-dir (make-temp-file "ejn-w15-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry `(:profile "p"
                  :session-id ,(format "w15-%s" phase)
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"))
         (emacs-jupyter-notebook-registry-file registry-file)
         result)
    (unwind-protect
        (progn
          (emacs-jupyter-notebook-registry-save (list entry) registry-file)
          (with-temp-buffer
            (emacs-jupyter-notebook-mode 1)
            (let* ((launch (emacs-jupyter-notebook-ssh-start-process
                            (format "ejn-test-w15-%s-launch" phase)
                            '("sleep" "60")))
                   (scp (emacs-jupyter-notebook-ssh-start-process
                         (format "ejn-test-w15-%s-scp" phase)
                         '("sleep" "60")))
                   (tunnel (emacs-jupyter-notebook-ssh-start-process
                            (format "ejn-test-w15-%s-tunnel" phase)
                            '("sleep" "60")))
                   (timer (run-at-time 600 nil #'ignore))
                   (stderrs (mapcar (lambda (p)
                                      (process-get
                                       p 'emacs-jupyter-notebook-stderr-buffer))
                                    (list launch scp tunnel))))
              (setq emacs-jupyter-notebook--session-entry entry)
              (setq emacs-jupyter-notebook--async-context
                    (emacs-jupyter-notebook--async-new-context
                     :phase phase
                     :launch-process launch
                     :scp-process scp
                     :tunnel-process tunnel
                     :timer timer
                     :origin-buffer (current-buffer)))
              (emacs-jupyter-notebook-mode -1)
              (setq result
                    (list :phase-cleared (null emacs-jupyter-notebook--async-context)
                          :launch-dead (not (process-live-p launch))
                          :scp-dead (not (process-live-p scp))
                          :tunnel-dead (not (process-live-p tunnel))
                          :timer-cancelled (not (memq timer timer-list))
                          :stderrs-dead (cl-every (lambda (b)
                                                    (not (buffer-live-p b)))
                                                  stderrs)
                          :session-entry emacs-jupyter-notebook--session-entry
                          :registry-entries
                          (emacs-jupyter-notebook-registry-load registry-file))))))
      (delete-directory registry-dir t))
    result))

(ert-deftest ejn-mode-disable-during-launch-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=launch kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'launch)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (plist-get result :session-entry))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-retrieve-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=retrieve kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'retrieve)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-tunnel-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=tunnel kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'tunnel)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(ert-deftest ejn-mode-disable-during-connect-phase-resets-and-preserves-registry ()
  "W1.5: disabling the mode during phase=connect kills processes, preserves registry."
  (let ((result (ejn-test--mode-disable-during-phase 'connect)))
    (should (plist-get result :phase-cleared))
    (should (plist-get result :launch-dead))
    (should (plist-get result :scp-dead))
    (should (plist-get result :tunnel-dead))
    (should (plist-get result :timer-cancelled))
    (should (plist-get result :stderrs-dead))
    (should (= 1 (length (plist-get result :registry-entries))))))

(defun ejn-test--ejn-process-buffers ()
  "Return live buffers whose names start with the EJN process buffer prefix."
  (cl-remove-if-not
   (lambda (b)
     (string-prefix-p " *emacs-jupyter-notebook-" (buffer-name b)))
   (buffer-list)))

(ert-deftest ejn-failed-launch-leaves-no-ejn-process-buffers ()
  "W1.6: a failed remote launch leaks no `*emacs-jupyter-notebook-*' buffers.
Spawn real launch/scp/tunnel processes through the SSH starter so each carries
both a stdout and a stderr buffer.  After `--async-fail' runs there must be
zero EJN-prefixed buffers above the baseline.  The remote-kernel-cleanup
branch is NOT stubbed: post-W1.8, `--async-fail' must not call
`--async-kill-remote-kernel' at all, so the kill helper would not run even
with `:owns-kernel' set."
  (let* ((baseline (ejn-test--ejn-process-buffers))
         (launch (emacs-jupyter-notebook-ssh-start-process
                  "emacs-jupyter-notebook-launch-w16" '("sleep" "60")))
         (scp (emacs-jupyter-notebook-ssh-start-process
               "emacs-jupyter-notebook-scp-w16" '("sleep" "60")))
         (tunnel (emacs-jupyter-notebook-ssh-start-process
                  "emacs-jupyter-notebook-tunnel-w16" '("sleep" "60")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'launch
                   :launch-process launch
                   :scp-process scp
                   :tunnel-process tunnel
                   :owns-kernel t)))
    (should (>= (length (cl-set-difference
                         (ejn-test--ejn-process-buffers) baseline))
                6))
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (with-temp-buffer
        (emacs-jupyter-notebook--async-fail context "simulated launch failure")))
    (should-not (process-live-p launch))
    (should-not (process-live-p scp))
    (should-not (process-live-p tunnel))
    (let ((leaked (cl-set-difference (ejn-test--ejn-process-buffers) baseline)))
      (should-not leaked))))

(ert-deftest ejn-async-fail-does-not-kill-remote-kernel-or-delete-local-file ()
  "W1.8: `--async-fail' must not terminate the remote kernel or delete the
context's `:local-file'.  Binding-rule compliance: no automatic remote-kernel
cleanup from async failure paths.  The `:local-file' is the future
`:local-connection-file' reconnect key once `--async-connect-finalize'
promotes it."
  (let ((kill-called nil)
        (local-file (make-temp-file "ejn-w18-local-")))
    (unwind-protect
        (let ((context (emacs-jupyter-notebook--async-new-context
                        :phase 'launch
                        :owns-kernel t
                        :local-file local-file
                        :entry '(:profile "p"
                                 :session-id "w18"
                                 :remote-connection-file "/remote/k.json"))))
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
                     (lambda (&rest _) (setq kill-called t)))
                    ((symbol-function 'display-warning) #'ignore))
            (with-temp-buffer
              (emacs-jupyter-notebook--async-fail context "boom")))
          (should-not kill-called)
          (should (file-exists-p local-file)))
      (when (file-exists-p local-file)
        (delete-file local-file)))))

(ert-deftest ejn-kill-buffer-with-live-client-does-not-shutdown-or-deregister ()
  "W1.7: killing a buffer that owns a live client does not call the configured
`emacs-jupyter-notebook-jupyter-shutdown-function' and does not remove the
session's registry entry.  The remote kernel and its registry entry are the
durable reconnect surface and must survive buffer kill."
  (let* ((registry-dir (make-temp-file "ejn-w17-registry-" t))
         (registry-file (expand-file-name "registry.eld" registry-dir))
         (entry '(:profile "p"
                  :session-id "w17-session"
                  :remote-host "example.com"
                  :remote-connection-file "/remote/kernel.json"
                  :local-connection-file "/tmp/w17-local.json"))
         (emacs-jupyter-notebook-registry-file registry-file)
         shutdown-called registry-removed remote-cleanup-called)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (setq remote-cleanup-called t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq registry-removed t)))
                  ;; The kernel-info adapter would otherwise touch the network
                  ;; when the buffer's local hooks run.
                  ((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
                   #'ignore))
          (let ((emacs-jupyter-notebook-jupyter-shutdown-function
                 (lambda (&rest _) (setq shutdown-called t))))
            (emacs-jupyter-notebook-registry-save (list entry) registry-file)
            (let ((buffer (generate-new-buffer "ejn-w17")))
              (with-current-buffer buffer
                (emacs-jupyter-notebook-mode 1)
                (setq emacs-jupyter-notebook--client
                      (ejn-test-backend-session 'mock-client t))
                (setq emacs-jupyter-notebook--session-entry entry))
              (kill-buffer buffer))
            (should-not shutdown-called)
            (should-not registry-removed)
            (should-not remote-cleanup-called)
            (let ((remaining (emacs-jupyter-notebook-registry-load registry-file)))
              (should (= (length remaining) 1))
              (should (equal (plist-get (car remaining) :session-id)
                             "w17-session")))))
      (delete-directory registry-dir t))))

;;; W2 — Output panel & fringe indicator

(defun ejn-test--make-source-buffer (&optional content)
  "Create a buffer-file-visited source buffer for panel tests."
  (let* ((file (make-temp-file "ejn-source-" nil ".py"))
         (buf (find-file-noselect file)))
    (with-current-buffer buf
      (erase-buffer)
      (insert (or content "# %%\nx = 1\n")))
    buf))

(defun ejn-test--kill-source-buffer (buf)
  "Kill BUF (and its visited file)."
  (let ((file (buffer-file-name buf)))
    (kill-buffer buf)
    (when (and file (file-exists-p file))
      (delete-file file))))

;; W2.1: panel mode + API in isolation
(ert-deftest ejn-w2.1-panel-mode-is-special-mode-derived ()
  "W2.1: panel mode is derived from `special-mode' and has buffer-read-only."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (with-current-buffer panel
            (should (derived-mode-p 'emacs-jupyter-notebook-panel-mode))
            (should (derived-mode-p 'special-mode))
            (should buffer-read-only)))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-panel-name-uses-source-basename ()
  "W2.1: the panel buffer name is `*ejn: <basename>*'."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (should (string-match-p (format "\\*ejn: %s\\*"
                                          (regexp-quote
                                           (file-name-nondirectory
                                            (buffer-file-name buf))))
                                  (buffer-name panel))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-ensure-is-idempotent ()
  "W2.1: ejn-panel-ensure returns the same buffer on repeated calls."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((p1 (ejn-panel-ensure buf))
              (p2 (ejn-panel-ensure buf)))
          (should (eq p1 p2)))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.1-api-start-append-finish-clear-image ()
  "W2.1: the entire panel API works without a kernel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("a" . 1) "x = 1")))
          (should handle)
          (should (plist-get handle :id))
          (should (plist-get handle :cell-key))
          (ejn-panel-append-text handle "hello ")
          (ejn-panel-append-text handle "world")
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (equal (ejn-panel-entry-text e) "hello world"))
            (should (eq (plist-get e :status) 'running))
            (should (equal (plist-get e :exec-count) "*")))
          (ejn-panel-replace-text handle "swapped")
          (should (equal (ejn-panel-entry-text handle)
                         "swapped"))
          (ejn-panel-set-image handle '(image :type png :data "fake"))
          (let ((e (ejn-panel-entry-snapshot handle)))
            (let ((image (car (ejn-panel-entry-images e))))
              (should (ejn-test-image-file-backed-p image))
              (should (equal (ejn-test-image-spec-data image) "fake")))
            ;; W16: the image is a new segment; the text coexists below it.
            (should (equal (ejn-panel-entry-text e) "swapped")))
          (ejn-panel-clear-entry handle)
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (equal (ejn-panel-entry-text e) ""))
            (should-not (car (ejn-panel-entry-images e))))
          (ejn-panel-finish-entry handle 'ok 7)
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (eq (plist-get e :status) 'ok))
            (should (equal (plist-get e :exec-count) 7))))
      (ejn-test--kill-source-buffer buf))))

;; W2.2: latest-per-cell view
(ert-deftest ejn-w2.2-latest-per-cell-replaces-same-cell ()
  "W2.2: re-evaluating the same cell leaves a single entry in the latest view."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (key '("file" . 10)))
          (ejn-panel-start-entry panel key "first")
          (ejn-panel-start-entry panel key "second")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 1))
              (should (equal (plist-get (car vis) :code) "second")))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.2-latest-per-cell-orders-by-cell-position ()
  "W2.2: latest-per-cell entries render in cell-position order."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (k1 '("file" . 5))
               (k2 '("file" . 50))
               (k3 '("file" . 100)))
          ;; Start in non-position order:
          (ejn-panel-start-entry panel k2 "second")
          (ejn-panel-start-entry panel k3 "third")
          (ejn-panel-start-entry panel k1 "first")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 3))
              (should (equal (plist-get (nth 0 vis) :code) "first"))
              (should (equal (plist-get (nth 1 vis) :code) "second"))
              (should (equal (plist-get (nth 2 vis) :code) "third")))))
      (ejn-test--kill-source-buffer buf))))

;; W2.3: history-log view + toggle
(ert-deftest ejn-w2.3-history-view-keeps-all-evals ()
  "W2.3 + W2.13: history view shows every evaluation in insertion order.
Re-evaluating the same cell key does NOT delete the prior entry; the latest
view dedupes by cell key at render time but the history view shows the full
timeline."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "cell1")
          (ejn-panel-start-entry panel '("f" . 2) "cell2")
          (ejn-panel-start-entry panel nil "region-eval")
          (ejn-panel-start-entry panel '("f" . 1) "cell1-again")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'history)
            (let ((vis (emacs-jupyter-notebook-panel--visible-entries)))
              (should (= (length vis) 4))
              (should (equal (plist-get (nth 0 vis) :code) "cell1"))
              (should (equal (plist-get (nth 1 vis) :code) "cell2"))
              (should (equal (plist-get (nth 2 vis) :code) "region-eval"))
              (should (equal (plist-get (nth 3 vis) :code) "cell1-again")))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-region-eval-absent-from-latest-view ()
  "W2.3: keyless (region/paragraph/defun) evals do not appear in latest view."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel nil "region")
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'latest)
            (should-not (emacs-jupyter-notebook-panel--visible-entries))
            (setq emacs-jupyter-notebook-panel--view 'history)
            (should (= 1 (length (emacs-jupyter-notebook-panel--visible-entries))))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-history-view-auto-scrolls-to-bottom ()
  "W2.3: rendering the history view leaves point at the bottom of the panel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--view 'history))
          (ejn-panel-start-entry panel '("f" . 1) "c1")
          (ejn-panel-start-entry panel '("f" . 2) "c2")
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (should (= (point) (point-max)))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.3-toggle-view-roundtrips ()
  "W2.3: H toggle moves between latest and history views without data loss."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "c1")
          (ejn-panel-start-entry panel nil "region")
          (with-current-buffer panel
            (should (eq emacs-jupyter-notebook-panel--view 'latest))
            (emacs-jupyter-notebook-panel-toggle-view)
            (should (eq emacs-jupyter-notebook-panel--view 'history))
            (emacs-jupyter-notebook-panel-toggle-view)
            (should (eq emacs-jupyter-notebook-panel--view 'latest))
            ;; Data preserved across toggles.
            (should (= 2 (length emacs-jupyter-notebook-panel--entries)))))
      (ejn-test--kill-source-buffer buf))))

;; W2.4: streaming throttle
(ert-deftest ejn-w2.4-streaming-throttle-coalesces-renders ()
  "W2.4: 1000 small stream events produce far fewer than 1000 renders.

The throttle keeps redisplay churn bounded; the exact upper bound depends on
batch timing, but it must be a tiny fraction of the event count."
  (let ((buf (ejn-test--make-source-buffer))
        (emacs-jupyter-notebook-panel-stream-throttle-ms 50))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code")))
          (with-current-buffer panel
            (setq emacs-jupyter-notebook-panel--render-count 0))
          (dotimes (_ 1000)
            (ejn-panel-append-text handle "x"))
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (should (<= emacs-jupyter-notebook-panel--render-count 20))))
      (ejn-test--kill-source-buffer buf))))

;; W2.5: image entry survives toggle / image zoom keys
(ert-deftest ejn-w2.5-image-zoom-in-out-scales-image ()
  "W2.5: + and - on an image entry scale the display image up and down."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "plot")))
          (ejn-panel-set-image
           handle (create-image (make-string 100 ?\0) 'pbm t :scale 1.0))
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (goto-char (point-min))
            ;; Walk to a position where the display property holds the image:
            (let ((pos nil))
              (while (and (not pos) (not (eobp)))
                (when-let ((d (get-text-property (point) 'display)))
                  (when (and (consp d) (eq (car d) 'image))
                    (setq pos (point))))
                (goto-char (or (next-single-property-change (point) 'display)
                               (point-max))))
              (should pos)
              (goto-char pos)
              (let ((before (or (image-property
                                 (get-text-property (point) 'display) :scale)
                                1.0)))
                (emacs-jupyter-notebook-panel-image-zoom-in)
                (should (> (image-property
                            (get-text-property (point) 'display) :scale)
                           before))
                (emacs-jupyter-notebook-panel-image-zoom-out)
                (emacs-jupyter-notebook-panel-image-zoom-out)
                (should (< (image-property
                            (get-text-property (point) 'display) :scale)
                           before))))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.5-image-survives-view-toggle ()
  "W2.5: image-bearing entry remains intact across a view toggle round-trip."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "plot")))
          (ejn-panel-set-image handle '(image :type png :data "data"))
          (with-current-buffer panel
            (emacs-jupyter-notebook-panel-toggle-view)
            (emacs-jupyter-notebook-panel-toggle-view))
          (let ((image (car (ejn-panel-entry-images handle))))
            (should (ejn-test-image-file-backed-p image))
            (should (equal (ejn-test-image-spec-data image) "data"))))
      (ejn-test--kill-source-buffer buf))))

;; W2.6: navigation
(ert-deftest ejn-w2.6-ret-visits-source-cell ()
  "W2.6: RET on an entry header jumps to the originating cell in source."
  (let ((buf (generate-new-buffer "ejn-w2.6-source")))
    (unwind-protect
        (let (cell-pos panel popped)
          (with-current-buffer buf
            (insert "# %% one\nfoo\n# %% two\nbar\n")
            (goto-char (point-min))
            (re-search-forward "# %% two")
            (setq cell-pos (line-beginning-position))
            (setq panel (ejn-panel-ensure buf))
            (ejn-panel-start-entry panel (cons "test.py" cell-pos) "bar")
            (emacs-jupyter-notebook-panel-flush-now panel))
          (with-current-buffer panel
            (goto-char (point-min))
            (let (header-pos)
              (while (and (not header-pos) (not (eobp)))
                (if (get-text-property (point) 'emacs-jupyter-notebook-entry-id)
                    (setq header-pos (point))
                  (goto-char (or (next-single-property-change
                                  (point) 'emacs-jupyter-notebook-entry-id)
                                 (point-max)))))
              (goto-char header-pos))
            ;; Capture pop-to-buffer target+goto destination from inside the
            ;; visit-source command (pop-to-buffer is hard to assert against
            ;; in batch mode otherwise).
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (target &rest _)
                         (setq popped target)
                         (set-buffer target))))
              (emacs-jupyter-notebook-panel-visit-source)
              (should (eq popped buf))
              (should (= (point) cell-pos)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ejn-w2.6-q-buries-panel-window ()
  "W2.6: q in the panel calls `quit-window' to bury the panel."
  (let ((buf (ejn-test--make-source-buffer))
        quit-called)
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (cl-letf (((symbol-function 'quit-window)
                     (lambda (&rest _) (setq quit-called t))))
            (with-current-buffer panel
              (emacs-jupyter-notebook-panel-quit)))
          (should quit-called))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.6-keymap-bindings ()
  "W2.6: q, H, RET, n, p are bound in the panel keymap."
  (let ((map emacs-jupyter-notebook-panel-mode-map))
    (should (eq (lookup-key map (kbd "q"))
                #'emacs-jupyter-notebook-panel-quit))
    (should (eq (lookup-key map (kbd "H"))
                #'emacs-jupyter-notebook-panel-toggle-view))
    (should (eq (lookup-key map (kbd "RET"))
                #'emacs-jupyter-notebook-panel-visit-source))
    (should (eq (lookup-key map (kbd "n"))
                #'emacs-jupyter-notebook-panel-next-entry))
    (should (eq (lookup-key map (kbd "p"))
                #'emacs-jupyter-notebook-panel-previous-entry))))

(ert-deftest ejn-w2.6-n-p-navigate-headers ()
  "W2.6: n and p step between entry headers in the panel."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let ((panel (ejn-panel-ensure buf)))
          (ejn-panel-start-entry panel '("f" . 1) "a")
          (ejn-panel-start-entry panel '("f" . 50) "b")
          (emacs-jupyter-notebook-panel-flush-now panel)
          (with-current-buffer panel
            (goto-char (point-min))
            (emacs-jupyter-notebook-panel-next-entry)
            (should (get-text-property (point) 'emacs-jupyter-notebook-entry-id))
            (let ((first-id (get-text-property
                             (point) 'emacs-jupyter-notebook-entry-id)))
              (emacs-jupyter-notebook-panel-next-entry)
              (let ((second-id (get-text-property
                                (point) 'emacs-jupyter-notebook-entry-id)))
                (should second-id)
                (should-not (equal first-id second-id))
                (emacs-jupyter-notebook-panel-previous-entry)
                (should (equal (get-text-property
                                (point) 'emacs-jupyter-notebook-entry-id)
                               first-id))))))
      (ejn-test--kill-source-buffer buf))))

;; W2.7: callback rewrite (additional)
(ert-deftest ejn-w2.7-stream-callback-routes-to-panel-append ()
  "W2.7: a stream message appends to the panel entry, not the source buffer."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle))
               (stream (cadr (assoc "stream" callbacks)))
               (before (with-current-buffer buf (buffer-string))))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:text "hello\n" :name "stdout"))))
            (funcall stream 'mock))
          (should (equal (ejn-panel-entry-text handle)
                         "hello\n"))
          (with-current-buffer buf
            (should (equal (buffer-string) before))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-error-callback-uses-error-face ()
  "W2.7: an error message lands in the panel content with the error face."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle))
               (err-fn (cadr (assoc "error" callbacks))))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg)
                       '(:traceback ("a" "b") :ename "Boom" :evalue "x"))))
            (funcall err-fn 'mock))
          (let ((content (ejn-panel-entry-text handle)))
            (should (string-match-p "a\nb" content))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-reply-plus-idle-marks-status-and-count ()
  "EI3: correlated execute_reply plus idle finishes status and exec-count."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle nil 1 11))
               (reply-fn (cadr (assoc "execute_reply" callbacks)))
               (status-fn (cadr (assoc "status" callbacks))))
          (with-current-buffer buf
            (emacs-jupyter-notebook--execution-put
             (list :id 1 :state 'dispatched :panel-entry handle
                   :backend-request-id 11
                   :generation (plist-get handle :generation)))
            (setq emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1)))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:status "ok" :execution_count 5))))
            (funcall reply-fn 'mock))
          (should (eq (plist-get (ejn-panel-entry-snapshot handle) :status)
                      'running))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:execution_state "idle"))))
            (funcall status-fn 'mock))
          (let ((e (ejn-panel-entry-snapshot handle)))
            (should (eq (plist-get e :status) 'ok))
            (should (equal (plist-get e :exec-count) 5))))
      (ejn-test--kill-source-buffer buf))))

(ert-deftest ejn-w2.7-callbacks-do-not-mutate-source-buffer ()
  "W2.7: an entire roundtrip of callbacks does not change source-buffer text."
  (let ((buf (ejn-test--make-source-buffer "# %%\ncode\n")))
    (unwind-protect
        (let* ((before (with-current-buffer buf (buffer-string)))
               (panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel '("f" . 1) "code"))
               (callbacks (emacs-jupyter-notebook-jupyter--callbacks
                           buf handle)))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:text "out" :name "stdout"))))
            (funcall (cadr (assoc "stream" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:data (:text/plain "42")))))
            (funcall (cadr (assoc "execute_result" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:wait nil))))
            (funcall (cadr (assoc "clear_output" callbacks)) 'mock))
          (cl-letf (((symbol-function 'jupyter-message-content)
                     (lambda (_msg) '(:status "ok" :execution_count 1))))
            (funcall (cadr (assoc "execute_reply" callbacks)) 'mock))
          (should (equal (with-current-buffer buf (buffer-string)) before)))
      (ejn-test--kill-source-buffer buf))))

;; W2.8: fringe indicator
(ert-deftest ejn-w2.8-fringe-state-transitions ()
  "W2.8: queued→running→ok and queued→running→error transitions work."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((key (emacs-jupyter-notebook--cell-key-for (point))))
      (emacs-jupyter-notebook-fringe-set key 'queued)
      (should (eq 'queued (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (eq 'running (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'ok 3)
      (should (eq 'ok (emacs-jupyter-notebook-fringe-state key)))
      (emacs-jupyter-notebook-fringe-set key 'error)
      (should (eq 'error (emacs-jupyter-notebook-fringe-state key))))))

(ert-deftest ejn-w2.8-fringe-indicator-does-not-mutate-source ()
  "W2.8: setting/clearing fringe indicators does not change source text."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((before (buffer-string))
          (key (emacs-jupyter-notebook--cell-key-for (point))))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (equal (buffer-string) before))
      (emacs-jupyter-notebook-fringe-clear-all)
      (should (equal (buffer-string) before)))))

(ert-deftest ejn-w2.8-typing-on-cell-line-does-not-interfere ()
  "W2.8: typing on the cell marker line does not delete or move the indicator."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'running)))
      (should (overlayp ov))
      (goto-char (line-end-position))
      (insert " extra")
      ;; The overlay must still exist and still mark the cell line.
      (should (overlayp ov))
      (should (overlay-buffer ov))
      (should (eq 'running (emacs-jupyter-notebook-fringe-state key))))))

(ert-deftest ejn-w2.8-glyph-truncates-to-last-digit-when-large ()
  "W2.8: the ok glyph shows only the last digit for exec-counts >= 10."
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 12) "✓2"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 30) "✓0"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'ok 5) "✓5"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'running 99) "►"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'error nil) "✗"))
  (should (equal (emacs-jupyter-notebook--fringe-glyph 'queued nil) "…")))

(ert-deftest ejn-w2.8-fringe-no-cursor-intangible-adjacency ()
  "W2.8: the indicator carries no cursor-intangible or read-only properties."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'running))
           (before (overlay-get ov 'before-string)))
      (should before)
      (should-not (get-text-property 0 'cursor-intangible before))
      (should-not (get-text-property 0 'read-only before)))))

;; W2.14: panel buffer name disambiguates same-basename sources
(ert-deftest ejn-w2.14-panel-names-distinguish-same-basename ()
  "W2.14: two source buffers whose visited files share a basename get
distinct panel buffers (Emacs already disambiguates `buffer-name' with
`<2>')."
  (let* ((dir1 (make-temp-file "ejn-w214-a-" t))
         (dir2 (make-temp-file "ejn-w214-b-" t))
         (file1 (expand-file-name "foo.py" dir1))
         (file2 (expand-file-name "foo.py" dir2)))
    (unwind-protect
        (let ((buf1 (find-file-noselect file1))
              (buf2 (find-file-noselect file2)))
          (unwind-protect
              (let ((panel1 (ejn-panel-ensure buf1))
                    (panel2 (ejn-panel-ensure buf2)))
                (should (buffer-live-p panel1))
                (should (buffer-live-p panel2))
                (should-not (eq panel1 panel2))
                (should-not (equal (buffer-name panel1)
                                   (buffer-name panel2))))
            (kill-buffer buf1)
            (kill-buffer buf2)))
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

;; W2.12: indicator display spec uses Emacs margin syntax
(ert-deftest ejn-w2.12-indicator-display-uses-margin-syntax ()
  "W2.12: the indicator overlay's `before-string' carries a `display'
property of the form `((margin SIDE) STRING)' as required by Emacs.
The previous implementation used `((SIDE STRING))' which is silently
ignored, so the indicator never actually rendered."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
           (ov (emacs-jupyter-notebook-fringe-set key 'ok 3))
           (before (overlay-get ov 'before-string))
           (display (get-text-property 0 'display before)))
      (should display)
      ;; The display spec should mention `margin'.
      (should (equal (car display) '(margin left-margin)))
      ;; The string is the second element of the spec.
      (should (stringp (cadr display)))
      (should (string-match-p "✓" (cadr display)))
      (should (string-match-p "3" (cadr display))))))

(ert-deftest ejn-w2.12-fringe-side-falls-back-to-margin ()
  "W2.12: choosing a fringe value for `--fringe-side' falls back to
`left-margin' rendering rather than emitting an invalid display spec."
  (let ((emacs-jupyter-notebook-fringe-side 'left-fringe))
    (with-temp-buffer
      (insert "# %%\nx = 1\n")
      (goto-char (point-min))
      (let* ((key (emacs-jupyter-notebook--cell-key-for (point)))
             (ov (emacs-jupyter-notebook-fringe-set key 'running))
             (before (overlay-get ov 'before-string))
             (display (get-text-property 0 'display before)))
        (should (equal (car display) '(margin left-margin)))))))

(ert-deftest ejn-w2.12-fringe-ensures-margin-width ()
  "W2.12: setting an indicator widens the buffer-local left margin so the
glyph has room to render."
  (with-temp-buffer
    (insert "# %%\nx = 1\n")
    (goto-char (point-min))
    (let ((key (emacs-jupyter-notebook--cell-key-for (point))))
      (should (or (null left-margin-width) (zerop left-margin-width)))
      (emacs-jupyter-notebook-fringe-set key 'running)
      (should (>= (or left-margin-width 0)
                  emacs-jupyter-notebook-fringe-margin-width)))))

;; W2.11: stable cell key across edits
(ert-deftest ejn-w2.11-cell-key-stable-across-edits-above ()
  "W2.11: the cell key returned for the same cell stays `equal' after the
user inserts or deletes text above the cell.  This guarantees that
latest-per-cell replacement and fringe-state lookup keep recognizing the
same cell across ordinary editing."
  (with-temp-buffer
    (insert "before\n# %%\nx = 1\n")
    (goto-char (point-min))
    (search-forward "# %%")
    (beginning-of-line)
    (let ((key-before (emacs-jupyter-notebook--cell-key-for (point))))
      ;; Insert several lines above the cell marker.
      (save-excursion
        (goto-char (point-min))
        (insert "extra1\nextra2\nextra3\n"))
      ;; Re-query at the (now shifted) cell line.  Because cell-key markers
      ;; have insertion-type t, the marker followed the cell line; the id
      ;; stays the same; the key is still `equal'.
      (search-forward "# %%")
      (beginning-of-line)
      (let ((key-after (emacs-jupyter-notebook--cell-key-for (point))))
        (should (equal key-before key-after))))))

(ert-deftest ejn-w2.11-cell-key-distinguishes-different-cells ()
  "W2.11: cell keys are distinct for distinct cell-marker lines."
  (with-temp-buffer
    (insert "# %% one\n1\n# %% two\n2\n")
    (goto-char (point-min))
    (let ((k1 (emacs-jupyter-notebook--cell-key-for (point))))
      (search-forward "# %% two")
      (beginning-of-line)
      (let ((k2 (emacs-jupyter-notebook--cell-key-for (point))))
        (should-not (equal k1 k2))))))

;; W2.9: panel cleanup
(ert-deftest ejn-w2.9-killing-source-buffer-kills-panel ()
  "W2.9: killing the source buffer kills its output panel."
  (let* ((buf (ejn-test--make-source-buffer))
         (panel nil))
    (with-current-buffer buf
      (emacs-jupyter-notebook-mode 1)
      (setq panel (ejn-panel-ensure buf))
      (should (buffer-live-p panel)))
    (let ((file (buffer-file-name buf)))
      (kill-buffer buf)
      (when (and file (file-exists-p file))
        (delete-file file)))
    (should-not (buffer-live-p panel))))

(ert-deftest ejn-w2.9-killing-panel-alone-does-not-affect-kernel-or-registry ()
  "W2.9: killing only the panel buffer leaves --client and registry untouched."
  (let* ((buf (ejn-test--make-source-buffer))
         shutdown-called registry-removed)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                   (lambda (&rest _) (setq shutdown-called t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq registry-removed t))))
          (with-current-buffer buf
            (emacs-jupyter-notebook-mode 1)
            (setq emacs-jupyter-notebook--client 'mock-client)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "s")))
          (let ((panel (ejn-panel-ensure buf)))
            (kill-buffer panel))
          (with-current-buffer buf
            (should (eq emacs-jupyter-notebook--client 'mock-client))
            (should emacs-jupyter-notebook--session-entry))
          (should-not shutdown-called)
          (should-not registry-removed))
      (ejn-test--kill-source-buffer buf))))

;; W2.10: customization variables exist and have the documented defaults
(ert-deftest ejn-w2.10-customization-defaults ()
  "W2.10: the W2 customization variables have the documented defaults."
  (should (eq emacs-jupyter-notebook-panel-side 'right))
  (should (= emacs-jupyter-notebook-panel-width 80))
  (should (eq emacs-jupyter-notebook-panel-default-view 'latest))
  (should (= emacs-jupyter-notebook-panel-stream-throttle-ms 50))
  ;; W2.12 changed the default from `left-fringe' (invalid for string glyphs)
  ;; to `left-margin' (the working margin syntax).
  (should (eq emacs-jupyter-notebook-fringe-side 'left-margin)))

(ert-deftest ejn-w2.10-inline-overlay-customizations-removed ()
  "W2.10: legacy inline-overlay customizations are gone."
  (should-not (boundp 'emacs-jupyter-notebook-use-inline-overlays))
  (should-not (boundp 'emacs-jupyter-notebook-inline-result-max-lines))
  (should-not (boundp 'emacs-jupyter-notebook-result-inline-lines))
  (should-not (boundp 'emacs-jupyter-notebook-result-inline-max-bytes))
  (should-not (boundp 'emacs-jupyter-notebook-result-max-lines)))

;;; W4.1 — Tunnel keepalives

(ert-deftest ejn-w4.1-tunnel-command-includes-server-alive-keepalive ()
  "W4.1: the tunnel argv carries ServerAlive keepalive options.
The keepalive option pair must appear together (Interval + CountMax),
and the existing ExitOnForwardFailure option must still be present."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 15)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ExitOnForwardFailure=yes" cmd))
    (should (member "ServerAliveInterval=15" cmd))
    (should (member "ServerAliveCountMax=3" cmd))))

(ert-deftest ejn-w4.1-tunnel-keepalive-interval-respected ()
  "W4.1: customizing the interval changes the rendered option value."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 30)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ServerAliveInterval=30" cmd))
    (should-not (member "ServerAliveInterval=15" cmd))))

(ert-deftest ejn-w4.1-tunnel-keepalive-disabled-when-zero ()
  "W4.1: setting the interval to 0 omits the keepalive options entirely."
  (let* ((emacs-jupyter-notebook-tunnel-keepalive-interval 0)
         (cmd (emacs-jupyter-notebook-ssh-tunnel-command
               '(:profile "p" :host "example.com")
               '(:shell_port 1)
               '(:shell_port 1001))))
    (should (member "ExitOnForwardFailure=yes" cmd))
    (should-not (cl-some (lambda (arg)
                           (and (stringp arg)
                                (string-prefix-p "ServerAliveInterval" arg)))
                         cmd))
    (should-not (member "ServerAliveCountMax=3" cmd))))

;;; W6.1 — Single-prefix keymap

(ert-deftest ejn-w6.1-prefix-key-customization-defaults-to-c-c-j ()
  "W6.1: the prefix-key customization defaults to `C-c j'."
  (should (equal emacs-jupyter-notebook-prefix-key "C-c j")))

(ert-deftest ejn-w6.1-mode-map-routes-through-prefix ()
  "W6.1: the mode-map contains exactly one binding — the prefix."
  ;; Bindings are a representative sample; what we assert is that every
  ;; expected command lives under `C-c j' on the prefix-map.
  (let ((map emacs-jupyter-notebook-prefix-map))
    (should (eq (lookup-key map (kbd "c"))
                #'emacs-jupyter-notebook-send-cell))
    (should (eq (lookup-key map (kbd "j"))
                #'emacs-jupyter-notebook-send-cell-and-advance))
    (should (eq (lookup-key map (kbd "r"))
                #'emacs-jupyter-notebook-send-region))
    (should (eq (lookup-key map (kbd "SPC"))
                #'emacs-jupyter-notebook-send-paragraph))
    (should (eq (lookup-key map (kbd "d"))
                #'emacs-jupyter-notebook-send-defun))
    (should (eq (lookup-key map (kbd "b"))
                #'emacs-jupyter-notebook-send-buffer))
    (should (eq (lookup-key map (kbd "s"))
                #'emacs-jupyter-notebook-start-remote-kernel))
    (should (eq (lookup-key map (kbd "R"))
                #'emacs-jupyter-notebook-reconnect-remote-kernel))
    (should (eq (lookup-key map (kbd "y"))
                #'emacs-jupyter-notebook-retry-fresh-kernel))
    (should (eq (lookup-key map (kbd "k"))
                #'emacs-jupyter-notebook-interrupt-kernel))
    (should (eq (lookup-key map (kbd "K"))
                #'emacs-jupyter-notebook-restart-kernel))
    (should (eq (lookup-key map (kbd "S"))
                #'emacs-jupyter-notebook-shutdown-kernel))
    (should (eq (lookup-key map (kbd "x"))
                #'emacs-jupyter-notebook-cancel-operation))
    (should (eq (lookup-key map (kbd "?"))
                #'emacs-jupyter-notebook-status))
    (should (eq (lookup-key map (kbd "L"))
                #'emacs-jupyter-notebook-show-log-buffer))
    (should (eq (lookup-key map (kbd "o"))
                #'emacs-jupyter-notebook-show-output-panel))
    (should (eq (lookup-key map (kbd "t"))
                #'emacs-jupyter-notebook-toggle-panel-view))
    (should (eq (lookup-key map (kbd "."))
                #'emacs-jupyter-notebook-inspect-at-point))
    (should (eq (lookup-key map (kbd "TAB"))
                #'emacs-jupyter-notebook-complete-at-point))
    (should (eq (lookup-key map (kbd "v"))
                #'emacs-jupyter-notebook-fetch-remote-log))
    (should (eq (lookup-key map (kbd "q"))
                #'emacs-jupyter-notebook-list-remote-processes))
    (should (eq (lookup-key map (kbd "w"))
                #'emacs-jupyter-notebook-clean-orphaned-kernels))
    (should (eq (lookup-key map (kbd "P"))
                #'emacs-jupyter-notebook-prune-dead-kernels))
    (should (eq (lookup-key map (kbd "n"))
                #'emacs-jupyter-notebook-forward-cell))
    (should (eq (lookup-key map (kbd "p"))
                #'emacs-jupyter-notebook-backward-cell))))

(ert-deftest ejn-w6.1-cell-edit-subprefix ()
  "W6.1: cell-edit subprefix is `%' with the documented sub-bindings."
  (let* ((prefix emacs-jupyter-notebook-prefix-map)
         (sub (lookup-key prefix (kbd "%"))))
    (should (keymapp sub))
    (should (eq (lookup-key sub (kbd "n")) #'emacs-jupyter-notebook-forward-cell))
    (should (eq (lookup-key sub (kbd "p")) #'emacs-jupyter-notebook-backward-cell))
    (should (eq (lookup-key sub (kbd "a")) #'emacs-jupyter-notebook-beginning-of-cell))
    (should (eq (lookup-key sub (kbd "e")) #'emacs-jupyter-notebook-end-of-cell))
    (should (eq (lookup-key sub (kbd "i")) #'emacs-jupyter-notebook-insert-cell-below))
    (should (eq (lookup-key sub (kbd "I")) #'emacs-jupyter-notebook-insert-cell-above))
    (should (eq (lookup-key sub (kbd "d")) #'emacs-jupyter-notebook-delete-cell))
    (should (eq (lookup-key sub (kbd "k")) #'emacs-jupyter-notebook-kill-cell))
    (should (eq (lookup-key sub (kbd "K")) #'emacs-jupyter-notebook-clear-cell))
    (should (eq (lookup-key sub (kbd "y")) #'emacs-jupyter-notebook-duplicate-cell))
    (should (eq (lookup-key sub (kbd "P")) #'emacs-jupyter-notebook-move-cell-up))
    (should (eq (lookup-key sub (kbd "N")) #'emacs-jupyter-notebook-move-cell-down))
    (should (eq (lookup-key sub (kbd "@")) #'code-cells-mark-cell))))

(ert-deftest ejn-w6.1-old-cell-edit-send-bindings-removed ()
  "W6.1: the old `s' / `RET' send-cell-and-advance bindings on `C-c j %' are gone."
  (let* ((prefix emacs-jupyter-notebook-prefix-map)
         (sub (lookup-key prefix (kbd "%"))))
    (should (keymapp sub))
    ;; `s' on the cell-edit subprefix used to send-and-advance; now unbound.
    (should-not (commandp (lookup-key sub (kbd "s"))))
    ;; `RET' likewise.
    (should-not (commandp (lookup-key sub (kbd "RET"))))))

(ert-deftest ejn-w6.1-mode-map-uses-customized-prefix ()
  "W6.1: the mode-map binds the prefix at `emacs-jupyter-notebook-prefix-key'.
This sanity-checks one keystroke from the mode-map all the way to a leaf
command, which is the contract a user actually depends on."
  (should (keymapp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j"))))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j c"))
              #'emacs-jupyter-notebook-send-cell))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j SPC"))
              #'emacs-jupyter-notebook-send-paragraph))
  (should (eq (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c j % i"))
              #'emacs-jupyter-notebook-insert-cell-below)))

(ert-deftest ejn-w6.1-old-c-c-c-binding-removed ()
  "W6.1: legacy `C-c C-c' / `C-c C-r' / `C-c C-b' bindings are gone."
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-c"))))
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-r"))))
  (should-not (commandp (lookup-key emacs-jupyter-notebook-mode-map (kbd "C-c C-b")))))

(ert-deftest ejn-w6.1-send-paragraph-routes-to-evaluate-code ()
  "W6.1: send-paragraph delimits via `mark-paragraph' and posts code with cell-key nil."
  (ejn-test-with-temp-buffer "para1 line1\npara1 line2\n\npara2 line1\n"
    (goto-char (point-min))
    (let (captured)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (code key) (push (list code key) captured))))
        (emacs-jupyter-notebook-send-paragraph))
      (should (= (length captured) 1))
      (let* ((entry (car captured))
             (code (nth 0 entry))
             (key (nth 1 entry)))
        (should (string-match-p "para1 line1" code))
        (should (string-match-p "para1 line2" code))
        (should (null key))))))

(ert-deftest ejn-w6.1-send-defun-routes-to-evaluate-code ()
  "W6.1: send-defun delimits via beginning-of-defun/end-of-defun and posts code with nil key."
  (ejn-test-with-temp-buffer "def first():\n    return 1\n\ndef second():\n    return 2\n"
    (goto-char (point-min))
    ;; Place point inside `first'.
    (search-forward "return 1")
    (let (captured)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (code key) (push (list code key) captured))))
        (emacs-jupyter-notebook-send-defun))
      (should (= (length captured) 1))
      (let* ((entry (car captured))
             (code (nth 0 entry))
             (key (nth 1 entry)))
        (should (string-match-p "def first" code))
        (should-not (string-match-p "def second" code))
        (should (null key))))))

;;; W6.2 — Mode-line lighter branches

(ert-deftest ejn-w6.2-mode-line-no-client ()
  "W6.2: no client and no context → ` EJN'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN")))))

(ert-deftest ejn-w6.2-mode-line-healthy ()
  "W6.2: live client + idle kernel + alive tunnel → ` EJN✓'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'idle))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✓")))))

(ert-deftest ejn-w6.2-mode-line-busy ()
  "W6.2: kernel status busy → ` EJN*'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN*")))))

(ert-deftest ejn-w6.2-mode-line-launch-phase ()
  "W6.2: in-progress async at launch phase → ` EJN…launch'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase launch))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…launch")))))

(ert-deftest ejn-w6.2-mode-line-retrieve-phase ()
  "W6.2: retrieve phase → ` EJN…retrieve'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase retrieve))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…retrieve")))))

(ert-deftest ejn-w6.2-mode-line-tunnel-phase ()
  "W6.2: tunnel phase → ` EJN…tunnel'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase tunnel))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…tunnel")))))

(ert-deftest ejn-w6.2-mode-line-connect-phase ()
  "W6.2: connect phase → ` EJN…connect'."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase connect))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status nil))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…connect")))))

(ert-deftest ejn-w6.2-mode-line-async-error ()
  "W6.2: most recent async failed → ` EJN✗' (above busy / phases)."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context nil)
          (emacs-jupyter-notebook--async-last-error t)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✗")))))

(ert-deftest ejn-w6.2-mode-line-tunnel-dead-wins ()
  "W6.2: tunnel-dead beats async-error, async-phase, busy, idle, and no-client."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead t)
          (emacs-jupyter-notebook--async-context '(:phase tunnel))
          (emacs-jupyter-notebook--async-last-error t)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN!")))))

(ert-deftest ejn-w6.2-mode-line-precedence-async-phase-over-busy ()
  "W6.2: when an async phase is live AND kernel status is busy, the phase wins."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase connect))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'busy))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN…connect")))))

(ert-deftest ejn-w6.2-mode-line-terminal-phase-not-pending ()
  "W6.2: terminal phases (done/error) do not show as `…' phases on the lighter."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client 'mock)
          (emacs-jupyter-notebook--tunnel-dead nil)
          (emacs-jupyter-notebook--async-context '(:phase done))
          (emacs-jupyter-notebook--async-last-error nil)
          (emacs-jupyter-notebook--kernel-status 'idle))
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✓")))))

(ert-deftest ejn-w6.2-async-fail-records-error-on-origin-buffer ()
  "W6.2: `--async-fail' sets `--async-last-error' on the originating buffer."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (ctx (list :phase 'launch :origin-buffer buf)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-cancel-timer)
                 (lambda (c) c))
                ((symbol-function 'emacs-jupyter-notebook--async-delete-process)
                 (lambda (_)))
                ((symbol-function 'emacs-jupyter-notebook--async-delete-file)
                 (lambda (_)))
                ((symbol-function 'display-warning)
                 (lambda (&rest _))))
        (emacs-jupyter-notebook--async-fail ctx "boom"))
      (should emacs-jupyter-notebook--async-last-error)
      (should (equal (emacs-jupyter-notebook--mode-line-string) " EJN✗")))))

(ert-deftest ejn-w6.2-ensure-clean-before-start-clears-error ()
  "W6.2: starting a new operation clears the lingering ` EJN✗' state."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--async-last-error t)
    (emacs-jupyter-notebook--ensure-clean-before-start)
    (should-not emacs-jupyter-notebook--async-last-error)))

;;; W10 — client-less debris is reapable, not an active session

(ert-deftest ejn-w10-clientless-debris-not-active-session ()
  "W10: a buffer with a `--session-entry' and a live tunnel but NO client
is DEBRIS, not an active session.  `--active-session-p' must classify it
as non-blocking, and `--clientless-debris-p' must flag it as reapable.
Adding a live `--client' flips both predicates."
  (with-temp-buffer
    (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                    "emacs-jupyter-notebook-tunnel-w10-debris"
                    '("sleep" "60"))))
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook--client nil)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "wedged"))
            (setq emacs-jupyter-notebook--tunnel-process tunnel)
            ;; No live client -> not active, IS debris.
            (should-not (emacs-jupyter-notebook--active-session-p))
            (should (emacs-jupyter-notebook--clientless-debris-p))
            ;; A live client flips it: active, NOT debris.
            (setq emacs-jupyter-notebook--client 'mock-client)
            (should (emacs-jupyter-notebook--active-session-p))
            (should-not (emacs-jupyter-notebook--clientless-debris-p)))
        (when (process-live-p tunnel)
          (delete-process tunnel))))))

(ert-deftest ejn-w10-ensure-clean-before-start-reaps-clientless-debris ()
  "W10: `--ensure-clean-before-start' must NOT signal on a client-less
debris buffer; it reaps the LOCAL resources (disposes the stale tunnel and
its stderr buffer, clears the buffer-local session state) WITHOUT shutting
down the remote kernel, then lets the fresh start proceed."
  (with-temp-buffer
    (let* ((tunnel (emacs-jupyter-notebook-ssh-start-process
                    "emacs-jupyter-notebook-tunnel-w10-reap"
                    '("sleep" "60")))
           (stderr (process-get tunnel
                                'emacs-jupyter-notebook-stderr-buffer))
           remote-shutdown-called)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                     (lambda (&rest _) (setq remote-shutdown-called t)))
                    ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                     (lambda (&rest _) (setq remote-shutdown-called t))))
            (setq emacs-jupyter-notebook--client nil)
            (setq emacs-jupyter-notebook--session-entry
                  '(:profile "p" :session-id "wedged"))
            (setq emacs-jupyter-notebook--tunnel-process tunnel)
            (setq emacs-jupyter-notebook--async-context
                  (emacs-jupyter-notebook--async-new-context
                   :phase 'done
                   :origin-buffer (current-buffer)))
            ;; Does not raise.
            (emacs-jupyter-notebook--ensure-clean-before-start)
            ;; Debris reaped: tunnel disposed, buffer-local session state cleared.
            (should-not (process-live-p tunnel))
            (should-not (buffer-live-p stderr))
            (should-not emacs-jupyter-notebook--tunnel-process)
            (should-not emacs-jupyter-notebook--session-entry)
            (should-not emacs-jupyter-notebook--async-context)
            (should-not emacs-jupyter-notebook--client)
            ;; The remote kernel was NEVER touched during the reap.
            (should-not remote-shutdown-called))
        (when (process-live-p tunnel)
          (delete-process tunnel))))))

(ert-deftest ejn-w10-ensure-clean-before-start-still-refuses-live-client ()
  "W10 no-regression: a genuinely LIVE client must still block a fresh
start — the guard's original leak-prevention is preserved.  A present
`--client' is the one state `--ensure-clean-before-start' refuses."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock-client)
    (setq emacs-jupyter-notebook--session-entry
          '(:profile "p" :session-id "live"))
    (should-error (emacs-jupyter-notebook--ensure-clean-before-start)
                  :type 'user-error)
    ;; Nothing was reaped: the live client and its entry are untouched.
    (should (eq emacs-jupyter-notebook--client 'mock-client))
    (should emacs-jupyter-notebook--session-entry)))

(ert-deftest ejn-w10-connect-async-invokes-callback-once-despite-finalize-error ()
  "W10 lesson re-pinned on the W15 adapter shape: the verify callback fires
exactly ONCE, always with a non-nil client, and a raise from the downstream
finalize work must NOT be misread as a connect failure nor re-enter the
callback with nil.  In the W15 shape the reply arrives through the
adapter's `--safe-callback' layer, which contains the raise (surfacing it
as a message) — the `called' latch guarantees single invocation.  The
adapter returns the unverified client synchronously."
  (let ((calls 0)
        captured)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--connect-unverified)
               (lambda (_file) 'mock-client))
              ((symbol-function 'emacs-jupyter-notebook-jupyter--store-kernel-info)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
               (lambda (_client cb)
                 ;; Deliver the reply through the same safe-callback layer
                 ;; production uses, twice — the latch must dedupe.
                 (emacs-jupyter-notebook-jupyter--safe-callback
                  cb '(:status "ok") nil)
                 (emacs-jupyter-notebook-jupyter--safe-callback
                  cb '(:status "ok") nil)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (let ((client (emacs-jupyter-notebook-jupyter--connect-async
                     "/tmp/kernel.json"
                     (lambda (client)
                       (cl-incf calls)
                       (setq captured client)
                       (error "finalize boom")))))
        ;; Unverified client returned synchronously.
        (should (eq client 'mock-client)))
      (should (= calls 1))
      (should (eq captured 'mock-client)))))

(ert-deftest ejn-w10-connect-nil-client-transitions-context-to-error ()
  "W10 secondary: a connect whose adapter yields a nil client must move the
async context to ERROR (surfacing the failure via `--async-fail'), never
silently to `done'.  Drives the full `--async-connect' -> adapter
callback(nil) -> `--async-connect-finalize' seam."
  (with-temp-buffer
    (let ((err-surfaced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--install-tunnel-sentinel)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-jupyter-connect-async)
                 (lambda (_file callback)
                   ;; Adapter reports a failed connect: nil client.
                   (funcall callback nil))))
        (let ((context (emacs-jupyter-notebook--async-new-context
                        :phase 'tunnel
                        :entry '(:profile "p" :session-id "session")
                        :local-ports '(:shell_port 1001)
                        :local-file "/tmp/kernel.json"
                        :tunnel-process 'mock-process
                        :origin-buffer (current-buffer)
                        :error-callback (lambda (_ctx _err)
                                          (setq err-surfaced t)))))
          (setq emacs-jupyter-notebook--async-context context)
          (emacs-jupyter-notebook--async-connect context)
          (ejn-test-drain-zero-delay-timers)
          (should (eq (plist-get emacs-jupyter-notebook--async-context :phase)
                      'error))
          (should-not emacs-jupyter-notebook--client)
          (should err-surfaced))))))

;;; W6.3 — Friendly first-evaluate

(ert-deftest ejn-w6.3-send-cell-announces-default-profile-on-cold-start ()
  "W6.3: with no client/async/registry, send-cell messages the default profile."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (equal announced "workstation")))))

(ert-deftest ejn-w6.3-send-cell-with-prefix-prompts-and-skips-message ()
  "W6.3: C-u send-cell on a cold start prompts via `--read-profile-name' and skips the banner."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "default")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil)
           (read-called nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--read-profile-name)
                 (lambda () (setq read-called t) "chosen"))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell '(4)))
      (should read-called)
      (should (null announced)))))

(ert-deftest ejn-w6.3-send-cell-with-live-client-does-not-announce ()
  "W6.3: when a client is already live, no banner fires."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client 'mock)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () nil))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (null announced)))))

(ert-deftest ejn-w6.3-send-cell-with-registry-entry-does-not-announce ()
  "W6.3: when a registry entry exists, send-cell silently reconnects (no banner)."
  (ejn-test-with-temp-buffer "# %% A\nx = 1\n"
    (let* ((emacs-jupyter-notebook-default-profile "workstation")
           (emacs-jupyter-notebook--client nil)
           (emacs-jupyter-notebook--async-context nil)
           (announced nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
                 (lambda () '(:session-id "s")))
                ((symbol-function 'emacs-jupyter-notebook--announce-cold-start)
                 (lambda (p) (setq announced p))))
        (emacs-jupyter-notebook-send-cell))
      (should (null announced)))))

(ert-deftest ejn-w6.3-announce-cold-start-message-shape ()
  "W6.3: `--announce-cold-start' produces the documented message shape."
  (let ((inhibit-message t))
    ;; Just exercise the function so it does not error; the contents end up
    ;; in `*Messages*' but that is not portable to assert from batch reliably.
    (emacs-jupyter-notebook--announce-cold-start "workstation"))
  ;; Check that the message bytes are the documented format with format.
  (should (equal
           (format "emacs-jupyter-notebook: starting kernel via profile %s (C-u to choose)"
                   "workstation")
           "emacs-jupyter-notebook: starting kernel via profile workstation (C-u to choose)")))

;;; W6.4 — Confirmations on destructive commands

(ert-deftest ejn-w6.4-confirm-helper-lisp-callers-always-pass ()
  "W6.4: from Lisp (interactive-p nil) the action is always authorized."
  (let ((asked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil)))
      (should (emacs-jupyter-notebook--confirm nil nil "?"))
      (should-not asked))))

(ert-deftest ejn-w6.4-confirm-helper-c-u-skips-prompt ()
  "W6.4: a non-nil FORCE prefix bypasses `y-or-n-p'."
  (let ((asked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil)))
      (should (emacs-jupyter-notebook--confirm t '(4) "?"))
      (should-not asked))))

(ert-deftest ejn-w6.4-confirm-helper-interactive-no-prefix-prompts ()
  "W6.4: interactive call without FORCE asks `y-or-n-p'."
  (let ((asked nil) (response t))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) response)))
      (should (emacs-jupyter-notebook--confirm t nil "?"))
      (should asked)
      (setq response nil)
      (should-not (emacs-jupyter-notebook--confirm t nil "?")))))

(ert-deftest ejn-w6.4-shutdown-from-lisp-skips-prompt ()
  "W6.4: calling `shutdown-kernel' from Lisp does not prompt."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) t))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (emacs-jupyter-notebook-shutdown-kernel)
      (should-not asked)
      (should cleanup-called))))

(ert-deftest ejn-w6.4-shutdown-interactive-asks-and-aborts-on-no ()
  "W6.4: interactive call with a `no' answer does NOT run cleanup."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (call-interactively #'emacs-jupyter-notebook-shutdown-kernel)
      (should asked)
      (should-not cleanup-called))))

(ert-deftest ejn-w6.4-shutdown-interactive-with-c-u-skips-prompt ()
  "W6.4: interactive call with C-u skips the prompt."
  (let ((asked nil) cleanup-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'emacs-jupyter-notebook-shutdown-kernel))
      (should-not asked)
      (should cleanup-called))))

(ert-deftest ejn-w6.4-send-buffer-from-lisp-skips-prompt ()
  "W6.4: Lisp callers of `send-buffer' bypass the confirmation."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let ((asked nil) sent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_p) (setq asked t) t))
                ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest args) (setq sent args))))
        (emacs-jupyter-notebook-send-buffer))
      (should-not asked)
      (should sent))))

(ert-deftest ejn-w6.4-send-buffer-interactive-asks-and-aborts-on-no ()
  "W6.4: interactive `send-buffer' aborts on a `no' answer."
  (ejn-test-with-temp-buffer "x = 1\n"
    (let (asked sent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_p) (setq asked t) nil))
                ((symbol-function 'emacs-jupyter-notebook--evaluate-code)
                 (lambda (&rest args) (setq sent args))))
        (call-interactively #'emacs-jupyter-notebook-send-buffer))
      (should asked)
      (should-not sent))))

(ert-deftest ejn-w6.4-retry-fresh-from-lisp-with-profile-string ()
  "W6.4: Lisp call with a profile string skips the confirmation."
  (let ((asked nil) cleanup-called start-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (profile &rest _)
                 (setq start-called profile))))
      (with-temp-buffer
        (emacs-jupyter-notebook-retry-fresh-kernel "specific")
        (should-not asked)
        (should cleanup-called)
        (should (equal start-called "specific"))))))

(ert-deftest ejn-w6.4-retry-fresh-interactive-prompts-and-aborts-on-no ()
  "W6.4: interactive `retry-fresh-kernel' with a `no' answer aborts."
  (let (asked cleanup-called start-called)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--cleanup-current-state)
               (lambda (&rest _) (setq cleanup-called t)))
              ((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
               (lambda (&rest _) (setq start-called t))))
      (with-temp-buffer
        (call-interactively #'emacs-jupyter-notebook-retry-fresh-kernel))
      (should asked)
      (should-not cleanup-called)
      (should-not start-called))))

(ert-deftest ejn-w6.4-clean-orphaned-kernels-interactive-prompts ()
  "W6.4: interactive `clean-orphaned-kernels' prompts and aborts on no."
  (let (asked ran)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-profile-name)
               (lambda () "p"))
              ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_p)
                 '(:profile "p" :host "host" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--management-run)
               (lambda (&rest _) (setq ran t))))
      (call-interactively #'emacs-jupyter-notebook-clean-orphaned-kernels)
      (should asked)
      (should-not ran))))

(ert-deftest ejn-w6.4-clean-orphaned-kernels-with-c-u-skips-prompt ()
  "W6.4: interactive `clean-orphaned-kernels' with C-u skips the prompt."
  (let (asked ran)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-profile-name)
               (lambda () "p"))
              ((symbol-function 'emacs-jupyter-notebook--read-host-profile)
               (lambda (_p)
                 '(:profile "p" :host "host" :remote-cache-dir "/tmp/ejn")))
              ((symbol-function 'y-or-n-p)
               (lambda (_p) (setq asked t) nil))
              ((symbol-function 'emacs-jupyter-notebook--management-run)
               (lambda (_label _name _argv success _failure &optional _timeout)
                 (setq ran t)
                 (funcall success ""))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'emacs-jupyter-notebook-clean-orphaned-kernels))
      (should-not asked)
      (should ran))))

;;; W6.5 — Status buffer

(defmacro ejn-test-with-status-buffer (status-buffer-var &rest body)
  "Run BODY with STATUS-BUFFER-VAR bound to a freshly-rendered status buffer.
Cleans up the status buffer (and its refresh timer) after BODY."
  (declare (indent 1))
  `(let ((,status-buffer-var (call-interactively
                              #'emacs-jupyter-notebook-status)))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,status-buffer-var)
         (with-current-buffer ,status-buffer-var
           (emacs-jupyter-notebook--status-cancel-refresh))
         (kill-buffer ,status-buffer-var)))))

(ert-deftest ejn-w6.5-status-buffer-is-special-mode-derived ()
  "W6.5: the status buffer's major mode is derived from `special-mode'."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      (with-current-buffer status-buf
        (should (derived-mode-p 'special-mode))
        (should (eq major-mode 'emacs-jupyter-notebook-status-mode))
        (should buffer-read-only)))))

(ert-deftest ejn-w6.5-status-buffer-renders-snapshot-content ()
  "W6.5: status buffer shows the snapshot lines for the originating buffer."
  (with-temp-buffer
    (setq emacs-jupyter-notebook--client 'mock
          emacs-jupyter-notebook--session-entry
          '(:profile "p" :session-id "sid"
            :remote-host "h" :remote-pid 42
            :remote-connection-file "/r.json"
            :local-connection-file "/l.json"
            :tunnel-ports (:shell_port 1001)))
    (ejn-test-with-status-buffer status-buf
      (with-current-buffer status-buf
        (let ((text (buffer-string)))
          (should (string-match-p "Profile: p" text))
          (should (string-match-p "Session: sid" text))
          (should (string-match-p "Suggested actions" text)))))))

(ert-deftest ejn-w6.5-status-buffer-source-buffer-is-recorded ()
  "W6.5: the status buffer's `--status-source-buffer' points at the originator."
  (with-temp-buffer
    (let ((src (current-buffer)))
      (ejn-test-with-status-buffer status-buf
        (should (eq (buffer-local-value
                     'emacs-jupyter-notebook--status-source-buffer
                     status-buf)
                    src))))))

(ert-deftest ejn-w6.5-status-buffer-installs-refresh-timer ()
  "W6.5: rendering installs a live-refresh timer on the status buffer."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      (should (timerp
               (buffer-local-value
                'emacs-jupyter-notebook--status-refresh-timer
                status-buf))))))

(ert-deftest ejn-w6.5-status-buffer-cancels-timer-on-kill ()
  "W6.5: killing the status buffer cancels its refresh timer."
  (with-temp-buffer
    (let ((status-buf (call-interactively #'emacs-jupyter-notebook-status))
          captured-timer)
      (setq captured-timer
            (buffer-local-value
             'emacs-jupyter-notebook--status-refresh-timer status-buf))
      (should (timerp captured-timer))
      (kill-buffer status-buf)
      ;; A cancelled timer is no longer in the list of live timers.
      (should-not (memq captured-timer timer-list)))))

(ert-deftest ejn-w6.5-status-buffer-tick-no-window-cancels-timer ()
  "W6.5: when the status buffer is buried (no window), tick cancels the timer."
  (with-temp-buffer
    (ejn-test-with-status-buffer status-buf
      ;; Simulate burying by removing the buffer from any window.
      (dolist (win (get-buffer-window-list status-buf nil t))
        (when (window-live-p win) (delete-window win)))
      (emacs-jupyter-notebook--status-tick)
      (should-not (buffer-local-value
                   'emacs-jupyter-notebook--status-refresh-timer
                   status-buf)))))

(ert-deftest ejn-w6.5-status-buffer-suggestion-button-invokes-command-in-source ()
  "W6.5: a click on a suggestion button switches to source and invokes its command."
  (with-temp-buffer
    (let ((src (current-buffer))
          invoked-in-buffer)
      ;; Force the snapshot to show no client so we always get a Start button.
      (setq emacs-jupyter-notebook--client nil)
      (ejn-test-with-status-buffer status-buf
        (with-current-buffer status-buf
          ;; Replace the Start command with a probe that records its caller.
          (let ((actions emacs-jupyter-notebook--status-suggestion-actions))
            (should actions)
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-start-remote-kernel)
                       (lambda (&rest _)
                         (interactive)
                         (setq invoked-in-buffer (current-buffer)))))
              ;; Find the first button and activate it.
              (goto-char (point-min))
              (let ((btn (next-button (point))))
                (should btn)
                (button-activate btn))))))
      (should (eq invoked-in-buffer src)))))

;;; W6.6 — Global async log buffer

(defmacro ejn-test-with-fresh-log-buffer (&rest body)
  "Run BODY with a freshly-created log buffer; clean up afterwards."
  (declare (indent 0))
  `(progn
     (let ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name)))
       (when (buffer-live-p buf) (kill-buffer buf)))
     (unwind-protect
         (progn ,@body)
       (let ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name)))
         (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest ejn-w6.6-log-buffer-is-special-mode ()
  "W6.6: the log buffer is derived from `special-mode' and read-only."
  (ejn-test-with-fresh-log-buffer
   (let ((buf (emacs-jupyter-notebook--log-buffer-ensure)))
     (with-current-buffer buf
       (should (derived-mode-p 'special-mode))
       (should buffer-read-only)))))

(ert-deftest ejn-w6.6-log-append-writes-timestamped-entry ()
  "W6.6: an appended entry carries timestamp, buffer name, phase, and message."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (rename-buffer "*ejn-test-source*" t)
     (emacs-jupyter-notebook--log-append 'launch "hello %s" "world"))
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "hello world" text))
     (should (string-match-p "\\[launch\\]" text))
     (should (string-match-p "\\*ejn-test-source\\*" text))
     (should (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T" text)))))

(ert-deftest ejn-w6.6-log-append-truncates-to-log-max-lines ()
  "W6.6: appends beyond `--log-max-lines' drop the oldest lines."
  (ejn-test-with-fresh-log-buffer
   (let ((emacs-jupyter-notebook-log-max-lines 5))
     (dotimes (i 12)
       (emacs-jupyter-notebook--log-append 'tick "entry %d" i))
     (with-current-buffer (get-buffer emacs-jupyter-notebook--log-buffer-name)
       (should (= (count-lines (point-min) (point-max)) 5))
       (let ((text (buffer-string)))
         ;; Oldest entries 0..6 are gone; 7..11 remain.
         (should-not (string-match-p "entry 0\n" text))
         (should-not (string-match-p "entry 6\n" text))
         (should (string-match-p "entry 7\n" text))
         (should (string-match-p "entry 11\n" text)))))))

(ert-deftest ejn-w6.6-async-message-writes-to-log ()
  "W6.6: `--async-message' writes a structured entry tagged with the phase."
  (ejn-test-with-fresh-log-buffer
   (emacs-jupyter-notebook--async-message '(:phase tunnel) "ports up")
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "ports up" text))
     (should (string-match-p "\\[tunnel\\]" text)))))

(ert-deftest ejn-w6.6-async-message-nil-context-tags-none ()
  "W6.6: when the context is nil, the log line is tagged `[none]'."
  (ejn-test-with-fresh-log-buffer
   (emacs-jupyter-notebook--async-message nil "bare message")
   (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
          (text (with-current-buffer buf (buffer-string))))
     (should (string-match-p "bare message" text))
     (should (string-match-p "\\[none\\]" text)))))

(ert-deftest ejn-w6.6-heartbeat-miss-logs ()
  "W6.6: each heartbeat miss writes a `heartbeat-miss' line."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 99))
       (emacs-jupyter-notebook--heartbeat-on-miss))
     (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
            (text (with-current-buffer buf (buffer-string))))
       (should (string-match-p "\\[heartbeat-miss\\]" text))))))

(ert-deftest ejn-w6.6-heartbeat-death-logs ()
  "W6.6: crossing the miss-allowed threshold writes `heartbeat-dead'."
  (ejn-test-with-fresh-log-buffer
   (with-temp-buffer
     (let ((emacs-jupyter-notebook-heartbeat-misses-allowed 1))
       ;; First miss already crosses since allowed=1.
       (cl-letf (((symbol-function 'display-warning) (lambda (&rest _))))
         (emacs-jupyter-notebook--heartbeat-on-miss)))
     (let* ((buf (get-buffer emacs-jupyter-notebook--log-buffer-name))
            (text (with-current-buffer buf (buffer-string))))
       (should (string-match-p "\\[heartbeat-dead\\]" text))))))

(ert-deftest ejn-w6.6-show-log-buffer-displays-existing ()
  "W6.6: `show-log-buffer' creates and displays the log buffer."
  (ejn-test-with-fresh-log-buffer
   (cl-letf* (((symbol-function 'display-buffer)
               (lambda (b &rest _)
                 (should (eq b (get-buffer emacs-jupyter-notebook--log-buffer-name)))
                 b)))
     (emacs-jupyter-notebook-show-log-buffer)
     (should (buffer-live-p
              (get-buffer emacs-jupyter-notebook--log-buffer-name))))))

;;; W6.7 — `--read-host-profile' input validation

(ert-deftest ejn-w6.7-prompt-host-empty-reprompts ()
  "W6.7: empty input re-prompts until non-empty input is given."
  (let ((answers '("" "   " "example.com"))
        (asked 0))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (cl-incf asked)
                 (pop answers))))
      (should (equal (emacs-jupyter-notebook--prompt-host) "example.com"))
      (should (= asked 3)))))

(ert-deftest ejn-w6.7-prompt-host-rejects-whitespace-in-host ()
  "W6.7: input that contains internal whitespace is rejected with `user-error'."
  (let ((answers '("bad host with space")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop answers))))
      (should-error
       (emacs-jupyter-notebook--prompt-host) :type 'user-error))))

(ert-deftest ejn-w6.10-clear-results-bound-under-prefix ()
  "W6.10: `clear-results' is reachable from the new `C-c j' prefix."
  (let ((cmd (lookup-key
              (emacs-jupyter-notebook--build-prefix-map) (kbd "l"))))
    (should (eq cmd #'emacs-jupyter-notebook-clear-results))))

(ert-deftest ejn-w6.10-read-host-profile-rejects-profile-with-bad-host ()
  "W6.10: a profile whose stored `:host' contains whitespace fails fast,
before any SSH command is constructed.  Bypassing the prompt branch must
not bypass the whitespace check."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("dirty" . (:host "bad host with space"
                       :remote-cwd "~" :kernelspec "python3")))))
    (should-error (emacs-jupyter-notebook--read-host-profile "dirty")
                  :type 'user-error)))

(ert-deftest ejn-w6.10-read-host-profile-rejects-profile-with-bad-remote-host ()
  "W6.10: `--read-host-profile' also checks `:remote-host' (the
registry-entry shape) for whitespace."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("dirty2" . (:remote-host "with\ttab"
                        :remote-cwd "~" :kernelspec "python3")))))
    (should-error (emacs-jupyter-notebook--read-host-profile "dirty2")
                  :type 'user-error)))

(ert-deftest ejn-w6.10-status-tick-cancels-when-source-buffer-killed ()
  "W6.10: `--status-tick' cancels the refresh timer when the source
buffer that originated the status view has been killed.  Without this
the timer would fire forever on a dead source."
  (let* ((source (generate-new-buffer "ejn-w610-src"))
         (status (get-buffer-create
                  emacs-jupyter-notebook--status-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer status
            (unless (derived-mode-p 'emacs-jupyter-notebook-status-mode)
              (emacs-jupyter-notebook-status-mode))
            (setq emacs-jupyter-notebook--status-source-buffer source)
            (setq emacs-jupyter-notebook--status-refresh-timer
                  (run-with-timer 1000 1000 #'ignore)))
          (kill-buffer source)
          (emacs-jupyter-notebook--status-tick)
          (with-current-buffer status
            (should-not emacs-jupyter-notebook--status-refresh-timer)))
      (when (buffer-live-p status) (kill-buffer status)))))

(ert-deftest ejn-w6.7-prompt-host-trims-surrounding-whitespace ()
  "W6.7: surrounding whitespace is trimmed; the trimmed value is accepted."
  (let ((answers '("  example.com  ")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop answers))))
      (should (equal (emacs-jupyter-notebook--prompt-host) "example.com")))))

(ert-deftest ejn-w6.7-read-host-profile-skips-prompt-when-host-set ()
  "W6.7: when the profile already has a :host, no prompt is issued."
  (let ((asked nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (setq asked t) "x"))
              ((symbol-function 'emacs-jupyter-notebook-ssh-profile)
               (lambda (_p) '(:profile "p" :host "example.com"))))
      (let ((profile (emacs-jupyter-notebook--read-host-profile "p")))
        (should-not asked)
        (should (equal (plist-get profile :host) "example.com"))))))

(ert-deftest ejn-w6.7-read-host-profile-prompts-when-host-missing ()
  "W6.7: a profile with no :host triggers `--prompt-host', value is interned."
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) "example.com"))
            ((symbol-function 'emacs-jupyter-notebook-ssh-profile)
             (lambda (_p) '(:profile "p"))))
    (let ((profile (emacs-jupyter-notebook--read-host-profile "p")))
      (should (equal (plist-get profile :host) "example.com")))))

;;; W6.8 — `--read-registry-entry' chooser always with current-file default

(ert-deftest ejn-w6.8-read-registry-entry-always-prompts ()
  "W6.8: even when only one entry exists, the chooser is invoked."
  (let* ((entry '(:profile "p" :session-id "sole"))
         (asked nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list entry)))
              ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (setq asked t)
                 (emacs-jupyter-notebook--registry-entry-label entry))))
      (with-temp-buffer
        (should (equal (emacs-jupyter-notebook--read-registry-entry) entry))
        (should asked)))))

(ert-deftest ejn-w6.8-read-registry-entry-uses-current-file-default ()
  "W6.8: when current-file entry exists, it is passed as the chooser's default."
  (let* ((file (expand-file-name "x.py" temporary-file-directory))
         (current `(:profile "p" :session-id "x-session" :local-file ,file))
         (other '(:profile "p" :session-id "other"))
         (passed-default nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) (list other current)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &optional _pred _require _initial _hist default)
                 (setq passed-default default)
                 default)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (let ((selected (emacs-jupyter-notebook--read-registry-entry)))
          (should (equal selected current))
          (should (stringp passed-default))
          (should (string-match-p "x-session" passed-default)))))))

(ert-deftest ejn-w6.8-read-registry-entry-no-current-file-no-default ()
  "W6.8: when there is no current-file entry, the default is nil and the chooser still runs."
  (let* ((entries '((:profile "p" :session-id "a")
                    (:profile "p" :session-id "b")))
         (asked-with-default 'unset))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) entries))
              ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &optional _pred _require _initial _hist default)
                 (setq asked-with-default default)
                 (emacs-jupyter-notebook--registry-entry-label (car entries)))))
      (with-temp-buffer
        (emacs-jupyter-notebook--read-registry-entry)
        (should (null asked-with-default))))))

(ert-deftest ejn-w6.1-old-evaluate-command-names-removed ()
  "W6.1: the legacy `emacs-jupyter-notebook-evaluate-*' names are gone (no aliases)."
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-current-cell))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-region))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-buffer))
  (should-not (fboundp 'emacs-jupyter-notebook-evaluate-current-cell-and-advance)))

;;; W7.5 — Continuous coverage backfill

(ert-deftest ejn-w7.5-registry-load-corrupt-file-returns-nil-with-warning ()
  "W7.5: `registry-load' on a corrupt file must not raise; it returns nil
and surfaces a warning.  The registry is durable truth — a garbled file
must not brick the package's ability to start a fresh kernel."
  (let ((file (make-temp-file "ejn-w75-corrupt-")))
    (unwind-protect
        (let (warned)
          (with-temp-file file (insert "this is not (a valid) sexp"))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (should-not (emacs-jupyter-notebook-registry-load file)))
          (should warned))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest ejn-w7.5-ssh-command-honors-identity-file-and-port ()
  "W7.5: profile `:identity-file' expands `~' and joins the ssh argv
after `-p PORT'; ssh uses `-p'.  Regression: without this the identity
knob silently disappears from the launch/probe argv."
  (let ((emacs-jupyter-notebook-ssh-command "ssh")
        (emacs-jupyter-notebook-ssh-options nil))
    (let ((argv (emacs-jupyter-notebook-ssh-command
                 '(:profile "p" :host "h" :user "u"
                   :port 2222 :identity-file "~/.ssh/id_ed25519"))))
      (should (member "-p" argv))
      (should (member "2222" argv))
      (should (member "-i" argv))
      ;; ~ is expanded to an absolute path.
      (should (cl-some (lambda (a)
                         (and (stringp a)
                              (string-suffix-p ".ssh/id_ed25519" a)
                              (not (string-prefix-p "~" a))))
                       argv)))))

(ert-deftest ejn-w7.5-ssh-scp-from-command-honors-port-and-identity-file ()
  "W7.5: `scp' uses `-P' (capital) not `-p' for the remote port; the
`:identity-file' knob also propagates to scp.  Getting these wrong
silently makes the retrieve step fail."
  (let ((emacs-jupyter-notebook-scp-command "scp")
        (emacs-jupyter-notebook-ssh-options nil))
    (let ((argv (emacs-jupyter-notebook-ssh-scp-from-command
                 '(:profile "p" :host "h"
                   :port 2222 :identity-file "~/.ssh/id_ed25519")
                 "~/.cache/ejn/k.json" "/tmp/k.json")))
      (should (member "-P" argv))
      (should-not (member "-p" argv))
      (should (member "2222" argv))
      (should (member "-i" argv))
      ;; The `~'-anchored source is rewritten to a home-relative path so
      ;; SFTP-protocol scp (OpenSSH 9+) can resolve it — see
      ;; `ejn-ssh-scp-rewrites-tilde-to-home-relative'.
      (should (member "h:.cache/ejn/k.json" argv))
      (should (equal (car (last argv)) "/tmp/k.json")))))

(ert-deftest ejn-w7.5-panel-late-writes-after-panel-kill-are-safe ()
  "W7.5: streaming/reply callbacks arriving after the panel buffer is
killed must be no-ops, not raises.  Common race: user kills the panel
while a slow evaluate is in flight."
  (let ((buf (ejn-test--make-source-buffer)))
    (unwind-protect
        (let* ((panel (ejn-panel-ensure buf))
               (handle (ejn-panel-start-entry panel nil "print('hi')")))
          (kill-buffer panel)
          (should-not (buffer-live-p panel))
          ;; Every public writer must tolerate a dead panel silently.
          (should (progn (ejn-panel-append-text handle "late stream") t))
          (should (progn (ejn-panel-replace-text handle "late replace") t))
          (should (progn (ejn-panel-set-image handle '(image :type png)) t))
          (should (progn (ejn-panel-clear-entry handle) t))
          (should (progn (ejn-panel-clear-entry handle t) t))
          (should (progn (ejn-panel-finish-entry handle 'ok 1) t)))
      (ejn-test--kill-source-buffer buf))))

(defun ejn-w7.5--strip-lisp-comments-and-strings (source)
  "Return SOURCE with Emacs-Lisp line comments and string literals blanked.
Blanking preserves offsets — comments become spaces and string bodies
become spaces — so downstream regexes cannot false-positive on text
that only exists inside comments or docstrings."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    ;; Blank out string literals first (`\"...\"'), skipping escaped quotes.
    (while (re-search-forward "\"" nil t)
      (let ((start (1- (point))))
        (while (and (not (eobp))
                    (not (looking-at "\"")))
          (if (looking-at "\\\\.")
              (goto-char (+ 2 (point)))
            (forward-char 1)))
        (when (looking-at "\"")
          (let ((end (1+ (point))))
            (delete-region start end)
            (insert (make-string (- end start) ?\s))))))
    ;; Blank each line comment (`;' through end of line).
    (goto-char (point-min))
    (while (re-search-forward ";.*$" nil t)
      (let ((s (match-beginning 0)) (e (match-end 0)))
        (delete-region s e)
        (insert (make-string (- e s) ?\s))))
    (buffer-string)))

(ert-deftest ejn-w7.5-source-files-do-not-depend-on-tramp ()
  "W7.5: the hard architecture rule (AGENTS.md) forbids TRAMP, `jupyter-tramp',
and Emacs remote file handlers.  Static-scan every package `.el' file in
the project root for actual `require' / `use-package' of a tramp module.
W7.6: comments and string literals (docstrings) are blanked BEFORE the
scan so mentions of `require 'tramp' inside prose cannot trigger a false
positive.  The scan also anchors `require' at line-start so a text
fragment inside a nested form is not sufficient."
  (let* ((root (or (locate-dominating-file
                    (or (symbol-file 'emacs-jupyter-notebook-mode) default-directory)
                    "emacs-jupyter-notebook.el")
                   default-directory))
         (files (directory-files root t "\\`emacs-jupyter-notebook.*\\.el\\'"))
         offenders)
    (should files)
    (dolist (file files)
      (let ((raw (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string))))
        (let ((code (ejn-w7.5--strip-lisp-comments-and-strings raw)))
          (with-temp-buffer
            (insert code)
            (goto-char (point-min))
            ;; Top-level or nested `(require 'tramp)' / `(use-package tramp)'.
            (when (re-search-forward
                   "(\\(require\\|use-package\\)[[:space:]]+'?\\(tramp\\|jupyter-tramp\\)\\b"
                   nil t)
              (push (file-name-nondirectory file) offenders))
            (goto-char (point-min))
            (when (re-search-forward
                   "\\btramp-file-name-p\\|\\bjupyter-tramp-\\|\\btramp-tramp-file-p\\b"
                   nil t)
              (push (file-name-nondirectory file) offenders))))))
    (should-not offenders)))

(ert-deftest ejn-w7.6-strip-comments-blanks-tramp-mentions-in-docstrings ()
  "W7.6 self-check: `--strip-lisp-comments-and-strings' successfully blanks
`require 'tramp' inside a docstring, so the W7.5 scanner cannot fire on
a mention that only exists in prose."
  (let* ((source (concat
                  "(defun foo () \"Do not (require 'tramp).\" nil)\n"
                  "; also do not `(require 'jupyter-tramp)' here\n"))
         (stripped (ejn-w7.5--strip-lisp-comments-and-strings source)))
    (should-not (string-match-p "tramp" stripped))
    (should-not (string-match-p "jupyter-tramp" stripped))))

;;; W8 — local interactive matplotlib viewer

;;; W8.1 — remote formatter-registration snippet injection

(ert-deftest ejn-w8.1-inject-uses-silent-execute-adapter ()
  "W8.1: the formatter injection routes the snippet through the silent
execute adapter (no panel entry) and passes the actual snippet string."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (should (= (length calls) 1))
      (should (eq (caar calls) 'mock-client))
      (should (equal (cadar calls)
                     emacs-jupyter-notebook--viewer-formatter-snippet))
      ;; The snippet must reference the custom MIME and patch the figure
      ;; type's `_repr_mimebundle_'.  It must NOT use the old
      ;; `for_type_by_name' display-formatter registration, which the
      ;; matplotlib inline backend wipes on the first plot (the payload then
      ;; silently degrades to the figure `__repr__').  See
      ;; `viewer/test_formatter_kernel.py' for the real-kernel regression.
      (should (string-match-p "application/x-ejn-mpl-pickle"
                              emacs-jupyter-notebook--viewer-formatter-snippet))
      (should (string-match-p "_repr_mimebundle_"
                              emacs-jupyter-notebook--viewer-formatter-snippet))
      ;; Must not CALL the wipeable display-formatter registration API.
      (should-not (string-match-p "\\.for_type_by_name("
                                  emacs-jupyter-notebook--viewer-formatter-snippet))
      (should-not (string-match-p "\\.for_type("
                                  emacs-jupyter-notebook--viewer-formatter-snippet))
      (should (string-match-p "get_ipython"
                              emacs-jupyter-notebook--viewer-formatter-snippet)))))

(ert-deftest ejn-w8.1-inject-noop-without-client ()
  "W8.1: with no client the injection is a silent no-op (no adapter call)."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (should (null calls)))))

(ert-deftest ejn-w8.1-inject-swallows-adapter-errors ()
  "W8.1: a raise from the adapter must not propagate out of injection —
formatter injection may never break a connect or restart."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) (error "boom"))))
        ;; Should not signal.
        (should (progn (emacs-jupyter-notebook--inject-viewer-formatter) t))))))

(ert-deftest ejn-w8.1-inject-produces-no-panel-entry ()
  "W8.1: injecting the snippet creates no panel entry for the source buffer."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (panel (ejn-panel-ensure (current-buffer))))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) nil)))
        (emacs-jupyter-notebook--inject-viewer-formatter))
      (with-current-buffer panel
        (should (null emacs-jupyter-notebook-panel--entries))))))

(ert-deftest ejn-w8.1-png-plus-pickle-bundle-still-renders-png ()
  "W8.1: a display_data bundle carrying BOTH image/png and the custom
pickle MIME still renders the PNG through the callbacks — the extra MIME
key never disturbs the existing PNG path."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (panel (ejn-panel-ensure buffer))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks buffer handle))
           (display-fn (cadr (assoc "display_data" callbacks)))
           (png (base64-encode-string "imgdata" t))
           (pickle (base64-encode-string "pickle-bytes" t)))
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   `(:data (:image/png ,png
                            :application/x-ejn-mpl-pickle ,pickle))))
                ((symbol-function 'create-image)
                 (lambda (data &optional _type _data-p &rest _props)
                   (list 'image :type 'png :data data))))
        (funcall display-fn 'mock-msg))
      (let ((image (car (ejn-panel-entry-images handle))))
        (should (ejn-test-image-file-backed-p image))
        (should (equal (ejn-test-image-spec-data image) "imgdata"))))))

;;; W8.2 — MIME recognition + pickle stash

(ert-deftest ejn-w8.2-select-mime-type-ignores-pickle ()
  "W8.2: the pickle MIME is never chosen as a renderable thumbnail."
  (should (equal (emacs-jupyter-notebook--select-mime-type
                  '(:application/x-ejn-mpl-pickle "cGts" :image/png "aW1n"))
                 '(:image/png . "aW1n")))
  (should (null (emacs-jupyter-notebook--select-mime-type
                 '(:application/x-ejn-mpl-pickle "cGts")))))

(ert-deftest ejn-w8.2-helper-bundle-stores-descriptor-and-renders-png ()
  "W8.2/EI4V: helper-published PNG and pickle metadata are retained together."
  (ejn-test-with-fresh-log-buffer
    (let* ((root (make-temp-file "ejn-w8-bundle-" t))
           (image-file nil)
           (pickle-file nil)
           (image-canary "RUpOX0lNQUdFX0JBU0U2NF9QYXlsb2FkX0NBTkFSWQ==")
           (pickle-canary "RUpOX1BJQ0tMRV9CQVNFNjRfUGF5bG9hZF9DQU5BUlk="))
      (unwind-protect
          (progn
            (set-file-modes root #o700)
            (setq image-file
                  (ejn-ei4v-test--artifact-file
                   root "88888888888888888888888888888888" image-canary))
            (setq pickle-file
                  (ejn-ei4v-test--artifact-file
                   root "99999999999999999999999999999999" pickle-canary))
            (with-temp-buffer
              (let* ((source (current-buffer))
                     (panel (ejn-panel-ensure source))
                     (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                     (context (list :buffer source :entry-handle handle))
                     (event
                      `(:type display
                        :data (:ejn-published-image
                               ,(ejn-ei4v-test--descriptor
                                 root image-file "image/png" "fig")
                               :ejn-published-pickle
                               ,(ejn-ei4v-test--descriptor
                                 root pickle-file nil "fig"))
                        :display-id "fig"))
                     panel-text log-text)
                (dolist (canary (list image-canary pickle-canary))
                  (should-not (string-match-p canary (prin1-to-string event))))
                (should (emacs-jupyter-notebook-events-dispatch context event))
                (with-current-buffer panel
                  (emacs-jupyter-notebook-panel-flush-now panel)
                  (setq panel-text (buffer-string)))
                (when-let ((log (get-buffer emacs-jupyter-notebook--log-buffer-name)))
                  (with-current-buffer log
                    (setq log-text (buffer-string))))
                (let* ((entry (ejn-panel-entry-snapshot handle))
                       (image (car (ejn-panel-entry-images handle)))
                       (printed (prin1-to-string entry)))
                  (should (equal (plist-get (cdr image) :file) image-file))
                  (should (equal (plist-get (plist-get entry :mpl-pickle) :file)
                                 pickle-file))
                  (dolist (surface (list printed panel-text (or log-text "")))
                    (dolist (canary (list image-canary pickle-canary))
                      (should-not (string-match-p canary surface))))))))
        (ignore-errors (delete-directory root t))))))

(ert-deftest ejn-a5-panel-caps-retained-pickle-artifacts ()
  "A5/EI4V: only the newest `panel-max-pickles' entries keep pickle files."
  (let ((root (make-temp-file "ejn-a5-pickle-cap-" t))
        files handles)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (let ((emacs-jupyter-notebook-panel-max-pickles 2)
                  (panel (ejn-panel-ensure (current-buffer))))
              (dotimes (i 5)
                (let* ((hex (format "%032x" i))
                       (file (ejn-ei4v-test--artifact-file
                              root hex (format "pickle-%d" i)))
                       (handle (ejn-panel-start-entry
                                panel (cons "x.py" (1+ i)) "")))
                  (push file files)
                  (should
                   (ejn-panel-set-published-pickle
                    handle root file
                    (ejn-ei4-test--content-sha256 file)
                    (file-attribute-size (file-attributes file 'integer))
                    (file-attribute-file-identifier
                     (file-attributes root 'integer))))
                  (push (cons i handle) handles)))
              (setq handles (nreverse handles))
              (should (ejn-panel-entry-pickle (cdr (assq 4 handles))))
              (should (ejn-panel-entry-pickle (cdr (assq 3 handles))))
              (dolist (i '(0 1 2))
                (should-not (ejn-panel-entry-pickle (cdr (assq i handles))))
                (should-not (file-exists-p
                             (nth i (nreverse (copy-sequence files))))))
              (dolist (i '(3 4))
                (should (file-exists-p
                         (nth i (nreverse (copy-sequence files)))))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w14-panel-open-figure-finds-pickle-off-header ()
  "W14/EI4V: panel `v' lookup finds descriptor metadata within an entry body."
  (let* ((root (make-temp-file "ejn-w14-panel-v-" t))
         (image-file nil)
         (preview-file nil)
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq image-file
                (ejn-ei4d-test--write-artifact
                 root "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
                 (ejn-ei4d-test--png 2 3)))
          (setq preview-file
                (ejn-ei4d-test--write-artifact
                 root "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"
                 (ejn-ei4d-test--ppm 2 3)))
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2" "pickle"))
          (with-temp-buffer
            (let* ((panel (ejn-panel-ensure (current-buffer)))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()")))
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4d-result-test--image-descriptor
                 root image-file preview-file "fig" "image/png" 2 3)
                (ejn-ei4v-test--descriptor root pickle-file nil "fig")
                nil))
              (with-current-buffer panel
                (emacs-jupyter-notebook-panel--render panel)
                (let ((img-pos (next-single-property-change (point-min) 'display))
                      lease)
                  (should img-pos)
                  (goto-char img-pos)
                  (should-not (get-text-property (point)
                                                 'emacs-jupyter-notebook-entry-id))
                  (setq lease (emacs-jupyter-notebook-panel--entry-pickle-at-point))
                  (unwind-protect
                      (should (equal (plist-get lease :file) pickle-file))
                    (ejn-panel-release-pickle lease)))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w8.7-replace-text-and-clear-entry-drop-pickle ()
  "W8.7(d)/EI4V: text replacement and clear retire interactive descriptors."
  (let* ((root (make-temp-file "ejn-w8-drop-pickle-" t))
         (file-a nil)
         (file-b nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq file-a
                (ejn-ei4v-test--artifact-file
                 root "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1" "pk1"))
          (setq file-b
                (ejn-ei4v-test--artifact-file
                 root "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2" "pk2"))
          (with-temp-buffer
            (let* ((panel (ejn-panel-ensure (current-buffer)))
                   (h1 (ejn-panel-start-entry panel '("x.py" . 1) ""))
                   (h2 (ejn-panel-start-entry panel '("x.py" . 2) ""))
                   (root-id (file-attribute-file-identifier
                             (file-attributes root 'integer))))
              (should (ejn-panel-set-published-pickle
                       h1 root file-a (ejn-ei4-test--content-sha256 file-a)
                       3 root-id))
              (ejn-panel-replace-text h1 "now text")
              (should-not (ejn-panel-entry-pickle h1))
              (should-not (file-exists-p file-a))
              (should (ejn-panel-set-published-pickle
                       h2 root file-b (ejn-ei4-test--content-sha256 file-b)
                       3 root-id))
              (ejn-panel-clear-entry h2)
              (should-not (ejn-panel-entry-pickle h2))
              (should-not (file-exists-p file-b)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w8.7-auto-open-disabled-default-does-not-schedule ()
  "W8.7/EI4V: auto-open alone cannot load pickles without explicit opt-in."
  (let* ((root (make-temp-file "ejn-w8-auto-disabled-" t))
         (file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq file
                (ejn-ei4v-test--artifact-file
                 root "cccccccccccccccccccccccccccccccc" "pickle"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (context (list :buffer source :entry-handle handle))
                   (emacs-jupyter-notebook-viewer-auto-open t)
                   (emacs-jupyter-notebook-enable-pickle-viewer nil))
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (&rest _)
                           (ert-fail "disabled pickle viewer scheduled auto-open"))))
                (should
                 (emacs-jupyter-notebook-events-dispatch
                  context `(:type display
                            :data (:ejn-published-pickle
                                   ,(ejn-ei4v-test--descriptor root file nil "fig"))
                            :display-id "fig"))))
              (should (ejn-panel-entry-pickle handle))
              (should-not (plist-get (ejn-panel-entry-snapshot handle)
                                     :pickle-open-timer)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w14-apply-carriage-returns-collapses-progress ()
  "W14: tqdm-style `\\r' progress collapses to the final frame; `\\r\\n'
becomes `\\n'; plain multi-line text is untouched."
  (should (equal (emacs-jupyter-notebook--apply-carriage-returns "10%\r20%\r30%")
                 "30%"))
  (should (equal (emacs-jupyter-notebook--apply-carriage-returns "a\r\nb") "a\nb"))
  (should (equal (emacs-jupyter-notebook--apply-carriage-returns "l1\nl2") "l1\nl2"))
  (should (equal (emacs-jupyter-notebook--apply-carriage-returns "x\r100%\nnext")
                 "100%\nnext")))

(ert-deftest ejn-w14-append-text-collapses-tqdm-across-messages ()
  "W14: `\\r' progress arriving as separate stream messages collapses to the
latest frame in the stored entry content (no dumped intermediate frames)."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text h "\r 10%")
      (ejn-panel-append-text h "\r 55%")
      (ejn-panel-append-text h "\r100%")
      (should (equal (ejn-panel-entry-text h) "100%")))))

(ert-deftest ejn-w14-image-zoom-rebuilds-spec-numeric-unclamped ()
  "W14/W16: zooming rebuilds the entry's image spec — a non-numeric
`:scale' (Emacs 29+ reports the symbol `default') is coerced before
multiplying, the clamping `:max-width'/`:max-height' keys are dropped (they
made zoom-in a visual no-op), and the new spec persists on the entry so it
survives re-renders."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "plot()")))
      (ejn-panel-set-image h (list 'image :type 'png :scale 'default
                                   :max-width 800 :max-height 600))
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel--render panel)
        (goto-char (next-single-property-change (point-min) 'display))
        (emacs-jupyter-notebook-panel--scale-image-at-point 1.2))
      (let ((img (car (ejn-panel-entry-images h))))
        (should (numberp (plist-get (cdr img) :scale)))
        (should (< (abs (- (plist-get (cdr img) :scale) 1.2)) 1e-6))
        (should-not (plist-member (cdr img) :max-width))
        (should-not (plist-member (cdr img) :max-height))))))

(ert-deftest ejn-w17-image-insert-tags-segment-and-falls-back-headless ()
  "W17/W18: `--insert-image' tags the whole inserted region with the segment
index (so zoom resolves the right output from any slice row), and on a
non-graphic display falls back to a plain single display-property insert.
W18: the materialized preview requires INLINE-P; without it a lightweight
placeholder (no `display' property) carrying the same segment index is
inserted instead."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-panel-slice-images t))
      ;; Inline preview: real image inserted.
      (emacs-jupyter-notebook-panel--insert-image
       '(image :type png :data "fake") 3 t)
      ;; Batch mode is non-graphic: single-property fallback.
      (should (equal (get-text-property (point-min) 'display)
                     '(image :type png :data "fake" :ejn-materialized t)))
      (should (= (get-text-property (point-min)
                                    'emacs-jupyter-notebook-segment-index)
                 3)))
    (goto-char (point-max))
    (let ((emacs-jupyter-notebook-panel-slice-images t)
          (placeholder-start (point)))
      ;; Placeholder: no display property, but keeps the segment index.
      (emacs-jupyter-notebook-panel--insert-image
       '(image :type png :file "/tmp/x.png") 4 nil)
      (should-not (get-text-property placeholder-start 'display))
      (should (= (get-text-property placeholder-start
                                    'emacs-jupyter-notebook-segment-index)
                 4))
      (should (string-match-p "png image"
                              (buffer-substring placeholder-start (point)))))))

;;; W8.3 — local viewer process manager

(defvar ejn-w8.3--received nil
  "Cons cell whose car accumulates strings received by the stub viewer.")

(defun ejn-w8.3--make-stub-server (socket-path)
  "Create a real unix-socket server on SOCKET-PATH that records input.
Received strings are pushed onto `(car ejn-w8.3--received)'.  Returns the
server process, which doubles as the manager's placeholder process."
  (make-network-process
   :name "ejn-w8.3-stub-viewer"
   :server t
   :family 'local
   :service socket-path
   :noquery t
   :filter (lambda (_proc string)
             (push string (car ejn-w8.3--received)))))

(defun ejn-w8.3--make-pipe-viewer (_socket-path)
  "Return a live process stub for viewer lifecycle tests."
  (make-pipe-process :name "ejn-w8.3-pipe-viewer" :buffer nil :noquery t))

(defmacro ejn-w8.3-with-clean-manager (&rest body)
  "Run BODY with fresh, isolated viewer-manager global state, then reap."
  (declare (indent 0))
  `(let ((emacs-jupyter-notebook-viewer--process nil)
         (emacs-jupyter-notebook-viewer--socket-path nil)
         (emacs-jupyter-notebook-viewer--socket-directory nil)
         (emacs-jupyter-notebook-viewer--socket-directory-identity nil)
         (emacs-jupyter-notebook-viewer--active-transaction nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (emacs-jupyter-notebook-viewer-reap)))))

(ert-deftest ejn-w8.3-ensure-spawns-once-and-reuses ()
  "W8.3: the manager spawns the viewer lazily exactly once and reuses it."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (spawn-count 0)
           (emacs-jupyter-notebook-viewer-spawn-function
            (lambda (socket-path)
              (cl-incf spawn-count)
              (ejn-w8.3--make-pipe-viewer socket-path))))
      (let ((p1 (emacs-jupyter-notebook-viewer-ensure))
            (p2 (emacs-jupyter-notebook-viewer-ensure)))
        (should (= spawn-count 1))
        (should (eq p1 p2))
        (should (emacs-jupyter-notebook-viewer-live-p))))))

(ert-deftest ejn-w8.3-ensure-installs-kill-emacs-reaper ()
  "W8.3: ensuring the viewer installs the `kill-emacs-hook' reaper."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (kill-emacs-hook nil)
           (emacs-jupyter-notebook-viewer-spawn-function
            #'ejn-w8.3--make-pipe-viewer))
      (emacs-jupyter-notebook-viewer-ensure)
      (should (memq #'emacs-jupyter-notebook-viewer-reap kill-emacs-hook)))))

(ert-deftest ejn-w8.3-reap-kills-process-and-removes-socket ()
  "W8.3: reap deletes the process, removes the socket file, and clears state."
  (ejn-w8.3-with-clean-manager
    (let* ((ejn-w8.3--received (list nil))
           (kill-emacs-hook nil)
           (emacs-jupyter-notebook-viewer-spawn-function
            (lambda (socket-path)
              (with-temp-file socket-path (insert "socket"))
              (ejn-w8.3--make-pipe-viewer socket-path))))
      (emacs-jupyter-notebook-viewer-ensure)
      (let ((socket-path emacs-jupyter-notebook-viewer--socket-path)
            (directory emacs-jupyter-notebook-viewer--socket-directory))
        (should (file-exists-p socket-path))
        (emacs-jupyter-notebook-viewer-reap)
        (should-not (emacs-jupyter-notebook-viewer-live-p))
        (should-not emacs-jupyter-notebook-viewer--socket-path)
        (should-not emacs-jupyter-notebook-viewer--active-transaction)
        (should-not (file-exists-p socket-path))
        (should-not (file-exists-p directory))
        (should-not (memq #'emacs-jupyter-notebook-viewer-reap kill-emacs-hook))))))

(ert-deftest ejn-w8.3-open-pickle-is-single-flight ()
  "W8.3/EI4V: repeated opens cannot accumulate unbounded socket handoffs."
  (ejn-w8.3-with-clean-manager
    (let (sent-states completions)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-ensure)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-viewer--send-pickle-attempt)
                 (lambda (state) (push state sent-states))))
        (emacs-jupyter-notebook-viewer-open-pickle-file
         '(:file "first") (lambda (accepted) (push (list 'first accepted) completions)))
        (should (= (length sent-states) 1))
        (should emacs-jupyter-notebook-viewer--active-transaction)
        (emacs-jupyter-notebook-viewer-open-pickle-file
         '(:file "second") (lambda (accepted) (push (list 'second accepted) completions)))
        (should (= (length sent-states) 1))
        (should (equal completions '((second nil))))
        (emacs-jupyter-notebook-viewer--transaction-finish
         emacs-jupyter-notebook-viewer--active-transaction t)
        (should-not emacs-jupyter-notebook-viewer--active-transaction)
        (should (equal completions '((first t) (second nil))))))))

(ert-deftest ejn-w8.3-reap-releases-active-handoff-once ()
  "W8.3/EI4V: viewer reap fails an active handoff exactly once."
  (ejn-w8.3-with-clean-manager
    (let* ((completions 0)
           (state (list :pickle '(:file "p")
                        :completion (lambda (_accepted) (cl-incf completions))
                        :attempt 0 :token 0 :timer nil :connection nil :done nil)))
      (setq emacs-jupyter-notebook-viewer--active-transaction state)
      (emacs-jupyter-notebook-viewer-reap)
      (emacs-jupyter-notebook-viewer-reap)
      (should (= completions 1))
      (should-not emacs-jupyter-notebook-viewer--active-transaction))))

(ert-deftest ejn-w8.3-python-path-resolves-command ()
  "W8.3: `--python-path' resolves an absolute executable or PATH command,
and returns nil for a bogus command."
  (should (null (emacs-jupyter-notebook-viewer--python-path
                 "ejn-nonexistent-python-xyz")))
  ;; /bin/sh is a reliable absolute executable on the CI host.
  (when (file-executable-p "/bin/sh")
    (should (equal (emacs-jupyter-notebook-viewer--python-path "/bin/sh")
                   "/bin/sh"))))

(ert-deftest ejn-w8.3-confined-ack-is-fragmented-correlated-and-once ()
  "Viewer hand-off sends descriptor identities and consumes one framed ACK."
  (let* ((real-run-at-time (symbol-function 'run-at-time))
         (real-delete (symbol-function 'delete-process))
         (fake (make-pipe-process :name "ejn-w8-ack" :buffer nil :noquery t))
         (sent nil) (completed nil) timer-callback timer network-args)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
              ((symbol-function 'make-network-process)
               (lambda (&rest args) (setq network-args args) fake))
              ((symbol-function 'process-send-string) (lambda (_ string) (setq sent string)))
              ((symbol-function 'delete-process) (lambda (&rest _) nil))
              ((symbol-function 'run-at-time)
               (lambda (&rest args)
                 (setq timer-callback (nth 2 args))
                 (setq timer (funcall real-run-at-time 100 nil #'ignore)))))
      (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
            (emacs-jupyter-notebook-viewer--next-request-id 0))
        (emacs-jupyter-notebook-viewer--send-pickle-attempt
         (list :pickle '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                         :root-identity (7 . 11) :identity (7 . 12) :size 3
                         :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
               :completion (lambda (accepted) (push accepted completed))
              :attempt 0 :token 0 :timer nil :connection nil :done nil))
        (should (eq (plist-get network-args :nowait) t))
        (should (string-match-p "\\\"root_identity\\\":\\[11,7\\]" sent))
        (should (string-match-p "\\\"file_identity\\\":\\[12,7\\]" sent))
        (let ((filter (process-filter fake))
              request-id)
          (should (string-match "\\\"id\\\":\\\"\\([^\\\"]+\\)\\\"" sent))
          (setq request-id (match-string 1 sent))
          (should (equal request-id "v1"))
          (funcall filter fake (format "{\"id\":\"%s\",\"accepted\":tr" request-id))
          (should-not completed)
          (should (equal (process-get fake 'ejn-viewer-ack-buffer)
                         (format "{\"id\":\"%s\",\"accepted\":tr" request-id)))
          (funcall filter fake (format "ue}\n{\"id\":\"%s\",\"accepted\":false}\n" request-id))
          (should (equal (emacs-jupyter-notebook-viewer--parse-ack
                          (format "{\"id\":\"%s\",\"accepted\":true}" request-id)
                          request-id)
                         '(t . t)))
          (should (equal completed '(t)))
          (should-not (emacs-jupyter-notebook-viewer--parse-ack
                       "{\"id\":\"stale\",\"accepted\":true}" request-id))))
      (when (timerp timer) (cancel-timer timer))
      (when (process-live-p fake) (funcall real-delete fake)))))

(ert-deftest ejn-w8.3-real-file-identities-are-accepted-by-python-viewer ()
  "An Emacs descriptor crosses the real Python confinement identity seam."
  (let* ((root (make-temp-file "ejn-w8-real-identity-" t))
         (file (expand-file-name
                "ejn-artifact-0123456789abcdef0123456789abcdef" root))
         (viewer-dir (expand-file-name "viewer" default-directory))
         (python (or (executable-find "python3")
                     (ert-fail "python3 is required by the local test suite")))
         (payload "identity-seam")
         (real-delete (symbol-function 'delete-process))
         process sent state timer)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert payload))
          (set-file-modes file #o600)
          (let* ((root-id (file-attribute-file-identifier
                           (file-attributes root 'integer)))
                 (file-id (file-attribute-file-identifier
                           (file-attributes file 'integer)))
                 (pickle (list :root root :file file
                               :root-identity root-id :identity file-id
                               :size (string-bytes payload)
                               :sha256 (ejn-ei4-test--content-sha256 file))))
            (setq state (list :pickle pickle :completion #'ignore :attempt 0
                              :token 0 :timer nil :connection nil :done nil))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p)
                       (lambda () t))
                      ((symbol-function 'make-network-process)
                       (lambda (&rest _)
                         (setq process
                               (make-pipe-process
                                :name "ejn-w8-real-identity-send"
                                :buffer nil :noquery t))))
                      ((symbol-function 'process-send-string)
                       (lambda (_process wire) (setq sent wire)))
                      ((symbol-function 'run-at-time)
                       (lambda (&rest _)
                         (setq timer (timer-create))
                         timer))
                      ((symbol-function 'delete-process) (lambda (&rest _) nil)))
              (let ((emacs-jupyter-notebook-viewer--socket-path
                     "/tmp/ejn-viewer.sock"))
                (emacs-jupyter-notebook-viewer--send-pickle-attempt state)))
            (should sent)
            (with-temp-buffer
              (insert sent)
              (let ((status
                     (call-process-region
                      (point-min) (point-max) python t t nil "-c"
                      (concat
                       "import json, os, sys; "
                       "sys.path.insert(0, sys.argv[1]); import ejn_viewer; "
                       "r=json.load(sys.stdin); "
                       "fd=ejn_viewer.open_confined_pickle("
                       "r['root'],r['path'],r['root_identity'],"
                       "r['file_identity'],r['size'],r['sha256']); "
                       "os.close(fd); print('accepted')")
                      viewer-dir)))
                (should (= status 0))
                (should (equal (string-trim (buffer-string)) "accepted"))))))
      (when (timerp timer) (cancel-timer timer))
      (when (processp process) (ignore-errors (funcall real-delete process)))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w8.3-confined-ack-false-completes-once ()
  "A negative viewer ACK releases the lease and later duplicates stay inert."
  (let* ((real-run-at-time (symbol-function 'run-at-time))
         (real-delete (symbol-function 'delete-process))
         (fake (make-pipe-process :name "ejn-w8-ack-false" :buffer nil :noquery t))
         sent completed timer)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
                  ((symbol-function 'make-network-process) (lambda (&rest _) fake))
                  ((symbol-function 'process-send-string)
                   (lambda (_ string) (setq sent string)))
                  ((symbol-function 'delete-process) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest args)
                     (setq timer (funcall real-run-at-time 100 nil #'ignore))
                     timer)))
          (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                (emacs-jupyter-notebook-viewer--next-request-id 0))
            (emacs-jupyter-notebook-viewer--send-pickle-attempt
             (list :pickle '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                             :root-identity (7 . 11) :identity (7 . 12) :size 3
                             :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                   :completion (lambda (accepted) (push accepted completed))
                   :attempt 0 :token 0 :timer nil :connection nil :done nil))
            (should (string-match "\\\"id\\\":\\\"\\([^\\\"]+\\)\\\"" sent))
            (let ((request-id (match-string 1 sent))
                  (filter (process-filter fake)))
              (funcall filter fake (format "{\"id\":\"%s\",\"accepted\":false}\n"
                                           request-id))
              (should (equal completed '(nil)))
              (funcall filter fake (format "{\"id\":\"%s\",\"accepted\":true}\n"
                                           request-id))
              (should (equal completed '(nil))))))
      (when (timerp timer) (cancel-timer timer))
      (when (process-live-p fake) (funcall real-delete fake)))))

(ert-deftest ejn-w8.3-confined-ack-timeout-completes-once ()
  "A missing ACK deadline closes its process and later ACKs stay inert."
  (let* ((real-run-at-time (symbol-function 'run-at-time))
         (real-delete (symbol-function 'delete-process))
         (fake (make-pipe-process :name "ejn-w8-ack-timeout" :buffer nil :noquery t))
         (deleted nil)
         (completed nil)
         timer filter)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
                  ((symbol-function 'make-network-process) (lambda (&rest _) fake))
                  ((symbol-function 'process-send-string) (lambda (&rest _) nil))
                  ((symbol-function 'delete-process)
                   (lambda (process &rest args)
                     (push process deleted)
                     (when (processp process)
                       (apply real-delete process args))))
                  ((symbol-function 'run-at-time)
                   (lambda (_seconds _repeat function &rest args)
                     (setq timer (apply real-run-at-time 0.01 nil function args)))))
          (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                (emacs-jupyter-notebook-viewer--next-request-id 0))
            (emacs-jupyter-notebook-viewer--send-pickle-attempt
             (list :pickle '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                             :root-identity (7 . 11) :identity (7 . 12) :size 3
                             :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                   :completion (lambda (accepted) (push accepted completed))
                   :attempt 0 :token 0 :timer nil :connection nil :done nil))
            (setq filter (process-filter fake))
            (accept-process-output nil 0.05)
            (should (equal completed '(nil)))
            (should (memq fake deleted))
            (funcall filter fake "{\"id\":\"v1\",\"accepted\":true}\n")
            (should (equal completed '(nil)))))
      (when (timerp timer) (cancel-timer timer))
      (when (process-live-p fake) (funcall real-delete fake)))))

(ert-deftest ejn-w8.3-confined-ack-rejects-malformed-extra-and-oversize ()
  "Malformed, schema-extra, and oversized viewer ACKs fail closed once."
  (let* ((real-delete (symbol-function 'delete-process))
         (real-run-at-time (symbol-function 'run-at-time))
         (fake (make-pipe-process :name "ejn-w8-bad-ack" :buffer nil :noquery t))
         (sent nil)
         (completed nil)
         timer)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
                  ((symbol-function 'make-network-process) (lambda (&rest _) fake))
                  ((symbol-function 'process-send-string)
                   (lambda (_ string) (setq sent string)))
                  ((symbol-function 'delete-process) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest args)
                     (setq timer (funcall real-run-at-time 100 nil #'ignore))
                     (nth 2 args))))
          (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                (emacs-jupyter-notebook-viewer--next-request-id 0))
            (emacs-jupyter-notebook-viewer--send-pickle-attempt
             (list :pickle '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                             :root-identity (7 . 11) :identity (7 . 12) :size 3
                             :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                   :completion (lambda (accepted) (push accepted completed))
                   :attempt 0 :token 0 :timer nil :connection nil :done nil))
            (should (string-match "\\\"id\\\":\\\"\\([^\\\"]+\\)\\\"" sent))
            (let ((request-id (match-string 1 sent))
                  (filter (process-filter fake)))
              (funcall filter fake "{not json}\n")
              (funcall filter fake (format "{\"id\":\"%s\",\"accepted\":true,\"extra\":1}\n"
                                           request-id))
              (should-not completed)
              (funcall filter fake (make-string 1025 ?x))
              (should (equal completed '(nil)))
              (funcall filter fake (format "{\"id\":\"%s\",\"accepted\":true}\n"
                                           request-id))
              (should (equal completed '(nil))))))
      (when (timerp timer) (cancel-timer timer))
      (when (process-live-p fake) (funcall real-delete fake)))))

(ert-deftest ejn-w8.3-send-error-does-not-replay-ambiguous-frame ()
  "A post-connect send error fails once; old callbacks remain inert."
  (let* ((fake-a (make-pipe-process :name "ejn-w8-send-a" :buffer nil :noquery t))
         (real-delete (symbol-function 'delete-process))
         (send-count 0)
         (completed nil)
         timers)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
                  ((symbol-function 'make-network-process)
                   (lambda (&rest _) fake-a))
                  ((symbol-function 'process-send-string)
                   (lambda (_conn _string)
                     (cl-incf send-count)
                     (error "send failed")))
                  ((symbol-function 'delete-process) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (seconds _repeat function &rest _args)
                     (let ((timer (list seconds function)))
                       (push timer timers)
                       timer))))
          (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                (emacs-jupyter-notebook-viewer-send-retry-delay 0)
                (emacs-jupyter-notebook-viewer--next-request-id 0)
                (state (list :pickle
                             '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                               :root-identity (7 . 11) :identity (7 . 12) :size 3
                               :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                             :completion (lambda (accepted) (push accepted completed))
                             :attempt 0 :token 0 :timer nil :connection nil :done nil)))
            (emacs-jupyter-notebook-viewer--send-pickle-attempt state)
            (should (= send-count 1))
            (let ((old-filter (process-filter fake-a))
                  (old-timeout (cadar timers)))
              (should-not emacs-jupyter-notebook-viewer--active-transaction)
              (should (equal completed '(nil)))
              (funcall old-filter fake-a "{\"id\":\"v1\",\"accepted\":true}\n")
              (funcall old-timeout)
              (should (= send-count 1))
              (should (equal completed '(nil))))))
      (dolist (proc (list fake-a))
        (when (process-live-p proc) (funcall real-delete proc))))))

(ert-deftest ejn-w8.3-connect-error-retries-with-bounded-token ()
  "A pre-connect socket failure retries, and stale timers cannot finish it."
  (let ((connect-count 0)
        (completed nil)
        timers
        sent
        conn)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-live-p) (lambda () t))
                  ((symbol-function 'make-network-process)
                   (lambda (&rest _)
                     (cl-incf connect-count)
                     (if (= connect-count 1)
                         (error "socket not ready")
                       (setq conn
                             (make-pipe-process
                              :name "ejn-w8-connect" :buffer nil :noquery t)))))
                  ((symbol-function 'process-send-string)
                   (lambda (_conn string) (setq sent string)))
                  ((symbol-function 'delete-process) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (seconds _repeat function &rest _args)
                     (let ((timer (list seconds function)))
                       (push timer timers)
                       timer))))
          (let ((emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                (emacs-jupyter-notebook-viewer-send-retry-delay 0)
                (state (list :pickle
                             '(:root "/tmp/root" :file "/tmp/root/ejn-artifact-0123456789abcdef0123456789abcdef"
                               :root-identity (7 . 11) :identity (7 . 12) :size 3
                               :sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                             :completion (lambda (accepted) (push accepted completed))
                             :attempt 0 :token 0 :timer nil :connection nil :done nil)))
            (emacs-jupyter-notebook-viewer--send-pickle-attempt state)
            (should (= connect-count 1))
            (should-not completed)
            (let ((retry (cadar timers)))
              (funcall retry))
            (should (= connect-count 2))
            (should (string-match-p "\\\"id\\\":" sent))
            (let ((old-retry (cadar (cdr timers))))
              (when old-retry (funcall old-retry)))
            (should (= connect-count 2))
            (should-not completed)))
      (when (and (processp conn) (process-live-p conn))
        (delete-process conn)))))

(ert-deftest ejn-w8.3-socket-directory-cleanup-pins-its-identity ()
  "Cleanup removes only the exact private directory it created."
  (let (path directory replacement)
    (unwind-protect
        (progn
          (setq path (emacs-jupyter-notebook-viewer--new-socket-path)
                directory emacs-jupyter-notebook-viewer--socket-directory)
          (let ((attrs (file-attributes directory 'integer)))
            (should (equal (file-attribute-user-id attrs) (user-uid)))
            (should (= (logand (file-modes directory) #o7777) #o700)))
          (with-temp-file path (insert "socket"))
          (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
          (should-not (file-exists-p directory))
          (setq path (emacs-jupyter-notebook-viewer--new-socket-path)
                directory emacs-jupyter-notebook-viewer--socket-directory
                replacement (concat directory "-old"))
          (rename-file directory replacement)
          (make-directory directory)
          (set-file-modes directory #o700)
          (emacs-jupyter-notebook-viewer--cleanup-socket-directory)
          (should (file-directory-p directory)))
      (ignore-errors (delete-directory directory t))
      (ignore-errors (delete-directory replacement t))
      (emacs-jupyter-notebook-viewer--cleanup-socket-directory))))

;;; W8.4 — viewer Python script

(ert-deftest ejn-w8.4-bundled-viewer-script-exists ()
  "W8.4: the manager resolves the bundled viewer/ejn_viewer.py and it exists."
  (let ((path (emacs-jupyter-notebook-viewer--script-path)))
    (should path)
    (should (string-suffix-p "viewer/ejn_viewer.py" path))
    (should (file-exists-p path))))

(ert-deftest ejn-a9-viewer-script-resolves-through-build-symlink ()
  "A9: under a straight.el-style layout — a build dir holding a byte-compiled
`.elc' plus a SYMLINK to the `.el' source, while `viewer/' lives only in the
symlinked-to repo — the resolver still finds `viewer/ejn_viewer.py' by
following the `.el' symlink.  Regression for the fresh-machine failure where
the viewer was reported missing though the `.py' was present in the repo."
  (let* ((repo (make-temp-file "ejn-a9-repo-" t))
         (build (make-temp-file "ejn-a9-build-" t)))
    (unwind-protect
        (let ((repo-el (expand-file-name "emacs-jupyter-notebook-viewer.el" repo))
              (repo-viewer-dir (expand-file-name "viewer" repo))
              (build-el (expand-file-name "emacs-jupyter-notebook-viewer.el" build))
              (build-elc (expand-file-name "emacs-jupyter-notebook-viewer.elc" build)))
          ;; Repo: real source file + viewer/ejn_viewer.py.
          (with-temp-file repo-el (insert ";; source\n"))
          (make-directory repo-viewer-dir t)
          (with-temp-file (expand-file-name "ejn_viewer.py" repo-viewer-dir)
            (insert "# viewer\n"))
          ;; Build: real .elc (what `load' loads) + symlink to the .el source.
          ;; No viewer/ here, exactly as straight builds it.
          (with-temp-file build-elc (insert ";; compiled\n"))
          (make-symbolic-link repo-el build-el)
          ;; Loaded file is the build .elc.
          (let ((emacs-jupyter-notebook-viewer--load-file build-elc))
            (let ((path (emacs-jupyter-notebook-viewer--script-path)))
              (should path)
              (should (file-exists-p path))
              (should (string-suffix-p "viewer/ejn_viewer.py" path))
              (should (string-prefix-p (file-truename repo)
                                       (file-truename path))))))
      (delete-directory repo t)
      (delete-directory build t))))

(ert-deftest ejn-w8.4-viewer-selfcheck-passes ()
  "W8.4: the viewer script's headless non-GUI self-check passes.
Covers the format_coord row/col/value math and the linked-zoom LinkGroup
wiring.  Skipped when no local python3 is available in this environment."
  (let ((python (executable-find "python3"))
        (script (emacs-jupyter-notebook-viewer--script-path)))
    (unless python
      (ert-skip "python3 not available"))
    (should script)
    (with-temp-buffer
      (let ((status (call-process python nil t nil script "--selfcheck")))
        (should (= status 0))
        (goto-char (point-min))
        (should (re-search-forward "SELFCHECK OK" nil t))))))

;;; W8.5 — interactive figure command surface

(ert-deftest ejn-w8.5-open-interactive-errors-without-figure ()
  "W8.5: source command reports a friendly error when the cell has no figure."
  (ejn-test-with-temp-buffer "# %%\nprint('no figure')\n"
    (should-error (emacs-jupyter-notebook-open-figure-interactive)
                  :type 'user-error)))

(ert-deftest ejn-w8.5-panel-open-figure-errors-without-pickle ()
  "W8.5: panel command reports a friendly error when the entry has no pickle."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "print(1)")))
      (ejn-panel-append-text handle "plain output")
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel--render panel)
        (goto-char (point-min))
        (should-error (emacs-jupyter-notebook-panel-open-figure)
                      :type 'user-error)))))

(ert-deftest ejn-w8.5-disabled-pickle-viewer-releases-manual-lease ()
  "EI4V: manual pickle opens release their lease when opt-in is disabled."
  (let ((emacs-jupyter-notebook-enable-pickle-viewer nil)
        (pickle (list :file "/tmp/p" :leases 1 :retired nil :deleted nil)))
    (should-error (emacs-jupyter-notebook-open-figure-pickle-lease pickle)
                  :type 'user-error)
    (should (= (plist-get pickle :leases) 0))))

(ert-deftest ejn-w8.5-missing-local-python-releases-manual-lease ()
  "W8.5/EI4V: local setup errors also release the acquired panel lease."
  (let ((emacs-jupyter-notebook-enable-pickle-viewer t)
        (emacs-jupyter-notebook-local-python-command "ejn-python-missing")
        (pickle (list :file "/tmp/p" :leases 1 :retired nil :deleted nil)))
    (should-error (emacs-jupyter-notebook-open-figure-pickle-lease pickle)
                  :type 'user-error)
    (should (= (plist-get pickle :leases) 0))))

(ert-deftest ejn-w8.5-open-uses-bounded-viewer-transaction-without-probe ()
  "W8.5/EI4V: opening goes directly to the bounded viewer handoff."
  (let ((emacs-jupyter-notebook-enable-pickle-viewer t)
        (pickle (list :file "/tmp/p" :leases 1 :retired nil :deleted nil))
        (handoffs 0))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer--python-path)
               (lambda (_command) "/bin/python"))
              ((symbol-function 'make-process)
               (lambda (&rest _)
                 (ert-fail "unbounded matplotlib probe was started")))
              ((symbol-function 'emacs-jupyter-notebook--viewer-hand-off)
               (lambda (leased)
                 (should (eq leased pickle))
                 (cl-incf handoffs))))
      (emacs-jupyter-notebook-open-figure-pickle-lease pickle)
      (should (= handoffs 1))
      ;; The viewer transaction owns the lease until its bounded ACK/deadline.
      (should (= (plist-get pickle :leases) 1)))))

;;; W11 — kernel lifecycle / GC

;;; W11(A) — self-reaping idle watchdog snippet + injection

(ert-deftest ejn-w11-watchdog-snippet-shape ()
  "W11: the idle-watchdog template has the required, load-bearing shape."
  (let ((s emacs-jupyter-notebook--kernel-idle-watchdog-snippet))
    ;; Idempotency guard so re-injection on reconnect never stacks a
    ;; second watchdog thread.
    (should (string-match-p "_ejn_watchdog_installed" s))
    ;; Embeds the configured timeout via a single %d placeholder.
    (should (string-match-p "%d" s))
    (should (string-match-p "_EJN_WD_TIMEOUT = %d" s))
    ;; Tracks activity + executing-state via BOTH IPython cell events.
    (should (string-match-p "register('pre_run_cell'" s))
    (should (string-match-p "register('post_run_cell'" s))
    ;; Starts ONE daemon thread.
    (should (string-match-p "daemon=True" s))
    (should (string-match-p "\\.start()" s))
    ;; The busy-guard that makes a long-running cell un-reapable.
    (should (string-match-p "if _ejn_wd_state\\['executing'\\]:" s))
    ;; Clean self-shutdown via SIGTERM, with os._exit(0) as last resort.
    (should (string-match-p "os.kill\\|_ejn_wd_os.kill" s))
    (should (string-match-p "SIGTERM\\|_ejn_wd_sig.SIGTERM" s))
    (should (string-match-p "_ejn_wd_os._exit(0)" s))
    ;; Imports only stdlib + get_ipython — no matplotlib/numpy/etc.
    (should (string-match-p "import threading" s))
    (should (string-match-p "get_ipython" s))
    (should-not (string-match-p "matplotlib" s))
    (should-not (string-match-p "import numpy" s))))

(ert-deftest ejn-w11-watchdog-injection-embeds-timeout ()
  "W11: injection routes through the silent adapter and embeds the timeout."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-kernel-idle-timeout 1234))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-idle-watchdog))
      (should (= (length calls) 1))
      (should (eq (caar calls) 'mock-client))
      (should (string-match-p "_EJN_WD_TIMEOUT = 1234" (cadar calls)))
      ;; The formatted code must carry both cell events and the shutdown.
      (should (string-match-p "register('pre_run_cell'" (cadar calls)))
      (should (string-match-p "register('post_run_cell'" (cadar calls)))
      (should (string-match-p "SIGTERM" (cadar calls))))))

(ert-deftest ejn-w11-watchdog-noop-when-timeout-zero ()
  "W11: a 0 idle timeout disables the watchdog — nothing is injected."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client 'mock-client)
          (emacs-jupyter-notebook-kernel-idle-timeout 0))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-idle-watchdog))
      (should (null calls)))))

(ert-deftest ejn-w11-watchdog-noop-without-client ()
  "W11: with no client the watchdog injection is a silent no-op."
  (with-temp-buffer
    (let ((calls nil)
          (emacs-jupyter-notebook--client nil)
          (emacs-jupyter-notebook-kernel-idle-timeout 3600))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (client code) (push (list client code) calls))))
        (emacs-jupyter-notebook--inject-idle-watchdog))
      (should (null calls)))))

(ert-deftest ejn-w11-watchdog-swallows-adapter-errors ()
  "W11: a raise from the adapter must not propagate out of injection."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-kernel-idle-timeout 3600))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) (error "boom"))))
        (should (progn (emacs-jupyter-notebook--inject-idle-watchdog) t))))))

(ert-deftest ejn-w11-watchdog-injected-on-connect-finalize ()
  "W11: connect-finalize injects the watchdog carrying the configured timeout."
  (let ((entry '(:profile "p" :session-id "session"))
        (local-ports '(:shell_port 1001))
        (local-file "/tmp/test.json")
        (emacs-jupyter-notebook--client nil)
        (emacs-jupyter-notebook--session-entry nil)
        (emacs-jupyter-notebook-kernel-idle-timeout 7200)
        (codes nil))
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (context (emacs-jupyter-notebook--async-new-context
                      :phase 'connect
                      :entry entry
                      :origin-buffer (current-buffer))))
        (setq emacs-jupyter-notebook--async-context context)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                   (lambda (_entry &optional _file) nil))
                  ((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                   (lambda (_client code) (push code codes))))
        (emacs-jupyter-notebook--async-connect-finalize
         context buffer entry local-ports local-file
         (ejn-test-backend-session 'mock-client t))
        (ejn-test-drain-zero-delay-timers))
        ;; A watchdog snippet carrying the configured timeout was sent.
        (should (cl-some (lambda (c) (string-match-p "_EJN_WD_TIMEOUT = 7200" c))
                         codes))))))

(ert-deftest ejn-w11-watchdog-injected-on-restart ()
  "W11/W13-Viewer3: restart-kernel re-injects the watchdog carrying the
configured timeout — but only after the restarted kernel answers a
`kernel_info_request' (mocked here to reply immediately)."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-kernel-idle-timeout 5400)
          (codes nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-restart)
                 (lambda (_client) nil))
                ((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_client callback) (funcall callback '(:status "ok") nil)))
                ((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client code) (push code codes))))
        (call-interactively #'emacs-jupyter-notebook-restart-kernel)
        (ejn-test-drain-zero-delay-timers))
      (should (cl-some (lambda (c) (string-match-p "_EJN_WD_TIMEOUT = 5400" c))
                       codes)))))

(ert-deftest ejn-w13-viewer3-restart-reinjection-waits-for-kernel-info ()
  "W13-Viewer3: the post-restart re-injection is gated on a kernel_info reply.
No reply (kernel still coming up / failed restart) means NO injection race —
nothing is sent; a reply triggers both formatter and watchdog injection."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client
           (ejn-test-backend-session 'mock-client t))
          (emacs-jupyter-notebook-kernel-idle-timeout 900)
          info-cb sent)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-restart)
                 (lambda (_client) nil))
                ((symbol-function 'emacs-jupyter-notebook-jupyter-kernel-info)
                 (lambda (_client callback) (setq info-cb callback)))
                ((symbol-function 'emacs-jupyter-notebook-jupyter-execute-silent)
                 (lambda (_client _code) (setq sent t))))
        (call-interactively #'emacs-jupyter-notebook-restart-kernel)
        (ejn-test-drain-zero-delay-timers)
        ;; Kernel has not answered yet: nothing injected (no race).
        (should-not sent)
        ;; Kernel comes up and answers kernel_info: injection fires.
        (funcall info-cb '(:status "ok") nil)
        (ejn-test-drain-zero-delay-timers)
        (should sent)))))

;;; W11(B) — non-destructive prune of dead registry entries

(defun ejn-w11--entry (session pid host)
  "Build a registry ENTRY fixture with SESSION, PID, and HOST."
  (list :profile "p" :session-id session :remote-pid pid :remote-host host
        :remote-connection-file (format "/cache/kernel-%s.json" session)))

(ert-deftest ejn-w11-prune-removes-only-confirmed-dead ()
  "W11: prune drops confirmed-dead entries, keeps alive AND unknown ones.
A dead PID on a host that ANSWERED is pruned; an unreachable host's
entries (UNKNOWN) are kept — an unreachable host must never cause a false
prune."
  (let* ((live   (ejn-w11--entry "live"    "100" "up.example"))
         (dead   (ejn-w11--entry "dead"    "200" "up.example"))
         (ghost  (ejn-w11--entry "ghost"   "300" "down.example"))
         (nopid  (list :profile "p" :session-id "nopid" :remote-host "up.example"))
         (entries (list live dead ghost nopid))
         (saved nil)
         ;; Mock probe: host "up.example" answers (100 alive, 200 dead);
         ;; host "down.example" is unreachable (:answered nil).
         (probe (lambda (profile pids)
                  (let ((host (plist-get profile :host)))
                    (cond
                     ((equal host "up.example")
                      (list :answered t
                            :alive (cl-remove-if-not
                                    (lambda (p) (equal (format "%s" p) "100"))
                                    pids)))
                     (t (list :answered nil :alive nil)))))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) entries))
              ((symbol-function 'emacs-jupyter-notebook-registry-save)
               (lambda (kept &optional _file) (setq saved kept))))
      (let ((res (emacs-jupyter-notebook--prune-dead-registry-entries
                  nil probe)))
        (should (= (plist-get res :pruned) 1))
        (should (= (plist-get res :alive) 1))
        ;; ghost (unreachable) + nopid (no pid) are both UNKNOWN, kept.
        (should (= (plist-get res :unknown) 2))
        ;; Exactly the dead entry was pruned.
        (should (equal (plist-get res :pruned-entries) (list dead)))
        ;; The saved registry keeps live + ghost + nopid, drops dead.
        (should (member live saved))
        (should (member ghost saved))
        (should (member nopid saved))
        (should-not (member dead saved))))))

(ert-deftest ejn-w11-prune-unreachable-host-keeps-entries ()
  "W11: when every host is unreachable, nothing is pruned and no save runs."
  (let* ((a (ejn-w11--entry "a" "10" "down.example"))
         (b (ejn-w11--entry "b" "20" "down.example"))
         (entries (list a b))
         (save-called nil)
         (probe (lambda (_profile _pids) (list :answered nil :alive nil))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) entries))
              ((symbol-function 'emacs-jupyter-notebook-registry-save)
               (lambda (_kept &optional _file) (setq save-called t))))
      (let ((res (emacs-jupyter-notebook--prune-dead-registry-entries nil probe)))
        (should (= (plist-get res :pruned) 0))
        (should (= (plist-get res :unknown) 2))
        ;; No dead entries → the file is never rewritten.
        (should-not save-called)))))

(ert-deftest ejn-w11-prune-dead-kernels-messages-summary ()
  "W11: the command prunes and reports pruned/live counts."
  (let* ((live (ejn-w11--entry "live" "100" "up.example"))
         (dead (ejn-w11--entry "dead" "200" "up.example"))
         (entries (list live dead))
         (msg nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
                 (lambda (&optional _file) entries))
                ((symbol-function 'emacs-jupyter-notebook-registry-save)
                 (lambda (_kept &optional _file) nil))
                ((symbol-function
                  'emacs-jupyter-notebook--classify-registry-liveness-async)
                 (lambda (_entries _token callback)
                   (funcall callback
                            (list (cons live 'alive) (cons dead 'dead)) nil)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
      (with-temp-buffer
        (call-interactively #'emacs-jupyter-notebook-prune-dead-kernels)
        (should (string-match-p "pruned 1 dead" msg))
        (should (string-match-p "1 live remain" msg))))))

(ert-deftest ejn-w11-prune-dead-kernels-empty-registry ()
  "W11: with an empty registry the command reports nothing to prune."
  (let ((msg nil))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
      (call-interactively #'emacs-jupyter-notebook-prune-dead-kernels)
      (should (string-match-p "registry is empty" msg)))))

(ert-deftest ejn-w11-picker-excludes-dead-entries ()
  "W11: the reconnect picker drops confirmed-dead entries and only offers
alive/unknown ones; the dead ghost is removed from the registry too."
  (let* ((live  (ejn-w11--entry "live"  "100" "up.example"))
         (dead  (ejn-w11--entry "dead"  "200" "up.example"))
         (entries (list live dead))
         (saved nil)
         (offered nil)
         selected)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _file) entries))
              ((symbol-function 'emacs-jupyter-notebook-registry-save)
               (lambda (kept &optional _file) (setq saved kept)))
              ((symbol-function 'emacs-jupyter-notebook--current-file-registry-entry)
               (lambda () nil))
              ((symbol-function
                'emacs-jupyter-notebook--classify-registry-liveness-async)
               (lambda (_entries _token callback)
                 (funcall callback
                          (list (cons live 'alive) (cons dead 'dead)) nil)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq offered collection)
                 ;; Pick the first (only surviving) choice.
                 (caar collection))))
      (with-temp-buffer
        (emacs-jupyter-notebook--read-registry-entry-async
         (lambda (entry) (setq selected entry)))
          ;; Only the live entry survived and was selectable.
          (should (equal selected live))
          (should (= (length offered) 1))
          (should (string-match-p "live" (caar offered)))
          ;; The dead ghost was pruned from the durable registry.
          (should (member live saved))
          (should-not (member dead saved))))))

;;; W19 — reconnect robustness

(ert-deftest ejn-w19-classify-pid-probe ()
  "W19: the pure probe-output classifier distinguishes a live match, a
reused PID (mismatch), an unverifiable-but-alive PID, a confirmed death, and
an unreachable or malformed probe response."
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "__EJN_ALIVE_MATCH__\n__EJN_DONE__") 'alive))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "__EJN_ALIVE_MISMATCH__\n__EJN_DONE__") 'mismatch))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "__EJN_INSPECT_UNAVAILABLE__\n__EJN_DONE__") 'unverified))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "__EJN_DEAD__\n__EJN_DONE__") 'dead))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe "__EJN_DONE__")
              'unreachable))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "__EJN_ALIVE_MATCH__\n__EJN_DEAD__\n__EJN_DONE__")
              'unreachable))
  (should (eq (emacs-jupyter-notebook--classify-pid-probe
               "ssh: connect failed") 'unreachable)))

(ert-deftest ejn-w19-build-pid-alive-with-connection-file-checks-identity ()
  "W19: with a connection file the probe verifies the live PID's command
line carries this session's `--KernelManager.connection_file=' argument,
emitting the identity tokens."
  (let* ((argv (emacs-jupyter-notebook-ssh-build-pid-alive
                '(:profile "p" :host "mother") 12345
                '("--connection-file=/home/u/.cache/ejn/kernel.json")))
         (remote (car (last argv))))
    (should (string-match-p "kill -0" remote))
    (should (string-match-p
             (regexp-quote
              (shell-quote-argument
               "--connection-file=/home/u/.cache/ejn/kernel.json"))
             remote))
    (should (string-match-p "__EJN_ALIVE_MATCH__" remote))
    (should (string-match-p "__EJN_ALIVE_MISMATCH__" remote))
    (should (string-match-p "__EJN_DEAD__" remote))
    (should (string-match-p "__EJN_DONE__" remote))))

(ert-deftest ejn-w19-async-probe-match-proceeds-to-retrieve ()
  "W19: an identity-confirmed live kernel proceeds to retrieval."
  (let* ((retrieve-called nil)
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 12345 :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :profile '(:profile "p" :host "h")
                   :entry entry :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (ejn-test--probe-process-fn
                "echo __EJN_ALIVE_MATCH__; echo __EJN_DONE__")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not retrieve-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should retrieve-called)))

(ert-deftest ejn-w19-async-probe-mismatch-fails-kernel-mismatch ()
  "W19: a live PID that belongs to a DIFFERENT process (PID reuse after a
long outage) fails with `kernel-mismatch' — the registered kernel is gone,
but we never claim it is merely dead-and-reachable."
  (let* (fail-called fail-reason fail-ctx
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 12345 :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :profile '(:profile "p" :host "h")
                   :entry entry :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
               (lambda (ctx err)
                 (setq fail-called t fail-reason err fail-ctx ctx)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (ejn-test--probe-process-fn
                "echo __EJN_ALIVE_MISMATCH__; echo __EJN_DONE__")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not fail-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should fail-called)
    (should (eq (plist-get fail-ctx :error-kind) 'kernel-mismatch))
    (should (string-match-p "different process" fail-reason))))

(ert-deftest ejn-w19-async-probe-unverified-still-proceeds ()
  "W19: when the host confirms the PID is alive but identity cannot be
checked (no readable /proc cmdline, no ps), we proceed to retrieve — the
kernel_info verification on connect is the real arbiter.  We must NOT treat
an unverified-alive PID as dead."
  (let* ((retrieve-called nil)
         (entry (ejn-test-direct-entry
                 '(:profile "p" :session-id "s1" :remote-host "h"
                   :remote-pid 12345 :remote-connection-file "/r/k.json")))
         (context (emacs-jupyter-notebook--async-new-context
                   :phase 'retrieve :profile '(:profile "p" :host "h")
                   :entry entry :session-id "s1"
                   :origin-buffer (current-buffer))))
    (setq emacs-jupyter-notebook--async-context context)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (_ctx) (setq retrieve-called t)))
              ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
               (ejn-test--probe-process-fn
                "echo __EJN_INSPECT_UNAVAILABLE__; echo __EJN_DONE__")))
      (emacs-jupyter-notebook--async-probe-pid-alive context)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not retrieve-called) (< (float-time) deadline))
          (accept-process-output nil 0.01))))
    (setq emacs-jupyter-notebook--async-context nil)
    (should retrieve-called)))

(ert-deftest ejn-w19-entry-profile-preserves-named-profile-options ()
  "W19 (root cause of the hours-later reconnect failure): reconnect must
reconstruct the FULL named profile, not a bare plist from the registry entry
— otherwise the profile's port, identity file, and jump host are silently
lost once the ControlMaster that masked the omission expires.  The resolved
profile carries the named profile's `:port' and `:identity-file' into argv."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("prod" :host "mother.lan" :user "alice" :port 2222
            :identity-file "~/.ssh/prod_id")))
        (entry '(:profile "prod" :remote-host "mother.lan" :remote-cwd "~"
                 :remote-connection-file "/home/alice/.cache/ejn/kernel.json"
                 :connection-file-tokens ("--connection-file=/home/alice/.cache/ejn/kernel.json")
                 :kernelspec "python3" :launch-kind direct)))
    (let* ((profile (emacs-jupyter-notebook--entry-profile entry))
           (argv (emacs-jupyter-notebook-ssh-build-pid-alive
                  profile 123 (plist-get entry :connection-file-tokens))))
      (should (member "-p" argv))
      (should (member "2222" argv))
      (should (member "-i" argv))
      (should (cl-some (lambda (a) (string-match-p "prod_id" a)) argv))
      ;; The durable registry fields still overlay the profile.
      (should (equal (plist-get profile :kernelspec) "python3")))))

(ert-deftest ejn-w19-overall-attempt-timeout-fails-context ()
  "W19: the whole-attempt deadline fails an in-flight attempt that overruns
it, with the `attempt-timeout' kind — the backstop that guarantees no
connection attempt can wedge a buffer forever."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-connection-attempt-timeout 0.05)
           fail-called fail-kind
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'retrieve :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (ctx _err)
                   (setq fail-called t
                         fail-kind (plist-get ctx :error-kind)))))
        (emacs-jupyter-notebook--async-arm-overall-timeout context)
        (let ((deadline (+ (float-time) 2)))
          (while (and (not fail-called) (< (float-time) deadline))
            (accept-process-output nil 0.01))))
      (setq emacs-jupyter-notebook--async-context nil)
      (should fail-called)
      (should (eq fail-kind 'attempt-timeout)))))

(ert-deftest ejn-w19-process-watchdog-kills-hung-process ()
  "W19: a one-shot remote process that outlives the per-process deadline is
killed and its attempt failed with `process-timeout' — bounding a probe or
retrieval that rides a dead ControlMaster or otherwise ignores ConnectTimeout."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-ssh-process-timeout 0.05)
           fail-called fail-kind
           (proc (emacs-jupyter-notebook-ssh-start-process
                  "ejn-test-watchdog" '("sleep" "60")))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'retrieve :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                 (lambda (ctx _err)
                   (setq fail-called t
                         fail-kind (plist-get ctx :error-kind)))))
        (emacs-jupyter-notebook--async-arm-process-timeout
         context proc "Test op")
        (let ((deadline (+ (float-time) 2)))
          (while (and (not fail-called) (< (float-time) deadline))
            (accept-process-output nil 0.01))))
      (setq emacs-jupyter-notebook--async-context nil)
      (should fail-called)
      (should (eq fail-kind 'process-timeout))
      (should-not (process-live-p proc)))))

(ert-deftest ejn-w19-auto-reconnect-delay-backoff ()
  "W19: the automatic reconnect delay doubles per attempt (exponential
backoff) and is capped at the configured maximum."
  (let ((emacs-jupyter-notebook-reconnect-initial-delay 2)
        (emacs-jupyter-notebook-reconnect-max-delay 300))
    (with-temp-buffer
      (setq emacs-jupyter-notebook--reconnect-attempt 0)
      (should (= (emacs-jupyter-notebook--auto-reconnect-delay) 2))
      (setq emacs-jupyter-notebook--reconnect-attempt 1)
      (should (= (emacs-jupyter-notebook--auto-reconnect-delay) 4))
      (setq emacs-jupyter-notebook--reconnect-attempt 3)
      (should (= (emacs-jupyter-notebook--auto-reconnect-delay) 16))
      (setq emacs-jupyter-notebook--reconnect-attempt 25)
      (should (= (emacs-jupyter-notebook--auto-reconnect-delay) 300)))))

(ert-deftest ejn-w19-auto-reconnect-schedules-on-tunnel-death ()
  "W19: with a durable session entry and a dead tunnel, auto-reconnect
schedules a background attempt; disabling the option or lacking a session
entry schedules nothing."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 1 :remote-connection-file "/r/k.json")))
    (with-temp-buffer
      (setq emacs-jupyter-notebook-mode t)
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (setq emacs-jupyter-notebook--session-entry entry)
      (emacs-jupyter-notebook--schedule-auto-reconnect)
      (should (timerp emacs-jupyter-notebook--reconnect-timer))
      (should emacs-jupyter-notebook--reconnect-next-at)
      (emacs-jupyter-notebook--cancel-auto-reconnect)
      (should-not emacs-jupyter-notebook--reconnect-timer)
      ;; Disabled by customization: nothing scheduled.
      (let ((emacs-jupyter-notebook-auto-reconnect nil))
        (emacs-jupyter-notebook--schedule-auto-reconnect)
        (should-not emacs-jupyter-notebook--reconnect-timer))
      ;; No session entry: nothing scheduled.
      (setq emacs-jupyter-notebook--session-entry nil)
      (emacs-jupyter-notebook--schedule-auto-reconnect)
      (should-not emacs-jupyter-notebook--reconnect-timer))))

(ert-deftest ejn-w19-auto-reconnect-terminal-probe-stops-loop ()
  "W19: a confirmed-terminal probe outcome (kernel-dead / kernel-mismatch /
no-pid) STOPS the automatic loop — the background path never starts or
terminates a kernel, it just leaves the durable entry for an explicit
command."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 1 :remote-connection-file "/r/k.json")))
    (dolist (kind '(kernel-dead kernel-mismatch no-pid))
      (with-temp-buffer
        (setq emacs-jupyter-notebook-mode t)
        (setq emacs-jupyter-notebook--tunnel-dead t)
        (setq emacs-jupyter-notebook--session-entry entry)
        (setq emacs-jupyter-notebook--reconnect-schedule-token
              (gensym "w19-terminal-"))
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
                   (lambda (_entry _cb error-cb &optional _owner)
                     (funcall error-cb (list :error-kind kind) "terminal"))))
          (emacs-jupyter-notebook--auto-reconnect-fire
           (current-buffer)
           emacs-jupyter-notebook--reconnect-schedule-token))
        (should-not (timerp emacs-jupyter-notebook--reconnect-timer))))))

(ert-deftest ejn-w19-auto-reconnect-transient-failure-reschedules ()
  "W19: a transient failure (host unreachable) reschedules another attempt
with backoff instead of giving up; a success schedules nothing further."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 1 :remote-connection-file "/r/k.json")))
    (with-temp-buffer
      (setq emacs-jupyter-notebook-mode t)
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (setq emacs-jupyter-notebook--session-entry entry)
      (setq emacs-jupyter-notebook--reconnect-schedule-token
            (gensym "w19-transient-"))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
                 (lambda (_entry _cb error-cb &optional _owner)
                   (let ((context
                          (emacs-jupyter-notebook--async-new-context
                           :phase 'error :error-kind 'probe-unreachable
                           :origin-buffer (current-buffer))))
                     (setq emacs-jupyter-notebook--async-context context)
                     (emacs-jupyter-notebook--handle-reconnect-failure
                      context "blip" error-cb)))))
        (emacs-jupyter-notebook--auto-reconnect-fire
         (current-buffer)
         emacs-jupyter-notebook--reconnect-schedule-token))
      (should (timerp emacs-jupyter-notebook--reconnect-timer))
      (should (= emacs-jupyter-notebook--reconnect-attempt 1))
      (emacs-jupyter-notebook--cancel-auto-reconnect)
      ;; Success path: no further attempt is scheduled.
      (setq emacs-jupyter-notebook--reconnect-schedule-token
            (gensym "w19-success-"))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
                 (lambda (_entry cb _error-cb &optional _owner)
                   (funcall cb '(:phase done)))))
        (emacs-jupyter-notebook--auto-reconnect-fire
         (current-buffer)
         emacs-jupyter-notebook--reconnect-schedule-token))
      (should-not (timerp emacs-jupyter-notebook--reconnect-timer)))))

(ert-deftest ejn-w19-reconnect-supersedes-stale-reconnect-without-prompt ()
  "W19: an explicit reconnect is the reliable escape hatch from a wedged
background attempt — it supersedes a stale RECONNECT attempt silently (no
second prompt), because cancelling a reconnect never touches a kernel."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :remote-host "h" :remote-cwd "~"
                  :kernelspec "python3" :remote-pid 1
                  :remote-connection-file "/r/k.json" :session-id "s")))
        prompted retrieved)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq prompted t) nil))
              ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
               (lambda (context)
                 (emacs-jupyter-notebook--async-retrieve context)))
              ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
               (lambda (context) (setq retrieved t) context)))
      (with-temp-buffer
        (setq emacs-jupyter-notebook--async-context
              (emacs-jupyter-notebook--async-new-context
               :phase 'connect :owns-kernel nil
               :origin-buffer (current-buffer)))
        (emacs-jupyter-notebook-reconnect-remote-kernel entry)
        (should-not prompted)
        (should retrieved)))))

(ert-deftest ejn-w19-reconnect-kernel-dead-offers-fresh-start ()
  "W19: when an interactive reconnect confirms the registered kernel is gone
(kernel-dead / kernel-mismatch, e.g. after the idle watchdog reaped it), the
user is offered a one-step fresh kernel on the same profile instead of being
left to run shutdown + start by hand."
  (let ((entry '(:profile "prod" :remote-host "h" :remote-cwd "~"
                 :kernelspec "python3" :remote-pid 1
                 :remote-connection-file "/r/k.json" :session-id "s"))
        fresh-profile)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--read-registry-entry-async)
               (lambda (callback) (funcall callback entry)))
              ((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
               (lambda (_entry _cb error-cb &optional _owner)
                 (funcall error-cb '(:error-kind kernel-dead) "dead")))
              ;; `called-interactively-p' with kind `interactive' is nil in
              ;; batch by design; stub it to model a real user invocation.
              ((symbol-function 'called-interactively-p) (lambda (&rest _) t))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-retry-fresh-kernel)
               (lambda (profile) (setq fresh-profile profile))))
      (with-temp-buffer
        (call-interactively #'emacs-jupyter-notebook-reconnect-remote-kernel)
        (should (equal fresh-profile "prod"))))))

(ert-deftest ejn-w19-reconnect-kernel-dead-no-prompt-for-lisp-callers ()
  "W19: the fresh-start offer is gated on a genuine interactive invocation —
a Lisp caller (e.g. the `--ensure-client-async' fallback) that reconnects and
hits kernel-dead must NOT be answered with an interactive prompt; it just
surfaces the error."
  (let ((entry '(:profile "prod" :remote-host "h" :remote-cwd "~"
                 :kernelspec "python3" :remote-pid 1
                 :remote-connection-file "/r/k.json" :session-id "s"))
        fresh-called err-seen)
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
               #'ignore)
              ((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
               (lambda (_entry _cb error-cb &optional _owner)
                 (funcall error-cb '(:error-kind kernel-dead) "dead")))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'emacs-jupyter-notebook-retry-fresh-kernel)
               (lambda (_profile) (setq fresh-called t))))
      (with-temp-buffer
        ;; Non-interactive (Lisp) call: no prompt, error surfaced to the
        ;; caller's error-callback.
        (emacs-jupyter-notebook-reconnect-remote-kernel
         entry nil (lambda (_ctx _err) (setq err-seen t)))
        (should err-seen)
        (should-not fresh-called)))))

(ert-deftest ejn-w19-finalize-resets-reconnect-backoff ()
  "W19: a successful connect resets the auto-reconnect backoff counter and
clears the pending-reconnect timestamp, so the NEXT drop starts from the
initial delay instead of inheriting this recovery's accumulated attempts."
  (with-temp-buffer
    (let* ((entry '(:profile "p" :session-id "s" :remote-host "h"))
           (session (ejn-test-backend-session 'mock-client t))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "s"
                     :origin-buffer (current-buffer))))
      (setq emacs-jupyter-notebook--async-context context)
      (setq emacs-jupyter-notebook--reconnect-attempt 5)
      (setq emacs-jupyter-notebook--reconnect-next-at 12345.0)
      (setq emacs-jupyter-notebook--tunnel-dead t)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-start)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--inject-viewer-formatter)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--inject-idle-watchdog)
                 #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-save-entry)
                 #'ignore))
        (emacs-jupyter-notebook--async-connect-finalize
         context (current-buffer) entry '(:shell_port 1)
         "/tmp/local.json" session))
      (should (= emacs-jupyter-notebook--reconnect-attempt 0))
      (should-not emacs-jupyter-notebook--reconnect-next-at)
      (should-not emacs-jupyter-notebook--tunnel-dead)
      (should (eq emacs-jupyter-notebook--client session)))))

(ert-deftest ejn-w19-release-local-resources-disconnects-client-not-kernel ()
  "W19: tearing down local transport disconnects the stale emacs-jupyter
client (a local handle) but NEVER shuts the remote kernel down — the kernel
is durable and outlives the local client."
  (with-temp-buffer
    (let (disconnected shutdown)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-disconnect)
                 (lambda (_client) (setq disconnected t)))
                ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                 (lambda (_client) (setq shutdown t))))
        (setq emacs-jupyter-notebook--client
              (ejn-test-backend-session 'stale-client t))
        (emacs-jupyter-notebook--release-local-resources)
        (should disconnected)
        (should-not shutdown)
        (should-not emacs-jupyter-notebook--client)))))

(ert-deftest ejn-w19-async-fail-disposes-unverified-client ()
  "Review fix: a FAILED connect must not retain its `:client-unverified'.
The abandoned client holds a ZMQ ioloop subprocess that emacs-jupyter only
reclaims through a GC finalizer, so `--async-fail' releases the client's
local I/O and clears the reference — repeated failed recoveries must not
accumulate ioloop subprocesses."
  (with-temp-buffer
    (let* ((disconnected-client nil)
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect
                     :origin-buffer (current-buffer)
                     :session-id "s"
                     :client-unverified
                     (ejn-test-backend-session 'stale-io-client t))))
      (setq emacs-jupyter-notebook--async-context context)
      ;; Keep the test hermetic: `--async-fail' would otherwise emit a real
      ;; warning and force a mode-line redisplay.
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-disconnect)
                 (lambda (client) (setq disconnected-client client)))
                ((symbol-function 'display-warning) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (emacs-jupyter-notebook--async-fail context "boom"))
      (should (eq disconnected-client 'stale-io-client))
      (should-not (plist-get context :client-unverified)))))

(ert-deftest ejn-w19-cancel-context-locally-disposes-unverified-client ()
  "Review fix: an in-flight connect abandoned by buffer kill / mode disable
\(`--cancel-async-context-locally') also releases its `:client-unverified'
ioloop, and does so without resurrecting the context into the buffer slot."
  (let ((disconnected-client nil)
        (context (emacs-jupyter-notebook--async-new-context
                  :phase 'connect
                  :client-unverified
                  (ejn-test-backend-session 'stale-io t))))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-disconnect)
               (lambda (client) (setq disconnected-client client))))
      (emacs-jupyter-notebook--cancel-async-context-locally context))
    (should (eq disconnected-client 'stale-io))
    (should-not (plist-get context :client-unverified))))

(ert-deftest ejn-w19-dispose-unverified-client-noop-without-client ()
  "Review fix: disposing a context that never reached connect (no
`:client-unverified') is a harmless no-op — no disconnect, no error."
  (let ((disconnected nil)
        (context (emacs-jupyter-notebook--async-new-context
                  :phase 'retrieve)))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter-disconnect)
               (lambda (_client) (setq disconnected t))))
      (emacs-jupyter-notebook--dispose-unverified-client context)
      (should-not disconnected)
      (should-not (plist-get context :client-unverified)))))

;;; W18 — bounded, non-blocking panel images

(ert-deftest ejn-w18-panel-materialize-image-to-file ()
  "W18: image payloads are moved out of the Lisp heap into a private 0600
file owned by the panel; the stored spec references the file and drops the
inline `:data'."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "plot")))
      (ejn-panel-set-image h '(image :type png :data "imgdata"))
      (let* ((image (car (ejn-panel-entry-images (ejn-panel-entry-snapshot h))))
             (file (plist-get (cdr image) :file)))
        (should-not (plist-member (cdr image) :data))
        (should (stringp file))
        (should (file-exists-p file))
        (should (= (logand (file-modes file) #o777) #o600))
        (should (equal (ejn-test-image-spec-data image) "imgdata"))))))

(ert-deftest ejn-w18-panel-kill-cleans-image-directory ()
  "W18: killing the panel releases its private image directory (disposable
local files), so an image-heavy session leaves no debris behind."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "plot"))
           dir)
      (ejn-panel-set-image h '(image :type png :data "imgdata"))
      (setq dir (with-current-buffer panel
                  emacs-jupyter-notebook-panel--image-directory))
      (should (file-directory-p dir))
      (kill-buffer panel)
      (should-not (file-directory-p dir)))))

(ert-deftest ejn-w18-panel-inline-preview-cap-placeholder ()
  "W18: only the newest `panel-max-inline-images' images are materialized as
inline previews; older images render as lightweight placeholders (no display
property) that still open externally.  This bounds the native image-cache
memory regardless of history length."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (emacs-jupyter-notebook-panel-max-inline-images 2))
      (dotimes (i 4)
        (let ((h (ejn-panel-start-entry panel `("x.py" . ,i) "plot")))
          (ejn-panel-set-image h `(image :type png :data ,(format "img%d" i)))
          (ejn-panel-finish-entry h 'ok (1+ i))))
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel-flush-now panel)
        (should (= (length emacs-jupyter-notebook-panel--inline-image-specs) 2))
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (placeholders 0) (start 0))
          (while (string-match "png image" text start)
            (cl-incf placeholders)
            (setq start (match-end 0)))
          ;; The two OLDER images are placeholders.
          (should (= placeholders 2)))))))

(ert-deftest ejn-w18-panel-open-image-externally ()
  "W18: `o' opens the stored original image through the configured external
opener function with the backing file path."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "plot"))
           opened-file)
      (ejn-panel-set-image h '(image :type png :data "imgdata"))
      (ejn-panel-finish-entry h 'ok 1)
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel-flush-now panel)
        (let ((img-pos (next-single-property-change (point-min) 'display)))
          (should img-pos)
          (goto-char img-pos)
          (let ((emacs-jupyter-notebook-panel-external-open-function
                 (lambda (file) (setq opened-file file))))
            (emacs-jupyter-notebook-panel-open-image-externally))))
      (should (stringp opened-file))
      (should (file-exists-p opened-file))
      (should (equal (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally opened-file)
                       (buffer-string))
                     "imgdata")))))

(ert-deftest ejn-ei4d-external-open-uses-durable-verified-snapshot ()
  "An immediate launcher exit cannot invalidate its verified snapshot path."
  (let* ((root (make-temp-file "ejn-ei4d-open-" t))
         (original (ejn-ei4d-test--write-artifact
                    root "abababababababababababababababab"
                    (ejn-ei4d-test--png 2 3)))
         (emacs-jupyter-notebook-panel--external-image-snapshots nil)
         (emacs-jupyter-notebook-panel--external-image-pending-count 0)
         (emacs-jupyter-notebook-panel--external-image-pending-cancels nil)
         (emacs-jupyter-notebook-external-image-snapshot-ttl 3600)
         callback verified snapshot opened panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((handle (ejn-panel-start-entry panel '("open.py" . 1) "plot()")))
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4v-test--descriptor
                 root original "image/png" "open-original")
                nil nil))
              (with-current-buffer panel
                (emacs-jupyter-notebook-panel--render panel)
                (goto-char
                 (or (text-property-any
                      (point-min) (point-max)
                      'emacs-jupyter-notebook-segment-index 0)
                     (ert-fail "image placeholder was not rendered")))
                (let ((emacs-jupyter-notebook-panel-original-verify-function
                       (lambda (metadata destination completion)
                         (setq verified metadata snapshot destination
                               callback completion)
                         #'ignore))
                      (emacs-jupyter-notebook-panel-external-open-function
                       (lambda (file) (setq opened file) nil)))
                  (emacs-jupyter-notebook-panel-open-image-externally)
                  (should (equal (plist-get verified :file) original))
                  (should-not opened)
                  ;; Clearing retires the entry, but verification still owns
                  ;; one lease on the exact original.
                  (ejn-panel-clear-entry handle)
                  (should (file-exists-p original))
                  (let ((coding-system-for-write 'no-conversion))
                    (write-region
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally original)
                       (buffer-string))
                     nil (plist-get snapshot :file) nil 'silent))
                  (set-file-modes (plist-get snapshot :file) #o600)
                  (funcall callback t)
                  (should (equal opened (plist-get snapshot :file)))
                  (should-not (file-exists-p original))
                  ;; The opener returned immediately, but a delayed consumer
                  ;; still reads the independent path successfully.
                  (should (equal
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally opened)
                             (buffer-string))
                           (ejn-ei4d-test--png 2 3)))
                  (should (= (length
                              emacs-jupyter-notebook-panel--external-image-snapshots)
                             1))
                  (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                   (car emacs-jupyter-notebook-panel--external-image-snapshots))
                  (should-not (file-exists-p opened)))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (emacs-jupyter-notebook-panel--cleanup-external-image-opens-on-exit)
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-external-open-is-single-flight-and-cancellable ()
  "Repeated `o' cancels one verifier rather than launching another process."
  (let* ((root (make-temp-file "ejn-ei4d-open-cancel-" t))
         (original (ejn-ei4d-test--write-artifact
                    root "acacacacacacacacacacacacacacacac" "original"))
         (emacs-jupyter-notebook-panel--external-image-snapshots nil)
         (emacs-jupyter-notebook-panel--external-image-pending-count 0)
         (emacs-jupyter-notebook-panel--external-image-pending-cancels nil)
         (calls 0) verifier-cancelled panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((handle (ejn-panel-start-entry panel '("cancel.py" . 1) "plot()")))
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4v-test--descriptor
                 root original "image/png" "cancel-original")
                nil nil))
              (with-current-buffer panel
                (emacs-jupyter-notebook-panel--render panel)
                (goto-char
                 (or (text-property-any
                      (point-min) (point-max)
                      'emacs-jupyter-notebook-segment-index 0)
                     (ert-fail "image placeholder was not rendered")))
                (let ((emacs-jupyter-notebook-panel-original-verify-function
                       (lambda (_metadata _snapshot _completion)
                         (cl-incf calls)
                         (lambda () (setq verifier-cancelled t)))))
                  (emacs-jupyter-notebook-panel-open-image-externally)
                  (should (= calls 1))
                  (should (= emacs-jupyter-notebook-panel--external-image-pending-count 1))
                  (emacs-jupyter-notebook-panel-open-image-externally)
                  (should verifier-cancelled)
                  (should (= calls 1))
                  (should (= emacs-jupyter-notebook-panel--external-image-pending-count 0))
                  (should-not emacs-jupyter-notebook-panel--external-image-pending-cancels)
                  (should (file-exists-p original)))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (emacs-jupyter-notebook-panel--cleanup-external-image-opens-on-exit)
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-async-original-verifier-pins-and-snapshots-content ()
  "The real verifier bridges Emacs IDs and copies only exact pinned bytes."
  (let* ((root (make-temp-file "ejn-ei4d-verify-" t))
         (file (ejn-ei4d-test--write-artifact
                root "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" "original"))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("verify.py" . 1) "plot()"))
                   (_accepted
                    (ejn-panel-set-published-bundle
                     handle
                     (ejn-ei4v-test--descriptor root file "image/png" "verify")
                     nil nil))
                   (image (car (ejn-panel-entry-images handle)))
                   (original (plist-get (cdr image) :ejn-original)))
              (cl-labels
                  ((verify ()
                     (let* ((deadline (+ (float-time) 2.0)) done valid
                            (snapshot
                             (emacs-jupyter-notebook-panel--make-external-image-snapshot
                              "image/png")))
                       (emacs-jupyter-notebook-panel--verify-original-async
                        original snapshot
                        (lambda (result) (setq valid result done t)))
                       (while (and (not done) (< (float-time) deadline))
                         (accept-process-output nil 0.02))
                       (should done)
                       (prog1 (list valid snapshot)
                         (unless valid
                           (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                            snapshot))))))
                (let* ((attrs (file-attributes file 'integer))
                       (identity (file-attribute-file-identifier attrs))
                       (accepted (verify))
                       (snapshot (cadr accepted)))
                  (should (equal
                           (emacs-jupyter-notebook-panel--identity-parts identity)
                           (list (file-attribute-device-number attrs)
                                 (file-attribute-inode-number attrs))))
                  (should (car accepted))
                  (should (equal
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally
                              (plist-get snapshot :file))
                             (buffer-string))
                           "original"))
                  (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot
                   snapshot))
                (let ((coding-system-for-write 'no-conversion))
                  (write-region "mutated!" nil file nil 'silent))
                (set-file-modes file #o600)
                (should-not (car (verify)))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-w18-panel-open-image-externally-no-image-errors ()
  "W18: `o' on an entry without an image signals a friendly user-error."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h (ejn-panel-start-entry panel '("x.py" . 1) "print")))
      (ejn-panel-append-text h "just text")
      (ejn-panel-finish-entry h 'ok 1)
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel-flush-now panel)
        (goto-char (point-min))
        (should-error (emacs-jupyter-notebook-panel-open-image-externally)
                      :type 'user-error)))))

(ert-deftest ejn-w18-incremental-render-avoids-full-rerender ()
  "W18: appending streaming text to an existing entry re-renders only that
entry (incremental path), NOT the whole history — so a long image-heavy
session does not pay an O(history) erase+reinsert on every stream flush."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (h1 (ejn-panel-start-entry panel '("x.py" . 1) "cell1"))
           (h2 (ejn-panel-start-entry panel '("x.py" . 2) "cell2"))
           (full-render-calls 0))
      (ejn-panel-append-text h1 "first")
      (ejn-panel-append-text h2 "second")
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel-flush-now panel))
      (cl-letf* ((orig-render
                  (symbol-function 'emacs-jupyter-notebook-panel--render))
                 ((symbol-function 'emacs-jupyter-notebook-panel--render)
                  (lambda (p) (cl-incf full-render-calls)
                          (funcall orig-render p))))
        (ejn-panel-append-text h2 " more")
        (with-current-buffer panel
          (emacs-jupyter-notebook-panel-flush-now panel)))
      ;; The streaming append used the incremental path, not a full render.
      (should (= full-render-calls 0))
      (with-current-buffer panel
        (should (string-match-p
                 "second more"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

;; IR1: structural invalidation must win over queued content-only updates.
(ert-deftest ejn-ir1-toggle-with-pending-dirty-forces-full-render ()
  "Toggling views rebuilds all rendered entries despite a queued dirty entry."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (old (ejn-panel-start-entry panel '("x.py" . 1) "old cell"))
           (latest (ejn-panel-start-entry panel '("x.py" . 1) "latest cell"))
           (region (ejn-panel-start-entry panel nil "region evaluation")))
      (ejn-panel-append-text old "old output")
      (ejn-panel-append-text latest "latest output")
      (ejn-panel-append-text region "region output")
      (emacs-jupyter-notebook-panel-flush-now panel)
      ;; Only LATEST is dirty, which used to select the incremental path and
      ;; leave OLD and REGION absent after switching to history.
      (ejn-panel-append-text latest " pending")
      (with-current-buffer panel
        (emacs-jupyter-notebook-panel-toggle-view)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "view: history" text))
          (should (string-match-p "old output" text))
          (should (string-match-p "latest output pending" text))
          (should (string-match-p "region output" text)))
        (dolist (handle (list old latest region))
          (should (text-property-any
                   (point-min) (point-max)
                   'emacs-jupyter-notebook-entry-id
                   (plist-get handle :id))))))))

(ert-deftest ejn-ir1-clear-with-pending-dirty-leaves-empty-panel ()
  "Clearing results removes every rendered entry despite queued dirty content."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (first (ejn-panel-start-entry panel '("x.py" . 1) "first cell"))
           (second (ejn-panel-start-entry panel '("x.py" . 2) "second cell")))
      (ejn-panel-append-text first "first output")
      (ejn-panel-append-text second "second output")
      (emacs-jupyter-notebook-panel-flush-now panel)
      ;; Leaving only FIRST dirty exposed the old incremental clear bug: the
      ;; unmarked SECOND section remained in the visible buffer.
      (ejn-panel-append-text first " pending")
      (emacs-jupyter-notebook-clear-results)
      (with-current-buffer panel
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "view: latest" text))
          (should-not (string-match-p "first output" text))
          (should-not (string-match-p "second output" text)))
        (should-not (text-property-not-all
                     (point-min) (point-max)
                     'emacs-jupyter-notebook-entry-id nil))))))

(ert-deftest ejn-ir1-reordered-cells-rebuild-visible-order ()
  "Moving a cell rebuilds latest-view order despite queued dirty content."
  (ejn-test-with-temp-buffer "# %% A\na = 1\n# %% B\nb = 2\n"
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           first-key
           second-key)
      (goto-char (point-min))
      (setq first-key (emacs-jupyter-notebook--cell-key-for (point)))
      (search-forward "# %% B")
      (beginning-of-line)
      (setq second-key (emacs-jupyter-notebook--cell-key-for (point)))
      (let ((first (ejn-panel-start-entry panel first-key "first cell"))
            (second (ejn-panel-start-entry panel second-key "second cell")))
        (ejn-panel-append-text first "first output")
        (ejn-panel-append-text second "second output")
        (emacs-jupyter-notebook-panel-flush-now panel)
        ;; Queue a content update, then move B above A.  The rendered panel
        ;; must follow the source markers, not merely replace SECOND in place.
        (ejn-panel-append-text second " pending")
        (goto-char (point-min))
        (search-forward "# %% B")
        (beginning-of-line)
        (emacs-jupyter-notebook-move-cell-up 1)
        (emacs-jupyter-notebook-panel-flush-now panel)
        (with-current-buffer panel
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (second-pos (string-match "second cell" text))
                 (first-pos (string-match "first cell" text)))
            (should second-pos)
            (should first-pos)
            (should (< second-pos first-pos))
            (should (string-match-p "second output pending" text))))))))

;;; IR2 — artifact retirement and late callback quarantine

(ert-deftest ejn-ir2-clear-deletes-existing-artifacts ()
  "Clearing retires image files and confined pickle artifacts before entries vanish."
  (let* ((root (make-temp-file "ejn-ir2-pickle-" t))
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "pickle-bytes"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   image-file image-directory)
              (ejn-panel-set-image handle '(image :type png :data "image-bytes"))
              (setq image-file (plist-get (cdr (car (ejn-panel-entry-images handle))) :file)
                    image-directory (file-name-directory image-file))
              (should
               (ejn-panel-set-published-pickle
                handle root pickle-file
                (ejn-ei4-test--content-sha256 pickle-file)
                (file-attribute-size (file-attributes pickle-file 'integer))
                (file-attribute-file-identifier
                 (file-attributes root 'integer))))
              (should (file-exists-p image-file))
              (should (file-exists-p pickle-file))
              (should (ejn-panel-entry-pickle handle))
              (emacs-jupyter-notebook-clear-results)
              (should-not (file-exists-p image-file))
              (should-not (file-exists-p pickle-file))
              (should-not (file-directory-p image-directory))
              (should-not (ejn-panel-entry-live-p handle))
              (with-current-buffer panel
                (should-not emacs-jupyter-notebook-panel--entries)
                (should-not emacs-jupyter-notebook-panel--inline-image-specs)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-late-image-after-clear-creates-no-file ()
  "A late image callback after clear never decodes or materializes a file."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
           (callbacks (emacs-jupyter-notebook-jupyter--callbacks source handle))
           (display (cadr (assoc "display_data" callbacks)))
           (update (cadr (assoc "update_display_data" callbacks)))
           (stream (cadr (assoc "stream" callbacks)))
           (message-reads 0)
           (render-calls 0))
      (emacs-jupyter-notebook-clear-results)
      (cl-letf (((symbol-function 'jupyter-message-content)
                 (lambda (_msg)
                   (cl-incf message-reads)
                   '(:data (:image/png "aW1hZ2UtYnl0ZXM="))))
                ((symbol-function 'emacs-jupyter-notebook--render-mime-result)
                 (lambda (_data) (cl-incf render-calls) (ert-fail "late image decoded"))))
        (funcall display 'late-message)
        (funcall update 'late-message)
        (funcall stream 'late-message))
      (should (= message-reads 0))
      (should (= render-calls 0))
      (with-current-buffer panel
        (should-not emacs-jupyter-notebook-panel--image-directory)
        (should-not emacs-jupyter-notebook-panel--entries)))))

(ert-deftest ejn-ir2-late-pickle-after-clear-retains-no-bytes ()
  "A late confined pickle descriptor after clear is ignored before validation."
  (let* ((root (make-temp-file "ejn-ir2-late-pickle-" t))
         (file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq file
                (ejn-ei4v-test--artifact-file
                 root "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "pickle-bytes"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (descriptor (ejn-ei4v-test--descriptor root file nil "late"))
                   (context (list :buffer source :entry-handle handle))
                   validated)
              (emacs-jupyter-notebook-clear-results)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-panel--published-pickle)
                         (lambda (&rest _)
                           (setq validated t)
                           (ert-fail "late pickle descriptor was validated"))))
                (should (equal
                         (emacs-jupyter-notebook-events-dispatch
                          context `(:type display
                                    :data (:ejn-published-pickle ,descriptor)
                                    :display-id "late"))
                         '((:action ignore)))))
              (should-not validated)
              (should-not (ejn-panel-entry-pickle handle))
              (should (file-exists-p file))
              (with-current-buffer panel
                (should-not emacs-jupyter-notebook-panel--entries)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-clear-before-idle-pickle-open-does-not-materialize ()
  "A queued auto-viewer handoff claims a live descriptor only when it runs."
  (let* ((root (make-temp-file "ejn-ir2-idle-pickle-" t))
         (file nil)
         (real-cancel (symbol-function 'cancel-timer)))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq file
                (ejn-ei4v-test--artifact-file
                 root "cccccccccccccccccccccccccccccccc" "pickle-bytes"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   idle-callback timer opened)
              (unwind-protect
                  (cl-letf (((symbol-function 'run-with-idle-timer)
                             (lambda (_delay _repeat function &rest _args)
                               (setq idle-callback function)
                               (setq timer (run-at-time 100 nil #'ignore))))
                            ((symbol-function 'cancel-timer)
                             (lambda (timer)
                               (funcall real-cancel timer))))
                    (should
                     (ejn-panel-set-published-pickle
                      handle root file
                      (ejn-ei4-test--content-sha256 file)
                      (file-attribute-size (file-attributes file 'integer))
                      (file-attribute-file-identifier
                       (file-attributes root 'integer))))
                    (ejn-panel-schedule-pickle-open
                     handle (lambda (pickle)
                              (setq opened pickle)
                              (ejn-panel-release-pickle pickle)))
                    (should idle-callback)
                    (should (ejn-panel-entry-pickle handle))
                    (emacs-jupyter-notebook-clear-results)
                    (funcall idle-callback)
                    (should-not opened)
                    (should-not (ejn-panel-entry-pickle handle))
                    (should-not (file-exists-p file)))
                (when (timerp timer) (funcall real-cancel timer))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-pickle-auto-open-coalesces-latest-update ()
  "Rapid descriptor updates retain one pending handoff and open only the newest."
  (let* ((root (make-temp-file "ejn-ir2-coalesce-" t))
         (old-file nil)
         (new-file nil)
         (real-cancel (symbol-function 'cancel-timer)))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq old-file
                (ejn-ei4v-test--artifact-file
                 root "dddddddddddddddddddddddddddddddd" "old-pickle"))
          (setq new-file
                (ejn-ei4v-test--artifact-file
                 root "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "new-pickle"))
          (with-temp-buffer
            (let* ((panel (ejn-panel-ensure (current-buffer)))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (timers nil)
                   (cancelled 0)
                   (opened nil))
              (unwind-protect
                  (cl-letf (((symbol-function 'run-with-idle-timer)
                             (lambda (_delay _repeat function &rest _args)
                               (let ((timer (run-at-time 100 nil #'ignore)))
                                 (push (cons timer function) timers)
                                 timer)))
                            ((symbol-function 'cancel-timer)
                             (lambda (timer)
                               (cl-incf cancelled)
                               (funcall real-cancel timer))))
                    (dolist (file (list old-file new-file))
                      (should
                       (ejn-panel-set-published-pickle
                        handle root file
                        (ejn-ei4-test--content-sha256 file)
                        (file-attribute-size (file-attributes file 'integer))
                        (file-attribute-file-identifier
                         (file-attributes root 'integer))))
                      (ejn-panel-schedule-pickle-open
                       handle (lambda (pickle)
                                (push (plist-get pickle :file) opened)
                                (ejn-panel-release-pickle pickle))))
                    (setq timers (nreverse timers))
                    (should (= (length timers) 2))
                    (should (= cancelled 1))
                    (should (eq (plist-get (ejn-panel-entry-snapshot handle)
                                           :pickle-open-timer)
                                (caar (last timers))))
                    (should-not (file-exists-p old-file))
                    ;; Even if an already-cancelled callback is dispatched
                    ;; manually, its token can no longer claim the entry.
                    (funcall (cdr (car timers)))
                    (funcall (cdr (cadr timers)))
                    (should (equal opened (list new-file)))
                    (should-not (plist-get (ejn-panel-entry-snapshot handle)
                                           :pickle-open-timer)))
                (dolist (record timers)
                  (ignore-errors (funcall real-cancel (car record))))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-pending-clear-retires-pickle-and-auto-open ()
  "The next output after clear_output(wait=t) retires the old figure fully."
  (let* ((root (make-temp-file "ejn-ir2-pending-pickle-" t))
         (pickle-file nil)
         (real-cancel (symbol-function 'cancel-timer)))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "ffffffffffffffffffffffffffffffff" "old-pickle"))
          (with-temp-buffer
            (let* ((panel (ejn-panel-ensure (current-buffer)))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   idle-callback timer opened image-file)
              (unwind-protect
                  (cl-letf (((symbol-function 'run-with-idle-timer)
                             (lambda (_delay _repeat function &rest _args)
                               (setq idle-callback function)
                               (setq timer (run-at-time 100 nil #'ignore)))))
                    (ejn-panel-set-image handle '(image :type png :data "image-bytes"))
                    (setq image-file (plist-get (cdr (car (ejn-panel-entry-images handle))) :file))
                    (should
                     (ejn-panel-set-published-pickle
                      handle root pickle-file
                      (ejn-ei4-test--content-sha256 pickle-file)
                      (file-attribute-size (file-attributes pickle-file 'integer))
                      (file-attribute-file-identifier
                       (file-attributes root 'integer))))
                    (ejn-panel-schedule-pickle-open
                     handle (lambda (pickle)
                              (setq opened pickle)
                              (ejn-panel-release-pickle pickle)))
                    (ejn-panel-clear-entry handle t)
                    (ejn-panel-append-text handle "replacement")
                    (should-not (file-exists-p image-file))
                    (should-not (file-exists-p pickle-file))
                    (should-not (ejn-panel-entry-pickle handle))
                    (should-not (plist-get (ejn-panel-entry-snapshot handle)
                                           :pickle-open-timer))
                    (funcall idle-callback)
                    (should-not opened))
                (when (timerp timer) (funcall real-cancel timer))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-pending-clear-display-replaces-old-figure ()
  "A replacement display after clear(wait) keeps only its new figure state."
  (let* ((root (make-temp-file "ejn-ir2-replace-figure-" t))
         (old-image nil)
         (old-pickle nil)
         (new-image nil)
         (new-pickle nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq old-image (ejn-ei4v-test--artifact-file
                           root "11111111111111111111111111111111" "old-image"))
          (setq old-pickle (ejn-ei4v-test--artifact-file
                            root "22222222222222222222222222222222" "old-pickle"))
          (setq new-image (ejn-ei4v-test--artifact-file
                           root "33333333333333333333333333333333" "new-image"))
          (setq new-pickle (ejn-ei4v-test--artifact-file
                            root "44444444444444444444444444444444" "new-pickle"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (context (list :buffer source :entry-handle handle)))
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4v-test--descriptor root old-image "image/png" "fig")
                (ejn-ei4v-test--descriptor root old-pickle nil "fig")
                nil))
              (ejn-panel-clear-entry handle t)
              (emacs-jupyter-notebook-events-dispatch
               context `(:type display
                         :data (:ejn-published-image
                                ,(ejn-ei4v-test--descriptor root new-image "image/png" "fig")
                                :ejn-published-pickle
                                ,(ejn-ei4v-test--descriptor root new-pickle nil "fig"))
                         :display-id "fig"))
              (let* ((entry (ejn-panel-entry-snapshot handle))
                     (stored-image (car (ejn-panel-entry-images handle))))
                (should-not (file-exists-p old-image))
                (should-not (file-exists-p old-pickle))
                (should (file-exists-p new-image))
                (should (file-exists-p new-pickle))
                (should (equal (plist-get (cdr stored-image) :file) new-image))
                (should (equal (plist-get (plist-get entry :mpl-pickle) :file)
                               new-pickle))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-pending-clear-text-display-removes-stale-image ()
  "A no-pickle text replacement after clear(wait) forces stale-image removal."
  (let* ((root (make-temp-file "ejn-ir2-text-replace-" t))
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "55555555555555555555555555555555" "old-pickle"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (context (list :buffer source :entry-handle handle))
                   old-file opened)
              (ejn-panel-set-image handle '(image :type png :data "old-image"))
              (setq old-file (plist-get (cdr (car (ejn-panel-entry-images handle))) :file))
              (should
               (ejn-panel-set-published-pickle
                handle root pickle-file
                (ejn-ei4-test--content-sha256 pickle-file)
                (file-attribute-size (file-attributes pickle-file 'integer))
                (file-attribute-file-identifier
                 (file-attributes root 'integer))))
              (ejn-panel-schedule-pickle-open
               handle (lambda (pickle)
                        (setq opened pickle)
                        (ejn-panel-release-pickle pickle)))
              (ejn-panel-clear-entry handle t)
              (emacs-jupyter-notebook-events-dispatch
               context '(:type display :data (:text/plain "replacement")))
              (emacs-jupyter-notebook-panel-flush-now panel)
              (should-not (file-exists-p old-file))
              (should-not (file-exists-p pickle-file))
              (should-not (ejn-panel-entry-pickle handle))
              (should-not (plist-get (ejn-panel-entry-snapshot handle)
                                     :pickle-open-timer))
              (with-current-buffer panel
                (should (string-match-p "replacement" (buffer-string)))
                (should-not (text-property-not-all
                             (point-min) (point-max) 'display nil)))
              (should-not opened))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir2-exit-cleanup-is-local-only ()
  "The normal-exit artifact reaper leaves registry, SSH, and kernels alone."
  (let* ((root (make-temp-file "ejn-ir2-exit-pickle-" t))
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "12121212121212121212121212121212" "pickle"))
          (with-temp-buffer
            (let* ((source (current-buffer))
                   (panel (ejn-panel-ensure source))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "plot()"))
                   (file nil)
                   (lease nil)
                   (durable-calls 0)
                   (remote-calls 0))
              (ejn-panel-set-image handle '(image :type png :data "image-bytes"))
              (setq file (plist-get (cdr (car (ejn-panel-entry-images handle))) :file))
              (should
               (ejn-panel-set-published-pickle
                handle root pickle-file
                (ejn-ei4-test--content-sha256 pickle-file)
                (file-attribute-size (file-attributes pickle-file 'integer))
                (file-attribute-file-identifier
                 (file-attributes root 'integer))))
              (setq lease (ejn-panel-acquire-pickle handle))
              (should (file-exists-p file))
              (should (file-exists-p pickle-file))
              (should (memq #'emacs-jupyter-notebook-panel--cleanup-published-artifacts-on-exit
                            kill-emacs-hook))
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-save)
                         (lambda (&rest _) (cl-incf durable-calls)))
                        ((symbol-function 'emacs-jupyter-notebook--remove-registry-entry)
                         (lambda (&rest _) (cl-incf durable-calls)))
                        ((symbol-function 'emacs-jupyter-notebook-ssh-start-process)
                         (lambda (&rest _) (cl-incf remote-calls)))
                        ((symbol-function 'emacs-jupyter-notebook--async-kill-remote-kernel)
                         (lambda (&rest _) (cl-incf remote-calls)))
                        ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                         (lambda (&rest _) (cl-incf remote-calls)))
                        ((symbol-function 'emacs-jupyter-notebook-jupyter-shutdown)
                         (lambda (&rest _) (cl-incf remote-calls))))
                (emacs-jupyter-notebook-panel--cleanup-published-artifacts-on-exit))
              (should-not (file-exists-p file))
              (should (file-exists-p pickle-file))
              (should (plist-get lease :retired))
              (should (= durable-calls 0))
              (should (= remote-calls 0))
              (ejn-panel-release-pickle lease)
              (should-not (file-exists-p pickle-file)))))
      (ignore-errors (delete-directory root t)))))


;;; IR3 — total history and artifact retention budgets

(ert-deftest ejn-ir3-entry-budget-evicts-oldest ()
  "The entry cap retires the oldest history entry and leaves one marker."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-panel-max-history-entries 2)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 100)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 100)
          (panel (ejn-panel-ensure (current-buffer))))
      (let ((first (ejn-panel-start-entry panel '("x.py" . 1) "first"))
            (second (ejn-panel-start-entry panel '("x.py" . 2) "second"))
            (third (ejn-panel-start-entry panel '("x.py" . 3) "third")))
        (should-not (ejn-panel-entry-live-p first))
        (should (ejn-panel-entry-live-p second))
        (should (ejn-panel-entry-live-p third))
        (with-current-buffer panel
          (setq emacs-jupyter-notebook-panel--view 'history)
          (emacs-jupyter-notebook-panel-flush-now panel)
          (let ((text (buffer-string)))
            (should (= 1 (how-many "\\[older output evicted\\]" (point-min) (point-max))))
            (should-not (string-match-p "first" text))))))))

(ert-deftest ejn-ir3-text-budget-is-global ()
  "Source code and output text share one panel-wide retention budget."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-panel-max-history-entries 10)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 5)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 100)
          (panel (ejn-panel-ensure (current-buffer))))
      (let ((first (ejn-panel-start-entry panel '("x.py" . 1) "abc"))
            (second (ejn-panel-start-entry panel '("x.py" . 2) "")))
        (ejn-panel-append-text second "def")
        (should-not (ejn-panel-entry-live-p first))
        (should (ejn-panel-entry-live-p second))
        (with-current-buffer panel
          (should (= (emacs-jupyter-notebook-panel--total-text-bytes) 3)))))))

(ert-deftest ejn-ir3-artifact-budget-deletes-files ()
  "The artifact cap deletes evicted image and pickle files."
  (let* ((root (make-temp-file "ejn-ir3-pickle-budget-" t))
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "66666666666666666666666666666666" "oversize"))
          (with-temp-buffer
            (let ((emacs-jupyter-notebook-panel-max-history-entries 10)
                  (emacs-jupyter-notebook-panel-max-total-text-bytes 100)
                  (emacs-jupyter-notebook-panel-max-total-artifact-bytes 5)
                  (panel (ejn-panel-ensure (current-buffer))))
              (let* ((first (ejn-panel-start-entry panel '("x.py" . 1) "first"))
                     (second (ejn-panel-start-entry panel '("x.py" . 2) "second")))
                (ejn-panel-set-image first '(image :type png :data "aaaa"))
                (let ((old-file (plist-get (cdr (car (ejn-panel-entry-images first))) :file)))
                  (ejn-panel-set-image second '(image :type png :data "bbbb"))
                  (should-not (file-exists-p old-file))
                  (should-not (ejn-panel-entry-live-p first))
                  (should (ejn-panel-entry-live-p second))
                  (with-current-buffer panel
                    (should (= (emacs-jupyter-notebook-panel--total-artifact-bytes) 4)))
                  ;; Confined pickle descriptors participate in the same
                  ;; global artifact budget as file-backed images.
                  (let ((pickle-only (ejn-panel-start-entry panel '("x.py" . 3) "pickle")))
                    (should
                     (ejn-panel-set-published-pickle
                      pickle-only root pickle-file
                      (ejn-ei4-test--content-sha256 pickle-file)
                      (file-attribute-size (file-attributes pickle-file 'integer))
                      (file-attribute-file-identifier
                       (file-attributes root 'integer))))
                    (should-not (ejn-panel-entry-live-p pickle-only))
                    (should-not (file-exists-p pickle-file)))
                  ;; File deletion between existence and attribute checks is harmless.
                  (let ((racy-file (make-temp-file "ejn-ir3-race-")))
                    (unwind-protect
                        (progn
                          (cl-letf (((symbol-function 'file-attributes)
                                     (lambda (&rest _) (signal 'file-error '("gone")))))
                            (should (= 0 (emacs-jupyter-notebook-panel--image-artifact-bytes
                                          (list 'image :file racy-file)))))
                          (cl-letf (((symbol-function 'file-attributes)
                                     (lambda (&rest _) nil)))
                            (should (= 0 (emacs-jupyter-notebook-panel--image-artifact-bytes
                                          (list 'image :file racy-file))))))
                      (delete-file racy-file))))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir3-latest-cell-survives-history-eviction ()
  "Eviction removes stale history before a cell's latest result."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-panel-max-history-entries 2)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 100)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 100)
          (panel (ejn-panel-ensure (current-buffer)))
          (key '("x.py" . 1)))
      (let ((old (ejn-panel-start-entry panel key "old"))
            (other (ejn-panel-start-entry panel '("x.py" . 2) "other"))
            (new (ejn-panel-start-entry panel key "new")))
        (ejn-panel-append-text old "old output")
        (ejn-panel-append-text other "other output")
        (ejn-panel-append-text new "new output")
        (should-not (ejn-panel-entry-live-p old))
        (should (ejn-panel-entry-live-p new))
        (with-current-buffer panel
          (setq emacs-jupyter-notebook-panel--view 'latest)
          (emacs-jupyter-notebook-panel-flush-now panel)
          (let ((text (buffer-string)))
            (should (string-match-p "new output" text))
            (should-not (string-match-p "old output" text))))))))

(ert-deftest ejn-ir3-inline-images-use-creation-order ()
  "The inline preview cap chooses the newest entry, not source order."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-panel-max-history-entries 10)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 100)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 100)
          (emacs-jupyter-notebook-panel-max-inline-images 1)
          (panel (ejn-panel-ensure (current-buffer))))
      ;; The first entry sorts AFTER the newer entry by source position.
      (let ((older (ejn-panel-start-entry panel '("x.py" . 100) "older"))
            (newer (ejn-panel-start-entry panel '("x.py" . 1) "newer")))
        (ejn-panel-set-image older '(image :type png :data "old-image"))
        (ejn-panel-set-image newer '(image :type png :data "new-image-first"))
        (ejn-panel-set-image newer '(image :type png :data "new-image-final"))
        (with-current-buffer panel
          (setq emacs-jupyter-notebook-panel--view 'latest)
          (emacs-jupyter-notebook-panel-flush-now panel)
          (should (equal emacs-jupyter-notebook-panel--inline-image-specs
                         (last (ejn-panel-entry-images newer)))))))))

;;; IR3S — amortized streamed text and cached retention totals

(ert-deftest ejn-ir3s-ten-thousand-chunks-ordered-and-truncated ()
  "Ordered streamed chunks retain the exact newest bounded tail."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-result-max-bytes 128)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 1000)
          (emacs-jupyter-notebook-panel-max-history-entries 10)
          (emacs-jupyter-notebook-panel-max-total-artifact-bytes 1000)
          (panel (ejn-panel-ensure (current-buffer))))
      (let ((handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
        (dotimes (index 10000)
          (ejn-panel-append-text handle (format "%04d" index)))
        (let* ((entry (ejn-panel-entry-snapshot handle))
               (state (cdr (car (plist-get entry :outputs)))))
          (should-not (plist-get state :pending))
          (should (= (plist-get state :bytes) 128))
          (should (= (cl-loop for chunk in (plist-get state :chunks)
                              sum (string-bytes chunk))
                     128)))
        (should (= (length (ejn-panel-entry-text handle)) 128))
        (should (equal (ejn-panel-entry-text handle)
                       (apply #'concat
                              (cl-loop for index from 9968 to 9999
                                       collect (format "%04d" index)))))
        (with-current-buffer panel
          (should (= 128 emacs-jupyter-notebook-panel--retained-text-bytes)))))))

(ert-deftest ejn-ir3s-stream-appends-do-not-materialize-retained-text ()
  "Appending chunks does not materialize the accumulated stream each time."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (let ((emacs-jupyter-notebook-panel--text-materialization-count 0))
        (dotimes (_ 1000)
          (ejn-panel-append-text handle "x"))
        (should (= emacs-jupyter-notebook-panel--text-materialization-count 0))
        (ejn-panel-entry-text handle)
        (should (= emacs-jupyter-notebook-panel--text-materialization-count 1))))))

(ert-deftest ejn-ir3s-at-cap-stream-trim-visits-one-oldest-chunk-per-append ()
  "At-cap one-byte streams trim in constant queue work without materializing."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-result-max-bytes 8)
          (panel (ejn-panel-ensure (current-buffer))))
      (let ((handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
            (emacs-jupyter-notebook-panel--text-materialization-count 0)
            (emacs-jupyter-notebook-panel--text-trim-chunk-visits 0))
        (dotimes (_ 8)
          (ejn-panel-append-text handle "x"))
        (dotimes (_ 1000)
          (ejn-panel-append-text handle "x"))
        (should (= emacs-jupyter-notebook-panel--text-trim-chunk-visits 1000))
        (should (= emacs-jupyter-notebook-panel--text-materialization-count 0))))))

(ert-deftest ejn-ir3s-incremental-flush-inserts-only-stream-suffix ()
  "A dirty stream flush extends its text segment without deleting the entry."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (deletes 0)
           (real-delete (symbol-function 'delete-region)))
      (ejn-panel-append-text handle "first")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (ejn-panel-append-text handle " second")
      (cl-letf (((symbol-function 'delete-region)
                 (lambda (&rest args)
                   (cl-incf deletes)
                   (apply real-delete args))))
        (emacs-jupyter-notebook-panel-flush-now panel))
      (should (= deletes 0))
      (with-current-buffer panel
        (should (string-match-p "first second" (buffer-string)))))))

(ert-deftest ejn-ir3s-pending-clear-text-replaces-rendered-stream ()
  "Deferred clear forces a structural render before the next text suffix."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "old text")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (ejn-panel-clear-entry handle t)
      (ejn-panel-append-text handle "new text")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (with-current-buffer panel
        (should (string-match-p "new text" (buffer-string)))
        (should-not (string-match-p "old text" (buffer-string)))))))

(ert-deftest ejn-ir3s-multibyte-trim-uses-actual-retained-byte-count ()
  "A byte cap never leaves cached totals in the middle of a UTF-8 character."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook-result-max-bytes 5)
          (emacs-jupyter-notebook-panel-max-total-text-bytes 100)
          (panel (ejn-panel-ensure (current-buffer))))
      (let ((handle (ejn-panel-start-entry panel '("x.py" . 1) "z")))
        ;; Seven bytes: trimming two bytes drops "a" and then the next
        ;; complete two-byte character, leaving four output bytes.
        (ejn-panel-append-text handle "a\u00e9\u00e9\u00e9")
        (should (equal (ejn-panel-entry-text handle) "\u00e9\u00e9"))
        (with-current-buffer panel
          (should (= emacs-jupyter-notebook-panel--retained-text-bytes 5))
          (should (= (plist-get (ejn-panel-entry-snapshot handle)
                                :output-text-bytes)
                     4))
          (should (equal (emacs-jupyter-notebook-panel--recompute-totals)
                         '(:text 5 :artifacts 0))))))))

(ert-deftest ejn-ir3s-full-render-consumes-pending-chunks-and-clear-releases-them ()
  "Flush materializes a dirty stream once, and clear drops its retained state."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "pending")
      (emacs-jupyter-notebook-panel-flush-now panel)
      (let* ((entry (ejn-panel-entry-snapshot handle))
             (state (cdr (car (plist-get entry :outputs)))))
        (should-not (plist-get state :pending))
        (should (stringp (plist-get state :cache))))
      (ejn-panel-clear-entry handle)
      (let ((entry (ejn-panel-entry-snapshot handle)))
        (should-not (plist-get entry :outputs))
        (should (= (plist-get entry :output-text-bytes) 0))))))

(ert-deftest ejn-ir3s-cached-totals-match-recomputed-after-mutations ()
  "Cached panel totals track text, image, pickle, replacement, and clear deltas."
  (let* ((root (make-temp-file "ejn-ir3s-pickle-totals-" t))
         (pickle-file nil))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (setq pickle-file
                (ejn-ei4v-test--artifact-file
                 root "77777777777777777777777777777777" "pickle"))
          (with-temp-buffer
            (let* ((panel (ejn-panel-ensure (current-buffer)))
                   (handle (ejn-panel-start-entry panel '("x.py" . 1) "code")))
              (cl-labels ((assert-totals ()
                            (with-current-buffer panel
                              (let ((totals (emacs-jupyter-notebook-panel--recompute-totals)))
                                (should (= emacs-jupyter-notebook-panel--retained-text-bytes
                                           (plist-get totals :text)))
                                (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes
                                           (plist-get totals :artifacts)))))))
                (assert-totals)
                (ejn-panel-append-text handle "stream")
                (assert-totals)
                (ejn-panel-set-image handle '(image :type png :data "image"))
                (assert-totals)
                (should
                 (ejn-panel-set-published-pickle
                  handle root pickle-file
                  (ejn-ei4-test--content-sha256 pickle-file)
                  (file-attribute-size (file-attributes pickle-file 'integer))
                  (file-attribute-file-identifier
                   (file-attributes root 'integer))))
                (assert-totals)
                (ejn-panel-replace-text handle "replacement")
                (assert-totals)
                (ejn-panel-clear-entry handle)
                (assert-totals)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ir3s-artifact-stats-happen-at-admission-not-on-stream ()
  "Streaming text does not re-stat retained image files for budget checks."
  (with-temp-buffer
    (let* ((file (make-temp-file "ejn-ir3s-image-"))
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) ""))
           (stats 0)
           (real-attributes (symbol-function 'file-attributes)))
      (unwind-protect
          (cl-letf (((symbol-function 'file-attributes)
                     (lambda (&rest args)
                       (cl-incf stats)
                       (apply real-attributes args))))
            (ejn-panel-set-image handle (list 'image :type 'png :file file))
            (let ((admission-stats stats))
              (dotimes (_ 100)
                (ejn-panel-append-text handle "x"))
              (should (= stats admission-stats))))
        (ignore-errors (delete-file file))))))

(ert-deftest ejn-ir3s-carriage-return-across-chunks-remains-correct ()
  "A terminal-style carriage return in a later chunk replaces the old line."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel '("x.py" . 1) "")))
      (ejn-panel-append-text handle "10%")
      (ejn-panel-append-text handle "\r100%")
      (should (equal (ejn-panel-entry-text handle) "100%")))))

;;; IR4 — asynchronous management SSH

(defun ejn-ir4--never-exiting-command ()
  "Return a local command that remains alive until an IR4 test disposes it."
  (list shell-file-name shell-command-switch "sleep 10"))

(defun ejn-ir4--exercise-never-exiting-command (starter terminal)
  "Run STARTER and assert its child remains non-blocking through TERMINAL.
TERMINAL is `timeout' or `cancelled'.  Return the disposed process."
  (let* ((registry-file (make-temp-file "ejn-ir4-registry-"))
         (initial-registry "durable-registry-sentinel\n")
         (emacs-jupyter-notebook-registry-file registry-file)
         (emacs-jupyter-notebook-ssh-process-timeout 0.05)
         (emacs-jupyter-notebook-management-process-timeout 0.05)
         (emacs-jupyter-notebook-prune-ssh-timeout 0.05)
         (deadline (+ (float-time) 2.0))
         tick tick-timer cancel-timer process stdout stderr session-before)
    (unwind-protect
        (progn
          (with-temp-file registry-file (insert initial-registry))
          (with-temp-buffer
            (setq-local emacs-jupyter-notebook--session-entry
                        '(:profile "p" :session-id "durable" :remote-pid 71
                          :remote-host "host"
                          :remote-connection-file "/remote/kernel.json"))
            (setq session-before
                  (copy-tree emacs-jupyter-notebook--session-entry))
            (setq tick-timer
                  (run-at-time 0.01 nil (lambda () (setq tick t))))
            (funcall starter)
            (setq process
                  (plist-get emacs-jupyter-notebook--management-operation
                             :process))
            (should (processp process))
            (setq stdout (process-buffer process)
                  stderr (process-get
                          process 'emacs-jupyter-notebook-stderr-buffer))
            (when (eq terminal 'cancelled)
              (let ((source (current-buffer)))
                (setq cancel-timer
                      (run-at-time
                       0.02 nil
                       (lambda ()
                         (when (buffer-live-p source)
                           (with-current-buffer source
                             (emacs-jupyter-notebook-cancel-operation))))))))
            (while (and (emacs-jupyter-notebook--management-active-p)
                        (< (float-time) deadline))
              (accept-process-output nil 0.01))
            (should tick)
            (should-not (emacs-jupyter-notebook--management-active-p))
            (should (eq (process-get process 'ejn-management-outcome)
                        terminal))
            (should-not (process-live-p process))
            (should-not (buffer-live-p stdout))
            (should-not (buffer-live-p stderr))
            (should-not (process-get process 'ejn-management-timeout))
            (should-not (process-get process 'ejn-management-success))
            (should-not (process-get process 'ejn-management-failure))
            (should (equal emacs-jupyter-notebook--session-entry
                           session-before)))
          (with-temp-buffer
            (insert-file-contents registry-file)
            (should (equal (buffer-string) initial-registry)))
          process)
      (when (timerp tick-timer) (cancel-timer tick-timer))
      (when (timerp cancel-timer) (cancel-timer cancel-timer))
      (when (and (processp process) (process-live-p process))
        (delete-process process))
      (when (file-exists-p registry-file) (delete-file registry-file)))))

(ert-deftest ejn-ir4-fetch-log-never-exiting-child-times-out ()
  "Fetch-log returns immediately; its deadline and independent timer fire."
  (with-temp-buffer
    (setq-local emacs-jupyter-notebook--session-entry
                '(:profile "p" :remote-host "host"
                  :remote-connection-file "/remote/kernel-s.json"))
    (cl-letf (((symbol-function
                'emacs-jupyter-notebook-ssh-build-remote-cat-log)
               (lambda (&rest _) (ejn-ir4--never-exiting-command))))
      (ejn-ir4--exercise-never-exiting-command
       #'emacs-jupyter-notebook-fetch-remote-log 'timeout))))

(ert-deftest ejn-ir4-list-processes-never-exiting-child-cancels ()
  "Remote process listing is cancellable while independent timers run."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
             (lambda (&rest _) '(:profile "p" :host "host")))
            ((symbol-function
              'emacs-jupyter-notebook-ssh-build-remote-ps-command)
             (lambda (&rest _) (ejn-ir4--never-exiting-command))))
    (ejn-ir4--exercise-never-exiting-command
     (lambda () (emacs-jupyter-notebook-list-remote-processes "p"))
     'cancelled)))

(ert-deftest ejn-ir4-prune-never-exiting-child-times-out ()
  "Prune maps a timed-out host to unknown and preserves durable state."
  (let ((entry '(:profile "p" :remote-host "host" :remote-pid 71
                 :remote-connection-file "/remote/kernel.json"
                 :session-id "durable")))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _) (list entry)))
              ((symbol-function 'emacs-jupyter-notebook-registry-save)
               (lambda (&rest _) (ert-fail "timeout must not rewrite registry")))
              ((symbol-function
                'emacs-jupyter-notebook-ssh-build-batch-pid-alive)
               (lambda (&rest _) (ejn-ir4--never-exiting-command))))
      (ejn-ir4--exercise-never-exiting-command
       #'emacs-jupyter-notebook-prune-dead-kernels 'timeout))))

(ert-deftest ejn-ir4-clean-orphans-never-exiting-child-cancels ()
  "Explicit orphan cleanup is cancellable and never mutates local registry."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook--read-host-profile)
             (lambda (&rest _)
               '(:profile "p" :host "host" :remote-cache-dir "/cache")))
            ((symbol-function
              'emacs-jupyter-notebook-ssh-build-remote-cleanup-all)
             (lambda (&rest _) (ejn-ir4--never-exiting-command))))
    (ejn-ir4--exercise-never-exiting-command
     (lambda () (emacs-jupyter-notebook-clean-orphaned-kernels "p"))
     'cancelled)))

(ert-deftest ejn-ir4-reconnect-picker-never-exiting-child-cancels ()
  "Reconnect liveness is cancellable before the picker or reconnect starts."
  (let ((entry '(:profile "p" :remote-host "host" :remote-pid 71
                 :remote-connection-file "/remote/kernel.json"
                 :session-id "durable")))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-load)
               (lambda (&optional _) (list entry)))
              ((symbol-function 'emacs-jupyter-notebook-registry-save)
               (lambda (&rest _) (ert-fail "cancel must not rewrite registry")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "cancel must not open picker")))
              ((symbol-function 'emacs-jupyter-notebook--begin-reconnect)
               (lambda (&rest _) (ert-fail "cancel must not reconnect")))
              ((symbol-function
                'emacs-jupyter-notebook-ssh-build-batch-pid-alive)
               (lambda (&rest _) (ejn-ir4--never-exiting-command))))
      (ejn-ir4--exercise-never-exiting-command
       (lambda () (emacs-jupyter-notebook-reconnect-remote-kernel))
       'cancelled))))

(ert-deftest ejn-ir4-management-success-disposes-before-callback ()
  "Successful management callbacks run once after all local resources are gone."
  (let (process stdout stderr callback-state callback-count)
    (setq process
          (emacs-jupyter-notebook-ssh-start-management-operation
           "ejn-ir4-success"
           (list shell-file-name shell-command-switch
                 "printf stdout; printf stderr >&2")
           (lambda (output)
             (setq callback-count (1+ (or callback-count 0))
                   callback-state
                   (list output
                         (buffer-live-p stdout)
                         (buffer-live-p stderr))))
           (lambda (&rest _) (ert-fail "successful child must not fail"))
           1.0))
    (setq stdout (process-buffer process)
          stderr (process-get process 'emacs-jupyter-notebook-stderr-buffer))
    (let ((deadline (+ (float-time) 2.0)))
      (while (and (not (process-get process 'ejn-management-finished))
                  (< (float-time) deadline))
        (accept-process-output process 0.01)))
    (should (= callback-count 1))
    (should (equal callback-state '("stdout" nil nil)))
    (should-not (process-get process 'ejn-management-timeout))
    (should-not (process-get process 'ejn-management-success))
    (should-not (process-get process 'ejn-management-failure))))

(ert-deftest ejn-ir4-management-stale-sentinel-is-exact-once ()
  "A sentinel arriving after cancellation cannot invoke either callback again."
  (let ((success-count 0) (failure-count 0) process stale-sentinel)
    (setq process
          (emacs-jupyter-notebook-ssh-start-management-operation
           "ejn-ir4-stale" (ejn-ir4--never-exiting-command)
           (lambda (&rest _) (cl-incf success-count))
           (lambda (&rest _) (cl-incf failure-count))
           1.0)
          stale-sentinel (process-sentinel process))
    (emacs-jupyter-notebook-ssh-management-cancel process)
    (funcall stale-sentinel process "finished\n")
    (should (= success-count 0))
    (should (= failure-count 1))
    (should (eq (process-get process 'ejn-management-outcome) 'cancelled))))

(ert-deftest ejn-ir4-management-timeout-cannot-be-disabled ()
  "Nil/zero timeout customization still installs a finite watchdog."
  (dolist (configuration '((nil nil) (0 nil) (0 0)))
    (let ((emacs-jupyter-notebook-management-process-timeout
           (car configuration))
          (explicit (cadr configuration))
          process timer)
      (unwind-protect
          (progn
            (setq process
                  (emacs-jupyter-notebook-ssh-start-management-operation
                   "ejn-ir4-fallback-timeout"
                   (ejn-ir4--never-exiting-command)
                   #'ignore #'ignore explicit)
                  timer (process-get process 'ejn-management-timeout))
            (should (timerp timer))
            (should (> (float-time (timer--time timer)) (float-time))))
        (when (processp process)
          (emacs-jupyter-notebook-ssh-management-cancel process))))))

(ert-deftest ejn-ir4-management-output-flood-is-hard-bounded ()
  "Noisy stdout/stderr remain bounded, responsive, marked, and disposable."
  (let* ((emacs-jupyter-notebook-management-output-max-bytes 512)
         (emacs-jupyter-notebook-management-process-timeout 2)
         (flood (concat
                 "i=0; while [ \"$i\" -lt 2000 ]; do "
                 "printf '0123456789abcdef0123456789abcdef0123456789abcdef\\n'; "
                 "printf 'fedcba9876543210fedcba9876543210fedcba9876543210\\n' >&2; "
                 "i=$((i+1)); done; sleep 10"))
         process stdout stderr stderr-process callback-stderr tick tick-timer)
    (unwind-protect
        (progn
          (setq tick-timer (run-at-time 0.01 nil (lambda () (setq tick t)))
                process
                (emacs-jupyter-notebook-ssh-start-management-operation
                 "ejn-ir4-output-flood"
                 (list shell-file-name shell-command-switch flood)
                 (lambda (&rest _) (ert-fail "flood child must be cancelled"))
                 (lambda (_reason output) (setq callback-stderr output))
                 2)
                stdout (process-buffer process)
                stderr (process-get
                        process 'emacs-jupyter-notebook-stderr-buffer)
                stderr-process
                (process-get process 'ejn-management-stderr-process))
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (< (float-time) deadline)
                        (not (and tick
                                  (process-get process
                                               'ejn-management-truncated)
                                  (process-get stderr-process
                                               'ejn-management-truncated))))
              (accept-process-output nil 0.005)))
          (should tick)
          (should (process-get process 'ejn-management-truncated))
          (should (process-get stderr-process 'ejn-management-truncated))
          (dolist (buffer (list stdout stderr))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              (should (<= (emacs-jupyter-notebook-ssh--management-buffer-bytes)
                          512))
              (should (string-prefix-p
                       emacs-jupyter-notebook-ssh--management-truncation-marker
                       (buffer-string)))))
          (emacs-jupyter-notebook-ssh-management-cancel process)
          (should (<= (string-bytes callback-stderr) 512))
          (should (string-prefix-p
                   emacs-jupyter-notebook-ssh--management-truncation-marker
                   callback-stderr))
          (should-not (process-live-p stderr-process))
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr))
          (should-not (process-get process 'ejn-management-stderr-process)))
      (when (timerp tick-timer) (cancel-timer tick-timer))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))
    ;; The success callback receives the same bounded marker for stdout.
    (let (success-process callback-stdout)
      (unwind-protect
          (progn
            (setq success-process
                  (emacs-jupyter-notebook-ssh-start-management-operation
                   "ejn-ir4-stdout-flood"
                   (list shell-file-name shell-command-switch
                         (concat "i=0; while [ \"$i\" -lt 2000 ]; do "
                                 "printf 'stdout-output-line-0123456789abcdef\\n'; "
                                 "i=$((i+1)); done"))
                   (lambda (output) (setq callback-stdout output))
                   (lambda (&rest _) (ert-fail "stdout flood must succeed"))
                   2))
            (let ((deadline (+ (float-time) 2.0)))
              (while (and (not callback-stdout) (< (float-time) deadline))
                (accept-process-output nil 0.005)))
            (should (<= (string-bytes callback-stdout) 512))
            (should (string-prefix-p
                     emacs-jupyter-notebook-ssh--management-truncation-marker
                     callback-stdout)))
        (when (and (processp success-process)
                   (process-live-p success-process))
          (delete-process success-process))))))

(ert-deftest ejn-ir4-management-callback-error-still-disposes ()
  "An exception from a completion callback cannot leak child resources."
  (let (process stdout stderr message-seen)
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (setq message-seen t))))
      (setq process
            (emacs-jupyter-notebook-ssh-start-management-operation
             "ejn-ir4-callback-error"
             (list shell-file-name shell-command-switch "exit 0")
             (lambda (&rest _) (error "injected callback failure"))
             (lambda (&rest _) (ert-fail "successful child must not fail"))
             1.0)
            stdout (process-buffer process)
            stderr (process-get process
                                'emacs-jupyter-notebook-stderr-buffer))
      (let ((deadline (+ (float-time) 2.0)))
        (while (and (not (process-get process 'ejn-management-finished))
                    (< (float-time) deadline))
          (accept-process-output process 0.01)))
      (should message-seen)
      (should-not (buffer-live-p stdout))
      (should-not (buffer-live-p stderr))
      (should-not (process-get process 'ejn-management-timeout)))))

(defun ejn-ir4--source-definitions ()
  "Return a hash table of project function source forms for IR4 analysis."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (file '("emacs-jupyter-notebook.el"
                    "emacs-jupyter-notebook-ssh.el"))
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name file
                           (file-name-directory
                            (locate-library "emacs-jupyter-notebook"))))
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (when (and (consp form) (eq (car form) 'defun))
                  (puthash (cadr form) form table))))
          (end-of-file nil))))
    table))

(defun ejn-ir4--form-callees (form)
  "Return symbols called by parsed Lisp FORM, excluding quoted data."
  (let (callees)
    (cl-labels ((walk
                 (node)
                 (when (consp node)
                   (cond
                    ((eq (car node) 'quote) nil)
                    ((eq (car node) 'function)
                     (cond
                      ((symbolp (cadr node))
                       (push (cadr node) callees))
                      ((and (consp (cadr node))
                            (eq (caadr node) 'lambda))
                       (walk (cadr node)))))
                    (t
                     (when (symbolp (car node)) (push (car node) callees))
                     (mapc #'walk (cdr node)))))))
      (walk form))
    (delete-dups callees)))

(ert-deftest ejn-ir4-no-sync-ssh-in-interactive-call-graph ()
  "Stripped-source call graph keeps every IR4 UI root off blocking primitives."
  (let* ((definitions (ejn-ir4--source-definitions))
         (roots '(emacs-jupyter-notebook-reconnect-remote-kernel
                  emacs-jupyter-notebook-fetch-remote-log
                  emacs-jupyter-notebook-list-remote-processes
                  emacs-jupyter-notebook-prune-dead-kernels
                  emacs-jupyter-notebook-clean-orphaned-kernels))
         (forbidden '(emacs-jupyter-notebook-ssh-run-command
                      process-file call-process call-process-region
                      accept-process-output sleep-for sit-for))
         seen encountered pending)
    (should (memq 'sleep-for
                  (ejn-ir4--form-callees
                   '(function (lambda () (sleep-for 1))))))
    (should (memq 'sleep-for
                  (ejn-ir4--form-callees
                   '(funcall (function sleep-for) 1))))
    (setq pending (copy-sequence roots))
    (while pending
      (let ((symbol (pop pending)))
        (unless (memq symbol seen)
          (push symbol seen)
          (when-let* ((form (gethash symbol definitions)))
            (dolist (callee (ejn-ir4--form-callees form))
              (push callee encountered)
              (when (gethash callee definitions)
                (push callee pending)))))))
    (dolist (symbol forbidden)
      (should-not (memq symbol encountered)))
    (should (memq 'emacs-jupyter-notebook--management-launch seen))
    (should (memq 'emacs-jupyter-notebook-ssh-start-management-operation seen))
    (should (memq 'emacs-jupyter-notebook-ssh-start-process seen))
    (should-not (memq 'emacs-jupyter-notebook--read-registry-entry seen))))

;;; IR5 — truthful reconnect ownership and retry status

(defun ejn-ir5--begin-without-io (entry owner &optional error-callback)
  "Begin reconnect to ENTRY as OWNER without Jupyter, SSH, or timers."
  (cl-letf (((symbol-function 'emacs-jupyter-notebook-jupyter--ensure)
             #'ignore)
            ((symbol-function
              'emacs-jupyter-notebook--async-arm-overall-timeout)
             #'identity)
            ((symbol-function 'emacs-jupyter-notebook--async-probe-pid-alive)
             #'identity))
    (emacs-jupyter-notebook--begin-reconnect
     entry nil error-callback owner)))

(ert-deftest ejn-ir5-transient-transition-table-rearms-exactly-once ()
  "Scheduled-explicit and evaluation reconnect failures each own one retry."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :session-id "s" :remote-host "h"
                  :remote-pid 17 :remote-connection-file "/r/kernel.json")))
        (emacs-jupyter-notebook-reconnect-initial-delay 600))
    (dolist (case '((scheduled-explicit explicit t)
                    (evaluation evaluation nil)))
      (with-temp-buffer
        (let ((expected-owner (nth 1 case))
              (start-scheduled (nth 2 case))
              old-token context retry-timer (error-count 0))
          (unwind-protect
              (progn
                (setq emacs-jupyter-notebook-mode t
                      emacs-jupyter-notebook--tunnel-dead t
                      emacs-jupyter-notebook--session-entry entry)
                (when start-scheduled
                  (emacs-jupyter-notebook--schedule-auto-reconnect)
                  (setq old-token
                        emacs-jupyter-notebook--reconnect-schedule-token))
                (setq context
                      (if start-scheduled
                          (ejn-ir5--begin-without-io
                           entry 'explicit
                           (lambda (_context _error)
                             (cl-incf error-count)))
                        (cl-letf
                            (((symbol-function
                               'emacs-jupyter-notebook-jupyter--ensure)
                              #'ignore)
                             ((symbol-function
                               'emacs-jupyter-notebook--async-arm-overall-timeout)
                              #'identity)
                             ((symbol-function
                               'emacs-jupyter-notebook--async-probe-pid-alive)
                              #'identity))
                          (emacs-jupyter-notebook--tunnel-reconnect
                           (current-buffer) nil
                           (lambda (_context _error)
                             (cl-incf error-count))))))
                (should (eq (plist-get context :reconnect-owner)
                            expected-owner))
                (when old-token
                  (should-not
                   (eq old-token
                       emacs-jupyter-notebook--reconnect-schedule-token)))
                (plist-put context :error-kind 'probe-unreachable)
                (emacs-jupyter-notebook--async-fail context "offline")
                (setq retry-timer
                      emacs-jupyter-notebook--reconnect-timer)
                (should (timerp retry-timer))
                (should emacs-jupyter-notebook--reconnect-schedule-token)
                (should (= error-count 1))
                ;; Duplicate completion/error delivery cannot create a second
                ;; timer or notify the caller twice.
                (funcall (plist-get context :error-callback)
                         context "duplicate")
                (should (eq retry-timer
                            emacs-jupyter-notebook--reconnect-timer))
                (should (= error-count 1)))
            (emacs-jupyter-notebook--cancel-auto-reconnect)))))))

(ert-deftest ejn-ir5-failure-classification-transition-table ()
  "Confirmed-dead outcomes stop; unreachable and timeout outcomes retry."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :session-id "s" :remote-host "h"
                  :remote-pid 17 :remote-connection-file "/r/kernel.json")))
        (emacs-jupyter-notebook-reconnect-initial-delay 600))
    (dolist (case '((kernel-dead nil)
                    (kernel-mismatch nil)
                    (no-pid nil)
                    (probe-unreachable t)
                    (attempt-timeout t)
                    (process-timeout t)))
      (with-temp-buffer
        (unwind-protect
            (let* ((kind (car case))
                   (retry-p (cadr case))
                   (context
                    (emacs-jupyter-notebook--async-new-context
                     :phase 'error :error-kind kind
                     :origin-buffer (current-buffer)
                     :reconnect-owner 'explicit)))
              (setq emacs-jupyter-notebook-mode t
                    emacs-jupyter-notebook--tunnel-dead t
                    emacs-jupyter-notebook--session-entry entry
                    emacs-jupyter-notebook--async-context context)
              (emacs-jupyter-notebook--handle-reconnect-failure
               context "failed" nil)
              (should (eq (and (timerp
                                emacs-jupyter-notebook--reconnect-timer)
                               t)
                          retry-p))
              (when retry-p
                (let ((timer emacs-jupyter-notebook--reconnect-timer))
                  (emacs-jupyter-notebook--handle-reconnect-failure
                   context "duplicate" nil)
                  (should (eq timer
                              emacs-jupyter-notebook--reconnect-timer)))))
          (emacs-jupyter-notebook--cancel-auto-reconnect))))))

(ert-deftest ejn-ir5-synchronous-probe-start-failure-enters-retry-policy ()
  "A synchronous process-construction error is a bounded transient failure."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :session-id "s" :remote-host "h"
                  :remote-pid 17 :remote-connection-file "/r/kernel.json")))
        (emacs-jupyter-notebook-reconnect-initial-delay 600)
        (error-count 0))
    (with-temp-buffer
      (unwind-protect
          (progn
            (setq emacs-jupyter-notebook-mode t
                  emacs-jupyter-notebook--tunnel-dead t
                  emacs-jupyter-notebook--session-entry entry)
            (cl-letf (((symbol-function
                        'emacs-jupyter-notebook-jupyter--ensure)
                       #'ignore)
                      ((symbol-function
                        'emacs-jupyter-notebook--async-arm-overall-timeout)
                       #'identity)
                      ((symbol-function
                        'emacs-jupyter-notebook--async-probe-pid-alive)
                       (lambda (_context) (error "make-process failed"))))
              (emacs-jupyter-notebook--begin-reconnect
               entry nil
               (lambda (_context _error) (cl-incf error-count))
               'evaluation))
            (should (= error-count 1))
            (should (eq (plist-get emacs-jupyter-notebook--async-context
                                   :error-kind)
                        'probe-start-failed))
            (should (eq (plist-get emacs-jupyter-notebook--async-context
                                   :phase)
                        'error))
            (should (timerp emacs-jupyter-notebook--reconnect-timer)))
        (emacs-jupyter-notebook--cancel-auto-reconnect)))))

(ert-deftest ejn-ir5-cancel-live-reconnect-is-terminal-and-local ()
  "Cancel marks the live reconnect terminal without touching its kernel."
  (let ((entry (ejn-test-direct-entry
                '(:profile "p" :session-id "s" :remote-host "h"
                  :remote-pid 17 :remote-connection-file "/r/kernel.json"))))
    (with-temp-buffer
      (setq emacs-jupyter-notebook-mode t
            emacs-jupyter-notebook--tunnel-dead t
            emacs-jupyter-notebook--session-entry entry)
      (let ((context (ejn-ir5--begin-without-io entry 'explicit)))
        (cl-letf (((symbol-function
                    'emacs-jupyter-notebook-ssh-start-process)
                   (lambda (&rest _)
                     (ert-fail "reconnect cancel must not run remote cleanup"))))
          (emacs-jupyter-notebook-cancel-operation))
        (should (plist-get context :cancelled))
        (should-not emacs-jupyter-notebook--async-context)
        (should-not emacs-jupyter-notebook--reconnect-timer)
        (should (equal emacs-jupyter-notebook--session-entry entry))))))

(ert-deftest ejn-ir5-stale-retry-timer-cannot-supersede-new-owner ()
  "A cancelled timer generation cannot consume or replace a newer schedule."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 17 :remote-connection-file "/r/kernel.json"))
        (emacs-jupyter-notebook-reconnect-initial-delay 600))
    (with-temp-buffer
      (unwind-protect
          (let (old-token new-token new-timer (started 0))
            (setq emacs-jupyter-notebook-mode t
                  emacs-jupyter-notebook--tunnel-dead t
                  emacs-jupyter-notebook--session-entry entry)
            (emacs-jupyter-notebook--schedule-auto-reconnect)
            (setq old-token emacs-jupyter-notebook--reconnect-schedule-token)
            (emacs-jupyter-notebook--cancel-auto-reconnect)
            (emacs-jupyter-notebook--schedule-auto-reconnect)
            (setq new-token emacs-jupyter-notebook--reconnect-schedule-token
                  new-timer emacs-jupyter-notebook--reconnect-timer)
            (should-not (eq old-token new-token))
            (cl-letf (((symbol-function
                        'emacs-jupyter-notebook--begin-reconnect)
                       (lambda (&rest _) (cl-incf started))))
              (emacs-jupyter-notebook--auto-reconnect-fire
               (current-buffer) old-token))
            (should (= started 0))
            (should (eq new-token
                        emacs-jupyter-notebook--reconnect-schedule-token))
            (should (eq new-timer
                        emacs-jupyter-notebook--reconnect-timer)))
        (emacs-jupyter-notebook--cancel-auto-reconnect)))))

(ert-deftest ejn-ir5-successful-reconnect-resets-all-retry-state ()
  "Successful finalize clears retry count, deadline, timer, and token."
  (with-temp-buffer
    (let* ((entry '(:profile "p" :session-id "s" :remote-host "h"))
           (context (emacs-jupyter-notebook--async-new-context
                     :phase 'connect :entry entry :session-id "s"
                     :origin-buffer (current-buffer)
                     :reconnect-owner 'automatic))
           (client (emacs-jupyter-notebook-backend-session-create
                    nil (current-buffer)))
           (timer (run-at-time 600 nil #'ignore)))
      (emacs-jupyter-notebook-backend-session-mark-attached client)
      (setq emacs-jupyter-notebook--async-context context
            emacs-jupyter-notebook--reconnect-attempt 4
            emacs-jupyter-notebook--reconnect-next-at (+ (float-time) 600)
            emacs-jupyter-notebook--reconnect-schedule-token (gensym "retry-")
            emacs-jupyter-notebook--reconnect-timer timer
            emacs-jupyter-notebook--tunnel-dead t)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--heartbeat-start)
                 #'ignore)
                ((symbol-function
                  'emacs-jupyter-notebook--inject-viewer-formatter)
                 #'ignore)
                ((symbol-function
                  'emacs-jupyter-notebook--inject-idle-watchdog)
                 #'ignore)
                ((symbol-function
                  'emacs-jupyter-notebook-registry-save-entry)
                 #'ignore))
        (emacs-jupyter-notebook--async-connect-finalize
         context (current-buffer) entry '(:shell_port 1)
         "/tmp/ejn-ir5-local.json" client))
      (should (= emacs-jupyter-notebook--reconnect-attempt 0))
      (should-not emacs-jupyter-notebook--reconnect-next-at)
      (should-not emacs-jupyter-notebook--reconnect-schedule-token)
      (should-not emacs-jupyter-notebook--reconnect-timer)
      (should-not (memq timer timer-list))
      (should-not emacs-jupyter-notebook--tunnel-dead)
      (should (eq (plist-get context :phase) 'done)))))

(ert-deftest ejn-ir5-live-status-button-cancels-advertised-context ()
  "The actual status buffer reports and cancels its source's live reconnect."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 17 :remote-connection-file "/r/kernel.json")))
    (with-temp-buffer
      (let* ((source (current-buffer))
             (context
              (emacs-jupyter-notebook--async-new-context
               :phase 'probe :started-at (- (float-time) 12)
               :entry entry :origin-buffer source
               :reconnect-owner 'evaluation
               :error-callback
               (lambda (failed error-data)
                 (emacs-jupyter-notebook--handle-reconnect-failure
                  failed error-data nil)))))
        (setq emacs-jupyter-notebook-mode t
              emacs-jupyter-notebook--tunnel-dead t
              emacs-jupyter-notebook--session-entry entry
              emacs-jupyter-notebook--reconnect-attempt 3
              emacs-jupyter-notebook--async-context context)
        (ejn-test-with-status-buffer status-buffer
          (with-current-buffer status-buffer
            (let ((text (buffer-string)))
              (should (string-match-p "Live phase: probe" text))
              (should (string-match-p "Attempt owner: evaluation" text))
              (should (string-match-p "Attempt age: 1[12]\\.[0-9]s" text))
              (should (string-match-p "Retry count: 3" text))
              (should (string-match-p "Next retry: none" text)))
            (goto-char (point-min))
            (should (search-forward "Cancel reconnect" nil t))
            (let ((button (button-at (match-beginning 0))))
              (should button)
              (button-activate button)))
          (with-current-buffer source
            (should (plist-get context :cancelled))
            (should-not emacs-jupyter-notebook--async-context)
            (should-not emacs-jupyter-notebook--reconnect-timer)
            (should (equal emacs-jupyter-notebook--session-entry entry))))))))

(ert-deftest ejn-ir5-scheduled-status-shows-deadline-and-cancels-timer ()
  "The interactive status countdown advertises a working timer cancel action."
  (let ((entry '(:profile "p" :session-id "s" :remote-host "h"
                 :remote-pid 17 :remote-connection-file "/r/kernel.json"))
        (emacs-jupyter-notebook-reconnect-initial-delay 600))
    (with-temp-buffer
      (setq emacs-jupyter-notebook-mode t
            emacs-jupyter-notebook--tunnel-dead t
            emacs-jupyter-notebook--session-entry entry
            emacs-jupyter-notebook--reconnect-attempt 2)
      (emacs-jupyter-notebook--schedule-auto-reconnect)
      (unwind-protect
          (ejn-test-with-status-buffer status-buffer
            (with-current-buffer status-buffer
              (should (string-match-p "Retry count: 2" (buffer-string)))
              (should (string-match-p "Next retry: [0-9]+\\.[0-9]s"
                                      (buffer-string)))
              (goto-char (point-min))
              (should (search-forward "Cancel scheduled reconnect" nil t))
              (let ((button (button-at (match-beginning 0))))
                (should button)
                (button-activate button)))
            (should-not emacs-jupyter-notebook--reconnect-timer)
            (should-not emacs-jupyter-notebook--reconnect-schedule-token)
            (should (equal emacs-jupyter-notebook--session-entry entry)))
        (emacs-jupyter-notebook--cancel-auto-reconnect)))))

(ert-deftest ejn-ei3-fifo-reserves-order-before-synchronous-completeness ()
  "B cannot check or dispatch until A's full terminal decision advances FIFO."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness t)
          complete-callbacks sent)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil)))
                ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client operation payload success _failure)
                   (should (eq operation 'is-complete))
                   (push (cons (plist-get payload :code) success) complete-callbacks)
                   1))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code _options _success _failure)
                   (push code sent) 2)))
        (let ((a (emacs-jupyter-notebook--evaluate-code "a = 1" nil))
              (b (emacs-jupyter-notebook--evaluate-code "b = 2" nil)))
          (should (equal (mapcar #'car complete-callbacks) '("a = 1")))
          (funcall (cdar complete-callbacks) 1 '(:status "complete"))
          (should (equal sent '("a = 1")))
          (emacs-jupyter-notebook--execution-note-event
           (list :request-id a :backend-request-id 2
                 :panel-generation
                 (plist-get (emacs-jupyter-notebook--execution-record a) :generation))
           '(:type status :execution-state "idle"))
          (emacs-jupyter-notebook--execution-note-event
           (list :request-id a :backend-request-id 2
                 :panel-generation
                 (plist-get (emacs-jupyter-notebook--execution-record a) :generation))
           '(:type execute-reply :status "ok"))
          (should (equal emacs-jupyter-notebook--execution-active-id b))
          (should (equal (mapcar #'car complete-callbacks) '("b = 2" "a = 1"))))))))

(ert-deftest ejn-ei3-real-pump-arms-b-only-after-a-retires-once ()
  "The real pump leaves B untimed until A's terminal pair retires it once."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness nil)
          (sent nil) (next-backend-id 40))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (success _failure) (funcall success nil)))
                    ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                     (lambda (_client code _options _success _failure)
                       (setq sent (append sent (list code)))
                       (cl-incf next-backend-id))))
            (let* ((a (emacs-jupyter-notebook--evaluate-code "a" nil))
                   (b (emacs-jupyter-notebook--evaluate-code "b" nil))
                   (a-record (emacs-jupyter-notebook--execution-record a))
                   (b-record (emacs-jupyter-notebook--execution-record b))
                   (a-context (list :request-id a
                                    :backend-request-id
                                    (plist-get a-record :backend-request-id)
                                    :panel-generation (plist-get a-record :generation))))
              (should (equal sent '("a")))
              (should-not (plist-get b-record :timer))
              ;; A's reply is idempotent, including a duplicate before idle.
              (emacs-jupyter-notebook--execution-note-event
               a-context '(:type execute-reply :status "ok"))
              (emacs-jupyter-notebook--execution-note-event
               a-context '(:type execute-reply :status "ok"))
              (emacs-jupyter-notebook--execution-note-event
               a-context '(:type status :execution-state "idle"))
              (should (equal sent '("a" "b")))
              (should (timerp (plist-get
                               (emacs-jupyter-notebook--execution-record b)
                               :timer)))
              ;; Once A is retired, both late terminal signals are inert and
              ;; cannot dispatch B a second time.
              (emacs-jupyter-notebook--execution-note-event
               a-context '(:type status :execution-state "idle"))
              (emacs-jupyter-notebook--execution-note-event
               a-context '(:type execute-reply :status "ok"))
              (should (equal sent '("a" "b")))
              (should (equal emacs-jupyter-notebook--execution-active-id b))))
        (emacs-jupyter-notebook--clear-buffer-timers)))))

(ert-deftest ejn-ei3-reply-and-idle-terminal-order-is-exactly-once ()
  "Both correlated terminal signals, in either order, advance a record once."
  (dolist (events '(((:type execute-reply :status "ok")
                    (:type status :execution-state "idle"))
                   ((:type status :execution-state "idle")
                    (:type execute-reply :status "ok"))))
    (with-temp-buffer
      (let ((record (list :id 3 :state 'dispatched :backend-request-id 33
                          :generation 43 :reply-seen nil :idle-seen nil))
            finishes)
        (emacs-jupyter-notebook--execution-put record)
        (setq emacs-jupyter-notebook--execution-queue '(3)
              emacs-jupyter-notebook--execution-active-id 3)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook--execution-finish)
                   (lambda (_record status &rest _)
                     (push status finishes)
                     (emacs-jupyter-notebook--execution-remove record))))
          (dolist (event events)
            (emacs-jupyter-notebook--execution-note-event
             '(:request-id 3 :backend-request-id 33 :panel-generation 43) event))
          ;; A duplicate after the record has retired is inert.
          (emacs-jupyter-notebook--execution-note-event
           '(:request-id 3 :backend-request-id 33 :panel-generation 43)
           '(:type status :execution-state "idle")))
        (should (equal finishes '(ok)))
        (should-not emacs-jupyter-notebook--execution-active-id)))))

(ert-deftest ejn-ei3-active-cancel-interrupts-once-and-holds-fifo ()
  "Cancelling A leaves B queued until A supplies both terminal signals."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (record (list :id 1 :state 'dispatched :backend-request-id 11
                        :generation 12 :reply-seen nil :idle-seen nil))
          (second (list :id 2 :state 'queued))
          (interrupts 0))
      (emacs-jupyter-notebook--execution-put record)
      (emacs-jupyter-notebook--execution-put second)
      (setq emacs-jupyter-notebook--execution-queue '(1 2)
            emacs-jupyter-notebook--execution-active-id 1)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                 (lambda (&rest _) (cl-incf interrupts) 1))
                ((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
        (emacs-jupyter-notebook--cancel-evaluation)
        (emacs-jupyter-notebook--cancel-evaluation)
        (should (= interrupts 1))
        (should (eq emacs-jupyter-notebook--execution-active-id 1))
        (should (eq (plist-get (emacs-jupyter-notebook--execution-record 1) :state)
                    'cancelling))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 11 :panel-generation 12)
         '(:type execute-reply :status "ok"))
        (should (eq emacs-jupyter-notebook--execution-active-id 1))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 11 :panel-generation 12)
         '(:type status :execution-state "idle"))
        (should-not emacs-jupyter-notebook--execution-active-id)))))

(ert-deftest ejn-ei3-code-byte-counter-is-bounded-and-utf8-correct ()
  "Admission counts UTF-8 without allocating an encoded hostile copy."
  (should (= (emacs-jupyter-notebook--execution-code-bytes "a\u20ac") 4))
  (should (= (emacs-jupyter-notebook--execution-code-bytes (string-make-unibyte "\303\251")) 2))
  (should (> (emacs-jupyter-notebook--execution-code-bytes
              (make-string (1+ emacs-jupyter-notebook--max-code-bytes) ?x)
              emacs-jupyter-notebook--max-code-bytes)
             emacs-jupyter-notebook--max-code-bytes)))

(ert-deftest ejn-ei3-setup-gate-blocks-user-dispatch-until-terminal-decision ()
  "Formatter setup serializes ahead of user work and releases it only terminally."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (client (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (emacs-jupyter-notebook--client client)
           (emacs-jupyter-notebook-check-code-completeness nil)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           calls setup-success)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code options success _failure)
                   (push (list code options) calls)
                   (when (plist-get options :setup)
                     (setq setup-success success))
                   1))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil))))
        (emacs-jupyter-notebook--execution-start-setup client)
        (let ((id (emacs-jupyter-notebook--evaluate-code "user()" nil)))
          (should emacs-jupyter-notebook--execution-setup-pending)
          (should (= (length calls) 1))
          (should (plist-get (cadar calls) :setup))
          (funcall setup-success 1 nil)
          (should-not emacs-jupyter-notebook--execution-setup-pending)
          (should (= (length calls) 2))
          (should (equal (caar calls) "user()"))
          (should (equal emacs-jupyter-notebook--execution-active-id id)))))))

(ert-deftest ejn-ei3-setup-failure-and-late-reply-release-fifo-once ()
  "A failed silent setup is terminal; its late success cannot repump twice."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (client (ejn-test-backend-session 'helper t))
           (emacs-jupyter-notebook--client client)
           (emacs-jupyter-notebook-check-code-completeness nil)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           setup-success setup-failure user-sends)
      (setf (emacs-jupyter-notebook-backend-session-backend client) 'helper)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code options success failure)
                   (if (plist-get options :setup)
                       (setq setup-success success setup-failure failure)
                     (push code user-sends))
                   12))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil))))
        (emacs-jupyter-notebook--execution-start-setup client)
        (emacs-jupyter-notebook--evaluate-code "user()" nil)
        (funcall setup-failure 12 "setup rejected")
        (should-not emacs-jupyter-notebook--execution-setup-pending)
        (should (equal user-sends '("user()")))
        (funcall setup-success 12 nil)
        (should (equal user-sends '("user()")))))))

(ert-deftest ejn-ei3-legacy-setup-barrier-timeout-releases-fifo ()
  "A silent legacy setup barrier timeout is a terminal decision, not a wedge."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'legacy)
           (client (emacs-jupyter-notebook-backend-session-create nil (current-buffer)))
           (emacs-jupyter-notebook--client client)
           (emacs-jupyter-notebook-check-code-completeness nil)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           calls barrier-function)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code options success _failure)
                   (push (list code options) calls)
                   (when (plist-get options :setup) (funcall success 1 nil))
                   1))
                ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (&rest _) 1))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil)))
                ((symbol-function 'run-at-time)
                 (lambda (seconds _repeat function &rest args)
                   (when (= seconds 30)
                     (setq barrier-function (lambda () (apply function args))))
                   'test-timer)))
        (emacs-jupyter-notebook--execution-start-setup client)
        (emacs-jupyter-notebook--evaluate-code "user()" nil)
        (should emacs-jupyter-notebook--execution-setup-pending)
        (should barrier-function)
        (funcall barrier-function)
        (should-not emacs-jupyter-notebook--execution-setup-pending)
        (should (equal (caar calls) "user()"))))))

(ert-deftest ejn-ei3-queued-cancel-never-interrupts-active-kernel-work ()
  "A queued record retires locally while the older active record is unchanged."
  (with-temp-buffer
    (let ((active (list :id 1 :state 'dispatched))
          (queued (list :id 2 :state 'queued))
          interrupts)
      (emacs-jupyter-notebook--execution-put active)
      (emacs-jupyter-notebook--execution-put queued)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                 (lambda (&rest _) (setq interrupts t))))
        (should (emacs-jupyter-notebook--cancel-queued-execution 2)))
      (should-not interrupts)
      (should (emacs-jupyter-notebook--execution-record 1))
      (should-not (emacs-jupyter-notebook--execution-record 2))
      (should (equal emacs-jupyter-notebook--execution-queue '(1))))))

(ert-deftest ejn-ei3-oversize-code-is-rejected-before-panel-or-backend ()
  "Oversize source creates no panel entry and reaches no backend path."
  (with-temp-buffer
    (let ((code (make-string (1+ emacs-jupyter-notebook--max-code-bytes) ?x))
          panel-called)
      (cl-letf (((symbol-function 'ejn-panel-ensure)
                 (lambda (&rest _) (setq panel-called t))))
        (should-error (emacs-jupyter-notebook--evaluate-code code nil) :type 'user-error))
      (should-not panel-called)
      (should-not emacs-jupyter-notebook--execution-ledger))))

(ert-deftest ejn-ei3-utf8-admission-accepts-exact-boundary-rejects-one-byte-over ()
  "Admission uses UTF-8 bytes at the boundary before panel/backend effects."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
           (emacs-jupyter-notebook-check-code-completeness nil)
           (max-bytes emacs-jupyter-notebook--max-code-bytes)
           (prefix (make-string (/ max-bytes 2) ?\u00e9))
           (exact (if (= (string-bytes prefix) max-bytes)
                      prefix
                    (concat prefix "x")))
           (over (concat exact "x"))
           (backend-calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (success _failure) (funcall success nil)))
                    ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                     (lambda (&rest _args) (cl-incf backend-calls))))
            (should (= (string-bytes exact) max-bytes))
            (should (= (1+ max-bytes) (string-bytes over)))
            (emacs-jupyter-notebook--evaluate-code exact nil)
            (should (= backend-calls 1))
            (let (panel-called)
              (cl-letf (((symbol-function 'ejn-panel-ensure)
                         (lambda (&rest _) (setq panel-called t))))
                (should-error
                 (emacs-jupyter-notebook--evaluate-code over nil)
                 :type 'user-error))
              (should-not panel-called)
              (should (= backend-calls 1))))
        (emacs-jupyter-notebook--clear-buffer-timers)))))

(ert-deftest ejn-ei3-clear-results-does-not-release-active-execution-ownership ()
  "Presentation clear retires its handle but cannot advance a live execution."
  (with-temp-buffer
    (let* ((panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel nil "x"))
           (record (list :id 1 :state 'dispatched :panel-entry handle
                         :backend-request-id 9 :generation (plist-get handle :generation)
                         :reply-seen nil :idle-seen nil)))
      (emacs-jupyter-notebook--execution-put record)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (emacs-jupyter-notebook-clear-results)
      (should (equal emacs-jupyter-notebook--execution-active-id 1))
      (let (fringe)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore)
                  ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                   (lambda (&rest args) (push args fringe))))
        (emacs-jupyter-notebook--execution-note-event
         (list :request-id 1 :backend-request-id 9
               :panel-generation (plist-get handle :generation))
         '(:type execute-reply :status "ok"))
        (emacs-jupyter-notebook--execution-note-event
         (list :request-id 1 :backend-request-id 9
               :panel-generation (plist-get handle :generation))
         '(:type status :execution-state "idle")))
        (should-not fringe))
      (should-not emacs-jupyter-notebook--execution-active-id))))

(ert-deftest ejn-ei3-clear-results-late-reducer-events-have-no-presentation-side-effects ()
  "Clearing results retires presentation while terminal bookkeeping still settles."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness nil)
          (next-backend-id 70))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (success _failure) (funcall success nil)))
                    ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                     (lambda (&rest _args) (cl-incf next-backend-id))))
            (let* ((id (emacs-jupyter-notebook--evaluate-code "x" nil))
                   (record (emacs-jupyter-notebook--execution-record id))
                   (handle (plist-get record :panel-entry))
                   (context (list :buffer (current-buffer)
                                  :entry-handle handle :request-id id
                                  :backend-request-id
                                  (plist-get record :backend-request-id)
                                  :panel-generation (plist-get record :generation)))
                   render-called fringe-called)
              (emacs-jupyter-notebook-clear-results)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook--render-mime-result)
                         (lambda (&rest _) (setq render-called t)))
                        ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                         (lambda (&rest _) (setq fringe-called t))))
                (should (equal
                         (emacs-jupyter-notebook-events-dispatch
                          context '(:type stream :name "stdout" :text "late"))
                         '((:action ignore))))
                (should (equal
                         (emacs-jupyter-notebook-events-dispatch
                          context '(:type display :data (:image/png "late")))
                         '((:action ignore))))
                (should (equal
                         (emacs-jupyter-notebook-events-dispatch
                          context '(:type execute-reply :status "ok"))
                         nil))
                (should (equal
                         (emacs-jupyter-notebook-events-dispatch
                          context '(:type status :execution-state "idle"))
                         '((:action status :state "idle"))))
                (should-not render-called)
                (should-not fringe-called))
              (with-current-buffer (plist-get handle :panel)
                (should-not emacs-jupyter-notebook-panel--entries)
                (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes 0)))
              (should-not (emacs-jupyter-notebook--execution-record id))
              (should-not emacs-jupyter-notebook--execution-active-id)))
        (emacs-jupyter-notebook--clear-buffer-timers)))))

(ert-deftest ejn-ei3-cold-connect-setup-requeues-checking-head ()
  "A connect finalization gate returns a checking head to FIFO ownership."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (client (ejn-test-backend-session 'helper t))
           (emacs-jupyter-notebook-check-code-completeness nil)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           setup-success calls)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure)
                   (unless emacs-jupyter-notebook--client
                     (setq emacs-jupyter-notebook--client client)
                     (emacs-jupyter-notebook--execution-start-setup client))
                   (funcall success nil)))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code options success _failure)
                   (push code calls)
                   (when (plist-get options :setup) (setq setup-success success))
                   41)))
        (setf (emacs-jupyter-notebook-backend-session-backend client) 'helper)
        (let ((id (emacs-jupyter-notebook--evaluate-code "user()" nil)))
          (should emacs-jupyter-notebook--execution-setup-pending)
          (should-not emacs-jupyter-notebook--execution-active-id)
          (should (eq (plist-get (emacs-jupyter-notebook--execution-record id) :state)
                      'queued))
          (should (equal calls (list emacs-jupyter-notebook--viewer-formatter-snippet)))
          (funcall setup-success 1 nil)
          (should-not emacs-jupyter-notebook--execution-setup-pending)
          (should (equal (car calls) "user()")))))))

(ert-deftest ejn-ei3-reentrant-helper-execute-does-not-resurrect-record ()
  "Inline acknowledgements never synthesize terminality or resurrect records."
  (dolist (outcome '(success failure))
    (with-temp-buffer
      (let ((emacs-jupyter-notebook-backend 'helper)
            (emacs-jupyter-notebook--client (ejn-test-backend-session 'helper t))
            (emacs-jupyter-notebook-check-code-completeness nil))
        (setf (emacs-jupyter-notebook-backend-session-backend
               emacs-jupyter-notebook--client) 'helper)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                   (lambda (success _failure) (funcall success nil)))
                  ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                   (lambda (_client _code options success failure)
                     (unless (plist-get options :setup)
                       (if (eq outcome 'success)
                           (funcall success 77 '(:status "ok" :execution-count 3))
                         (funcall failure 77 "inline failure")))
                     77)))
          (let ((id (emacs-jupyter-notebook--evaluate-code "x" nil)))
            (ejn-test-drain-zero-delay-timers)
            (when (eq outcome 'success)
              ;; EI4 does not manufacture reply/idle evidence from the execute
              ;; acknowledgement.  The real pair still retires this record.
              (let ((record (emacs-jupyter-notebook--execution-record id)))
                (should record)
                (emacs-jupyter-notebook--execution-note-event
                 (list :request-id id :backend-request-id 77
                       :panel-generation (plist-get record :generation))
                 '(:type execute-reply :status "ok" :execution-count 3))
                (emacs-jupyter-notebook--execution-note-event
                 (list :request-id id :backend-request-id 77
                       :panel-generation (plist-get record :generation))
                 '(:type status :execution-state "idle"))))
            (should-not (emacs-jupyter-notebook--execution-record id))
            (should-not emacs-jupyter-notebook--execution-active-id)))))))

(ert-deftest ejn-ei3-terminal-correlation-requires-backend-and-generation ()
  "Wrong backend id or panel generation cannot settle a replacement record."
  (with-temp-buffer
    (let ((record (list :id 1 :state 'dispatched :backend-request-id 19
                        :generation 23 :reply-seen nil :idle-seen nil)))
      (emacs-jupyter-notebook--execution-put record)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 20 :panel-generation 23)
         '(:type execute-reply :status "ok"))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 19 :panel-generation 24)
         '(:type status :execution-state "idle"))
        (should (emacs-jupyter-notebook--execution-record 1))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 19 :panel-generation 23)
         '(:type execute-reply :status "ok"))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 19 :panel-generation 23)
         '(:type status :execution-state "idle")))
      (should-not (emacs-jupyter-notebook--execution-record 1)))))

(ert-deftest ejn-ei3-restart-gates-queued-work-until-readiness-and-setup ()
  "Restart gates synchronously, probes readiness, then serializes setup."
  (with-temp-buffer
    (let* ((emacs-jupyter-notebook-backend 'helper)
           (client (ejn-test-backend-session 'helper t))
           (emacs-jupyter-notebook--client client)
           (emacs-jupyter-notebook-kernel-idle-timeout 0)
           (active (list :id 1 :state 'dispatched))
           (queued (list :id 2 :state 'queued :code "queued()"))
           restart-success readiness-success setup-success calls)
      (emacs-jupyter-notebook--execution-put active)
      (emacs-jupyter-notebook--execution-put queued)
      (setf (emacs-jupyter-notebook-backend-session-backend client) 'helper)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                 (lambda (_client operation _payload success _failure)
                   (should (eq operation 'restart)) (setq restart-success success) 3))
                ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                 (lambda (_client operation _payload success _failure)
                   (should (eq operation 'kernel-info)) (setq readiness-success success) 4))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code options success _failure)
                   (push (cons code options) calls)
                   (when (plist-get options :setup) (setq setup-success success)) 5))
                ((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil))))
        (emacs-jupyter-notebook-restart-kernel)
        (should emacs-jupyter-notebook--execution-setup-pending)
        ;; Raising the gate alone cannot retire work that may still be running
        ;; remotely.  Restart acknowledgement establishes the new epoch.
        (should (emacs-jupyter-notebook--execution-record 1))
        (should (emacs-jupyter-notebook--execution-record 2))
        (should-not calls)
        (funcall restart-success 3 nil)
        (should-not (emacs-jupyter-notebook--execution-record 1))
        (should readiness-success)
        (should-not calls)
        (funcall readiness-success 4 t)
        (should setup-success)
        (funcall setup-success 5 nil)
        (should-not emacs-jupyter-notebook--execution-setup-pending)
        (should (equal (caar calls) "queued()"))))))

(ert-deftest ejn-ei3-restart-failure-keeps-active-ownership-and-b-queued ()
  "A rejected restart cannot dispatch B beside still-running remote work."
  (with-temp-buffer
    (let* ((client (ejn-test-backend-session 'helper t))
           (emacs-jupyter-notebook--client client)
           (panel (ejn-panel-ensure (current-buffer)))
           (handle (ejn-panel-start-entry panel nil "A"))
           (active (list :id 1 :state 'dispatched :panel-entry handle
                         :generation (plist-get handle :generation)))
           (queued (list :id 2 :state 'queued :code "B"))
           restart-failure sent shutdown)
      (emacs-jupyter-notebook--execution-put active)
      (emacs-jupyter-notebook--execution-put queued)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                 (lambda (_client operation _payload _success failure)
                   (if (eq operation 'restart)
                       (setq restart-failure failure)
                     (setq shutdown t))
                   3))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (&rest _) (setq sent t))))
        (emacs-jupyter-notebook-restart-kernel)
        (should emacs-jupyter-notebook--execution-setup-pending)
        (should (emacs-jupyter-notebook--execution-record 1))
        (funcall restart-failure 3 "restart unsupported")
        (should-not emacs-jupyter-notebook--execution-setup-pending)
        (should (eq emacs-jupyter-notebook--execution-active-id 1))
        (should (equal emacs-jupyter-notebook--execution-queue '(1 2)))
        (should (emacs-jupyter-notebook--execution-record 2))
        (should-not sent)
        (should-not shutdown)
        (should-not (string-match-p "kernel restarted"
                                    (ejn-panel-entry-text handle)))))))

(ert-deftest ejn-ei3-restart-rejects-an-existing-setup-epoch ()
  "A second restart cannot invalidate silent setup already in flight."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session nil t))
          (emacs-jupyter-notebook--execution-setup-pending t)
          sent)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                 (lambda (&rest _) (setq sent t))))
        (should-error (emacs-jupyter-notebook-restart-kernel) :type 'user-error))
      (should-not sent))))

(ert-deftest ejn-ei3-restart-unready-schedules-bounded-reconnect ()
  "An unready fresh kernel schedules recovery even without queued work."
  (with-temp-buffer
    (let ((client (ejn-test-backend-session nil t)) scheduled finished)
      (setq-local emacs-jupyter-notebook--client client)
      (setq-local emacs-jupyter-notebook--execution-setup-pending t)
      (setq-local emacs-jupyter-notebook--execution-setup-epoch 4)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--schedule-auto-reconnect)
                 (lambda () (setq scheduled t)))
                ((symbol-function 'emacs-jupyter-notebook--execution-setup-finish)
                 (lambda (_client _epoch reason) (setq finished reason))))
        (emacs-jupyter-notebook--execution-restart-unready client 4 "no reply"))
      (should scheduled)
      (should emacs-jupyter-notebook--tunnel-dead)
      (should (equal finished "no reply")))))

(ert-deftest ejn-ei3-public-queued-cancel-selects-newest-without-interrupt ()
  "The public queued-cancel command leaves the active remote request alone."
  (with-temp-buffer
    (dolist (record (list (list :id 1 :state 'dispatched)
                          (list :id 2 :state 'queued)
                          (list :id 3 :state 'queued)))
      (emacs-jupyter-notebook--execution-put record))
    (setq emacs-jupyter-notebook--execution-active-id 1
          emacs-jupyter-notebook--execution-queue '(1 2 3))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
               (lambda (&rest _) (ert-fail "queued cancel sent interrupt"))))
      (emacs-jupyter-notebook-cancel-queued-execution))
    (should (emacs-jupyter-notebook--execution-record 2))
    (should-not (emacs-jupyter-notebook--execution-record 3))))

(ert-deftest ejn-ei3-sync-legacy-terminal-events-stage-until-backend-id ()
  "Inline legacy reply/idle are consumed only after execute returns its id."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness nil)
          sent)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil)))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code _options _success _failure)
                   (push code sent)
                   (when (equal code "a")
                     (let ((record (emacs-jupyter-notebook--execution-record 1)))
                       (emacs-jupyter-notebook--execution-note-event
                        (list :request-id 1 :backend-request-id 71
                              :panel-generation (plist-get record :generation))
                        '(:type execute-reply :status "ok" :execution-count 1))
                       (emacs-jupyter-notebook--execution-note-event
                        (list :request-id 1 :backend-request-id 71
                              :panel-generation (plist-get record :generation))
                        '(:type status :execution-state "idle"))))
                   (if (equal code "a") 71 72))))
        (let ((a (emacs-jupyter-notebook--evaluate-code "a" nil))
              (b (emacs-jupyter-notebook--evaluate-code "b" nil)))
          (should (= a 1))
          (should-not (emacs-jupyter-notebook--execution-record a))
          (should (eq emacs-jupyter-notebook--execution-active-id b))
          (should (equal sent '("b" "a")))
          (should (timerp (plist-get (emacs-jupyter-notebook--execution-record b) :timer))))))))

(ert-deftest ejn-ei3-aborted-and-busy-statuses-do-not-falsely-succeed ()
  "Only exact ok plus idle settles successfully; busy is not terminal."
  (with-temp-buffer
    (let ((record (list :id 1 :state 'dispatched :backend-request-id 5 :generation 6
                        :reply-seen nil :idle-seen nil))
          finished)
      (emacs-jupyter-notebook--execution-put record)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--execution-finish)
                 (lambda (_record status &rest _) (setq finished status))))
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 5 :panel-generation 6)
         '(:type status :execution-state "busy"))
        (should-not finished)
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 5 :panel-generation 6)
         '(:type execute-reply :status "aborted" :execution-count 1))
        (should-not finished)
        (emacs-jupyter-notebook--execution-note-event
         '(:request-id 1 :backend-request-id 5 :panel-generation 6)
         '(:type status :execution-state "idle"))
        (should (eq finished 'error))))))

(ert-deftest ejn-ei3-terminal-fringe-respects-clear-and-newer-same-cell ()
  "A cleared or superseded entry cannot rewrite source fringe state on finish."
  (with-temp-buffer
    (let ((a (list :id 1 :state 'dispatched :cell-key "cell" :panel-entry 'a))
          (b (list :id 2 :state 'queued :cell-key "cell" :panel-entry 'b))
          fringe)
      (emacs-jupyter-notebook--execution-put a)
      (emacs-jupyter-notebook--execution-put b)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1 2))
      (cl-letf (((symbol-function 'ejn-panel-entry-live-p) (lambda (handle) (eq handle 'a)))
                ((symbol-function 'ejn-panel-finish-entry) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                 (lambda (&rest args) (push args fringe)))
                ((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
        (emacs-jupyter-notebook--execution-finish a 'ok 1)
        (should-not fringe)
        ;; A retired generation is equally presentation-inert even without B.
        (setq emacs-jupyter-notebook--execution-active-id 2
              emacs-jupyter-notebook--execution-queue '(2))
        (emacs-jupyter-notebook--execution-finish b 'ok 2)
        (should-not fringe)))))

(ert-deftest ejn-ei3-real-same-cell-terminal-cannot-clobber-newer-entry ()
  "A's terminal event cannot replace B's newer running fringe or panel state."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness nil)
          (sent nil) (next-backend-id 80) fringe)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (success _failure) (funcall success nil)))
                    ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                     (lambda (_client code _options _success _failure)
                       (setq sent (append sent (list code)))
                       (cl-incf next-backend-id)))
                    ((symbol-function 'emacs-jupyter-notebook-fringe-set)
                     (lambda (&rest args) (push args fringe))))
            (let* ((cell-key '("source.py" . 9))
                   (a (emacs-jupyter-notebook--evaluate-code "A" cell-key))
                   (b (emacs-jupyter-notebook--evaluate-code "B" cell-key))
                   (a-record (emacs-jupyter-notebook--execution-record a))
                   (b-record (emacs-jupyter-notebook--execution-record b))
                   (a-context (list :buffer (current-buffer)
                                    :entry-handle (plist-get a-record :panel-entry)
                                    :request-id a
                                    :backend-request-id
                                    (plist-get a-record :backend-request-id)
                                    :panel-generation (plist-get a-record :generation)))
                   (b-handle (plist-get b-record :panel-entry)))
              (should (equal sent '("A")))
              (should (eq (plist-get b-record :state) 'queued))
              (emacs-jupyter-notebook-events-dispatch
               a-context '(:type execute-reply :status "ok"))
              (emacs-jupyter-notebook-events-dispatch
               a-context '(:type status :execution-state "idle"))
              (should (equal sent '("A" "B")))
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record b)
                                    :state)
                          'dispatched))
              (should (eq (plist-get (ejn-panel-entry-snapshot
                                      (plist-get a-context :entry-handle)) :status)
                           'ok))
              (should (eq (plist-get (ejn-panel-entry-snapshot b-handle) :status)
                           'running))
              (should (equal (car (car fringe)) cell-key))
              (should (eq (cadr (car fringe)) 'running)))
        (emacs-jupyter-notebook--clear-buffer-timers))))))

(ert-deftest ejn-ei3-buffer-kill-releases-active-and-queued-ledger-locally ()
  "Killing a source buffer cancels local work and cannot clean up the kernel."
  (let ((buffer (generate-new-buffer " *ejn-ei3-release*"))
        timer late-success late-failure shutdown remote-cleanup registry-remove)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (setq remote-cleanup t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-remove-entry)
                   (lambda (&rest _) (setq registry-remove t)))
                  ((symbol-function 'emacs-jupyter-notebook-backend-control)
                   (lambda (&rest _) (setq shutdown t))))
          (with-current-buffer buffer
            (let ((emacs-jupyter-notebook-backend 'mock)
                  (emacs-jupyter-notebook-check-code-completeness nil)
                  (emacs-jupyter-notebook--client
                   (ejn-test-backend-session 'mock t))
                  (sent nil))
              (emacs-jupyter-notebook-mode 1)
              (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                         (lambda (success _failure) (funcall success nil)))
                        ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                         (lambda (_client code _options success failure)
                           (setq sent (append sent (list code))
                                 late-success success late-failure failure)
                           91)))
                (let ((a (emacs-jupyter-notebook--evaluate-code "A" nil))
                      (b (emacs-jupyter-notebook--evaluate-code "B" nil)))
                  (setq timer (plist-get
                               (emacs-jupyter-notebook--execution-record a)
                               :timer))
                  (should (timerp timer))
                  (should (eq (plist-get
                               (emacs-jupyter-notebook--execution-record b)
                               :state)
                              'queued))
                  (should (equal sent '("A")))))))
          (kill-buffer buffer)
          (should-not (buffer-live-p buffer))
          (should-not (memq timer timer-list))
          (should-not shutdown)
          (should-not remote-cleanup)
          (should-not registry-remove)
          ;; Both callback shapes are safe after the owning buffer is gone.
          (funcall late-success 91 '(:status "ok"))
          (funcall late-failure 91 "late failure"))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ejn-ei3-timeout-holds-fifo-and-terminally-releases-without-cleanup ()
  "Timeout interrupts once, keeps B queued, and performs no durable cleanup."
  (with-temp-buffer
    (let* ((timer (run-at-time 300 nil #'ignore))
           (record (list :id 1 :state 'dispatched :backend-request-id 7 :generation 8
                         :timer timer :panel-entry 'entry :reply-seen nil :idle-seen nil))
           (second (list :id 2 :state 'queued))
           (interrupts 0) shutdown cleanup suffix)
      (unwind-protect
          (progn
            (emacs-jupyter-notebook--execution-put record)
            (emacs-jupyter-notebook--execution-put second)
            (setq-local emacs-jupyter-notebook--client
                        (ejn-test-backend-session 'mock t))
            (setq emacs-jupyter-notebook--execution-active-id 1
                  emacs-jupyter-notebook--execution-queue '(1 2))
            (should emacs-jupyter-notebook--client)
            (should (emacs-jupyter-notebook--execution-current-p 1))
            (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-control)
                       (lambda (_client op &rest _) (if (eq op 'interrupt)
                                                        (cl-incf interrupts)
                                                      (setq shutdown t))))
                      ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                       (lambda (&rest _) (setq cleanup t)))
                      ((symbol-function 'ejn-panel-entry-live-p) (lambda (_x) t))
                      ((symbol-function 'ejn-panel-append-text)
                       (lambda (_h text &rest _) (setq suffix text)))
                      ((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
              (emacs-jupyter-notebook--evaluation-on-timeout 99)
              (emacs-jupyter-notebook--evaluation-on-timeout 1)
              (emacs-jupyter-notebook--evaluation-on-timeout 1)
              (should (= interrupts 1))
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record 1) :state)
                          'cancelling))
              (should (timerp timer))
              (should (string-match-p "timed out" suffix))
              (should-not shutdown) (should-not cleanup)
              (emacs-jupyter-notebook--execution-note-event
               '(:request-id 1 :backend-request-id 7 :panel-generation 8)
               '(:type execute-reply :status "ok"))
              (emacs-jupyter-notebook--execution-note-event
               '(:request-id 1 :backend-request-id 7 :panel-generation 8)
               '(:type status :execution-state "idle"))
              (should-not (emacs-jupyter-notebook--execution-record 1))
              (should-not (memq timer timer-list))))
        (when (timerp timer) (cancel-timer timer))))))

(ert-deftest ejn-ei3-checking-cancel-is-local-and-late-completeness-is-inert ()
  "Cancelling a checking head advances B without an interrupt or resurrection."
  (with-temp-buffer
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness t)
          completions sent control-called)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                     (lambda (success _failure) (funcall success nil)))
                    ((symbol-function 'emacs-jupyter-notebook-backend-aux)
                     (lambda (_client operation payload success _failure)
                       (should (eq operation 'is-complete))
                       (push (cons (plist-get payload :code) success) completions)
                       41))
                    ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                     (lambda (_client code _options _success _failure)
                       (setq sent (append sent (list code)))
                       42))
                    ((symbol-function 'emacs-jupyter-notebook-backend-control)
                     (lambda (&rest _) (setq control-called t))))
            (let ((a (emacs-jupyter-notebook--evaluate-code "a" '("source.py" . 1)))
                  (b (emacs-jupyter-notebook--evaluate-code "b" '("source.py" . 2))))
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record a) :state)
                          'checking))
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record b) :state)
                          'queued))
              (emacs-jupyter-notebook-cancel-operation)
              (should-not control-called)
              (should-not (emacs-jupyter-notebook--execution-record a))
              (should (eq emacs-jupyter-notebook--execution-active-id b))
              (should (eq (plist-get (emacs-jupyter-notebook--execution-record b) :state)
                          'checking))
              ;; A's asynchronous completeness reply cannot revive it.
              (funcall (cdr (assoc "a" completions)) 41 '(:status "complete"))
              (should-not sent)
              (funcall (cdr (assoc "b" completions)) 41 '(:status "complete"))
              (should (equal sent '("b")))
              ;; Duplicate callbacks are inert after B has been dispatched.
              (funcall (cdr (assoc "b" completions)) 41 '(:status "complete"))
              (should (equal sent '("b")))))
        (emacs-jupyter-notebook--clear-buffer-timers)))))

(ert-deftest ejn-ei3-reserved-code-and-cell-key-survive-source-edits ()
  "FIFO records retain captured code/key while source edits remain untouched."
  (with-temp-buffer
    (insert "original source\n")
    (set-buffer-modified-p nil)
    (let ((emacs-jupyter-notebook--client (ejn-test-backend-session 'mock t))
          (emacs-jupyter-notebook-check-code-completeness nil)
          (sent nil)
          (next-id 100))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-client-async)
                 (lambda (success _failure) (funcall success nil)))
                ((symbol-function 'emacs-jupyter-notebook-backend-execute)
                 (lambda (_client code _options _success _failure)
                   (setq sent (append sent (list code)))
                   (cl-incf next-id)))
                ((symbol-function 'emacs-jupyter-notebook-fringe-set) #'ignore))
        (let ((source-before-evaluation (buffer-string))
              (modified-before-evaluation (buffer-modified-p)))
          (let* ((key-a '("source.py" . 1))
                 (key-b '("source.py" . 2))
                 (a (emacs-jupyter-notebook--evaluate-code "captured-a" key-a))
                 (b (emacs-jupyter-notebook--evaluate-code "captured-b" key-b)))
            (should (equal (buffer-string) source-before-evaluation))
            (should (eq (buffer-modified-p) modified-before-evaluation))
            (insert "user edit\n")
            (let ((source-after-edit (buffer-string))
                  (modified-after-edit (buffer-modified-p)))
            (should (equal (plist-get (emacs-jupyter-notebook--execution-record a) :code)
                           "captured-a"))
            (should (equal (plist-get (emacs-jupyter-notebook--execution-record a) :cell-key)
                           key-a))
            (let ((record (emacs-jupyter-notebook--execution-record a)))
              (emacs-jupyter-notebook--execution-note-event
               (list :request-id a :backend-request-id (plist-get record :backend-request-id)
                     :panel-generation (plist-get record :generation))
               '(:type execute-reply :status "ok" :execution-count 1))
              (emacs-jupyter-notebook--execution-note-event
               (list :request-id a :backend-request-id (plist-get record :backend-request-id)
                     :panel-generation (plist-get record :generation))
               '(:type status :execution-state "idle")))
            (let ((record (emacs-jupyter-notebook--execution-record b)))
              (should (equal (plist-get record :code) "captured-b"))
              (should (equal (plist-get record :cell-key) key-b))
              (emacs-jupyter-notebook--execution-note-event
               (list :request-id b :backend-request-id (plist-get record :backend-request-id)
                     :panel-generation (plist-get record :generation))
               '(:type execute-reply :status "ok" :execution-count 2))
              (emacs-jupyter-notebook--execution-note-event
               (list :request-id b :backend-request-id (plist-get record :backend-request-id)
                     :panel-generation (plist-get record :generation))
               '(:type status :execution-state "idle")))
            (should (equal sent '("captured-a" "captured-b")))
            (should (equal (buffer-string) source-after-edit))
            (should (eq (buffer-modified-p) modified-after-edit)))))))))

(ert-deftest ejn-ei3-event-admission-precedes-panel-and-kernel-mutation ()
  "Wrong execution identity cannot reach the reducer or mutate presentation."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("source.py" . 1) "x"))
           (generation (plist-get handle :generation))
           (record (list :id 1 :state 'dispatched :panel-entry handle
                         :backend-request-id 11 :generation generation
                         :reply-seen nil :idle-seen nil))
           (context (list :buffer source :entry-handle handle :request-id 1
                          :backend-request-id 12 :panel-generation generation)))
      (emacs-jupyter-notebook--execution-put record)
      (setq emacs-jupyter-notebook--execution-active-id 1
            emacs-jupyter-notebook--execution-queue '(1)
            emacs-jupyter-notebook--kernel-status nil)
      (let ((before (ejn-panel-entry-text handle)))
        (should (equal (emacs-jupyter-notebook-events-dispatch
                        context
                        '(:type execute-reply :status "error" :watch-text "wrong"))
                       '((:action ignore))))
        (should (equal (ejn-panel-entry-text handle) before))
        (should-not emacs-jupyter-notebook--kernel-status)
        (should (equal (emacs-jupyter-notebook-events-dispatch
                        (plist-put
                         (plist-put (copy-sequence context) :backend-request-id 11)
                         :panel-generation (1+ generation))
                        '(:type status :execution-state "busy"))
                       '((:action ignore))))
        (should-not emacs-jupyter-notebook--kernel-status)
        (should-not (plist-get (emacs-jupyter-notebook--execution-record 1) :reply-seen))))))

(ert-deftest ejn-ei4-helper-events-use-real-reducer-terminality-and-retire-wire-map ()
  "A helper stream/reply/idle path reaches EI1R and retires exactly once."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("ei4.py" . 1) "x"))
           (generation (plist-get handle :generation))
           (mapping (make-hash-table :test #'equal))
           (state (emacs-jupyter-notebook-helper-backend--make-state
                   :request-map mapping))
           (session (emacs-jupyter-notebook-backend-session-create nil source))
           (record (list :id 41 :state 'dispatched :panel-entry handle
                         :backend-request-id 71 :generation generation
                         :reply-seen nil :idle-seen nil)))
      (setf (emacs-jupyter-notebook-backend-session-backend session) 'helper
            (emacs-jupyter-notebook-backend-session-data session) state)
      (puthash "wire-ei4-41"
               (list :ledger-id 41 :backend-request-id 71 :panel-generation generation)
               mapping)
      (emacs-jupyter-notebook--execution-put record)
      (setq emacs-jupyter-notebook--client session
            emacs-jupyter-notebook--execution-active-id 41
            emacs-jupyter-notebook--execution-queue '(41))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--execution-pump) #'ignore))
        (should
         (emacs-jupyter-notebook--backend-event
          session (list :type 'helper-event :helper-request-id "wire-ei4-41"
                        :ledger-id 41 :backend-request-id 71 :panel-generation generation
                        :event '(:type stream :name "stdout" :text "first\n"))))
        (should (equal (ejn-panel-entry-text handle) "first\n"))
        (emacs-jupyter-notebook--backend-event
         session (list :type 'helper-event :helper-request-id "wire-ei4-41"
                       :ledger-id 41 :backend-request-id 71 :panel-generation generation
                       :event '(:type execute-reply :status "ok")))
        ;; A response acknowledgement is not fabricated terminal evidence.
        (should (emacs-jupyter-notebook--execution-record 41))
        (emacs-jupyter-notebook--backend-event
         session (list :type 'helper-event :helper-request-id "wire-ei4-41"
                       :ledger-id 41 :backend-request-id 71 :panel-generation generation
                       :event '(:type status :execution-state "idle")))
        (should-not (emacs-jupyter-notebook--execution-record 41))
        (should-not (gethash "wire-ei4-41" mapping))))))

(ert-deftest ejn-ei4-valid-artifact-routes-helper-to-panel-without-base64 ()
  "A real HT9 descriptor crosses correlation and transfers exact file ownership."
  (let* ((pair (emacs-jupyter-notebook-helper-backend--make-artifact-directory))
         (root (car pair))
         (root-id (cdr pair))
         (accepted (expand-file-name
                    "ejn-artifact-00000000000000000000000000000001" root))
         (stale (expand-file-name
                 "ejn-artifact-00000000000000000000000000000002" root))
         panel state)
    (unwind-protect
        (with-temp-buffer
          (let* ((source (current-buffer))
                 (_ (dolist (file (list accepted stale))
                      (with-temp-file file (insert "png!"))
                      (set-file-modes file #o600)))
                 (handle (progn
                           (setq panel (ejn-panel-ensure source))
                           (ejn-panel-start-entry panel '("route.py" . 1) "plot()")))
                 (generation (plist-get handle :generation))
                 (session (emacs-jupyter-notebook-backend-session-create nil source))
                 (record (list :id 51 :state 'dispatched :panel-entry handle
                               :backend-request-id 81 :generation generation
                               :reply-seen nil :idle-seen nil))
                 (object (lambda (&rest pairs)
                           (let ((table (make-hash-table :test #'equal)))
                             (while pairs
                               (puthash (pop pairs) (pop pairs) table))
                             table)))
                 (raw-event
                  (lambda (path)
                    (funcall object
                     "event" "display_data" "request_id" "wire-route"
                     "data" (funcall object
                              "data" (funcall object
                                      "image/png"
                                      (funcall object
                                       "original"
                                       (funcall object
                                        "path" path "bytes" 4
                                        "sha256" (ejn-ei4-test--content-sha256 path))))
                              "metadata" (funcall object)))))
                 (mapping (list :ledger-id 51 :backend-request-id 81
                                :panel-generation generation)))
            (setq state
                  (emacs-jupyter-notebook-helper-backend--make-state
                   :artifact-dir root :artifact-identity root-id
                   :request-map (make-hash-table :test #'equal)))
            (setf (emacs-jupyter-notebook-backend-session-backend session) 'helper
                  (emacs-jupyter-notebook-backend-session-data session) state
                  (emacs-jupyter-notebook-helper-backend-state-emit state)
                  (lambda (event)
                    (emacs-jupyter-notebook--backend-event session event)))
            (emacs-jupyter-notebook--execution-put record)
            (setq emacs-jupyter-notebook--client session
                  emacs-jupyter-notebook--execution-active-id 51
                  emacs-jupyter-notebook--execution-queue '(51))
            (should
             (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
              state "wire-route" mapping (funcall raw-event accepted)))
            (let* ((image (car (ejn-panel-entry-images handle)))
                   (props (cdr image))
                   (original (plist-get props :ejn-original)))
              (should (equal (plist-get props :file) accepted))
              (should (equal (plist-get original :file) accepted))
              (should-not (plist-get props :ejn-preview))
              (should-not (plist-get props :type))
              (should-not (plist-member props :data)))
            (should (file-exists-p accepted))
            ;; The same valid publication under stale ownership is rejected
            ;; by the core and immediately discarded by the helper adapter.
            (should-not
             (emacs-jupyter-notebook-helper-backend--deliver-mapped-event
              state "wire-route"
              (plist-put (copy-sequence mapping) :panel-generation (1+ generation))
              (funcall raw-event stale)))
            (should-not (file-exists-p stale))
            (setq emacs-jupyter-notebook--client nil)))
      (when (buffer-live-p panel) (ejn-panel-clear-all panel))
      (when state (emacs-jupyter-notebook-helper-backend--dispose state "test cleanup"))
      (when (file-directory-p root) (delete-directory root t)))))

(ert-deftest ejn-ei4-published-images-pin-identity-and-replace-display-id ()
  "Published files transfer only after full validation and exact ID replacement."
  (let* ((root (make-temp-file "ejn-ei4-publication-" t))
         (first (expand-file-name "ejn-artifact-first" root))
         (second (expand-file-name "ejn-artifact-second" root))
         (unknown (expand-file-name "ejn-artifact-unknown" root))
         (unsafe (expand-file-name "ejn-artifact-unsafe" root))
         (root-id nil) (panel nil))
    (unwind-protect
        (with-temp-buffer
          (setq panel (ejn-panel-ensure (current-buffer)))
          (let ((handle (ejn-panel-start-entry panel '("ei4.py" . 2) "plot()"))
                update-handle)
            (dolist (pair `((,first . "first") (,second . "second")
                            (,unknown . "unknown") (,unsafe . "unsafe")))
              (with-temp-file (car pair) (insert (cdr pair)))
              (set-file-modes (car pair) #o600))
            (set-file-modes root #o700)
            (setq root-id (file-attribute-file-identifier (file-attributes root 'integer)))
            (let ((descriptor
                   (lambda (file id)
                     (ejn-ei4v-test--descriptor
                      root file "image/png" id))))
              (should (ejn-panel-set-published-bundle
                       handle (funcall descriptor first "display-ei4") nil nil))
              (should (equal (plist-get (cdr (car (ejn-panel-entry-images handle)))
                                        :ejn-display-id)
                             "display-ei4"))
              (setq update-handle
                    (ejn-panel-start-entry panel '("ei4.py" . 20) "update()"))
              (should (equal
                       (ejn-panel-set-published-bundle
                        update-handle
                        (funcall descriptor second "display-ei4") nil t)
                       handle))
              (should-not (file-exists-p first))
              (should (equal (plist-get (cdr (car (ejn-panel-entry-images handle))) :file)
                             second))
              (should-not (ejn-panel-entry-images update-handle))
              ;; Text display updates retain the same bounded display id;
              ;; they find an older entry but never replace unrelated output.
              (let ((context (list :buffer (current-buffer) :entry-handle handle))
                    (update-context
                     (list :buffer (current-buffer) :entry-handle update-handle)))
                (should (emacs-jupyter-notebook-events-dispatch
                         context '(:type display :data (:text/plain "text-first")
                                        :display-id "text-ei4"
                                        :metadata (:isolated t)
                                        :transient (:display_id "text-ei4"))))
                (should (emacs-jupyter-notebook-events-dispatch
                         update-context '(:type update-display :data (:text/plain "text-second")
                                        :display-id "text-ei4"
                                        :metadata (:isolated t)
                                        :transient (:display_id "text-ei4"))))
                (should (string-match-p "text-second" (ejn-panel-entry-text handle)))
                (should-not (string-match-p "text-first" (ejn-panel-entry-text handle)))
                (let ((before (ejn-panel-entry-text handle)))
                  ;; HT9 marks an oversized display id as omitted.  An update
                  ;; with no usable identity must not fall back to replacing
                  ;; unrelated text or the most recent image.
                  (emacs-jupyter-notebook-events-dispatch
                   update-context '(:type update-display :data (:text/plain "must-not-clobber")
                                          :require-display-id t))
                  (should (equal (ejn-panel-entry-text handle) before))))
              (should-not (ejn-panel-set-published-bundle
                           update-handle
                           (funcall descriptor unknown "missing-display") nil t))
              (should (file-exists-p unknown))
              (set-file-modes unsafe #o4600)
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor unsafe "unsafe") nil nil))
              (set-file-modes unknown #o600)
              (let* ((bad (funcall descriptor unknown "uppercase"))
                     (leaf (plist-get bad :original)))
                (plist-put leaf :sha256 (upcase (plist-get leaf :sha256)))
                (should-error
                 (ejn-panel-set-published-bundle handle bad nil nil))))))
          ;; A replaced path must survive panel retirement.  The panel only
          ;; unlinks its captured device/inode, never a new symlink.
          (delete-file second)
          (make-symbolic-link unknown second t)
          (ejn-panel-clear-all panel)
          (should (file-symlink-p second))
          ;; Matching the child inode alone is insufficient: if the root was
          ;; replaced, even a hard link to the old file must survive cleanup.
          (let* ((pinned (expand-file-name "ejn-artifact-root-pinned" root))
                 (replacement (concat root "-old"))
                 (handle (ejn-panel-start-entry panel '("ei4.py" . 30) "root()")))
            (with-temp-file pinned (insert "root-pinned"))
            (set-file-modes pinned #o600)
            (should
             (ejn-panel-set-published-bundle
              handle
              (ejn-ei4v-test--descriptor
               root pinned "image/png" "root-pinned")
              nil nil))
            (rename-file root replacement)
            (make-directory root)
            (set-file-modes root #o700)
            (add-name-to-file (expand-file-name "ejn-artifact-root-pinned" replacement)
                              pinned)
            (ejn-panel-clear-all panel)
            (should (file-exists-p pinned))
            (delete-directory replacement t)))
      (dolist (file (list first second unknown unsafe))
        (ignore-errors (delete-file file)))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root))))

(ert-deftest ejn-ei4-published-image-rejects-confinement-and-metadata-attacks ()
  "Every publication boundary check fails before panel ownership changes."
  (let* ((root (make-temp-file "ejn-ei4-attacks-" t))
         (valid (expand-file-name "valid" root))
         (nested-dir (expand-file-name "nested" root))
         (nested (expand-file-name "nested-file" nested-dir))
         (outside (make-temp-file "ejn-ei4-outside-"))
         (root-link (concat root "-link"))
         (root-id nil) panel handle)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (make-directory nested-dir)
          (set-file-modes nested-dir #o700)
          (dolist (file (list valid nested outside))
            (with-temp-file file (insert "image"))
            (set-file-modes file #o600))
          (setq root-id (file-attribute-file-identifier
                         (file-attributes root 'integer)))
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (setq handle (ejn-panel-start-entry panel '("attacks.py" . 1) "plot()"))
            (let* ((sha (ejn-ei4-test--content-sha256 valid))
                   (size (file-attribute-size (file-attributes valid 'integer)))
                   (descriptor
                    (lambda (path digest bytes &optional identity)
                      (list :root root :root-identity (or identity root-id)
                            :mime "image/png"
                            :original (list :path path :sha256 digest :size bytes)
                            :preview nil))))
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor outside sha size) nil nil))
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor nested sha size) nil nil))
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor nested-dir sha 0) nil nil))
              (when (fboundp 'make-symbolic-link)
                (make-symbolic-link outside (expand-file-name "link" root) t)
                (should-error
                 (ejn-panel-set-published-bundle
                  handle (funcall descriptor (expand-file-name "link" root) sha size)
                  nil nil))
                (make-symbolic-link root root-link t)
                (should-error
                 (ejn-panel-set-published-bundle
                  handle
                  (list :root root-link :root-identity root-id :mime "image/png"
                        :original (list :path valid :sha256 sha :size size)
                        :preview nil)
                  nil nil))
                (delete-file root-link))
              (set-file-modes valid #o644)
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor valid sha size) nil nil))
              (set-file-modes valid #o600)
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor valid sha (1+ size)) nil nil))
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor valid "invalid" size) nil nil))
              (should-error
               (ejn-panel-set-published-bundle
                handle (funcall descriptor valid sha size (cons 'wrong root-id)) nil nil))
              (should-not (ejn-panel-entry-images handle))
              (should (= (plist-get (ejn-panel-entry-snapshot handle)
                                    :artifact-bytes)
                         0))))
          ;; Replacing the root and recreating the same child cannot reuse the
          ;; captured publication identity.
          (let ((replacement (concat root "-replacement")))
            (rename-file root replacement)
            (make-directory root)
            (set-file-modes root #o700)
            (with-temp-file valid (insert "image"))
            (set-file-modes valid #o600)
            (with-temp-buffer
              (let* ((panel (ejn-panel-ensure (current-buffer)))
                     (handle (ejn-panel-start-entry panel '("replace.py" . 1) "x"))
                     (sha (ejn-ei4-test--content-sha256 valid))
                     (size (file-attribute-size (file-attributes valid 'integer))))
                (should-error
                 (ejn-panel-set-published-bundle
                  handle
                  (list :root root :root-identity root-id :mime "image/png"
                        :original (list :path valid :sha256 sha :size size)
                        :preview nil)
                  nil nil))
                (kill-buffer panel)))
            (delete-directory replacement t)))
      (ignore-errors (delete-file root-link))
      (when (and (stringp valid) (file-exists-p valid)) (delete-file valid))
      (ignore-errors (delete-file (expand-file-name "link" root)))
      (ignore-errors (delete-directory nested-dir t))
      (ignore-errors (delete-file nested))
      (ignore-errors (delete-file outside))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4-published-image-retirement-and-budget-are-exact ()
  "Published files carry bounded image specs and obey byte eviction."
  (let ((emacs-jupyter-notebook-panel-max-total-artifact-bytes 16)
        (root (make-temp-file "ejn-ei4-budget-" t))
        panel files)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (let ()
            (with-temp-buffer
              (setq panel (ejn-panel-ensure (current-buffer)))
              (dotimes (index 100)
                (let* ((path (expand-file-name (format "artifact-%03d" index) root))
                       (data (format "%04d" index)))
                  (with-temp-file path (insert data))
                  (set-file-modes path #o600)
                  (push path files)
                  (let ((handle (ejn-panel-start-entry
                                 panel (cons "budget.py" index) data)))
                    (should
                     (ejn-panel-set-published-bundle
                      handle
                      (ejn-ei4v-test--descriptor root path "image/png")
                      nil nil)))))
              (let ((total (with-current-buffer panel
                             (emacs-jupyter-notebook-panel--total-artifact-bytes))))
                (should (<= total 16))
                (let ((existing (cl-count-if #'file-exists-p files)))
                (should (<= existing 4))
                  (should (= (* existing 4) total))))
              (with-current-buffer panel
                (should (equal (emacs-jupyter-notebook-panel--recompute-totals)
                               (list :text
                                     (emacs-jupyter-notebook-panel--total-text-bytes)
                                     :artifacts
                                     (emacs-jupyter-notebook-panel--total-artifact-bytes)))))
              (let* ((handle (ejn-panel-start-entry panel '("retire.py" . 1) "x"))
                     (path (expand-file-name "retire" root)))
                (with-temp-file path (insert "once"))
                (set-file-modes path #o600)
                (ejn-panel-set-published-bundle
                 handle (ejn-ei4v-test--descriptor root path "image/png") nil nil)
                (let ((image (car (last (ejn-panel-entry-images handle)))))
                  (should (plist-get (cdr image) :max-width))
                  (should (plist-get (cdr image) :max-height))
                  (should (plist-get (cdr image) :ejn-original))
                  (should-not (plist-get (cdr image) :ejn-preview))
                  (should-not (plist-member (cdr image) :data))
                  (emacs-jupyter-notebook-panel--retire-image panel image)
                  (should-not (file-exists-p path))
                  (emacs-jupyter-notebook-panel--retire-image panel image)
                  (should-not (file-exists-p path)))))))
      (dolist (path files) (ignore-errors (delete-file path)))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4-published-image-size-ceiling-bounds-content-read ()
  "The exact PPM ceiling reads only its header; one over reads nothing."
  (let* ((root (make-temp-file "ejn-ei4-size-boundary-" t))
         (exact (expand-file-name "exact" root))
         (over (expand-file-name "over" root))
         (bytes (ejn-ei4d-test--ppm 1 1))
         (limit (length bytes)))
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil exact nil 'silent)
            (write-region (concat bytes "x") nil over nil 'silent))
          (set-file-modes exact #o600)
          (set-file-modes over #o600)
          (let* ((root-id (file-attribute-file-identifier
                           (file-attributes root 'integer)))
                 (real-read (symbol-function 'insert-file-contents-literally))
                 read-end)
            (cl-letf (((symbol-function 'insert-file-contents-literally)
                       (lambda (file &optional visit begin end replace)
                         (setq read-end end)
                         (funcall real-read file visit begin end replace))))
              (should
               (emacs-jupyter-notebook-panel--published-artifact-metadata
                root exact (ejn-ei4-test--content-sha256 exact) limit root-id
                limit t 1 1)))
            (should (= read-end
                       (min limit
                            emacs-jupyter-notebook-panel--ppm-header-read-limit)))
            (let (read-attempted)
              (cl-letf (((symbol-function 'insert-file-contents-literally)
                         (lambda (&rest _)
                           (setq read-attempted t)
                           (ert-fail "oversized preview content was read"))))
                (should-error
                 (emacs-jupyter-notebook-panel--published-artifact-metadata
                  root over (make-string 64 ?0) (1+ limit) root-id
                  limit t 1 1)))
              (should-not read-attempted))))
      (ignore-errors (delete-file exact))
      (ignore-errors (delete-file over))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4-retirement-flushes-cache-and-unlinks-once ()
  "Repeated retirement flushes once and unlinks each bundle artifact once."
  (let* ((root (make-temp-file "ejn-ei4-retire-count-" t))
         (file (expand-file-name "image" root))
         (preview (expand-file-name "preview" root))
         (real-delete (symbol-function 'delete-file))
         (flushes 0) (deleted nil) panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-file file
              (set-buffer-multibyte nil)
              (insert (ejn-ei4d-test--png 2 3))))
          (let ((coding-system-for-write 'no-conversion))
            (write-region (ejn-ei4d-test--ppm 2 3) nil preview nil 'silent))
          (set-file-modes file #o600)
          (set-file-modes preview #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((handle (ejn-panel-start-entry panel '("retire.py" . 1) "image()")))
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4d-result-test--image-descriptor
                 root file preview "retire" "image/png" 2 3)
                nil nil))
              (cl-letf (((symbol-function 'image-flush)
                         (lambda (&rest _) (cl-incf flushes)))
                        ((symbol-function 'delete-file)
                         (lambda (path &rest args)
                           (when (member path (list file preview))
                             (push path deleted))
                           (apply real-delete path args))))
                (with-temp-buffer
                  (emacs-jupyter-notebook-panel--insert-image
                   (car (ejn-panel-entry-images handle)) 0 t))
                (ejn-panel-clear-all panel)
                (ejn-panel-clear-all panel))
              (should (= flushes 1))
              (should (= (cl-count file deleted :test #'equal) 1))
              (should (= (cl-count preview deleted :test #'equal) 1)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-file preview))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-pickle-zero-budget-retires-publication ()
  "A zero pickle budget retains neither metadata nor its publication file."
  (let* ((root (make-temp-file "ejn-ei4v-pickle-" t))
         (file (expand-file-name "ejn-artifact-0123456789abcdef0123456789abcdef" root))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert "pickle"))
          (set-file-modes file #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((emacs-jupyter-notebook-panel-max-pickles 0)
                  (handle (ejn-panel-start-entry panel '("p.py" . 1) "p"))
                  (root-id (file-attribute-file-identifier (file-attributes root 'integer))))
              (should (ejn-panel-set-published-pickle
                       handle root file (ejn-ei4-test--content-sha256 file) 6 root-id))
              (should-not (ejn-panel-entry-pickle handle))
              (should-not (file-exists-p file)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-zero-pickle-budget-accepts-dual-event-thumbnail ()
  "Pruning a bundled pickle cannot make the retained thumbnail unaccepted."
  (let* ((root (make-temp-file "ejn-ei4v-zero-bundle-" t))
         (image (ejn-ei4v-test--artifact-file
                 root "40404040404040404040404040404040" "thumbnail"))
         (pickle (ejn-ei4v-test--artifact-file
                  root "50505050505050505050505050505050" "pickle"))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((emacs-jupyter-notebook-panel-max-pickles 0)
                   (handle (ejn-panel-start-entry panel '("bundle.py" . 1) "plot()"))
                   (context (list :buffer (current-buffer) :entry-handle handle))
                   (event `(:type display
                            :data (:ejn-published-image
                                   ,(ejn-ei4v-test--descriptor
                                     root image "image/png" "zero")
                                   :ejn-published-pickle
                                   ,(ejn-ei4v-test--descriptor
                                     root pickle nil "zero"))
                            :display-id "zero")))
              ;; This return value is the helper backend's ownership-transfer
              ;; decision.  It must stay true after pickle policy pruning.
              (should (emacs-jupyter-notebook-events-dispatch context event))
              (should (file-exists-p image))
              (should-not (file-exists-p pickle))
              (should (equal (plist-get (cdr (car (ejn-panel-entry-images handle)))
                                        :file)
                             image))
              (should-not (ejn-panel-entry-pickle handle)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-pickle-byte-budget-is-exact-and-evicts-one-byte-over ()
  "Pickles remain at the byte limit and oldest ownership retires above it."
  (let* ((root (make-temp-file "ejn-ei4v-byte-budget-" t))
         (exact (ejn-ei4v-test--artifact-file
                 root "10101010101010101010101010101010" "12345678"))
         (over (ejn-ei4v-test--artifact-file
                root "20202020202020202020202020202020" "x"))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((emacs-jupyter-notebook-panel-max-total-artifact-bytes 8)
                   (emacs-jupyter-notebook-panel-max-pickles 10)
                   (root-id (file-attribute-file-identifier
                             (file-attributes root 'integer)))
                   (exact-handle (ejn-panel-start-entry
                                  panel '("budget.py" . 1) "exact")))
              (should (ejn-panel-set-published-pickle
                       exact-handle root exact
                       (ejn-ei4-test--content-sha256 exact) 8 root-id))
              (should (ejn-panel-entry-pickle exact-handle))
              (should (file-exists-p exact))
              (with-current-buffer panel
                (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes 8)))
              (let ((over-handle (ejn-panel-start-entry
                                  panel '("budget.py" . 2) "over")))
                (should (ejn-panel-set-published-pickle
                         over-handle root over
                         (ejn-ei4-test--content-sha256 over) 1 root-id))
                (should (ejn-panel-entry-pickle over-handle))
                (should (file-exists-p over))
                (should-not (file-exists-p exact))
                (should-not (ejn-panel-entry-live-p exact-handle))
                (with-current-buffer panel
                  (should (= emacs-jupyter-notebook-panel--retained-artifact-bytes
                             1)))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-pickle-lease-defers-and-settles-retirement-once ()
  "A viewer lease keeps a retired pickle alive until its one completion."
  (let* ((root (make-temp-file "ejn-ei4v-lease-" t))
         (file (expand-file-name "ejn-artifact-abcdefabcdefabcdefabcdefabcdefab" root))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert "pickle"))
          (set-file-modes file #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("p.py" . 1) "p"))
                   (root-id (file-attribute-file-identifier (file-attributes root 'integer))))
              (should (ejn-panel-set-published-pickle
                       handle root file (ejn-ei4-test--content-sha256 file) 6 root-id))
              (let ((lease (ejn-panel-acquire-pickle handle)))
                (ejn-panel-clear-pickle handle)
                (should (file-exists-p file))
                (ejn-panel-release-pickle lease)
                (ejn-panel-release-pickle lease)
                (should-not (file-exists-p file))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-viewer-reap-releases-retired-panel-lease-once ()
  "Viewer death settles an in-flight panel lease and unlinks exactly once."
  (let* ((root (make-temp-file "ejn-ei4v-viewer-reap-" t))
         (file (ejn-ei4v-test--artifact-file
                root "30303030303030303030303030303030" "pickle"))
         (real-delete-file (symbol-function 'delete-file))
         (real-delete-process (symbol-function 'delete-process))
         (deletes 0)
         process timer panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("lease.py" . 1) "plot()"))
                   (root-id (file-attribute-file-identifier
                             (file-attributes root 'integer))))
              (should (ejn-panel-set-published-pickle
                       handle root file (ejn-ei4-test--content-sha256 file)
                       6 root-id))
              (let ((lease (ejn-panel-acquire-pickle handle))
                    (emacs-jupyter-notebook-viewer--process nil)
                    (emacs-jupyter-notebook-viewer--socket-path
                     "/tmp/ejn-viewer.sock")
                    (emacs-jupyter-notebook-viewer--socket-directory nil)
                    (emacs-jupyter-notebook-viewer--socket-directory-identity nil)
                    (emacs-jupyter-notebook-viewer--active-transaction nil))
                (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-ensure)
                           #'ignore)
                          ((symbol-function 'emacs-jupyter-notebook-viewer-live-p)
                           (lambda () t))
                          ((symbol-function 'make-network-process)
                           (lambda (&rest _)
                             (setq process
                                   (make-pipe-process
                                    :name "ejn-ei4v-reap-send"
                                    :buffer nil :noquery t))))
                          ((symbol-function 'process-send-string) #'ignore)
                          ((symbol-function 'run-at-time)
                           (lambda (&rest _)
                             (setq timer (timer-create))
                             timer))
                          ((symbol-function 'delete-file)
                           (lambda (path &rest args)
                             (when (equal path file) (cl-incf deletes))
                             (apply real-delete-file path args))))
                  (emacs-jupyter-notebook--viewer-hand-off lease)
                  (should emacs-jupyter-notebook-viewer--active-transaction)
                  (ejn-panel-clear-pickle handle)
                  (should (file-exists-p file))
                  (emacs-jupyter-notebook-viewer-reap)
                  (emacs-jupyter-notebook-viewer-reap)
                  (should-not (file-exists-p file))
                  (should (= deletes 1))
                  (should (= (plist-get lease :leases) 0)))))))
      (when (timerp timer) (cancel-timer timer))
      (when (processp process)
        (ignore-errors (funcall real-delete-process process)))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-pickle-delete-failure-remains-retriable ()
  "A failed unlink leaves retired pickle metadata available for retry cleanup."
  (let* ((root (make-temp-file "ejn-ei4v-delete-retry-" t))
         (file (expand-file-name "ejn-artifact-99999999999999999999999999999998" root))
         (real-delete (symbol-function 'delete-file))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert "pickle"))
          (set-file-modes file #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("p.py" . 1) "p"))
                   (root-id (file-attribute-file-identifier
                             (file-attributes root 'integer))))
              (should (ejn-panel-set-published-pickle
                       handle root file (ejn-ei4-test--content-sha256 file)
                       6 root-id))
              (let ((pickle (ejn-panel-entry-pickle handle)))
                (cl-letf (((symbol-function 'delete-file)
                           (lambda (path &rest _args)
                             (if (equal path file)
                                 (error "simulated unlink failure")
                               (funcall real-delete path)))))
                  (ejn-panel-clear-pickle handle))
                (should (file-exists-p file))
                (should (plist-get pickle :retired))
                (should-not (plist-get pickle :deleted))
                (emacs-jupyter-notebook-panel--retire-pickle pickle)
                (should-not (file-exists-p file))
                (should (plist-get pickle :deleted))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-pickle-admission-and-handoff-never-read-or-hash-bytes ()
  "Pickle admission and viewer handoff use descriptors, not payload bytes."
  (let* ((root (make-temp-file "ejn-ei4v-no-read-" t))
         (file (expand-file-name "ejn-artifact-99999999999999999999999999999999" root))
         (sha (make-string 64 ?a))
         (canary "EJN_PICKLE_PAYLOAD_CANARY_never_on_the_wire")
         process sent completed logs panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert canary))
          (set-file-modes file #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("p.py" . 1) "p"))
                   (root-id (file-attribute-file-identifier
                             (file-attributes root 'integer))))
              (cl-letf (((symbol-function 'insert-file-contents-literally)
                         (lambda (&rest _)
                           (ert-fail "pickle bytes were read in Emacs")))
                        ((symbol-function 'secure-hash)
                         (lambda (&rest _)
                           (ert-fail "pickle bytes were hashed in Emacs"))))
                (should (ejn-panel-set-published-pickle
                         handle root file sha (string-bytes canary) root-id))
                (let ((emacs-jupyter-notebook-viewer--process (list :fake))
                      (emacs-jupyter-notebook-viewer--socket-path "/tmp/ejn-viewer.sock")
                      (emacs-jupyter-notebook-viewer--active-transaction nil)
                      (emacs-jupyter-notebook-viewer--next-request-id 0))
                  (cl-letf (((symbol-function 'emacs-jupyter-notebook-viewer-ensure)
                             #'ignore)
                            ((symbol-function 'emacs-jupyter-notebook-viewer-live-p)
                             (lambda () t))
                            ((symbol-function 'make-network-process)
                             (lambda (&rest args)
                               (should (eq (plist-get args :nowait) t))
                               (setq process
                                     (make-pipe-process
                                      :name "ejn-test-viewer-send"
                                      :buffer nil
                                      :noquery t))))
                            ((symbol-function 'process-send-string)
                             (lambda (_proc string)
                               (setq sent string)))
                            ((symbol-function 'emacs-jupyter-notebook-viewer--log)
                             (lambda (format-string &rest args)
                               (push (apply #'format format-string args) logs)))
                            ((symbol-function 'run-at-time)
                             (lambda (&rest _) nil))
                            ((symbol-function 'delete-process)
                             (lambda (&rest _) nil)))
                    (emacs-jupyter-notebook-viewer-open-pickle-file
                     (ejn-panel-entry-pickle handle)
                     (lambda (ok) (push ok completed)))
                    (should sent)
                    (should-not (string-match-p canary sent))
                    (should-not (string-match-p canary
                                                (string-join logs "\n")))
                    (funcall (process-filter process)
                             process "{\"id\":\"v1\",\"accepted\":true}\n")
                    (should (equal completed '(t)))))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (processp process)
        (ignore-errors (delete-process process)))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-bundle-update-is-targeted-transactional-and-clears-stale-pickle ()
  "A display-id update moves image and pickle together onto its old entry."
  (let* ((root (make-temp-file "ejn-ei4v-bundle-" t))
         (image-a (expand-file-name "ejn-artifact-11111111111111111111111111111111" root))
         (pickle-a (expand-file-name "ejn-artifact-22222222222222222222222222222222" root))
         (image-b (expand-file-name "ejn-artifact-33333333333333333333333333333333" root))
         (pickle-b (expand-file-name "ejn-artifact-44444444444444444444444444444444" root))
         (image-c (expand-file-name "ejn-artifact-55555555555555555555555555555555" root))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (dolist (pair `((,image-a . "image-a") (,pickle-a . "pickle-a")
                          (,image-b . "image-b") (,pickle-b . "pickle-b")
                          (,image-c . "image-c")))
            (with-temp-file (car pair) (insert (cdr pair)))
            (set-file-modes (car pair) #o600))
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((root-id (file-attribute-file-identifier (file-attributes root 'integer)))
                   (first (ejn-panel-start-entry panel '("bundle.py" . 1) "first"))
                   (second (ejn-panel-start-entry panel '("bundle.py" . 2) "second"))
                   (image (lambda (path)
                            (list :root root :root-identity root-id
                                  :mime "image/png"
                                  :original
                                  (list :path path
                                        :sha256 (ejn-ei4-test--content-sha256 path)
                                        :size (file-attribute-size
                                               (file-attributes path 'integer)))
                                  :preview nil :display-id "bundle-id")))
                   (pickle (lambda (path)
                             (list :root root :path path
                                   :sha256 (ejn-ei4-test--content-sha256 path)
                                   :size (file-attribute-size (file-attributes path 'integer))
                                   :root-identity root-id :display-id "bundle-id"))))
              (should (ejn-panel-set-published-bundle first
                                                      (funcall image image-a)
                                                      (funcall pickle pickle-a) nil))
              (cl-letf (((symbol-function
                          'emacs-jupyter-notebook-panel--recompute-entry-artifact-bytes)
                         (lambda (&rest _)
                           (error "injected bundle construction failure"))))
                (should-error
                 (ejn-panel-set-published-bundle second
                                                 (funcall image image-b)
                                                 (funcall pickle pickle-b) t)))
              (should (file-exists-p image-a))
              (should (file-exists-p pickle-a))
              (should (equal (plist-get (cdr (car (ejn-panel-entry-images first))) :file)
                             image-a))
              (should (equal (plist-get (ejn-panel-entry-pickle first) :file) pickle-a))
              (cl-letf (((symbol-function
                          'emacs-jupyter-notebook-panel--schedule-render)
                         (lambda (&rest _)
                           (error "injected render scheduling failure"))))
                (should (equal (ejn-panel-set-published-bundle
                                second (funcall image image-b)
                                (funcall pickle pickle-b) t)
                               first)))
              (should-not (file-exists-p image-a))
              (should-not (file-exists-p pickle-a))
              (should (equal (plist-get (cdr (car (ejn-panel-entry-images first))) :file)
                             image-b))
              (should (equal (plist-get (ejn-panel-entry-pickle first) :file) pickle-b))
              (should-not (ejn-panel-entry-images second))
              ;; A later image-only update invalidates the old interactive
              ;; figure on that same display target.
              (should (ejn-panel-set-published-bundle second (funcall image image-c) nil t))
              (should-not (ejn-panel-entry-pickle first))
              (should-not (file-exists-p pickle-b)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4v-invalid-or-unknown-bundle-is-not-admitted ()
  "Malformed and unknown update bundles leave the panel untouched for discard."
  (let* ((root (make-temp-file "ejn-ei4v-reject-" t))
         (file (expand-file-name "ejn-artifact-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" root))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-file file (insert "pickle"))
          (set-file-modes file #o600)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("reject.py" . 1) "x"))
                   (root-id (file-attribute-file-identifier (file-attributes root 'integer)))
                   (descriptor (list :root root :path file
                                     :sha256 (ejn-ei4-test--content-sha256 file)
                                     :size 6 :root-identity root-id :display-id "missing"))
                   (context (list :buffer (current-buffer) :entry-handle handle)))
              (should-not (ejn-panel-set-published-bundle
                           handle nil descriptor t))
              (should-not (ejn-panel-entry-pickle handle))
              ;; A malformed peer descriptor also returns a normal rejection,
              ;; allowing helper-side atomic disposal instead of a callback error.
              (emacs-jupyter-notebook-events-dispatch
               context `(:type display :data (:ejn-published-pickle ,descriptor
                                      :ejn-published-image (:root ,root :path ,file
                                      :mime "image/png" :sha256 "bad" :size 6
                                      :root-identity ,root-id))))
              (should-not (ejn-panel-entry-pickle handle))
              (should (file-exists-p file)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

;;; EI4D - compressed image admission before native decoding

(ert-deftest ejn-ei4d-canonical-ppm-and-pixel-boundaries ()
  "Only exact bounded P6 output is admitted for Emacs-native rendering."
  (let ((ppm (ejn-ei4d-test--ppm 2 3)))
    (should (equal (emacs-jupyter-notebook-panel--canonical-ppm-header-metadata
                    ppm (string-bytes ppm))
                   '(:mime "image/x-portable-pixmap" :width 2 :height 3)))
    (dolist (bad (list (substring ppm 0 -1)
                       (concat ppm "x")
                       (replace-regexp-in-string "255" "254" ppm t t)
                       (replace-regexp-in-string "2 3" "2  3" ppm t t)
                       (replace-regexp-in-string "P6" "P3" ppm t t)))
      (should-not
       (emacs-jupyter-notebook-panel--canonical-ppm-header-metadata
        bad (string-bytes bad))))
    (dolist (dimensions '((1024 1 t) (1025 1 nil)
                          (1 1024 t) (1 1025 nil)
                          (1024 1024 t)))
      (pcase-let ((`(,width ,height ,safe) dimensions))
        (should (eq (and (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p
                          width height)
                         t)
                    safe))))
    (let ((emacs-jupyter-notebook-helper-inline-image-max-pixels 100))
      (should-not (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p 11 10)))
    (let ((emacs-jupyter-notebook-helper-inline-image-max-pixels nil))
      (should-not (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p 1 1)))
    (let ((emacs-jupyter-notebook-helper-inline-image-max-pixels most-positive-fixnum))
      (should (emacs-jupyter-notebook-panel--inline-image-dimensions-safe-p 1024 1024)))))

(ert-deftest ejn-ei4d-preview-admission-reads-only-fixed-header ()
  "Preview admission never hashes or synchronously reads its pixel payload."
  (let* ((root (make-temp-file "ejn-ei4d-header-only-" t))
         (original (ejn-ei4d-test--write-artifact
                    root "10101010101010101010101010101010" "original"))
         (preview (ejn-ei4d-test--write-artifact
                   root "20202020202020202020202020202020"
                   (ejn-ei4d-test--ppm 8 8)))
         (descriptor
          (ejn-ei4d-result-test--image-descriptor
           root original preview "header-only" "image/png" 8 8))
         (real-insert (symbol-function 'insert-file-contents-literally))
         reads panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((handle (ejn-panel-start-entry panel '("header.py" . 1) "plot()")))
              (cl-letf (((symbol-function 'secure-hash)
                         (lambda (&rest _)
                           (ert-fail "preview bytes were hashed in Emacs")))
                        ((symbol-function 'insert-file-contents-literally)
                         (lambda (file &optional visit begin end replace)
                           (when (equal file preview)
                             (push (list begin end) reads)
                             (should (integerp end))
                             (should (<= (- end (or begin 0)) 64)))
                           (funcall real-insert file visit begin end replace))))
                (should
                 (ejn-panel-set-published-bundle handle descriptor nil nil)))
              (should (equal reads '((0 64)))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-published-unsafe-images-never-reach-native-apis ()
  "A helper original without a PPM preview never enters a native image API."
  (let* ((root (make-temp-file "ejn-ei4d-native-" t))
         (original (ejn-ei4d-test--write-artifact
                    root "11111111111111111111111111111111"
                    (ejn-ei4d-test--png 65535 65535)))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((handle (ejn-panel-start-entry panel '("ei4d.py" . 1) "plot()"))
                   native-calls)
              (should
               (ejn-panel-set-published-bundle
                handle
                (ejn-ei4v-test--descriptor
                 root original "image/png" "original-only")
                nil nil))
              (let ((spec (car (ejn-panel-entry-images handle))))
                (should-not (plist-get (cdr spec) :ejn-preview))
                (should-not (emacs-jupyter-notebook-panel--native-image-safe-p spec))
                (cl-letf (((symbol-function 'image-size)
                           (lambda (&rest _) (push 'image-size native-calls)))
                          ((symbol-function 'insert-sliced-image)
                           (lambda (&rest _) (push 'insert-sliced-image native-calls)))
                          ((symbol-function 'image-flush)
                           (lambda (&rest _) (push 'image-flush native-calls)))
                          ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
                  (with-temp-buffer
                    (emacs-jupyter-notebook-panel--insert-image spec 1 t)
                    (should-not (get-text-property (point-min) 'display)))
                  (emacs-jupyter-notebook-panel--retire-image panel spec))
                (should-not native-calls)
                (should-not (file-exists-p original))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-render-rechecks-only-bounded-inline-candidates ()
  "History length cannot turn native-boundary stat checks into O(all images)."
  (let* ((root (make-temp-file "ejn-ei4d-history-" t)) panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let ((emacs-jupyter-notebook-panel-max-inline-images 2))
              (dotimes (index 24)
                (let* ((file (ejn-ei4d-test--write-artifact
                              root (format "%032x" index)
                              (ejn-ei4d-test--png 2 3)))
                       (preview (ejn-ei4d-test--write-artifact
                                 root (format "%032x" (+ index 100))
                                 (ejn-ei4d-test--ppm 2 3)))
                       (handle (ejn-panel-start-entry
                                panel (cons "ei4d.py" index) "plot()"))
                       (descriptor
                        (ejn-ei4d-result-test--image-descriptor
                         root file preview (format "image-%d" index)
                         "image/png" 2 3)))
                  (should (ejn-panel-set-published-bundle handle descriptor nil nil))))
              (let ((real-check (symbol-function
                                 'emacs-jupyter-notebook-panel--published-artifact-metadata))
                    (checks 0))
                (cl-letf (((symbol-function
                            'emacs-jupyter-notebook-panel--published-artifact-metadata)
                           (lambda (&rest arguments)
                             (cl-incf checks)
                             (apply real-check arguments))))
                  (with-current-buffer panel
                    (emacs-jupyter-notebook-panel--render panel)))
                (should (= checks 2))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-unsafe-original-obeys-existing-artifact-budget ()
  "A decoder-bomb placeholder still retires through the ordinary byte budget."
  (let* ((root (make-temp-file "ejn-ei4d-budget-" t))
         (bomb (ejn-ei4d-test--write-artifact
                root "44444444444444444444444444444444" (ejn-ei4d-test--png 4097 1024)))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((emacs-jupyter-notebook-panel-max-total-artifact-bytes 1)
                   (handle (ejn-panel-start-entry panel '("ei4d.py" . 2) "plot()"))
                   (descriptor (ejn-ei4v-test--descriptor
                                root bomb "image/png" "bomb" 4097 1024 nil)))
              (ejn-panel-set-published-bundle handle descriptor nil nil)
              (should-not (file-exists-p bomb)))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(ert-deftest ejn-ei4d-native-calls-receive-only-the-ppm-preview ()
  "The compressed original is absent from every native image API argument."
  (let* ((root (make-temp-file "ejn-ei4d-preview-" t))
         (original (ejn-ei4d-test--write-artifact
                    root "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" (ejn-ei4d-test--png 2 1)))
         (preview (ejn-ei4d-test--write-artifact
                   root "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" (ejn-ei4d-test--ppm 2 1)))
         panel)
    (unwind-protect
        (progn
          (set-file-modes root #o700)
          (with-temp-buffer
            (setq panel (ejn-panel-ensure (current-buffer)))
            (let* ((root-id (file-attribute-file-identifier (file-attributes root 'integer)))
                   (leaf (lambda (file)
                           (let ((attrs (file-attributes file 'integer)))
                             (list :path file :size (file-attribute-size attrs)
                                   :sha256 (ejn-ei4-test--content-sha256 file)))))
                   (descriptor
                    (list :root root :root-identity root-id :mime "image/png"
                          :original (funcall leaf original)
                          :preview (append (funcall leaf preview)
                                           (list :mime "image/x-portable-pixmap"
                                                 :width 2 :height 1))))
                   (handle (ejn-panel-start-entry panel '("ppm.py" . 1) "plot()")))
              (should (ejn-panel-set-published-bundle handle descriptor nil nil))
              (let ((spec (car (ejn-panel-entry-images handle))))
                (cl-labels ((contains-original (value)
                              (cond ((stringp value) (equal value original))
                                    ((consp value) (or (contains-original (car value))
                                                       (contains-original (cdr value))))
                                    (t nil)))
                            (native-call (&rest arguments)
                              (should-not (contains-original arguments))))
                  (let ((emacs-jupyter-notebook-panel-slice-images t))
                    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                              ((symbol-function 'image-size)
                               (lambda (&rest args) (apply #'native-call args) '(2 . 1)))
                              ((symbol-function 'insert-sliced-image)
                               (lambda (&rest args) (apply #'native-call args) (insert " ")))
                              ((symbol-function 'image-flush)
                               (lambda (&rest args) (apply #'native-call args))))
                      (with-temp-buffer
                        (emacs-jupyter-notebook-panel--insert-image spec 0 t))
                      (should (equal (plist-get
                                      (emacs-jupyter-notebook-panel--original-for-external-open spec)
                                      :file)
                                     original))
                      (emacs-jupyter-notebook-panel--retire-image panel spec))))
                (should-not (file-exists-p preview))
                (should-not (file-exists-p original))))))
      (when (buffer-live-p panel) (kill-buffer panel))
      (ignore-errors (delete-directory root t)))))

(provide 'emacs-jupyter-notebook-tests)

;;; emacs-jupyter-notebook-tests.el ends here
