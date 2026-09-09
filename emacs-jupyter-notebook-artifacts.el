;;; emacs-jupyter-notebook-artifacts.el --- Confined local artifact ownership  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Local helper and panel artifacts are untrusted filesystem names by the time
;; they are retired.  This module mints a small capability at creation and
;; makes every later destructive operation prove that the original private
;; parent, root, and owner marker are still present.  It intentionally has no
;; dependency on registry, SSH, Jupyter, or panel state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-jupyter-notebook-vars)

(defconst emacs-jupyter-notebook-artifacts--marker-name ".ejn-owner-v1")
(defconst emacs-jupyter-notebook-artifacts--parent-prefix
  "emacs-jupyter-notebook-artifacts-")
(defconst emacs-jupyter-notebook-artifacts--prune-max-candidates 64
  "Maximum direct roots examined by one stale-artifact prune.")
(defconst emacs-jupyter-notebook-artifacts--prune-max-deletions 32
  "Maximum stale roots retired by one stale-artifact prune.")

(defcustom emacs-jupyter-notebook-artifact-stale-age 86400
  "Seconds a locally owned artifact root must be idle before startup pruning.
Only roots strictly older than this value are eligible.  A non-positive or
non-numeric value disables pruning rather than widening deletion authority."
  :type 'integer
  :group 'emacs-jupyter-notebook)

(cl-defstruct (emacs-jupyter-notebook-artifacts-capability
               (:constructor emacs-jupyter-notebook-artifacts--make-capability))
  "Identity-bound authority to retire one local EJN artifact root."
  kind parent parent-identity root root-identity marker-identity
  lease lease-identity)

(defvar emacs-jupyter-notebook-artifacts--startup-pruned nil
  "Non-nil after this Emacs has attempted its asynchronous startup prune.")

(defconst emacs-jupyter-notebook-artifacts--load-file
  (or load-file-name buffer-file-name)
  "Artifact module to load in the isolated local prune process.")

(defvar emacs-jupyter-notebook-artifacts--prune-process nil
  "The sole local startup-prune child, independent of kernel lifetime.")
(defvar emacs-jupyter-notebook-artifacts--prune-timer nil
  "Hard watchdog for the local startup-prune child.")

(defun emacs-jupyter-notebook-artifacts--kind-prefix (kind)
  "Return the strict root prefix for artifact KIND, or nil."
  (pcase kind
    ('helper "ejn-helper-artifacts-")
    ('panel-images "ejn-panel-images-")
    ('image-open "ejn-image-open-")
    (_ nil)))

(defun emacs-jupyter-notebook-artifacts--marker-text (kind)
  "Return the exact ASCII owner marker for artifact KIND."
  (format "ejn-owner-v1\nkind=%s\n" (symbol-name kind)))

(defun emacs-jupyter-notebook-artifacts--mode= (path mode)
  "Return non-nil when PATH has exactly MODE permission bits."
  (= (logand (file-modes path) #o7777) mode))

(defun emacs-jupyter-notebook-artifacts--direct-child-p (parent path)
  "Return non-nil when PATH is spelled as one direct child of PARENT."
  (and (stringp parent) (stringp path) (file-name-absolute-p path)
       (equal (file-name-directory (directory-file-name (expand-file-name path)))
              (file-name-as-directory (directory-file-name parent)))))

(defun emacs-jupyter-notebook-artifacts--temp-parent-path ()
  "Return this uid's canonical, dedicated artifact parent spelling."
  (let* ((temp (file-name-as-directory (file-truename temporary-file-directory)))
         (name (format "%s%d" emacs-jupyter-notebook-artifacts--parent-prefix
                       (user-uid))))
    (directory-file-name (expand-file-name name temp))))

(defun emacs-jupyter-notebook-artifacts--directory-attributes (path)
  "Return secure directory attributes for PATH, or nil.
The caller still compares identity when it holds one."
  (and (stringp path) (not (file-symlink-p path))
       (let ((attrs (file-attributes path 'integer)))
         (and attrs (file-directory-p path) (eq (file-attribute-type attrs) t)
              (equal (file-attribute-user-id attrs) (user-uid))
              (emacs-jupyter-notebook-artifacts--mode= path #o700)
              (file-attribute-file-identifier attrs)
              attrs))))

(defun emacs-jupyter-notebook-artifacts--ensure-parent ()
  "Create and return `(PARENT . IDENTITY)' for the dedicated private parent."
  (let ((file-name-handler-alist nil)
        (parent (emacs-jupyter-notebook-artifacts--temp-parent-path)))
    (let ((created nil))
      (unless (file-exists-p parent)
        (make-directory parent nil)
        (setq created t))
    ;; Do not chmod an existing object until it is known not to be a symlink.
    (when (file-symlink-p parent)
      (error "EJN artifact parent is a symlink"))
    (let ((attrs (file-attributes parent 'integer)))
      (unless (and attrs (file-directory-p parent)
                   (eq (file-attribute-type attrs) t)
                   (equal (file-attribute-user-id attrs) (user-uid)))
        (error "EJN artifact parent is not a private directory"))
      ;; The fixed parent spelling is not proof that an existing directory is
      ;; ours.  We may tighten permissions only on the object this invocation
      ;; just created; an unexpected existing parent is retained untouched.
      (when (and created
                 (not (emacs-jupyter-notebook-artifacts--mode= parent #o700)))
        (set-file-modes parent #o700))
      (unless (emacs-jupyter-notebook-artifacts--mode= parent #o700)
        (error "EJN artifact parent is not private"))
      ;; A final stat catches a replacement while the mode was being fixed.
      (let ((final (emacs-jupyter-notebook-artifacts--directory-attributes parent)))
        (unless final (error "EJN artifact parent changed during setup"))
        (cons parent (file-attribute-file-identifier final)))))))

(defun emacs-jupyter-notebook-artifacts--root-name-valid-p (kind root parent)
  "Return non-nil when ROOT is an exact direct KIND child of PARENT."
  (let ((prefix (emacs-jupyter-notebook-artifacts--kind-prefix kind)))
    (and prefix (emacs-jupyter-notebook-artifacts--direct-child-p parent root)
         (string-match-p (concat "\\`" (regexp-quote prefix) "[[:alnum:]]+\\'")
                         (file-name-nondirectory root)))))

(defun emacs-jupyter-notebook-artifacts--lease-name-p (name)
  "Return non-nil when NAME is one exact EJN process-lease filename."
  (and (stringp name)
       (string-match-p
        "\\`\\.ejn-live-[1-9][0-9]*-[0-9a-f]\\{32\\}\\'" name)))

(defun emacs-jupyter-notebook-artifacts--lease-text (name)
  "Return the exact lease payload for validated lease NAME."
  (let ((parts (split-string name "-" t)))
    (format "ejn-live-v1\npid=%s\ntoken=%s\n"
            (nth 2 parts) (nth 3 parts))))

(defun emacs-jupyter-notebook-artifacts--lease-attributes (root path &optional identity)
  "Return validated attributes for direct lease PATH below ROOT, or nil."
  (let* ((name (and (stringp path) (file-name-nondirectory path)))
         (path-name (and name (expand-file-name name root)))
         (text (and name (emacs-jupyter-notebook-artifacts--lease-text name))))
    (and name path-name text
         (emacs-jupyter-notebook-artifacts--lease-name-p name)
         (equal path-name (expand-file-name path))
         (emacs-jupyter-notebook-artifacts--direct-child-p root path-name)
         (not (file-symlink-p path-name))
         (let ((attrs (file-attributes path-name 'integer)))
           (and attrs (file-regular-p path-name) (null (file-attribute-type attrs))
                (equal (file-attribute-user-id attrs) (user-uid))
                (= (file-attribute-link-number attrs) 1)
                (emacs-jupyter-notebook-artifacts--mode= path-name #o600)
                (= (file-attribute-size attrs) (string-bytes text))
                (or (null identity)
                    (equal identity (file-attribute-file-identifier attrs)))
                (condition-case nil
                    (with-temp-buffer
                      (let ((coding-system-for-read 'no-conversion))
                        (insert-file-contents-literally path-name)
                        (and (string-equal (buffer-string) text) attrs)))
                  (error nil)))))))

(defun emacs-jupyter-notebook-artifacts--lease-valid-p (cap)
  "Return non-nil when CAP's optional live lease remains exact."
  (let ((lease (emacs-jupyter-notebook-artifacts-capability-lease cap)))
    (or (null lease)
        (emacs-jupyter-notebook-artifacts--lease-attributes
         (emacs-jupyter-notebook-artifacts-capability-root cap) lease
         (emacs-jupyter-notebook-artifacts-capability-lease-identity cap)))))

(defun emacs-jupyter-notebook-artifacts--marker-valid-p (cap)
  "Return non-nil when CAP's exact owner marker still proves ownership."
  (let* ((root (emacs-jupyter-notebook-artifacts-capability-root cap))
         (marker (expand-file-name emacs-jupyter-notebook-artifacts--marker-name root))
         (wanted (emacs-jupyter-notebook-artifacts--marker-text
                  (emacs-jupyter-notebook-artifacts-capability-kind cap))))
    (and (emacs-jupyter-notebook-artifacts--direct-child-p root marker)
         (not (file-symlink-p marker))
         (let ((attrs (file-attributes marker 'integer)))
           (and attrs (file-regular-p marker) (null (file-attribute-type attrs))
                (equal (file-attribute-user-id attrs) (user-uid))
                (= (file-attribute-link-number attrs) 1)
                (emacs-jupyter-notebook-artifacts--mode= marker #o600)
                (= (file-attribute-size attrs) (string-bytes wanted))
                (equal (file-attribute-file-identifier attrs)
                       (emacs-jupyter-notebook-artifacts-capability-marker-identity cap))
                (condition-case nil
                    (with-temp-buffer
                      (let ((coding-system-for-read 'no-conversion))
                        (insert-file-contents-literally marker)
                        (string-equal (buffer-string) wanted)))
                  (error nil)))))))

(defun emacs-jupyter-notebook-artifacts--capability-base-valid-p (cap)
  "Return non-nil while CAP's parent, root, and marker identities remain intact."
  (and (emacs-jupyter-notebook-artifacts-capability-p cap)
       (let* ((parent (emacs-jupyter-notebook-artifacts-capability-parent cap))
              (root (emacs-jupyter-notebook-artifacts-capability-root cap))
              (parent-attrs (emacs-jupyter-notebook-artifacts--directory-attributes parent))
              (root-attrs (emacs-jupyter-notebook-artifacts--directory-attributes root)))
         (and parent-attrs root-attrs
              (equal (file-attribute-file-identifier parent-attrs)
                     (emacs-jupyter-notebook-artifacts-capability-parent-identity cap))
              (equal (file-attribute-file-identifier root-attrs)
                     (emacs-jupyter-notebook-artifacts-capability-root-identity cap))
              (emacs-jupyter-notebook-artifacts--root-name-valid-p
               (emacs-jupyter-notebook-artifacts-capability-kind cap) root parent)
              (emacs-jupyter-notebook-artifacts--marker-valid-p cap)))))

(defun emacs-jupyter-notebook-artifacts--capability-valid-p (cap)
  "Return non-nil only while CAP retains its exact live ownership lease."
  (and (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
       (emacs-jupyter-notebook-artifacts-capability-lease cap)
       (emacs-jupyter-notebook-artifacts--lease-valid-p cap)))

(defun emacs-jupyter-notebook-artifacts-capability-valid-p (cap)
  "Return non-nil only while CAP's root, marker, and lease remain exact."
  (condition-case nil
      (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
    (error nil)))

(defun emacs-jupyter-notebook-artifacts--write-marker
    (root kind parent parent-identity root-identity)
  "Atomically install KIND's exact owner marker in ROOT and return its identity."
  (let* ((file-name-handler-alist nil)
         (marker (expand-file-name emacs-jupyter-notebook-artifacts--marker-name root))
         (temporary (make-temp-file (expand-file-name ".ejn-owner-v1.tmp-" root)))
         (text (emacs-jupyter-notebook-artifacts--marker-text kind))
         temporary-identity marker-identity cap complete)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region text nil temporary nil 'silent))
          (set-file-modes temporary #o600)
          (when (file-symlink-p temporary)
            (error "EJN marker temporary became a symlink"))
          (let ((attrs (file-attributes temporary 'integer)))
            (unless (and attrs (file-regular-p temporary)
                         (null (file-attribute-type attrs))
                         (equal (file-attribute-user-id attrs) (user-uid))
                         (= (file-attribute-link-number attrs) 1)
                         (emacs-jupyter-notebook-artifacts--mode= temporary #o600)
                         (file-attribute-file-identifier attrs))
              (error "EJN marker temporary validation failed"))
            (setq temporary-identity (file-attribute-file-identifier attrs)))
          (rename-file temporary marker nil)
          ;; Rename preserves the inode.  Mint the rollback capability from
          ;; the already validated temporary inode before the first post-rename
          ;; stat, so a transient stat failure can still be cleaned up safely.
          (setq marker-identity temporary-identity
                cap (emacs-jupyter-notebook-artifacts--make-capability
                     :kind kind :parent parent :parent-identity parent-identity
                     :root root :root-identity root-identity
                     :marker-identity marker-identity))
          (let ((attrs (file-attributes marker 'integer)))
            (unless (and attrs (not (file-symlink-p marker))
                         (file-regular-p marker) (null (file-attribute-type attrs))
                         (= (file-attribute-link-number attrs) 1)
                         (equal (file-attribute-user-id attrs) (user-uid))
                         (emacs-jupyter-notebook-artifacts--mode= marker #o600)
                         (= (file-attribute-size attrs) (string-bytes text))
                         (file-attribute-file-identifier attrs))
              (error "EJN owner marker validation failed"))
            (unless (equal marker-identity (file-attribute-file-identifier attrs))
              (error "EJN owner marker changed during rename")))
          ;; This repeats the content and identity checks after the rename.  If
          ;; an injected/stat validation fails after the marker exists, CAP
          ;; still permits only nonrecursive identity-pinned rollback.
          (unless (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
            (error "EJN owner marker validation failed"))
          (setq complete t)
          marker-identity)
      (unless complete
        ;; This is an unpublished private temporary name, not an advertised
        ;; artifact.  Still refuse to unlink a symlink replacement.
        (when (and temporary-identity (file-exists-p temporary)
                   (not (file-symlink-p temporary))
                   (let ((attrs (file-attributes temporary 'integer)))
                     (and attrs (file-regular-p temporary)
                          (null (file-attribute-type attrs))
                          (= (file-attribute-link-number attrs) 1)
                          (equal (file-attribute-user-id attrs) (user-uid))
                          (= (logand (file-modes temporary) #o7777) #o600)
                          (equal temporary-identity
                                 (file-attribute-file-identifier attrs)))))
          (ignore-errors (delete-file temporary)))
        (when cap
          (ignore-errors (emacs-jupyter-notebook-artifacts--delete-marker-and-root cap)))))))

(defun emacs-jupyter-notebook-artifacts--create-lease (cap)
  "Attach one fresh process lease to already validated CAP and return it.
The lease is deliberately a direct regular file so stale pruning can prove a
different Emacs still owns a root without contacting a remote kernel."
  (let* ((root (emacs-jupyter-notebook-artifacts-capability-root cap))
         (token (md5 (format "%s:%s:%s" (emacs-pid) (float-time) (random))))
         (name (format ".ejn-live-%d-%s" (emacs-pid) token))
         (lease (expand-file-name name root))
         (text (emacs-jupyter-notebook-artifacts--lease-text name))
         attrs complete)
    (unless (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
      (error "EJN artifact root changed before lease creation"))
    (let ((coding-system-for-write 'no-conversion))
      ;; `write-region' with MUSTBENEW keeps an accidental/replaced name from
      ;; being adopted.  The random token makes normal collisions negligible.
      (write-region text nil lease nil 'silent nil 'excl))
    (unwind-protect
        (progn
          (set-file-modes lease #o600)
          (setq attrs (emacs-jupyter-notebook-artifacts--lease-attributes root lease))
          (unless attrs (error "EJN artifact lease validation failed"))
          (setf (emacs-jupyter-notebook-artifacts-capability-lease cap) lease
                (emacs-jupyter-notebook-artifacts-capability-lease-identity cap)
                (file-attribute-file-identifier attrs))
          (unless (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
            (error "EJN artifact lease changed during creation"))
          (setq complete t)
          cap)
      (unless complete
        (when (emacs-jupyter-notebook-artifacts--lease-attributes
               root lease (emacs-jupyter-notebook-artifacts-capability-lease-identity cap))
          (ignore-errors (delete-file lease)))
        (setf (emacs-jupyter-notebook-artifacts-capability-lease cap) nil
              (emacs-jupyter-notebook-artifacts-capability-lease-identity cap) nil)))))

(defun emacs-jupyter-notebook-artifacts-capture
    (kind root &optional root-identity acquire-lease)
  "Return a validated capability for KIND ROOT, or nil when it is unsafe.
ROOT must live directly in EJN's dedicated parent and have the exact marker.
When ROOT-IDENTITY is non-nil it must also match, which prevents a late event
from gaining authority over a replacement root.  A lease is acquired unless
ACQUIRE-LEASE is the internal sentinel `:no-lease'."
  (condition-case nil
      (let* ((file-name-handler-alist nil)
             (acquire-lease (not (eq acquire-lease :no-lease)))
             (parent-pair (emacs-jupyter-notebook-artifacts--ensure-parent))
             (parent (car parent-pair))
             (parent-id (cdr parent-pair))
             (root-name (and (stringp root) (directory-file-name (expand-file-name root))))
             (root-attrs (emacs-jupyter-notebook-artifacts--directory-attributes root-name)))
        (when (and root-attrs
                   (emacs-jupyter-notebook-artifacts--root-name-valid-p kind root-name parent)
                   (or (null root-identity)
                       (equal root-identity (file-attribute-file-identifier root-attrs))))
          (let* ((cap (emacs-jupyter-notebook-artifacts--make-capability
                       :kind kind :parent parent :parent-identity parent-id
                       :root root-name
                       :root-identity (file-attribute-file-identifier root-attrs)
                       :marker-identity nil))
                 (marker (expand-file-name emacs-jupyter-notebook-artifacts--marker-name root-name))
                 (marker-attrs (and (not (file-symlink-p marker))
                                    (file-attributes marker 'integer))))
            (when (and marker-attrs (file-attribute-file-identifier marker-attrs))
              (setf (emacs-jupyter-notebook-artifacts-capability-marker-identity cap)
                    (file-attribute-file-identifier marker-attrs))
              (when (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
                (if acquire-lease
                    (emacs-jupyter-notebook-artifacts--create-lease cap)
                  cap))))))
    (error nil)))

(defun emacs-jupyter-notebook-artifacts--cancel-prune ()
  "Retire the exact local prune child and its watchdog, never a kernel."
  (let ((process emacs-jupyter-notebook-artifacts--prune-process)
        (timer emacs-jupyter-notebook-artifacts--prune-timer))
    (setq emacs-jupyter-notebook-artifacts--prune-process nil
          emacs-jupyter-notebook-artifacts--prune-timer nil)
    (when (timerp timer) (cancel-timer timer))
    (when (and (processp process) (process-live-p process))
      (ignore-errors (delete-process process)))))

(add-hook 'kill-emacs-hook #'emacs-jupyter-notebook-artifacts--cancel-prune)

(defun emacs-jupyter-notebook-artifacts--prune-once ()
  "Prune stale roots once in a supervised local child, never during load.
Directory enumeration, inode checks and bulk deletion all run outside the
interactive Emacs.  A crashed prior session may leave arbitrarily many roots
or leaves; root-count caps alone cannot bound that filesystem work."
  (unless emacs-jupyter-notebook-artifacts--startup-pruned
    (setq emacs-jupyter-notebook-artifacts--startup-pruned t)
    (when (and (numberp emacs-jupyter-notebook-artifact-stale-age)
               (> emacs-jupyter-notebook-artifact-stale-age 0))
      (condition-case nil
          (let* ((file-name-handler-alist nil)
                 (default-directory temporary-file-directory)
                 (module emacs-jupyter-notebook-artifacts--load-file)
                 (directory (file-name-directory module))
                 (executable (expand-file-name invocation-name invocation-directory))
                 (form `(let ((temporary-file-directory ,temporary-file-directory)
                              (emacs-jupyter-notebook-artifact-stale-age
                               ,emacs-jupyter-notebook-artifact-stale-age))
                          (emacs-jupyter-notebook-artifacts-prune-stale)))
                 (process
                  (make-process
                   :name "ejn-artifact-prune" :buffer nil :noquery t
                   :connection-type 'pipe :coding 'utf-8-unix
                   :command (list executable "-Q" "--batch" "-L" directory
                                  "-l" module "--eval" (prin1-to-string form))
                   :filter #'ignore
                   :sentinel
                   (lambda (child _event)
                     (when (and (eq child emacs-jupyter-notebook-artifacts--prune-process)
                                (memq (process-status child) '(exit signal failed closed)))
                       (emacs-jupyter-notebook-artifacts--cancel-prune))))))
            (setq emacs-jupyter-notebook-artifacts--prune-process process)
            (setq emacs-jupyter-notebook-artifacts--prune-timer
                  (run-at-time
                   30 nil
                   (lambda ()
                     (when (eq process emacs-jupyter-notebook-artifacts--prune-process)
                       (emacs-jupyter-notebook-artifacts--cancel-prune)))))
            ;; A very fast failure may settle while make-process is returning.
            (unless (process-live-p process)
              (emacs-jupyter-notebook-artifacts--cancel-prune)))
        (error (emacs-jupyter-notebook-artifacts--cancel-prune))))))

(defun emacs-jupyter-notebook-artifacts--cleanup-created-root
    (kind parent parent-identity root root-identity marker-identity)
  "Nonrecursively remove a just-created empty ROOT when identities still match.
This is limited to creation-time names and never follows or unlinks a
replacement symlink.  It deliberately leaves any unexpected leaf for the
bounded stale-prune path rather than broadening failure cleanup authority."
  (let* ((cap (and marker-identity
                   (emacs-jupyter-notebook-artifacts--make-capability
                    :kind kind :parent parent :parent-identity parent-identity
                    :root root :root-identity root-identity
                    :marker-identity marker-identity))))
    (cond
     (cap (emacs-jupyter-notebook-artifacts--delete-marker-and-root cap))
     ((and (emacs-jupyter-notebook-artifacts--direct-child-p parent root)
           (emacs-jupyter-notebook-artifacts--root-name-valid-p kind root parent)
           (let ((parent-attrs (emacs-jupyter-notebook-artifacts--directory-attributes parent))
                 (root-attrs (emacs-jupyter-notebook-artifacts--directory-attributes root)))
             (and parent-attrs root-attrs
                  (equal parent-identity (file-attribute-file-identifier parent-attrs))
                  (equal root-identity (file-attribute-file-identifier root-attrs))
                  (not (file-symlink-p root))
                  (= (length (directory-files root nil nil t)) 2))))
      (ignore-errors (delete-directory root))))))

(defun emacs-jupyter-notebook-artifacts-create (kind)
  "Create and return one fresh, identity-bound private artifact capability.
KIND is one of `helper', `panel-images', or `image-open'."
  (let ((prefix (or (emacs-jupyter-notebook-artifacts--kind-prefix kind)
                    (error "Unknown EJN artifact kind: %S" kind))))
    (emacs-jupyter-notebook-artifacts--prune-once)
    (let* ((file-name-handler-alist nil)
           (parent-pair (emacs-jupyter-notebook-artifacts--ensure-parent))
           (parent (car parent-pair))
           (parent-identity (cdr parent-pair))
           (created (make-temp-file (expand-file-name prefix (file-name-as-directory parent)) t))
           rollback-root-identity root-identity
           marker-identity cap)
      (unwind-protect
          (progn
            (when (file-symlink-p created)
              (error "EJN artifact root became a symlink"))
            ;; Preserve an internal rollback identity before chmod.  A normal
            ;; capability is still captured only after the forced 0700 stat,
            ;; but an injected chmod failure can safely remove this known,
            ;; still-empty root if it was already private.
            (let ((pre-attrs (emacs-jupyter-notebook-artifacts--directory-attributes
                              created)))
              (unless pre-attrs
                (error "EJN artifact root validation failed"))
              (setq rollback-root-identity
                    (file-attribute-file-identifier pre-attrs)))
            (set-file-modes created #o700)
            (let ((attrs (emacs-jupyter-notebook-artifacts--directory-attributes created)))
              (unless (and attrs
                           (equal rollback-root-identity
                                  (file-attribute-file-identifier attrs))
                           (emacs-jupyter-notebook-artifacts--root-name-valid-p
                            kind created parent))
                (error "EJN artifact root validation failed"))
              (setq root-identity (file-attribute-file-identifier attrs)))
            (setq marker-identity
                  (emacs-jupyter-notebook-artifacts--write-marker
                   created kind parent parent-identity root-identity))
            (setq cap (emacs-jupyter-notebook-artifacts-capture kind created))
            (unless cap (error "EJN artifact capability validation failed"))
            cap)
        (unless cap
          (emacs-jupyter-notebook-artifacts--cleanup-created-root
           kind parent parent-identity created
           (or root-identity rollback-root-identity) marker-identity))))))

(defun emacs-jupyter-notebook-artifacts--leaf-name-valid-p (kind name)
  "Return non-nil when NAME is an allowed direct leaf for KIND."
  (pcase kind
    ('helper (or (string-match-p "\\`\\.ejn-partial-[0-9a-f]\\{32\\}\\'" name)
                 (string-match-p "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'" name)))
    ('panel-images
     (string-match-p
      "\\`image-[[:alnum:]]+\\(?:\\.\\(?:png\\|jpg\\|gif\\|webp\\|img\\)\\)?\\'" name))
    ('image-open
     (string-match-p "\\`original\\.\\(?:png\\|jpg\\|gif\\|webp\\|img\\)\\'" name))
    (_ nil)))

(defun emacs-jupyter-notebook-artifacts--root-entry-attributes (cap path)
  "Return attributes for one safe root entry under CAP, or nil.
Artifact payloads and live leases are intentionally separate namespaces."
  (or (emacs-jupyter-notebook-artifacts--leaf-attributes cap path)
      (emacs-jupyter-notebook-artifacts--lease-attributes
       (emacs-jupyter-notebook-artifacts-capability-root cap) path)))

(defun emacs-jupyter-notebook-artifacts--leaf-attributes (cap path &optional identity)
  "Return validated direct-leaf attributes for CAP PATH, or nil.
IDENTITY, when supplied, pins deletion to the advertised inode."
  (let* ((root (emacs-jupyter-notebook-artifacts-capability-root cap))
         (name (and (stringp path) (file-name-nondirectory path)))
         (path-name (and name (expand-file-name name root))))
    (and name path-name
         (equal path-name (expand-file-name path))
         (emacs-jupyter-notebook-artifacts--direct-child-p root path-name)
         (emacs-jupyter-notebook-artifacts--leaf-name-valid-p
          (emacs-jupyter-notebook-artifacts-capability-kind cap) name)
         (not (file-symlink-p path-name))
         (let ((attrs (file-attributes path-name 'integer)))
           (and attrs (file-regular-p path-name) (null (file-attribute-type attrs))
                (equal (file-attribute-user-id attrs) (user-uid))
                (= (file-attribute-link-number attrs) 1)
                (emacs-jupyter-notebook-artifacts--mode= path-name #o600)
                (or (null identity)
                    (equal identity (file-attribute-file-identifier attrs)))
                attrs)))))

(defun emacs-jupyter-notebook-artifacts-delete-leaves (cap leaves)
  "Delete identity-pinned artifact LEAVES under CAP with one root preflight.
LEAVES is a list of `(PATH . IDENTITY)' pairs.  Every identity is mandatory.
An unsafe sibling rejects the complete batch before any unlink, keeping panel
clear/kill bounded while preserving the module's fail-closed root policy."
  (let ((file-name-handler-alist nil))
    (condition-case nil
        (let ((names nil))
          (when (and (listp leaves)
                     (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
                     ;; A root with even one unknown, nested, symlinked, or
                     ;; hardlinked sibling is retained as a whole.
                     (listp (emacs-jupyter-notebook-artifacts--root-leaves cap)))
            (dolist (leaf leaves)
              (unless (and (consp leaf) (cdr leaf)
                           (stringp (car leaf))
                           (emacs-jupyter-notebook-artifacts--leaf-attributes
                            cap (car leaf) (cdr leaf)))
                (error "unsafe EJN artifact batch leaf"))
              (push (cons (file-name-nondirectory (car leaf)) (cdr leaf)) names))
            (setq names (delete-dups (nreverse names)))
            ;; Emacs has no portable directory descriptor API.  The one
            ;; full-root inventory above keeps panel clear O(N); each selected
            ;; inode and the capability are still rechecked immediately before
            ;; its unlink, so a replacement cannot be deleted.
            (let (deleted)
              (dolist (leaf names)
                (let ((path (expand-file-name (car leaf)
                                              (emacs-jupyter-notebook-artifacts-capability-root cap))))
                  (unless (and (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
                               (emacs-jupyter-notebook-artifacts--leaf-attributes
                                cap path (cdr leaf)))
                    (error "EJN artifact leaf changed during batch deletion"))
                  (delete-file path)
                  (push path deleted)))
              (nreverse deleted))))
      (error nil))))

(defun emacs-jupyter-notebook-artifacts-delete-leaf (cap path identity)
  "Delete identity-pinned direct PATH under CAP, or return nil.
IDENTITY is mandatory; callers that have not captured an inode must retain the
leaf for normal stale pruning instead of guessing ownership."
  (car (emacs-jupyter-notebook-artifacts-delete-leaves
        cap (and identity (list (cons path identity))))))

(defun emacs-jupyter-notebook-artifacts--root-leaves (cap)
  "Return validated leaf names in CAP, or `:unsafe' for an unsafe root.
The marker itself is omitted.  A nested name, symlink, hardlink, or unknown
entry fails closed before retirement deletes anything."
  (let ((root (emacs-jupyter-notebook-artifacts-capability-root cap))
        names)
    (condition-case nil
        (progn
          (dolist (name (directory-files root nil nil t))
            (unless (member name (list "." ".."
                                      emacs-jupyter-notebook-artifacts--marker-name))
              (let ((path (expand-file-name name root)))
                (unless (emacs-jupyter-notebook-artifacts--root-entry-attributes cap path)
                  (error "unsafe EJN artifact leaf"))
                (push name names))))
          (nreverse names))
      (error :unsafe))))

(defun emacs-jupyter-notebook-artifacts--delete-prevalidated-leaf (cap name)
  "Unlink preflighted direct NAME after one final local identity recheck.
Only `--retire' calls this after `--root-leaves' has proved every sibling
safe, avoiding repeated whole-root scans during bulk retirement."
  (let ((path (expand-file-name name
                                (emacs-jupyter-notebook-artifacts-capability-root cap))))
    (condition-case nil
        (when (and (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
                   (emacs-jupyter-notebook-artifacts--leaf-attributes cap path))
          (delete-file path)
          t)
      (error nil))))

(defun emacs-jupyter-notebook-artifacts--delete-own-lease (cap)
  "Release CAP's exact process lease and return non-nil on success/no lease."
  (let ((lease (emacs-jupyter-notebook-artifacts-capability-lease cap))
        (identity (emacs-jupyter-notebook-artifacts-capability-lease-identity cap)))
    (cond
     ((null lease) t)
     ((and (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
           (emacs-jupyter-notebook-artifacts--lease-attributes
            (emacs-jupyter-notebook-artifacts-capability-root cap) lease identity))
      (condition-case nil
          (progn
            (delete-file lease)
            (setf (emacs-jupyter-notebook-artifacts-capability-lease cap) nil
                  (emacs-jupyter-notebook-artifacts-capability-lease-identity cap) nil)
            t)
        (error nil)))
     (t nil))))

(defun emacs-jupyter-notebook-artifacts--delete-marker-and-root (cap)
  "Remove CAP's marker then its now-empty root after final identity checks."
  (let* ((root (emacs-jupyter-notebook-artifacts-capability-root cap))
         (marker (expand-file-name emacs-jupyter-notebook-artifacts--marker-name root)))
    (condition-case nil
        (when (and (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
                   (equal (emacs-jupyter-notebook-artifacts--root-leaves cap) nil)
                   ;; Empty and unsafe are distinguishable here: an empty
                   ;; root has only the marker, while a bad root makes the
                   ;; capability check above fail or leaves enumeration nil.
                   (= (length (directory-files root nil nil t)) 3)
                   (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap))
          (delete-file marker)
          (let ((root-attrs (emacs-jupyter-notebook-artifacts--directory-attributes root))
                (parent-attrs (emacs-jupyter-notebook-artifacts--directory-attributes
                               (emacs-jupyter-notebook-artifacts-capability-parent cap))))
            (when (and root-attrs parent-attrs
                       (equal (file-attribute-file-identifier root-attrs)
                              (emacs-jupyter-notebook-artifacts-capability-root-identity cap))
                       (equal (file-attribute-file-identifier parent-attrs)
                              (emacs-jupyter-notebook-artifacts-capability-parent-identity cap))
                       (not (file-symlink-p root))
                       (null (directory-files root nil directory-files-no-dot-files-regexp t)))
              (delete-directory root)
              t)))
      (error nil))))

(defun emacs-jupyter-notebook-artifacts-release (cap)
  "Release CAP's live lease and remove only an already empty root.
Unlike `emacs-jupyter-notebook-artifacts-retire', this never deletes artifact
payloads.  It is used after a cancelled writer whose destination inode was
never safely observed."
  (when (and (if (emacs-jupyter-notebook-artifacts-capability-lease cap)
                 (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
               (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap))
             (listp (emacs-jupyter-notebook-artifacts--root-leaves cap))
             (emacs-jupyter-notebook-artifacts--delete-own-lease cap))
    (emacs-jupyter-notebook-artifacts--delete-marker-and-root cap)))

(defun emacs-jupyter-notebook-artifacts-release-if-empty (cap)
  "Release CAP only when its root has no artifact payload.
This lets a panel drop its cached ownership immediately after the final
publication is deleted, while preserving another Emacs's valid lease."
  (when (and (emacs-jupyter-notebook-artifacts--capability-valid-p cap)
             (let ((leaves (emacs-jupyter-notebook-artifacts--root-leaves cap)))
               (and (listp leaves)
                    (cl-every #'emacs-jupyter-notebook-artifacts--lease-name-p leaves)
                    (member (file-name-nondirectory
                             (emacs-jupyter-notebook-artifacts-capability-lease cap))
                            leaves)))
             (emacs-jupyter-notebook-artifacts--delete-own-lease cap))
    (ignore-errors (emacs-jupyter-notebook-artifacts--delete-marker-and-root cap))
    t))

(defun emacs-jupyter-notebook-artifacts--retire (cap prune-p)
  "Retire CAP locally, treating helper publications as retained unless PRUNE-P."
  (let ((file-name-handler-alist nil))
    (let (result)
      (when (if prune-p
                (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
              (emacs-jupyter-notebook-artifacts--capability-valid-p cap))
        (let ((leaves (emacs-jupyter-notebook-artifacts--root-leaves cap)))
          (when (listp leaves)
            (let ((publications
                   (and (eq (emacs-jupyter-notebook-artifacts-capability-kind cap) 'helper)
                        (cl-some (lambda (name) (string-prefix-p "ejn-artifact-" name)) leaves))))
            ;; Ordinary helper disposal cleans partials but deliberately leaves
            ;; completed publications for panel ownership or crash pruning.
            (dolist (name leaves)
              (when (and (emacs-jupyter-notebook-artifacts--leaf-name-valid-p
                          (emacs-jupyter-notebook-artifacts-capability-kind cap) name)
                         (or prune-p
                             (not (eq (emacs-jupyter-notebook-artifacts-capability-kind cap) 'helper))
                             (string-prefix-p ".ejn-partial-" name)))
                (unless (emacs-jupyter-notebook-artifacts--delete-prevalidated-leaf cap name)
                  (setq publications t))))
            (unless (and (eq (emacs-jupyter-notebook-artifacts-capability-kind cap) 'helper)
                         publications)
              (setq result (emacs-jupyter-notebook-artifacts-release cap)))
            ;; A helper root that still carries published files must still give
            ;; up its own lease: panel ownership has a separate lease.
            (when (and (eq (emacs-jupyter-notebook-artifacts-capability-kind cap) 'helper)
                       publications)
              (setq result (emacs-jupyter-notebook-artifacts-release cap)))))))
      result)))

(defun emacs-jupyter-notebook-artifacts-retire (cap)
  "Retire CAP's local transient leaves without touching retained publications.
Return non-nil only if its root was entirely removed."
  (emacs-jupyter-notebook-artifacts--retire cap nil))

(defun emacs-jupyter-notebook-artifacts--kind-for-root-name (name)
  "Return the sole recognized kind represented by root NAME, or nil."
  (cl-loop for kind in '(helper panel-images image-open)
           when (string-match-p
                 (concat "\\`" (regexp-quote
                                  (emacs-jupyter-notebook-artifacts--kind-prefix kind))
                         "[[:alnum:]]+\\'") name)
           return kind))

(defun emacs-jupyter-notebook-artifacts--lease-pid (name)
  "Return NAME's validated lease pid, or nil."
  (when (emacs-jupyter-notebook-artifacts--lease-name-p name)
    (let ((pid (string-to-number (nth 2 (split-string name "-" t)))))
      (and (> pid 0) pid))))

(defun emacs-jupyter-notebook-artifacts--root-live-lease-p (cap)
  "Return t for a live or indeterminate lease, nil for dead, unsafe otherwise."
  (let ((leaves (emacs-jupyter-notebook-artifacts--root-leaves cap))
        live)
    (cond
     ((not (listp leaves)) :unsafe)
     (t
      (dolist (name leaves)
        (when (emacs-jupyter-notebook-artifacts--lease-name-p name)
          (let ((pid (emacs-jupyter-notebook-artifacts--lease-pid name)))
            ;; An inability to query the local process table is conservative:
            ;; it delays stale cleanup rather than deleting an active root.
            (let ((dead (and pid (fboundp 'process-attributes)
                             (condition-case nil
                                 (null (process-attributes pid))
                               (error nil)))))
              (setq live (or live (not dead)))))))
      live))))

(defun emacs-jupyter-notebook-artifacts--prune-dead-leases (cap)
  "Delete only validated dead leases in stale CAP, returning non-nil on success."
  (let ((leaves (emacs-jupyter-notebook-artifacts--root-leaves cap)))
    (when (listp leaves)
      (catch 'failed
        (dolist (name leaves t)
          (when (emacs-jupyter-notebook-artifacts--lease-name-p name)
            (let ((path (expand-file-name name
                                          (emacs-jupyter-notebook-artifacts-capability-root cap))))
              (unless (and (emacs-jupyter-notebook-artifacts--capability-base-valid-p cap)
                           (emacs-jupyter-notebook-artifacts--lease-attributes
                            (emacs-jupyter-notebook-artifacts-capability-root cap) path))
                (throw 'failed nil))
              (condition-case nil
                  (delete-file path)
                (error (throw 'failed nil))))))))))

(defun emacs-jupyter-notebook-artifacts-prune-stale ()
  "Boundedly retire stale EJN-owned roots under the dedicated private parent.
Only direct children are enumerated.  Unknown names, future timestamps, and
roots exactly on the configured age boundary are retained."
  (let ((age emacs-jupyter-notebook-artifact-stale-age))
    (when (and (numberp age) (> age 0))
      (condition-case nil
          (let* ((file-name-handler-alist nil)
                 (parent-pair (emacs-jupyter-notebook-artifacts--ensure-parent))
                 (parent (car parent-pair))
                 (cutoff (- (float-time) age))
                 (candidates 0) (deleted 0))
            ;; `parent' is a mode-0700 EJN-only directory, never /tmp.  The
            ;; candidate and deletion caps bound post-enumeration work.
            (dolist (name (directory-files parent nil "\\`ejn-" t))
              (let ((kind (emacs-jupyter-notebook-artifacts--kind-for-root-name name)))
                ;; Arbitrary same-parent names do not consume the bounded
                ;; candidate budget and cannot permanently starve real roots.
                (when (and kind (< deleted emacs-jupyter-notebook-artifacts--prune-max-deletions))
                  (let* ((kind kind)
                       (root (expand-file-name name parent))
                       (attrs (and kind (not (file-symlink-p root))
                                   (file-attributes root 'integer)))
                       (mtime (and attrs (file-attribute-modification-time attrs))))
                  (when (and kind attrs mtime
                             ;; Strict comparison retains future and exact-boundary roots.
                             (< (float-time mtime) cutoff)
                             (< candidates emacs-jupyter-notebook-artifacts--prune-max-candidates))
                    ;; Fresh/future/malformed roots do not consume the
                    ;; eligible-candidate budget, so they cannot starve an
                    ;; actually stale EJN-owned root later in this scan.
                    (when-let ((cap (emacs-jupyter-notebook-artifacts-capture
                                     kind root nil :no-lease)))
                      (cl-incf candidates)
                      (when (and (null (emacs-jupyter-notebook-artifacts--root-live-lease-p cap))
                                 (emacs-jupyter-notebook-artifacts--prune-dead-leases cap)
                                 (emacs-jupyter-notebook-artifacts--retire cap t))
                        (cl-incf deleted))))))))
            deleted)
        (error 0)))))

(provide 'emacs-jupyter-notebook-artifacts)
;;; emacs-jupyter-notebook-artifacts.el ends here
