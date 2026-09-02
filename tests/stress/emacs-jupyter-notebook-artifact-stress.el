;;; emacs-jupyter-notebook-artifact-stress.el --- AG3 artifact worker gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This gate is deliberately loaded after `emacs-jupyter-notebook-stress.el'.
;; It reuses that file's real local kernel/TH3 relay attach macro.  In
;; particular, no test helper is substituted for the `ejn-helper' process.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-artifacts)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook-helper-protocol)
(require 'emacs-jupyter-notebook-stress)

(defconst ejn-ag3-artifact--exact-bytes 67108864)
(defconst ejn-ag3-artifact--exact-sha256
  "1093ffd8dc4917554eb84c889c738284cdfa9826376146c5dbb0fdabf3241ea1")
;; This is a recognisable prefix of base64(sha256 of the bytes `ag3').  The generated
;; payload repeats that digest, so seeing it on helper stdout would prove the
;; helper emitted Jupyter's original base64 instead of a small descriptor.
(defconst ejn-ag3-artifact--base64-sample "n2CqNUkzxdNFPenK7xP4MmOFsBrGJIRw")
(defconst ejn-ag3-artifact--terminal-statuses '(ok error cancelled outcome-unknown))

(defun ejn-ag3-artifact--pickle-code (bytes tag)
  "Return bounded Python source that displays exactly BYTES deterministic bytes.

TAG is only a small panel-identification comment.  The raw value never enters
the visited source buffer; `emacs-jupyter-notebook--evaluate-code' presents it
through the production execution queue."
  (format (concat "# %s\n"
                  "import base64, hashlib\n"
                  "_ag3_size = %d\n"
                  "_ag3_block = hashlib.sha256(b'ag3').digest()\n"
                  "_ag3_raw = (_ag3_block * ((_ag3_size + len(_ag3_block) - 1) // len(_ag3_block)))[:_ag3_size]\n"
                  "from IPython.display import display\n"
                  "display({'application/x-ejn-mpl-pickle': base64.b64encode(_ag3_raw).decode('ascii')}, raw=True)\n"
                  "del _ag3_raw\n")
          tag bytes))

(defun ejn-ag3-artifact--entry (source tag)
  "Return SOURCE's panel entry carrying TAG, or nil."
  (ejn-ag2--entry-with-code source tag))

(defun ejn-ag3-artifact--entry-terminal-p (source tag)
  "Return non-nil after TAG's panel entry has terminal status."
  (when-let ((entry (ejn-ag3-artifact--entry source tag)))
    (memq (plist-get entry :status) ejn-ag3-artifact--terminal-statuses)))

(defun ejn-ag3-artifact--state (source)
  "Return SOURCE's live helper backend state, or signal a fixture error."
  (with-current-buffer source
    (let* ((client emacs-jupyter-notebook--client)
           (state (and (emacs-jupyter-notebook-backend-session-p client)
                       (emacs-jupyter-notebook-backend-session-data client))))
      (unless (emacs-jupyter-notebook-helper-backend-state-p state)
        (error "AG3 artifact gate has no attached helper backend state"))
      state)))

(defun ejn-ag3-artifact--worker-active-p (root)
  "Return non-nil while the real helper worker has a partial below ROOT."
  (and (stringp root)
       (file-directory-p root)
       (directory-files root nil "\\`\\.ejn-partial-" t)))

(defun ejn-ag3-artifact--assert-descriptor-only (entry bytes sha256)
  "Assert ENTRY retains only a confined pickle descriptor for BYTES/SHA256."
  (let* ((pickle (plist-get entry :mpl-pickle))
         (path (plist-get pickle :file)))
    (should (listp pickle))
    (should (= (plist-get pickle :size) bytes))
    (should (equal (plist-get pickle :sha256) sha256))
    (should (stringp path))
    (should (file-regular-p path))
    (should (= (logand (file-modes path) #o777) #o600))
    (should (= (file-attribute-size (file-attributes path 'integer)) bytes))
    ;; The helper's descriptor is itself gated by its worker's incremental
    ;; SHA-256 calculation; do not re-read 64 MiB into Emacs merely to test it.
    ;; Published panel metadata is file identity/capability material only.
    (should-not (plist-member pickle :data))
    (should-not (plist-member pickle :base64))
    (should-not
     (string-match-p (regexp-quote ejn-ag3-artifact--base64-sample)
                     (format "%S" pickle)))
    pickle))

(defun ejn-ag3-artifact--published-leaves (root)
  "Return sorted published helper artifacts directly below ROOT."
  (sort (directory-files root nil "\\`ejn-artifact-[0-9a-f]\\{32\\}\\'" t)
        #'string<))

(defun ejn-ag3-artifact--stdout-observer (bytes state)
  "Inspect actual helper stdout BYTES with bounded stateful framing checks.

STATE is a plist carrying only a short base64 overlap and frame accounting.
The production filter continues to own parsing; this observer merely verifies
the same byte stream before it reaches that decoder."
  (let* ((wire (if (multibyte-string-p bytes)
                   (encode-coding-string bytes 'binary t)
                 bytes))
         (tail (or (plist-get state :tail) ""))
         (sample ejn-ag3-artifact--base64-sample)
         (joined (concat tail wire))
         (offset 0)
         (prefix (or (plist-get state :prefix) ""))
         (remaining (plist-get state :remaining)))
    (when (string-match-p (regexp-quote sample) joined)
      (plist-put state :base64-seen t))
    (plist-put state :tail
               (substring joined (max 0 (- (length joined) (1- (length sample))))))
    ;; Parse only four-byte prefixes and counters.  No payload is accumulated.
    (while (< offset (length wire))
      (if remaining
          (let ((amount (min remaining (- (length wire) offset))))
            (setq offset (+ offset amount)
                  remaining (- remaining amount))
            (when (= remaining 0)
              (plist-put state :frames (1+ (or (plist-get state :frames) 0)))
              (setq remaining nil)))
        (let* ((need (- 4 (length prefix)))
               (amount (min need (- (length wire) offset))))
          (setq prefix (concat prefix (substring wire offset (+ offset amount)))
                offset (+ offset amount))
          (when (= (length prefix) 4)
            (setq remaining (+ (ash (aref prefix 0) 24)
                               (ash (aref prefix 1) 16)
                               (ash (aref prefix 2) 8)
                               (aref prefix 3)))
            (plist-put state :max-frame
                       (max (or (plist-get state :max-frame) 0) (+ 4 remaining)))
            (when (> (+ 4 remaining) ejn-helper-protocol-max-to-emacs-frame)
              (plist-put state :oversized-frame t))
            (setq prefix "")))))
    (plist-put state :prefix prefix)
    (plist-put state :remaining remaining)))

(ert-deftest ejn-ag3-artifact-worker-spools-cap-and-rejects-one-byte-over ()
  "Exercise Gate 5 through a real kernel, relay, helper, worker, and panel."
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source baseline modified)
    (let* ((exact-tag "ag3-exact-64m")
           (over-tag "ag3-over-64m")
           (exact-code (ejn-ag3-artifact--pickle-code
                        ejn-ag3-artifact--exact-bytes exact-tag))
           (over-code (ejn-ag3-artifact--pickle-code
                       (1+ ejn-ag3-artifact--exact-bytes) over-tag))
           (backend-state (ejn-ag3-artifact--state source))
           (helper (emacs-jupyter-notebook-helper-backend-state-helper
                    backend-state))
           (worker-root (emacs-jupyter-notebook-helper-backend-state-artifact-dir
                         backend-state))
           (helper-process (emacs-jupyter-notebook-helper-session-process helper))
           (stdout-state (list :tail "" :prefix "" :remaining nil :frames 0
                               :max-frame 0 :base64-seen nil :oversized-frame nil))
           (decoded-frames nil)
           (ticks 0)
           (pings 0)
           (execution-window-pings 0)
           (worker-pings 0)
           (worker-observed nil)
           (ping-errors nil)
           (max-ping-ms 0.0)
           (ping-open 0)
           (artifact-active nil)
           (peak-queue 0)
           (peak-raw 0)
           (test-started (float-time))
           (canary (run-at-time 0 0.05 (lambda () (cl-incf ticks))))
           ping-timer filter-advice decode-advice sampler exact-root exact-leaves)
      (should (emacs-jupyter-notebook-helper-session-p helper))
      (should (file-directory-p worker-root))
      (setq sampler
            (lambda (&rest _)
              (setq peak-queue
                    (max peak-queue
                         (+ (emacs-jupyter-notebook-helper-session-event-queue-bytes helper)
                            (emacs-jupyter-notebook-helper-session-priority-queue-bytes helper)))
                    peak-raw
                    (max peak-raw
                         (+ (emacs-jupyter-notebook-helper-session-raw-bytes helper)
                            (ejn-helper-protocol-decoder-buffered-bytes
                             (emacs-jupyter-notebook-helper-session-decoder helper)))))))
      (setq filter-advice
            (lambda (process bytes)
              (when (eq process helper-process)
                (ejn-ag3-artifact--stdout-observer bytes stdout-state))))
      (setq decode-advice
            (lambda (session _object wire-bytes)
              (when (eq session helper)
                (push wire-bytes decoded-frames))))
      (advice-add #'emacs-jupyter-notebook-helper--filter :before filter-advice)
      (advice-add #'emacs-jupyter-notebook-helper--enqueue-object :before decode-advice)
      ;; Sample immediately after mutation as well as from the canary; a
      ;; periodic observer alone can miss a short-lived queue peak.
      (advice-add #'emacs-jupyter-notebook-helper--raw-append :after sampler)
      (advice-add #'emacs-jupyter-notebook-helper--queue-push :after sampler)
      (unwind-protect
          (progn
            (setq ping-timer
                  (run-at-time
                   0.02 0.02
                   (lambda ()
                     ;; The timer keeps pings in flight while the worker
                     ;; writes/fsyncs the 64 MiB artifact.  A small bound
                     ;; prevents the test itself from creating unbounded work.
                     (when (and (< ping-open 3)
                                (not (emacs-jupyter-notebook-helper-session-disposed helper)))
                       (cl-incf ping-open)
                       (let ((sent (float-time))
                             (sent-during-worker
                              (ejn-ag3-artifact--worker-active-p worker-root)))
                         (when sent-during-worker
                           (setq worker-observed t))
                         (condition-case err
                             (emacs-jupyter-notebook-helper-request
                              helper "ping" (make-hash-table :test 'equal)
                              (lambda (_session response error-data)
                                (cl-decf ping-open)
                                (if (or error-data (null response))
                                    (push (or error-data "empty ping response") ping-errors)
                                  (cl-incf pings)
                                  (when artifact-active
                                    (cl-incf execution-window-pings))
                                  (when sent-during-worker
                                    (cl-incf worker-pings))
                                  (setq max-ping-ms
                                        (max max-ping-ms
                                             (* 1000 (- (float-time) sent))))))
                              :timeout 2 :internal t)
                           (error
                            (cl-decf ping-open)
                            (push (error-message-string err) ping-errors))))))))
            ;; This is the production execution FIFO and panel reducer, but
            ;; it deliberately does not alter the visited source buffer.
            (setq artifact-active t)
            (emacs-jupyter-notebook--evaluate-code exact-code nil)
            (ejn-ag2--await-phase
             "exact 64 MiB artifact"
             (lambda () (ejn-ag3-artifact--entry-terminal-p source exact-tag)) 75)
            (setq artifact-active nil)
            (let ((exact-entry (ejn-ag3-artifact--entry source exact-tag)))
              (should (eq (plist-get exact-entry :status) 'ok))
              (let ((pickle
                     (ejn-ag3-artifact--assert-descriptor-only
                      exact-entry ejn-ag3-artifact--exact-bytes
                      ejn-ag3-artifact--exact-sha256)))
                (setq exact-root (plist-get pickle :root)
                      exact-leaves (ejn-ag3-artifact--published-leaves
                                    (plist-get pickle :root)))
                (should (= (length exact-leaves) 1))))
            ;; A one-byte-over payload has the same base64 length at this
            ;; modulus boundary, so only the real worker/store size check can
            ;; reject it.  It must leave a marker, never a panel publication.
            (emacs-jupyter-notebook--evaluate-code over-code nil)
            (ejn-ag2--await-phase
             "one-byte-over artifact"
             (lambda () (ejn-ag3-artifact--entry-terminal-p source over-tag)) 75)
            (let ((over-entry (ejn-ag3-artifact--entry source over-tag)))
              (should (eq (plist-get over-entry :status) 'ok))
              (should-not (plist-get over-entry :mpl-pickle))
              (should-not (ejn-panel-entry-images over-entry))
              (should (string-match-p "output omitted: invalid artifact"
                                      (ejn-panel-entry-text over-entry))))
            ;; The rejected worker input cannot leave a partial or a second
            ;; published leaf beside the exact-limit artifact.
            (should (equal (ejn-ag3-artifact--published-leaves exact-root)
                           exact-leaves))
            (should-not (directory-files exact-root nil "\\`\\.ejn-partial-" t))
            ;; Require at least half of the nominal 50 ms canary cadence over
            ;; the complete test wall time.  A long UI freeze followed by a few
            ;; cleanup ticks must not satisfy the responsiveness gate.
            (let ((wall (- (float-time) test-started)))
              (should (>= ticks (floor (/ wall 0.1)))))
            (should (>= pings 2))
            (should (>= execution-window-pings 2))
            (should worker-observed)
            (should (>= worker-pings 1))
            (should-not ping-errors)
            (should (< max-ping-ms 1000))
            (should (<= peak-queue emacs-jupyter-notebook-helper--max-event-queue))
            (should (<= peak-raw ejn-helper-protocol-max-raw-accumulator))
            (should-not (plist-get stdout-state :base64-seen))
            (should-not (plist-get stdout-state :oversized-frame))
            (should (>= (plist-get stdout-state :frames) 4))
            (should (>= (length decoded-frames) 4))
            (should (cl-every (lambda (wire-bytes)
                                (and (integerp wire-bytes)
                                     (<= wire-bytes ejn-helper-protocol-max-to-emacs-frame)))
                              decoded-frames))
            (should-not (plist-get stdout-state :remaining))
            (should (string-empty-p (plist-get stdout-state :prefix)))
            (ejn-ag2--assert-source-pristine source baseline modified)
            (ejn-ag3--metric
             "artifact-worker"
             (cons "canary_ticks" ticks)
             (cons "pings" pings)
             (cons "execution_window_pings" execution-window-pings)
             (cons "worker_pings" worker-pings)
             (cons "max_ping_ms" max-ping-ms)
             (cons "peak_queue" peak-queue)
             (cons "peak_raw" peak-raw)
             (cons "artifact_bytes" ejn-ag3-artifact--exact-bytes)
             (cons "artifact_sha256" ejn-ag3-artifact--exact-sha256)
             (cons "stdout_frames" (plist-get stdout-state :frames))
             (cons "max_stdout_frame" (plist-get stdout-state :max-frame))
             (cons "decoded_frames" (length decoded-frames))
             (cons "over_limit_rejected" t)))
        (when (timerp ping-timer) (cancel-timer ping-timer))
        (when (timerp canary) (cancel-timer canary))
        (advice-remove #'emacs-jupyter-notebook-helper--filter filter-advice)
        (advice-remove #'emacs-jupyter-notebook-helper--enqueue-object decode-advice)
        (advice-remove #'emacs-jupyter-notebook-helper--raw-append sampler)
        (advice-remove #'emacs-jupyter-notebook-helper--queue-push sampler)))))

(provide 'emacs-jupyter-notebook-artifact-stress)

;;; emacs-jupyter-notebook-artifact-stress.el ends here
