;;; emacs-jupyter-notebook-history.el --- Lightweight execution trail -*- lexical-binding: t; -*-

;;; Commentary:
;; Source-owned, bounded execution facts independent of disposable outputs.
;; A trail is a memory aid, not a claim to recover arbitrary kernel state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'tabulated-list)
(require 'diff-mode)
(require 'emacs-jupyter-notebook-vars)

(defvar emacs-jupyter-notebook-mode)
(defvar emacs-jupyter-notebook--session-entry)
(defvar emacs-jupyter-notebook-panel--source-buffer)
(defvar emacs-jupyter-notebook-scratch--owner)
(declare-function emacs-jupyter-notebook--current-cell-key "emacs-jupyter-notebook")
(declare-function emacs-jupyter-notebook-scratch "emacs-jupyter-notebook-scratch"
                  (&optional code))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))

(defcustom emacs-jupyter-notebook-history-limit 200
  "Maximum recent execution records retained in each live source buffer.
The hard ceiling is 1000.  Saved findings own separate copies of their context."
  :type 'natnum :group 'emacs-jupyter-notebook)

(defcustom emacs-jupyter-notebook-history-code-bytes (* 4 1024 1024)
  "Maximum bytes of exact code retained in each source's recent trail.
The hard ceiling is 8 MiB.  Evicted records cannot be recalled."
  :type 'natnum :group 'emacs-jupyter-notebook)

(defconst emacs-jupyter-notebook-history--provenance-bytes 24576)
(defvar-local emacs-jupyter-notebook-history--entries nil)
(defvar-local emacs-jupyter-notebook-history--bytes 0)
(defvar-local emacs-jupyter-notebook-history--evicted nil)
(defvar-local emacs-jupyter-notebook-history--view nil)
(defvar-local emacs-jupyter-notebook-history--code-view nil)
(defvar-local emacs-jupyter-notebook-history--diff-view nil)
(defvar-local emacs-jupyter-notebook-history--owner nil)
(defvar-local emacs-jupyter-notebook-history--detail-id nil)
(defvar-local emacs-jupyter-notebook-history--kernel-epoch 0
  "Confirmed local kernel replacements, independent of reconnect attempts.")

(defun emacs-jupyter-notebook-history-kernel-restarted ()
  "Start a new history identity once a requested restart ends the old kernel.
Do not call for reconnecting to the same durable remote kernel."
  (cl-incf emacs-jupyter-notebook-history--kernel-epoch))

(defun emacs-jupyter-notebook-history--source ()
  "Return this surface's live source buffer, or signal a user error."
  (let ((owner (or emacs-jupyter-notebook-history--owner
                   (bound-and-true-p emacs-jupyter-notebook-scratch--owner)
                   (bound-and-true-p emacs-jupyter-notebook-panel--source-buffer)
                   (and (bound-and-true-p emacs-jupyter-notebook-mode)
                        (current-buffer)))))
    (unless (buffer-live-p owner)
      (user-error "Open a notebook source buffer first"))
    owner))

(defun emacs-jupyter-notebook-history--record (id)
  "Return source-local trail record ID."
  (cl-find id emacs-jupyter-notebook-history--entries
           :key (lambda (entry) (plist-get entry :id)) :test #'equal))

(defun emacs-jupyter-notebook-history--trim ()
  "Enforce both bounded retention budgets without truncating code."
  (let ((count (if (natnump emacs-jupyter-notebook-history-limit)
                   (min 1000 emacs-jupyter-notebook-history-limit) 200))
        (bytes (if (natnump emacs-jupyter-notebook-history-code-bytes)
                   (min (* 8 1024 1024) emacs-jupyter-notebook-history-code-bytes)
                 (* 4 1024 1024))))
    (while (and emacs-jupyter-notebook-history--entries
                (or (> (length emacs-jupyter-notebook-history--entries) count)
                    (> emacs-jupyter-notebook-history--bytes bytes)))
      (let ((old (pop emacs-jupyter-notebook-history--entries)))
        (cl-decf emacs-jupyter-notebook-history--bytes
                 (string-bytes (plist-get old :code)))
        (setq emacs-jupyter-notebook-history--evicted t)))))

(defun emacs-jupyter-notebook-history-record-created (record)
  "Remember exact reserved RECORD without claiming it has executed."
  (unless (emacs-jupyter-notebook-history--record (plist-get record :id))
    (let* ((code (substring-no-properties (plist-get record :code)))
           (entry (list :id (plist-get record :id) :code code
                        :cell-key (copy-tree (plist-get record :cell-key))
                        :panel-entry (copy-sequence (plist-get record :panel-entry))
                        :origin (or (plist-get record :origin)
                                    (and (plist-get record :inspection) 'inspection)
                                    (and (plist-get record :cell-key) 'cell) 'selection)
                        :queued-at (or (plist-get record :started-at) (float-time))
                        :submitted-at nil :finished-at nil :execution-count nil
                        :session-id nil :kernel-identity nil :status 'queued)))
      (setq emacs-jupyter-notebook-history--entries
            (append emacs-jupyter-notebook-history--entries (list entry)))
      (cl-incf emacs-jupyter-notebook-history--bytes (string-bytes code))
      (emacs-jupyter-notebook-history--trim))))

(defun emacs-jupyter-notebook-history-record-dispatched (record)
  "Record actual backend admission of RECORD in the source's trail."
  (when-let ((entry (emacs-jupyter-notebook-history--record (plist-get record :id))))
    (unless (plist-get entry :submitted-at)
      (setf (plist-get entry :submitted-at) (float-time)
            (plist-get entry :session-id)
            (plist-get emacs-jupyter-notebook--session-entry :session-id)
            (plist-get entry :kernel-identity)
            (list :session-id (plist-get emacs-jupyter-notebook--session-entry :session-id)
                  :remote-pid (plist-get emacs-jupyter-notebook--session-entry :remote-pid)
                  :docker-container-id
                  (plist-get emacs-jupyter-notebook--session-entry :docker-container-id)
                  :epoch emacs-jupyter-notebook-history--kernel-epoch)))
    (unless (plist-get entry :finished-at)
      (setf (plist-get entry :status) 'running))))

(defun emacs-jupyter-notebook-history-record-finished (record status &optional count)
  "Record terminal STATUS and kernel COUNT for RECORD, including unsent work."
  (when-let ((entry (emacs-jupyter-notebook-history--record (plist-get record :id))))
    (unless (plist-get entry :finished-at)
      (setf (plist-get entry :finished-at) (float-time)
            (plist-get entry :status) status
            (plist-get entry :execution-count) count))))

(defun emacs-jupyter-notebook-history--same-handle-p (left right)
  "Whether LEFT and RIGHT identify exactly the same output entry."
  (and left right
       (eq (plist-get left :panel) (plist-get right :panel))
       (equal (plist-get left :generation) (plist-get right :generation))
       (equal (plist-get left :id) (plist-get right :id))))

(defun emacs-jupyter-notebook-history--object (&rest pairs)
  "Build a JSON object from alternating string keys and values in PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object)) object))

(defun emacs-jupyter-notebook-history--json-entry (entry &optional omit-code)
  "Copy ENTRY into JSON values, explicitly marking OMIT-CODE."
  (let ((code (plist-get entry :code)))
    (emacs-jupyter-notebook-history--object
     "id" (plist-get entry :id)
     "code" (if omit-code :null (copy-sequence code))
     "code_sha256" (secure-hash 'sha256 (encode-coding-string code 'utf-8 t))
     "code_omitted" (if omit-code t :false)
     "cell_id" (or (cdr (plist-get entry :cell-key)) :null)
     "origin" (symbol-name (plist-get entry :origin))
     "queued_at" (plist-get entry :queued-at)
     "submitted_at" (or (plist-get entry :submitted-at) :null)
     "finished_at" (or (plist-get entry :finished-at) :null)
     "status" (symbol-name (plist-get entry :status))
     "session_id" (or (plist-get entry :session-id) :null)
     "kernel_identity"
     (if-let ((identity (plist-get entry :kernel-identity)))
         (emacs-jupyter-notebook-history--object
          "session_id" (or (plist-get identity :session-id) :null)
          "remote_pid" (or (plist-get identity :remote-pid) :null)
          "docker_container_id" (or (plist-get identity :docker-container-id) :null)
          "epoch" (plist-get identity :epoch))
       :null)
     "execution_count" (or (plist-get entry :execution-count) :null))))

(defun emacs-jupyter-notebook-history--json-bytes (object)
  "Return encoded UTF-8 byte size of JSON OBJECT."
  (string-bytes (encode-coding-string
                 (json-serialize object :null-object :null :false-object :false)
                 'utf-8 t)))

(defun emacs-jupyter-notebook-history-provenance (&optional panel-handle)
  "Return independent JSON-ready context through PANEL-HANDLE's execution.
Call in the owning source.  The encoded object never exceeds 24 KiB.  Exact
target code takes priority over earlier entries.  A code snippet that cannot
fit is replaced by its hash and an explicit omission flag; it is never
silently shortened.  A missing target never borrows another execution's code.
Use JSON null/false objects `:null' and `:false' when serializing."
  (let* ((entries emacs-jupyter-notebook-history--entries)
         (target (if panel-handle
                     (cl-find-if
                      (lambda (entry)
                        (emacs-jupyter-notebook-history--same-handle-p
                         panel-handle (plist-get entry :panel-entry))) entries)
                   (car (last entries))))
         (source (or buffer-file-name (buffer-name)))
         (object (emacs-jupyter-notebook-history--object
                  "version" 1 "source" (substring source 0 (min 4096 (length source)))
                  "scope" "Recorded local executions; kernel state may also have changed elsewhere"
                  "truncated" (if emacs-jupyter-notebook-history--evicted t :false)
                  "target_id" (or (plist-get target :id) :null)
                  "target_missing" (if target :false t) "entries" []))
         retained)
    (if (not target)
        (puthash "truncated" t object)
      (let ((preceding (reverse (cl-subseq entries 0 (1+ (cl-position target entries))))))
        (while preceding
          (let* ((entry (pop preceding))
                 (copy (emacs-jupyter-notebook-history--json-entry entry)))
            (puthash "entries" (vconcat (cons copy retained)) object)
            (when (> (emacs-jupyter-notebook-history--json-bytes object)
                     emacs-jupyter-notebook-history--provenance-bytes)
              (setq copy (emacs-jupyter-notebook-history--json-entry entry t))
              (puthash "truncated" t object)
              (puthash "entries" (vconcat (cons copy retained)) object))
            (if (<= (emacs-jupyter-notebook-history--json-bytes object)
                    emacs-jupyter-notebook-history--provenance-bytes)
                (push copy retained)
              (setq preceding nil)
              (puthash "truncated" t object)
              (puthash "entries" (vconcat retained) object))))))
    object))

(defun emacs-jupyter-notebook-history--summary (entry)
  "Return a short single-line summary of ENTRY's exact code."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\r\t]+" " " (string-trim (plist-get entry :code)))
   100 nil nil t))

(defvar emacs-jupyter-notebook-history-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'emacs-jupyter-notebook-history-show)
    (define-key map (kbd "g") #'emacs-jupyter-notebook-history-refresh)
    (define-key map (kbd "d") #'emacs-jupyter-notebook-history-diff)
    (define-key map (kbd "w") #'emacs-jupyter-notebook-history-copy-code)
    (define-key map (kbd "s") #'emacs-jupyter-notebook-history-recall)
    map))

(defun emacs-jupyter-notebook-history--evil-setup ()
  "Keep trail actions reachable under Doom and explicit Evil states."
  (evil-set-initial-state 'emacs-jupyter-notebook-history-mode 'emacs)
  (evil-define-key* '(normal motion visual) emacs-jupyter-notebook-history-mode-map
    (kbd "j") #'next-line (kbd "k") #'previous-line
    (kbd "RET") #'emacs-jupyter-notebook-history-show
    (kbd "g") #'emacs-jupyter-notebook-history-refresh
    (kbd "d") #'emacs-jupyter-notebook-history-diff
    (kbd "w") #'emacs-jupyter-notebook-history-copy-code
    (kbd "s") #'emacs-jupyter-notebook-history-recall
    (kbd "q") #'quit-window))

(with-eval-after-load 'evil (emacs-jupyter-notebook-history--evil-setup))

(define-derived-mode emacs-jupyter-notebook-history-mode tabulated-list-mode "EJN Trail"
  "Review recent executions; RET shows code, d changes, w copies, s recalls."
  (setq tabulated-list-format [("Run" 6 t) ("Time" 8 t) ("Kind" 10 t)
                               ("Outcome" 19 t) ("Code" 0 nil)]
        tabulated-list-padding 2)
  (setq-local header-line-format "Execution trail   RET code   d changes   w copy   s to scratch   g refresh")
  (tabulated-list-init-header))

(defun emacs-jupyter-notebook-history-refresh ()
  "Refresh the trail list from its source without contacting the kernel."
  (interactive)
  (let* ((owner (emacs-jupyter-notebook-history--source))
         (entries (buffer-local-value 'emacs-jupyter-notebook-history--entries owner)))
    (setq tabulated-list-entries
          (mapcar
           (lambda (entry)
             (let ((status (symbol-name (plist-get entry :status))))
               (list (plist-get entry :id)
                     (vector (number-to-string (plist-get entry :id))
                             (format-time-string "%H:%M:%S" (plist-get entry :queued-at))
                             (symbol-name (plist-get entry :origin))
                             (if (or (plist-get entry :submitted-at) (eq (plist-get entry :status) 'queued))
                                 status (concat status " (unsent)"))
                             (emacs-jupyter-notebook-history--summary entry)))))
           (reverse entries)))
    (tabulated-list-print t)))

;;;###autoload
(defun emacs-jupyter-notebook-history ()
  "Open the source's recent execution trail without changing source text."
  (interactive)
  (let* ((owner (emacs-jupyter-notebook-history--source))
         (view (buffer-local-value 'emacs-jupyter-notebook-history--view owner)))
    (unless (buffer-live-p view)
      (setq view (generate-new-buffer (format "*EJN trail: %s*" (buffer-name owner))))
      (with-current-buffer owner
        (setq emacs-jupyter-notebook-history--view view)
        (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-history--cleanup nil t))
      (with-current-buffer view
        (emacs-jupyter-notebook-history-mode)
        (setq emacs-jupyter-notebook-history--owner owner)))
    (with-current-buffer view (emacs-jupyter-notebook-history-refresh))
    (pop-to-buffer view)))

(defun emacs-jupyter-notebook-history--cleanup ()
  "Remove the source's disposable trail view on source-buffer kill."
  (dolist (view (list emacs-jupyter-notebook-history--view
                      emacs-jupyter-notebook-history--code-view
                      emacs-jupyter-notebook-history--diff-view))
    (when (buffer-live-p view) (kill-buffer view))))

(defun emacs-jupyter-notebook-history--selected ()
  "Return the selected trail record, or latest execution of the source cell."
  (let* ((owner (emacs-jupyter-notebook-history--source))
         (id (or emacs-jupyter-notebook-history--detail-id
                 (and (derived-mode-p 'emacs-jupyter-notebook-history-mode)
                      (tabulated-list-get-id))))
         (key (and (eq owner (current-buffer))
                   (emacs-jupyter-notebook--current-cell-key)))
         (entry (with-current-buffer owner
                  (if id (emacs-jupyter-notebook-history--record id)
                    (car (last (if key
                                   (cl-remove-if-not
                                    (lambda (item) (equal key (plist-get item :cell-key)))
                                    emacs-jupyter-notebook-history--entries)
                                 emacs-jupyter-notebook-history--entries)))))))
    (or entry (user-error "No retained execution here"))))

(defun emacs-jupyter-notebook-history--detail (owner entry text &optional diff)
  "Display TEXT about ENTRY in an owned read-only buffer, optionally DIFF."
  (let* ((variable (if diff 'emacs-jupyter-notebook-history--diff-view
                     'emacs-jupyter-notebook-history--code-view))
         (view (buffer-local-value variable owner)))
    (unless (buffer-live-p view)
      (setq view (generate-new-buffer (format "*EJN %s: %s*"
                                             (if diff "changes" "code") (buffer-name owner)))))
    (with-current-buffer owner
      (set variable view)
      (add-hook 'kill-buffer-hook #'emacs-jupyter-notebook-history--cleanup nil t))
    (with-current-buffer view
      (let ((inhibit-read-only t)) (erase-buffer) (insert text))
      (if diff (diff-mode) (special-mode))
      (setq-local emacs-jupyter-notebook-history--owner owner
                  emacs-jupyter-notebook-history--detail-id (plist-get entry :id))
      (local-set-key (kbd "w") #'emacs-jupyter-notebook-history-copy-code)
      (local-set-key (kbd "s") #'emacs-jupyter-notebook-history-recall)
      (goto-char (point-min))
      (setq buffer-read-only t))
    (pop-to-buffer view)))

(defun emacs-jupyter-notebook-history-show ()
  "Show the selected exact code and its recorded outcome."
  (interactive)
  (let ((entry (emacs-jupyter-notebook-history--selected)))
    (emacs-jupyter-notebook-history--detail
     (emacs-jupyter-notebook-history--source) entry
     (format "Run #%s | %s | %s\nSession: %s\nKernel: %S\nSubmitted: %s\n\n%s"
             (plist-get entry :id) (plist-get entry :origin) (plist-get entry :status)
             (or (plist-get entry :session-id) "not recorded")
             (plist-get entry :kernel-identity)
             (if-let ((time (plist-get entry :submitted-at)))
                 (format-time-string "%Y-%m-%d %H:%M:%S" time) "not submitted")
             (plist-get entry :code)))))

(defun emacs-jupyter-notebook-history-copy-code ()
  "Copy a retained execution's exact code without modifying source text."
  (interactive)
  (kill-new (plist-get (emacs-jupyter-notebook-history--selected) :code))
  (message "Execution code copied"))

(defun emacs-jupyter-notebook-history-recall ()
  "Recall selected code into disposable scratch input for editing."
  (interactive)
  (require 'emacs-jupyter-notebook-scratch)
  (let ((code (plist-get (emacs-jupyter-notebook-history--selected) :code))
        (owner (emacs-jupyter-notebook-history--source)))
    (with-current-buffer owner (emacs-jupyter-notebook-scratch code))))

(defun emacs-jupyter-notebook-history--line-diff (old new)
  "Return a bounded contiguous unified change from OLD to NEW.
Keep common leading/trailing lines as context, without external processes."
  (if (equal old new) "Cell code is unchanged.\n"
    (let* ((left (vconcat (split-string old "\n")))
           (right (vconcat (split-string new "\n")))
           (start 0) (left-end (length left)) (right-end (length right)))
      (while (and (< start left-end) (< start right-end)
                  (equal (aref left start) (aref right start))) (cl-incf start))
      (while (and (> left-end start) (> right-end start)
                  (equal (aref left (1- left-end)) (aref right (1- right-end))))
        (cl-decf left-end) (cl-decf right-end))
      (let ((context-start (max 0 (- start 3)))
            (tail (min 3 (- (length left) left-end))) lines)
        (push (format "--- previous execution\n+++ selected execution\n@@ -%d,%d +%d,%d @@\n"
                      (1+ context-start) (+ (- left-end context-start) tail)
                      (1+ context-start) (+ (- right-end context-start) tail)) lines)
        (cl-loop for i from context-start below start do
                 (push (concat " " (aref left i) "\n") lines))
        (cl-loop for i from start below left-end do
                 (push (concat "-" (aref left i) "\n") lines))
        (cl-loop for i from start below right-end do
                 (push (concat "+" (aref right i) "\n") lines))
        (cl-loop for i from left-end below (+ left-end tail) do
                 (push (concat " " (aref left i) "\n") lines))
        (apply #'concat (nreverse lines))))))

;;;###autoload
(defun emacs-jupyter-notebook-history-diff ()
  "Show cell-code changes and executions since its previous submitted run.
The baseline must be the same stable cell and recorded kernel identity."
  (interactive)
  (let* ((owner (emacs-jupyter-notebook-history--source))
         (entry (emacs-jupyter-notebook-history--selected))
         (all (buffer-local-value 'emacs-jupyter-notebook-history--entries owner))
         (preceding (cl-subseq all 0 (cl-position entry all)))
         (previous
          (and (plist-get entry :cell-key) (plist-get entry :submitted-at)
               (cl-find-if
                (lambda (item)
                  (and (plist-get item :submitted-at)
                       (equal (plist-get item :cell-key) (plist-get entry :cell-key))
                       (equal (plist-get item :kernel-identity)
                              (plist-get entry :kernel-identity))))
                (reverse preceding)))))
    (unless previous (user-error "No previous submitted execution of this cell on the same recorded kernel"))
    (emacs-jupyter-notebook-history--detail
     owner entry
     (concat
      (format "Changes from run #%s to #%s\n\n"
              (plist-get previous :id) (plist-get entry :id))
      (emacs-jupyter-notebook-history--line-diff
       (plist-get previous :code) (plist-get entry :code))
      "\nIntervening executions (recorded order):\n"
      (let ((between (cdr (memq previous preceding))))
        (if (not between) "None.\n"
          (mapconcat
           (lambda (item)
             (format "\nRun #%s | %s%s\n%s\n"
                     (plist-get item :id) (plist-get item :status)
                     (if (plist-get item :submitted-at) "" " (not submitted)")
                     (plist-get item :code))) between "")))) t)))

(provide 'emacs-jupyter-notebook-history)
;;; emacs-jupyter-notebook-history.el ends here
