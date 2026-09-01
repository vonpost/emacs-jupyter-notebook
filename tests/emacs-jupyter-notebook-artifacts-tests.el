;;; emacs-jupyter-notebook-artifacts-tests.el --- EI9 artifact confinement tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; These tests exercise the capability boundary using only local temporary
;; files.  In particular, every hostile replacement is checked for both
;; non-deletion and preservation of an outside canary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-artifacts)

(defun ejn-ei9-test--root (cap)
  (emacs-jupyter-notebook-artifacts-capability-root cap))

(defun ejn-ei9-test--marker (cap)
  (expand-file-name ".ejn-owner-v1" (ejn-ei9-test--root cap)))

(defun ejn-ei9-test--parent (cap)
  (emacs-jupyter-notebook-artifacts-capability-parent cap))

(defun ejn-ei9-test--write (path contents &optional mode)
  (let ((coding-system-for-write 'no-conversion))
    (write-region contents nil path nil 'silent))
  (set-file-modes path (or mode #o600))
  path)

(defun ejn-ei9-test--leaf (cap name &optional contents)
  (ejn-ei9-test--write
   (expand-file-name name (ejn-ei9-test--root cap))
   (or contents "artifact")
   #o600))

(defun ejn-ei9-test--remove-fixture (cap)
  ;; This is test-fixture cleanup only.  Production retirement is what the
  ;; assertions exercise and is deliberately non-recursive.
  (let ((root (and cap (ejn-ei9-test--root cap))))
    (when (and root (file-directory-p root))
      (ignore-errors (delete-directory root t)))))

(defun ejn-ei9-test--outside (cap name)
  (expand-file-name name (file-name-directory (directory-file-name
                                               (ejn-ei9-test--parent cap)))))

(defun ejn-ei9-test--kind-leaf (kind)
  (pcase kind
    ('helper ".ejn-partial-0123456789abcdef0123456789abcdef")
    ('panel-images "image-012345.png")
    ('image-open "original.png")))

(defun ejn-ei9-test--children (parent)
  (directory-files parent nil directory-files-no-dot-files-regexp t))

(defvar ejn-ei9-test--root-scan-count 0
  "Root directory enumerations observed by the bounded-cleanup ERTs.")

(cl-defmacro ejn-ei9-test--with-capability ((kind cap) &body body)
  (declare (indent 1) (debug t))
  `(let ((,cap (emacs-jupyter-notebook-artifacts-create ,kind)))
     (unwind-protect
         (progn ,@body)
       (ejn-ei9-test--remove-fixture ,cap))))

(ert-deftest ejn-ei9-create-all-kinds-has-private-root-and-marker ()
  "Every supported kind gets an owner-checked 0700 root and 0600 marker."
  (dolist (kind '(helper panel-images image-open))
    (ejn-ei9-test--with-capability (kind cap)
      (let* ((root (ejn-ei9-test--root cap))
             (marker (ejn-ei9-test--marker cap))
             (attrs (file-attributes marker 'integer)))
        (should (file-directory-p root))
        (should (= (logand (file-modes root) #o777) #o700))
        (should (= (file-modes marker) #o600))
        (should (= (file-attribute-user-id attrs) (user-uid)))
        (should (= (file-attribute-link-number attrs) 1))
        (should (emacs-jupyter-notebook-artifacts-capability-lease cap))
        (should (equal (with-temp-buffer
                         (insert-file-contents-literally marker)
                         (buffer-string))
                       (format "ejn-owner-v1\nkind=%s\n" kind)))))))

(ert-deftest ejn-ei9-retire-happy-path-removes-each-kind ()
  "Normal transient roots remove leaves, marker, and root, and are inert twice."
  (dolist (kind '(helper panel-images image-open))
    (ejn-ei9-test--with-capability (kind cap)
      (let ((leaf (ejn-ei9-test--leaf cap (ejn-ei9-test--kind-leaf kind))))
        (should (file-exists-p leaf))
        (should (emacs-jupyter-notebook-artifacts-retire cap))
        (should-not (file-exists-p leaf))
        (should-not (file-exists-p (ejn-ei9-test--marker cap)))
        (should-not (file-exists-p (ejn-ei9-test--root cap)))
        (should-not (emacs-jupyter-notebook-artifacts-retire cap))))))

(ert-deftest ejn-ei9-helper-retire-retains-published-artifact ()
  "Ordinary helper disposal removes partials but retains published payloads."
  (ejn-ei9-test--with-capability ('helper cap)
    (let ((partial (ejn-ei9-test--leaf
                    cap ".ejn-partial-0123456789abcdef0123456789abcdef"))
          (published (ejn-ei9-test--leaf
                      cap "ejn-artifact-0123456789abcdef0123456789abcdef"
                      "published")))
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should-not (file-exists-p partial))
      (should (equal (with-temp-buffer
                       (insert-file-contents-literally published)
                       (buffer-string))
                     "published"))
      (should (file-directory-p (ejn-ei9-test--root cap))))))

(ert-deftest ejn-ei9-capture-refuses-wrong-kind-and-prefix ()
  "A valid capability cannot be recast as another kind or renamed loosely."
  (ejn-ei9-test--with-capability ('helper cap)
    (should-not (emacs-jupyter-notebook-artifacts-capture
                 'panel-images (ejn-ei9-test--root cap)))
    (let* ((root (ejn-ei9-test--root cap))
           (renamed (expand-file-name "not-an-ejn-root"
                                      (ejn-ei9-test--parent cap))))
      (rename-file root renamed)
      (unwind-protect
          (should-not (emacs-jupyter-notebook-artifacts-capture 'helper renamed))
        (rename-file renamed root)))))

(ert-deftest ejn-ei9-capture-refuses-wrong-parent-and-non-direct-child ()
  "A root outside the dedicated direct-child namespace has no authority."
  (ejn-ei9-test--with-capability ('panel-images cap)
    (let* ((foreign-parent (make-temp-file "ejn-ei9-foreign-" t))
           (foreign-root (expand-file-name "ejn-panel-images-foreign" foreign-parent)))
      (unwind-protect
          (progn
            (set-file-modes foreign-parent #o700)
            (make-directory foreign-root)
            (set-file-modes foreign-root #o700)
            (ejn-ei9-test--write
             (expand-file-name ".ejn-owner-v1" foreign-root)
             "ejn-owner-v1\nkind=panel-images\n")
            (should-not (emacs-jupyter-notebook-artifacts-capture
                         'panel-images foreign-root)))
        (ignore-errors (delete-directory foreign-parent t))))))

(ert-deftest ejn-ei9-root-symlink-replacement-is-never-unlinked ()
  "Replacing the advertised root with a symlink leaves link and target intact."
  (ejn-ei9-test--with-capability ('panel-images cap)
    (let* ((root (ejn-ei9-test--root cap))
           (target (expand-file-name "ejn-ei9-root-target"
                                    (ejn-ei9-test--parent cap)))
           (canary (expand-file-name "canary" target)))
      (rename-file root target)
      (ejn-ei9-test--write canary "root-canary")
      (condition-case err
          (progn
            (make-symbolic-link target root)
            (should-not (emacs-jupyter-notebook-artifacts-retire cap))
            (should (file-symlink-p root))
            (should (file-directory-p target))
            (should (file-exists-p canary)))
        (file-error (ert-skip (error-message-string err)))
        (error (ert-fail (error-message-string err))))
      (delete-file root)
      (delete-file canary)
      (delete-file (expand-file-name ".ejn-owner-v1" target))
      (dolist (name (directory-files target nil "\\`\\.ejn-live-" t))
        (delete-file (expand-file-name name target)))
      (delete-directory target))))

(ert-deftest ejn-ei9-marker-symlink-replacement-is-never-unlinked ()
  "A marker symlink fails closed and does not touch its outside target."
  (ejn-ei9-test--with-capability ('image-open cap)
    (let* ((marker (ejn-ei9-test--marker cap))
           (outside (ejn-ei9-test--outside cap "ei9-marker-target")))
      (ejn-ei9-test--write outside "outside-marker")
      (delete-file marker)
      (condition-case err
          (make-symbolic-link outside marker)
        (file-error (ert-skip (error-message-string err))))
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should (file-symlink-p marker))
      (should (equal (with-temp-buffer
                       (insert-file-contents-literally outside)
                       (buffer-string))
                     "outside-marker"))
      (delete-file marker)
      (delete-file outside))))

(ert-deftest ejn-ei9-marker-content-and-mode-replacements-fail-closed ()
  "Wrong marker content or mode never authorizes deletion."
  (dolist (mutation '(content mode))
    (ejn-ei9-test--with-capability ('panel-images cap)
      (let ((marker (ejn-ei9-test--marker cap)))
        (if (eq mutation 'content)
            (ejn-ei9-test--write marker "not-an-owner\n")
          (set-file-modes marker #o644))
        (should-not (emacs-jupyter-notebook-artifacts-capture
                     'panel-images (ejn-ei9-test--root cap)))
        (should-not (emacs-jupyter-notebook-artifacts-retire cap))
        (should (file-directory-p (ejn-ei9-test--root cap)))))))

(ert-deftest ejn-ei9-marker-hardlink-is-rejected ()
  "A marker with an extra hardlink is not treated as an owner marker."
  (ejn-ei9-test--with-capability ('image-open cap)
    (let* ((marker (ejn-ei9-test--marker cap))
           (hardlink (expand-file-name ".marker-hardlink"
                                       (ejn-ei9-test--root cap))))
      (condition-case err
          (add-name-to-file marker hardlink)
        (file-error (ert-skip (error-message-string err))))
      (should-not (emacs-jupyter-notebook-artifacts-capture
                   'image-open (ejn-ei9-test--root cap)))
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should (file-exists-p marker))
      (delete-file hardlink))))

(ert-deftest ejn-ei9-unknown-direct-file-blocks-whole-retirement ()
  "Unknown direct files block cleanup instead of being speculatively removed."
  (ejn-ei9-test--with-capability ('panel-images cap)
    (let* ((unknown (ejn-ei9-test--leaf cap "unknown.bin" "unknown"))
           (canary (ejn-ei9-test--outside cap "ei9-unknown-canary")))
      (ejn-ei9-test--write canary "canary")
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should (file-exists-p unknown))
      (should (file-exists-p canary))
      (delete-file canary))))

(ert-deftest ejn-ei9-nested-directory-blocks-whole-retirement ()
  "Nested directories are never traversed by retirement."
  (ejn-ei9-test--with-capability ('image-open cap)
    (let* ((nested (expand-file-name "nested" (ejn-ei9-test--root cap)))
           (canary (expand-file-name "canary" nested)))
      (make-directory nested)
      (set-file-modes nested #o700)
      (ejn-ei9-test--write canary "nested-canary")
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should (file-directory-p nested))
      (should (file-exists-p canary)))))

(ert-deftest ejn-ei9-leaf-symlink-blocks-retirement-and-preserves-target ()
  "An allowlisted leaf replaced with a symlink is never followed or removed."
  (ejn-ei9-test--with-capability ('panel-images cap)
    (let* ((name "image-012345.png")
           (leaf (expand-file-name name (ejn-ei9-test--root cap)))
           (outside (ejn-ei9-test--outside cap "ei9-leaf-target")))
      (ejn-ei9-test--write outside "leaf-canary")
      (condition-case err
          (make-symbolic-link outside leaf)
        (file-error (ert-skip (error-message-string err))))
      (should-not (emacs-jupyter-notebook-artifacts-retire cap))
      (should (file-symlink-p leaf))
      (should (file-exists-p outside))
      (delete-file leaf)
      (delete-file outside))))

(ert-deftest ejn-ei9-leaf-hardlink-and-wrong-mode-block-retirement ()
  "Hardlinked and wrong-mode direct leaves fail closed."
  (dolist (variant '(hardlink mode))
    (ejn-ei9-test--with-capability ('panel-images cap)
      (let* ((name "image-012345.png")
             (leaf (expand-file-name name (ejn-ei9-test--root cap)))
             (outside (ejn-ei9-test--outside cap "ei9-hardlink-target")))
        (if (eq variant 'hardlink)
            (progn
              (ejn-ei9-test--write outside "hardlink-canary")
              (condition-case err
                  (add-name-to-file outside leaf)
                (file-error (ert-skip (error-message-string err)))))
          (ejn-ei9-test--write leaf "wrong-mode" #o644))
        (should-not (emacs-jupyter-notebook-artifacts-retire cap))
        (should (file-exists-p leaf))
        (when (file-exists-p outside) (delete-file outside))))))

(ert-deftest ejn-ei9-delete-leaf-requires-full-capability-and-is-idempotent ()
  "The explicit leaf operation deletes only an identity-matching safe leaf."
  (ejn-ei9-test--with-capability ('image-open cap)
    (let* ((leaf (ejn-ei9-test--leaf cap "original.png"))
           (attrs (file-attributes leaf 'integer))
           (identity (file-attribute-file-identifier attrs)))
      (should (emacs-jupyter-notebook-artifacts-delete-leaf cap leaf identity))
      (should-not (file-exists-p leaf))
      (should-not (emacs-jupyter-notebook-artifacts-delete-leaf cap leaf identity))
      (should (file-directory-p (ejn-ei9-test--root cap))))))

(ert-deftest ejn-ei9-delete-leaf-refuses-unsafe-siblings ()
  "A public leaf deletion cannot bypass an unknown or unsafe sibling."
  (dolist (variant '(unknown nested symlink))
    (ejn-ei9-test--with-capability ('panel-images cap)
      (let* ((leaf (ejn-ei9-test--leaf cap "image-012345.png"))
             (identity (file-attribute-file-identifier (file-attributes leaf 'integer)))
             (root (ejn-ei9-test--root cap))
             (sibling (expand-file-name
                       (pcase variant
                         ('unknown "unlisted")
                         ('nested "nested")
                         ('symlink "image-unsafe.png")) root))
             (outside (ejn-ei9-test--outside cap "ei9-sibling-target")))
        (pcase variant
          ('unknown (ejn-ei9-test--write sibling "unknown"))
          ('nested (make-directory sibling))
          ('symlink
           (ejn-ei9-test--write outside "sibling-canary")
           (condition-case err
               (make-symbolic-link outside sibling)
             (file-error (ert-skip (error-message-string err))))))
        (should-not (emacs-jupyter-notebook-artifacts-delete-leaf cap leaf identity))
        (should (file-exists-p leaf))
        (should (file-exists-p sibling))
        (when (file-exists-p outside) (delete-file outside))))))

(ert-deftest ejn-ei9-create-failure-does-not-publish-invalid-root ()
  "Failures during root/marker publication leave no invalid advertised root."
  (dolist (failure '(chmod marker-rename post-chmod-stat validation))
    (let* ((parent-path (car (emacs-jupyter-notebook-artifacts--ensure-parent)))
           (before (ejn-ei9-test--children parent-path))
           (original-modes (symbol-function 'set-file-modes))
           (original-rename (symbol-function 'rename-file))
           (original-directory-attributes
            (symbol-function
             'emacs-jupyter-notebook-artifacts--directory-attributes))
           (original-capture
            (symbol-function 'emacs-jupyter-notebook-artifacts-capture))
           (root-stat-count 0)
           (created nil))
      (unwind-protect
          (progn
            (should-error
             (cl-letf (((symbol-function 'set-file-modes)
                        (lambda (path mode)
                          (if (and (eq failure 'chmod)
                                   (= mode #o700)
                                   (string-prefix-p "ejn-helper-artifacts-"
                                                    (file-name-nondirectory path)))
                              (error "injected chmod failure")
                            (funcall original-modes path mode))))
                       ((symbol-function 'rename-file)
                       (lambda (old new &rest args)
                          (if (and (eq failure 'marker-rename)
                                   (string= (file-name-nondirectory new)
                                            ".ejn-owner-v1"))
                              (error "injected marker rename failure")
                            (apply original-rename old new args))))
                       ((symbol-function
                         'emacs-jupyter-notebook-artifacts--directory-attributes)
                        (lambda (path)
                          (if (and (eq failure 'post-chmod-stat)
                                   (string-prefix-p "ejn-helper-artifacts-"
                                                    (file-name-nondirectory path)))
                              (progn
                                (cl-incf root-stat-count)
                                (if (= root-stat-count 2)
                                    nil
                                  (funcall original-directory-attributes path)))
                            (funcall original-directory-attributes path))))
                       ((symbol-function
                         'emacs-jupyter-notebook-artifacts-capture)
                        (if (eq failure 'validation)
                            (lambda (&rest _args) nil)
                          original-capture)))
               (emacs-jupyter-notebook-artifacts-create 'helper)))
            (setq created (cl-set-difference
                           (ejn-ei9-test--children parent-path) before
                           :test #'string=))
            (dolist (name created)
              (let ((root (expand-file-name name parent-path)))
                ;; A failed publication may be retained for bounded pruning,
                ;; but it must never be a malformed advertised root.
                (should (or (not (file-exists-p root))
                            (emacs-jupyter-notebook-artifacts-capture
                             'helper root))))))
        (dolist (name created)
          (let ((root (expand-file-name name parent-path)))
            (when (file-directory-p root)
              (delete-directory root t))))))))

(ert-deftest ejn-ei9-helper-dispose-retains-published-until-explicit-retire ()
  "Helper disposal removes staging files but leaves published payload ownership intact."
  (require 'emacs-jupyter-notebook-helper-backend)
  (let* ((cap (emacs-jupyter-notebook-artifacts-create 'helper))
         (root (ejn-ei9-test--root cap))
         (partial (ejn-ei9-test--leaf
                   cap ".ejn-partial-0123456789abcdef0123456789abcdef"))
         (published (ejn-ei9-test--leaf
                     cap "ejn-artifact-0123456789abcdef0123456789abcdef"
                     "published"))
         (state (emacs-jupyter-notebook-helper-backend--make-state
                 :helper 'fake-helper :artifact-dir root
                 :artifact-identity
                 (emacs-jupyter-notebook-artifacts-capability-root-identity cap)
                 :artifact-capability cap
                 :request-map (make-hash-table :test #'equal)
                 :pending-events (make-hash-table :test #'equal)
                 :retired-request-ids (make-hash-table :test #'equal)))
         (disposed 0))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'emacs-jupyter-notebook-helper-dispose)
                     (lambda (&rest _args) (cl-incf disposed))))
            (emacs-jupyter-notebook-helper-backend--dispose state "EI9 test"))
          (should (= disposed 1))
          (should-not (file-exists-p partial))
          (should (file-exists-p published))
          (let ((published-cap
                 (emacs-jupyter-notebook-artifacts-capture 'helper root)))
            (should published-cap)
            (should (emacs-jupyter-notebook-artifacts-delete-leaf
                     published-cap published
                     (file-attribute-file-identifier
                      (file-attributes published 'integer))))
            (should (emacs-jupyter-notebook-artifacts-retire published-cap))
            (should-not (file-exists-p root))))
      (when (file-directory-p root) (delete-directory root t)))))

(ert-deftest ejn-ei9-retirement-deletes-leaves-before-marker-and-root ()
  "Retirement ordering leaves the root present while removing its marker."
  (ejn-ei9-test--with-capability ('image-open cap)
    (let ((leaf (ejn-ei9-test--leaf cap "original.png"))
          (marker (ejn-ei9-test--marker cap))
          (root (ejn-ei9-test--root cap))
          (events nil)
          (old-delete-file (symbol-function 'delete-file))
          (old-delete-directory (symbol-function 'delete-directory)))
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (path &rest args)
                   (push (list :file path (file-exists-p leaf)
                               (file-exists-p marker) (file-directory-p root)) events)
                   (apply old-delete-file path args)))
                ((symbol-function 'delete-directory)
                 (lambda (path &rest args)
                   (push (list :directory path (file-exists-p marker)
                               (file-directory-p root)) events)
                   (apply old-delete-directory path args))))
        (should (emacs-jupyter-notebook-artifacts-retire cap)))
      (setq events (nreverse events))
      (should (equal (mapcar #'car events) '(:file :file :file :directory)))
      (should (equal (cadr (nth 2 events)) marker))
      (should (cadddr (nth 2 events)))
      (should (cddddr (nth 2 events))))))

(ert-deftest ejn-ei9-prune-stale-is-strict-and-retains-unsafe-roots ()
  "Pruning removes only old valid roots, retaining fresh, future, boundary, and malformed roots."
  (let* ((emacs-jupyter-notebook-artifact-stale-age 100)
         (now 1000000.0)
         (old-time (seconds-to-time (- now 101)))
         (boundary-time (seconds-to-time (- now 100)))
         (future-time (seconds-to-time (+ now 100)))
         caps)
    (unwind-protect
        (progn
          (dolist (spec '((old . panel-images) (fresh . image-open)
                          (boundary . helper) (future . panel-images)))
            (let ((cap (emacs-jupyter-notebook-artifacts-create (cdr spec))))
              (push (cons (car spec) cap) caps)
              (ejn-ei9-test--leaf cap (ejn-ei9-test--kind-leaf (cdr spec)))
              (set-file-times (ejn-ei9-test--root cap)
                              (pcase (car spec)
                                ('old old-time)
                                ('boundary boundary-time)
                                ('future future-time)
                                (_ (current-time))))))
          (let* ((parent (ejn-ei9-test--parent (cdar caps)))
                 (malformed (expand-file-name "ejn-panel-images-malformed" parent)))
            (make-directory malformed)
            (set-file-modes malformed #o700)
            (ejn-ei9-test--write (expand-file-name ".ejn-owner-v1" malformed)
                                 "wrong-marker\n")
            (set-file-times malformed old-time)
            (let ((original-float-time (symbol-function 'float-time)))
              (cl-letf (((symbol-function 'float-time)
                         (lambda (&optional time)
                           (if time
                               (funcall original-float-time time)
                             now)))
                        ((symbol-function 'process-attributes)
                         (lambda (_pid) nil)))
                (emacs-jupyter-notebook-artifacts-prune-stale)))
            (should-not (file-directory-p (ejn-ei9-test--root
                                           (cdr (assq 'old caps)))))
            (dolist (name '(fresh boundary future))
              (should (file-directory-p
                       (ejn-ei9-test--root (cdr (assq name caps))))))
            (should (file-directory-p malformed))
            (delete-directory malformed t)))
      (mapc (lambda (pair) (ejn-ei9-test--remove-fixture (cdr pair))) caps))))

(ert-deftest ejn-ei9-prune-obeys-candidate-and-deletion-caps ()
  "A bounded prune examines and retires no more roots than its configured caps."
  (let ((emacs-jupyter-notebook-artifact-stale-age 1)
        (emacs-jupyter-notebook-artifacts--prune-max-candidates 2)
        (emacs-jupyter-notebook-artifacts--prune-max-deletions 1)
        caps)
    (unwind-protect
        (progn
          (dotimes (_ 4)
            (let ((cap (emacs-jupyter-notebook-artifacts-create 'panel-images)))
              (push cap caps)
              (ejn-ei9-test--leaf cap "image-cap.png")
              (set-file-times (ejn-ei9-test--root cap)
                              (seconds-to-time (- (float-time) 10)))))
          (let ((before (cl-count-if
                         (lambda (cap) (file-directory-p (ejn-ei9-test--root cap)))
                         caps)))
            (cl-letf (((symbol-function 'process-attributes)
                       (lambda (_pid) nil)))
              (emacs-jupyter-notebook-artifacts-prune-stale))
            (let ((after (cl-count-if
                          (lambda (cap) (file-directory-p (ejn-ei9-test--root cap)))
                          caps)))
              (should (<= (- before after) 1)))))
      (mapc #'ejn-ei9-test--remove-fixture caps))))

(ert-deftest ejn-ei9-prune-malformed-name-does-not-starve-valid-root ()
  "A malformed same-parent name does not consume the recognized-root budget."
  (let ((emacs-jupyter-notebook-artifact-stale-age 1)
        ;; Do not let unrelated stale roots left by another test hide the
        ;; starvation property; malformed names themselves must consume zero.
        (emacs-jupyter-notebook-artifacts--prune-max-candidates 64)
        (emacs-jupyter-notebook-artifacts--prune-max-deletions 1)
        cap malformed)
    (unwind-protect
        (progn
          (setq cap (emacs-jupyter-notebook-artifacts-create 'image-open))
          (ejn-ei9-test--leaf cap "original.png")
          (set-file-times (ejn-ei9-test--root cap)
                          (seconds-to-time (- (float-time) 10)))
          (let ((parent (ejn-ei9-test--parent cap)))
            (setq malformed (expand-file-name "ejn-image-open-" parent))
            (make-directory malformed)
            (set-file-modes malformed #o700)
            (cl-letf (((symbol-function 'process-attributes)
                       (lambda (_pid) nil)))
              (emacs-jupyter-notebook-artifacts-prune-stale)))
          (should-not (file-directory-p (ejn-ei9-test--root cap)))
          (should (file-directory-p malformed)))
      (ejn-ei9-test--remove-fixture cap)
      (when (file-directory-p malformed) (delete-directory malformed t)))))

(ert-deftest ejn-ei9-panel-and-external-snapshot-cleanup-is-local-only ()
  "Panel and external-viewer cleanup removes local roots without remote calls."
  (require 'emacs-jupyter-notebook-result)
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("ei9.py" . 1) "plot"))
           (calls nil)
           snapshot)
      (unwind-protect
          (progn
            (ejn-panel-set-image handle '(image :type png :data "local-image"))
            (let ((image-root (with-current-buffer panel
                                emacs-jupyter-notebook-panel--image-directory)))
              (should (file-directory-p image-root))
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-remove)
                         (lambda (&rest _) (push :registry-remove calls)))
                        ((symbol-function 'emacs-jupyter-notebook-registry-save)
                         (lambda (&rest _) (push :registry-save calls)))
                        ((symbol-function 'emacs-jupyter-notebook-backend-shutdown)
                         (lambda (&rest _) (push :backend-shutdown calls)))
                        ((symbol-function 'emacs-jupyter-notebook-backend-control)
                         (lambda (&rest _) (push :backend-control calls)))
                        ((symbol-function 'emacs-jupyter-notebook-helper-start)
                         (lambda (&rest _) (push :ssh-launch calls)))
                        ((symbol-function 'emacs-jupyter-notebook-helper-request)
                         (lambda (&rest _) (push :remote-request calls))))
                (emacs-jupyter-notebook-panel--retire-all-artifacts panel))
              (should-not (file-directory-p image-root))
              (should-not calls))
            (setq snapshot
                  (emacs-jupyter-notebook-panel--make-external-image-snapshot
                   "image/png"))
            (let ((file (plist-get snapshot :file)))
              (ejn-ei9-test--write file "snap")
              (emacs-jupyter-notebook-panel--register-external-image-snapshot
               snapshot (list :sha256 (secure-hash 'sha256 "snap") :size 4))
              (should (member snapshot
                              emacs-jupyter-notebook-panel--external-image-snapshots))
              (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot)
              (should-not (file-exists-p file))
              (should-not (member snapshot
                                  emacs-jupyter-notebook-panel--external-image-snapshots))))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest ejn-ei9-mode-disable-clears-panel-without-remote-authority ()
  "Mode disable releases panel files but cannot invoke registry or kernel actions."
  (require 'emacs-jupyter-notebook)
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("ei9.py" . 2) "plot"))
           (calls nil))
      (unwind-protect
          (progn
            (ejn-panel-set-image handle '(image :type png :data "disable-image"))
            (let ((root (with-current-buffer panel
                          emacs-jupyter-notebook-panel--image-directory)))
              (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-remove)
                         (lambda (&rest _) (push :registry-remove calls)))
                        ((symbol-function 'emacs-jupyter-notebook-registry-save)
                         (lambda (&rest _) (push :registry-save calls)))
                        ((symbol-function 'emacs-jupyter-notebook-backend-shutdown)
                         (lambda (&rest _) (push :backend-shutdown calls)))
                        ((symbol-function 'emacs-jupyter-notebook-backend-control)
                         (lambda (&rest _) (push :backend-control calls)))
                        ((symbol-function 'emacs-jupyter-notebook-helper-start)
                         (lambda (&rest _) (push :ssh-launch calls)))
                        ((symbol-function 'emacs-jupyter-notebook-helper-request)
                         (lambda (&rest _) (push :remote-request calls))))
                (emacs-jupyter-notebook--mode-disable-cleanup))
              (should-not (file-directory-p root))
              (should-not calls)))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest ejn-ei9-existing-nonprivate-parent-is-never-chmodded ()
  "A predictable but pre-existing parent is refused without mutating it."
  (let* ((temporary-file-directory (file-name-as-directory
                                    (make-temp-file "ejn-ei9-parent-" t)))
         (parent (emacs-jupyter-notebook-artifacts--temp-parent-path))
         (sentinel (expand-file-name "sentinel" parent)))
    (unwind-protect
        (progn
          (make-directory parent)
          (set-file-modes parent #o755)
          (ejn-ei9-test--write sentinel "do-not-touch")
          (should-error (emacs-jupyter-notebook-artifacts-create 'helper))
          (should (= (logand (file-modes parent) #o777) #o755))
          (should (file-exists-p sentinel)))
      (ignore-errors (delete-directory temporary-file-directory t)))))

(ert-deftest ejn-ei9-live-lease-blocks-cross-emacs-prune-but-dead-lease-does-not ()
  "A second Emacs cannot prune an older root while its owner PID is live."
  (let ((emacs-jupyter-notebook-artifact-stale-age 1)
        cap root)
    (unwind-protect
        (progn
          (setq cap (emacs-jupyter-notebook-artifacts-create 'image-open)
                root (ejn-ei9-test--root cap))
          (ejn-ei9-test--leaf cap "original.png")
          (set-file-times root (seconds-to-time (- (float-time) 10)))
          (cl-letf (((symbol-function 'process-attributes)
                     (lambda (_pid) '((pid . 1)))))
            (emacs-jupyter-notebook-artifacts-prune-stale))
          (should (file-directory-p root))
          (cl-letf (((symbol-function 'process-attributes)
                     (lambda (_pid) nil)))
            (emacs-jupyter-notebook-artifacts-prune-stale))
          (should-not (file-directory-p root)))
      (ejn-ei9-test--remove-fixture cap))))

(ert-deftest ejn-ei9-panel-clear-batches-local-image-deletion ()
  "Panel clear enumerates its local image root a constant number of times."
  (require 'emacs-jupyter-notebook-result)
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("ei9.py" . 3) "plots"))
           root old-directory-files)
      (unwind-protect
          (progn
            (dotimes (_ 40)
              (ejn-panel-set-image handle '(image :type png :data "small")))
            (setq root (with-current-buffer panel
                         emacs-jupyter-notebook-panel--image-directory)
                  old-directory-files (symbol-function 'directory-files)
                  ejn-ei9-test--root-scan-count 0)
            (cl-letf (((symbol-function 'directory-files)
                       (lambda (directory &rest args)
                         (when (and (stringp directory)
                                    (equal directory root))
                           (cl-incf ejn-ei9-test--root-scan-count))
                         (apply old-directory-files directory args))))
              (emacs-jupyter-notebook-panel--retire-all-artifacts panel))
            (should-not (file-directory-p root))
            (should (<= ejn-ei9-test--root-scan-count 8)))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest ejn-ei9-unregistered-snapshot-is-retained-without-an-inode-lease ()
  "Cancelled snapshot cleanup never guesses ownership from an allowed filename."
  (require 'emacs-jupyter-notebook-result)
  (with-temp-buffer
    (let (snapshot root file)
      (unwind-protect
          (progn
            (setq snapshot (emacs-jupyter-notebook-panel--make-external-image-snapshot
                            "image/png")
                  root (plist-get snapshot :root)
                  file (plist-get snapshot :file))
            (ejn-ei9-test--write file "unregistered")
            (emacs-jupyter-notebook-panel--cleanup-external-image-snapshot snapshot)
            (should (file-exists-p file))
            (should (file-directory-p root)))
        (when (file-directory-p root) (delete-directory root t))))))

(ert-deftest ejn-ei9-local-image-replacement-is-not-deleted-without-its-inode ()
  "Panel retirement preserves an allowed-name replacement with a new inode."
  (require 'emacs-jupyter-notebook-result)
  (with-temp-buffer
    (let* ((source (current-buffer))
           (panel (ejn-panel-ensure source))
           (handle (ejn-panel-start-entry panel '("ei9.py" . 4) "plot"))
           image file)
      (unwind-protect
          (progn
            (ejn-panel-set-image handle '(image :type png :data "old"))
            (setq image (car (ejn-panel-entry-images
                              (ejn-panel-entry-snapshot handle)))
                  file (plist-get (cdr image) :file))
            (delete-file file)
            (ejn-ei9-test--write file "replacement")
            (emacs-jupyter-notebook-panel--retire-image panel image)
            (should (file-exists-p file)))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest ejn-ei9-corrupt-lease-fails-closed-and-hot-validation-mints-none ()
  "Bad lease content blocks prune, and validating a live cap creates no lease."
  (let ((emacs-jupyter-notebook-artifact-stale-age 1)
        cap root lease)
    (unwind-protect
        (progn
          (setq cap (emacs-jupyter-notebook-artifacts-create 'panel-images)
                root (ejn-ei9-test--root cap)
                lease (emacs-jupyter-notebook-artifacts-capability-lease cap))
          (dotimes (_ 20)
            (should (emacs-jupyter-notebook-artifacts-capability-valid-p cap)))
          (should (= 1 (length (directory-files root nil "\\`\\.ejn-live-" t))))
          (ejn-ei9-test--write lease "corrupt")
          (set-file-times root (seconds-to-time (- (float-time) 10)))
          (cl-letf (((symbol-function 'process-attributes) (lambda (_pid) nil)))
            (emacs-jupyter-notebook-artifacts-prune-stale))
          (should (file-directory-p root))
          (should-not (emacs-jupyter-notebook-artifacts-capability-valid-p cap)))
      (ejn-ei9-test--remove-fixture cap))))

(ert-deftest ejn-ei9-release-invalidates-capability-and-panel-recaptures ()
  "A released helper capability cannot be reused; a panel gets one new lease."
  (require 'emacs-jupyter-notebook-result)
  (ejn-ei9-test--with-capability ('helper helper-cap)
    (let* ((root (ejn-ei9-test--root helper-cap))
           (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity
                     helper-cap))
           (file (ejn-ei9-test--leaf
                  helper-cap "ejn-artifact-0123456789abcdef0123456789abcdef"))
           (identity (file-attribute-file-identifier
                      (file-attributes file 'integer)))
           panel-cap)
      ;; Helper disposal hands its publication to the panel and releases its
      ;; own process lease rather than leaving a reusable dead capability.
      (should-not (emacs-jupyter-notebook-artifacts-retire helper-cap))
      (should-not (emacs-jupyter-notebook-artifacts-capability-valid-p helper-cap))
      (with-temp-buffer
        (setq panel-cap
              (emacs-jupyter-notebook-panel--helper-artifact-capability
               root root-id))
        (should (emacs-jupyter-notebook-artifacts-capability-valid-p panel-cap))
        (should-not (eq helper-cap panel-cap))
        (should (emacs-jupyter-notebook-artifacts-delete-leaf
                 panel-cap file identity))
        (should (emacs-jupyter-notebook-artifacts-release-if-empty panel-cap)))
      (should-not (file-directory-p root)))))

(ert-deftest ejn-ei9-create-post-lease-failure-removes-lease-and-root ()
  "Failure after lease creation leaves neither a live lease nor a root behind."
  (let* ((parent (car (emacs-jupyter-notebook-artifacts--ensure-parent)))
         (before (ejn-ei9-test--children parent))
         (original (symbol-function
                    'emacs-jupyter-notebook-artifacts--capability-valid-p)))
    (should-error
     (cl-letf (((symbol-function
                 'emacs-jupyter-notebook-artifacts--capability-valid-p)
                (lambda (cap)
                  ;; The post-lease validation observes CAP with its inode.
                  (if (emacs-jupyter-notebook-artifacts-capability-lease cap)
                      nil
                    (funcall original cap)))))
       (emacs-jupyter-notebook-artifacts-create 'image-open)))
    (should (equal before (ejn-ei9-test--children parent)))))

(ert-deftest ejn-ei9-single-publication-cache-releases-only-after-last-sibling ()
  "A panel lease is retained for sibling publications and dropped on the last."
  (require 'emacs-jupyter-notebook-result)
  (ejn-ei9-test--with-capability ('helper helper-cap)
    (let* ((root (ejn-ei9-test--root helper-cap))
           (root-id (emacs-jupyter-notebook-artifacts-capability-root-identity
                     helper-cap))
           (one (ejn-ei9-test--leaf
                 helper-cap "ejn-artifact-0123456789abcdef0123456789abcdef"))
           (two (ejn-ei9-test--leaf
                 helper-cap "ejn-artifact-fedcba9876543210fedcba9876543210"))
           (one-id (file-attribute-file-identifier (file-attributes one 'integer)))
           (two-id (file-attribute-file-identifier (file-attributes two 'integer)))
           (key (cons root root-id)))
      (should-not (emacs-jupyter-notebook-artifacts-retire helper-cap))
      (with-temp-buffer
        (let ((cap (emacs-jupyter-notebook-panel--helper-artifact-capability
                    root root-id)))
          (should (emacs-jupyter-notebook-panel--delete-published-artifact
                   (list :artifact-capability cap :file one :identity one-id)))
          (should (emacs-jupyter-notebook-artifacts-capability-valid-p cap))
          (should (gethash key
                           emacs-jupyter-notebook-panel--published-artifact-capabilities))
          (should (emacs-jupyter-notebook-panel--delete-published-artifact
                   (list :artifact-capability cap :file two :identity two-id)))
          (should-not (gethash key
                               emacs-jupyter-notebook-panel--published-artifact-capabilities))
          (should-not (emacs-jupyter-notebook-artifacts-capability-valid-p cap))))
      (should-not (file-directory-p root)))))

(ert-deftest ejn-ei9-batch-delete-inventories-each-root-once ()
  "A batch proves root safety once, then identity-checks selected leaves."
  (ejn-ei9-test--with-capability ('panel-images cap)
    (let (pairs
          (root (ejn-ei9-test--root cap))
          (original (symbol-function 'directory-files)))
      (dotimes (index 8)
        (let ((file (ejn-ei9-test--leaf cap (format "image-%d.png" index))))
          (push (cons file (file-attribute-file-identifier
                            (file-attributes file 'integer)))
                pairs)))
      (setq ejn-ei9-test--root-scan-count 0)
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (directory &rest args)
                   (when (equal directory root)
                     (cl-incf ejn-ei9-test--root-scan-count))
                   (apply original directory args))))
        (should (= 8 (length (emacs-jupyter-notebook-artifacts-delete-leaves
                              cap pairs)))))
      (should (= ejn-ei9-test--root-scan-count 1))
      (should (emacs-jupyter-notebook-artifacts-release cap)))))

(provide 'emacs-jupyter-notebook-artifacts-tests)
;;; emacs-jupyter-notebook-artifacts-tests.el ends here
