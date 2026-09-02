;;; emacs-jupyter-notebook-stress.el --- AG3 bounded helper stress -*- lexical-binding: t; -*-

;; This file intentionally keeps the hostile-wire checks independent of the
;; Jupyter fixture.  The local-kernel portions use the same helper/core attach
;; path as AG2, with TH3's rewritten connection file supplied by relay_bridge.

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'emacs-jupyter-notebook)
(require 'emacs-jupyter-notebook-artifacts)
(require 'emacs-jupyter-notebook-helper-backend)
(require 'emacs-jupyter-notebook-helper)
(require 'emacs-jupyter-notebook-helper-protocol)

(defconst ejn-ag3--root
  (expand-file-name "../.." (file-name-directory (file-truename load-file-name))))
(defconst ejn-ag3--fake-helper
  (expand-file-name "tests/fixtures/ejn_fake_helper.py" ejn-ag3--root))
(defconst ejn-ag3--fixtures
  (expand-file-name "tests/stress/fixtures/ag3_stress_fixtures.py" ejn-ag3--root))
(defconst ejn-ag3--await-timeout 8.0)
(defvar ejn-ag3--metrics nil)
(defvar ejn-ag3--started-at nil)
(defvar ejn-ag3--helper-event-callback nil)

;; Reuse AG2's real core attach and source-pristine helpers, but never its
;; source macro: that macro deliberately asks its direct-kernel bridge to
;; restart for every ERT, which would defeat AG3's same-kernel relay test.
(load (expand-file-name "tests/emacs-jupyter-notebook-helper-e2e.el"
                        ejn-ag3--root) nil nil t)

(declare-function ejn-ag2--copy-connection "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--attach "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--send-cell-containing "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--await-phase "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--entry-terminal-p "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--assert-source-pristine "emacs-jupyter-notebook-helper-e2e")
(declare-function ejn-ag2--entry-with-code "emacs-jupyter-notebook-helper-e2e")

(defun ejn-ag3--env (name)
  (or (getenv name) (error "AG3 runner did not provide %s" name)))

(defun ejn-ag3--await (predicate &optional seconds)
  (let ((deadline (+ (float-time) (or seconds ejn-ag3--await-timeout))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(defun ejn-ag3--drain-for (seconds)
  "Process timers and subprocess output for exactly bounded SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.01))))

(defun ejn-ag3--metric (name &rest facts)
  "Record NAME/FACTS immediately, so a timeout preserves useful evidence."
  (let ((value (append (list (cons "name" name)
                             (cons "elapsed" (- (float-time) ejn-ag3--started-at))) facts)))
    (push value ejn-ag3--metrics)
    (with-temp-file (ejn-ag3--env "EJN_AG3_METRICS")
      (insert (json-encode (vconcat (reverse ejn-ag3--metrics)))))))

(defun ejn-ag3--json-file (file)
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-string (buffer-string) :object-type 'hash-table
                       :array-type 'list :null-object nil :false-object nil)))

(defun ejn-ag3--bridge-state ()
  (ejn-ag3--json-file (ejn-ag3--env "EJN_AG3_STATE")))

(defun ejn-ag3--bridge-request (operation)
  "Execute bounded test-only relay bridge OPERATION."
  (let* ((directory (file-name-as-directory (ejn-ag3--env "EJN_AG3_CONTROL_DIR")))
         (nonce (format "%x-%x" (random most-positive-fixnum) (truncate (float-time))))
         (request (expand-file-name (format "request-%s.json" nonce) directory))
         (response (expand-file-name (format "response-%s.json" nonce) directory))
         (temporary (concat request ".tmp")))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (json-encode `(("token" . ,(ejn-ag3--env "EJN_AG3_TOKEN"))
                                   ("op" . ,operation)))))
          (set-file-modes temporary #o600)
          (rename-file temporary request)
          (should (ejn-ag3--await (lambda () (file-regular-p response)) 8))
          (let ((answer (ejn-ag3--json-file response)))
            (should (eq (gethash "ok" answer) t))
            answer))
      (ignore-errors (delete-file temporary))
      (ignore-errors (delete-file request))
      (ignore-errors (delete-file response)))))

(defun ejn-ag3--same-ports-p (left right)
  "Return non-nil when two bridge JSON port objects have identical values."
  (and (hash-table-p left) (hash-table-p right)
       (equal (sort (let (pairs) (maphash (lambda (key value) (push (cons key value) pairs)) left) pairs)
                    (lambda (a b) (string< (car a) (car b))))
              (sort (let (pairs) (maphash (lambda (key value) (push (cons key value) pairs)) right) pairs)
                    (lambda (a b) (string< (car a) (car b)))))))

(defun ejn-ag3--kill-helpers ()
  (emacs-jupyter-notebook-helper--kill-emacs)
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\*ejn-helper-stderr-" (buffer-name buffer))
      (kill-buffer buffer))))

(cl-defmacro ejn-ag3--with-source ((source baseline modified) &body body)
  "Attach one real helper/core source session through the TH3 relay bridge."
  (declare (indent 1) (debug ((symbolp symbolp symbolp) body)))
  `(let* ((root (make-temp-file "ejn-ag3-source-" t))
          (source-file (expand-file-name "stress.py" root))
          (local-file (expand-file-name "connection.json" root))
          (registry (expand-file-name "registry.el" root))
          (,source nil)
          (emacs-jupyter-notebook-backend 'helper)
          (emacs-jupyter-notebook-helper-command
           (list (ejn-ag3--env "EJN_E2E_HELPER") "--protocol"))
          (emacs-jupyter-notebook-registry-file registry)
          (emacs-jupyter-notebook-kernel-idle-timeout 0)
          (emacs-jupyter-notebook-heartbeat-interval 1)
          (emacs-jupyter-notebook-heartbeat-timeout 0.2)
          (emacs-jupyter-notebook-heartbeat-misses-allowed 1)
          (emacs-jupyter-notebook-auto-reconnect nil))
     (unwind-protect
         (progn
           (with-temp-file source-file
             (insert "# %%\n"
                     "ag3_relay_value = 733\n"
                     "# %%\n"
                     "assert ag3_relay_value == 733\n"
                     "# %%\n"
                     "import time; time.sleep(8)\n"
                     "# %%\n"
                     "ag3_boundary_counter = globals().get('ag3_boundary_counter', 0) + 1\n"))
           (setq ,source (find-file-noselect source-file))
           (with-current-buffer ,source
             (python-mode)
             (emacs-jupyter-notebook-mode 1)
             (let ((state (ejn-ag3--bridge-state)))
               (ejn-ag2--copy-connection state local-file)
               (ejn-ag2--attach local-file state))
             (let ((,baseline (buffer-string)) (,modified (buffer-modified-p)))
               ,@body)))
       (when (buffer-live-p ,source)
         (with-current-buffer ,source
           (when emacs-jupyter-notebook-mode (emacs-jupyter-notebook-mode -1))
           (when-let ((panel (emacs-jupyter-notebook-panel-buffer ,source)))
             (when (buffer-live-p panel) (kill-buffer panel))))
         (kill-buffer ,source))
       (ejn-ag3--kill-helpers)
       (ignore-errors (delete-directory root t)))))

(cl-defmacro ejn-ag3--with-helper ((session scenario &rest options) &body body)
  (declare (indent 1) (debug ((symbolp form &rest form) body)))
  `(let ((ready nil) (failure nil)
         (owner (generate-new-buffer " *ejn-ag3-owner*"))
         (emacs-jupyter-notebook-helper-hello-timeout 0.4)
         (emacs-jupyter-notebook-helper-partial-frame-timeout 0.15)
         (emacs-jupyter-notebook-helper--ping-interval 300)
         (emacs-jupyter-notebook-helper-command
          (if (equal ,scenario "ag3-flood")
              (append (list (or (executable-find "python3") "python3")
                            ejn-ag3--fixtures "helper" "--seconds" "5.1")
                      (list ,@options))
            (append (list (or (executable-find "python3") "python3")
                          ejn-ag3--fake-helper ,scenario) (list ,@options)))))
     (unwind-protect
         (let ((,session
                (emacs-jupyter-notebook-helper-start
                 :buffer owner
                 :ready-callback (lambda (&rest _) (setq ready t))
                 :failure-callback (lambda (_ reason) (setq failure reason))
                 :event-callback (or ejn-ag3--helper-event-callback
                                     (lambda (&rest _) nil)))))
           (ignore ready failure)
           ,@body)
       (when (buffer-live-p owner) (kill-buffer owner))
       (ejn-ag3--kill-helpers))))

(ert-deftest ejn-ag3-th1-lifecycle-faults-are-bounded ()
  "Every hostile TH1 startup/stream fault returns control inside one deadline."
  (setq ejn-ag3--started-at (float-time))
  (dolist (scenario '("silent" "garbage" "oversize" "mid-frame-stop"))
    (let ((started (float-time)))
      (ejn-ag3--with-helper (session scenario)
        (should (ejn-ag3--await
                 (lambda () (or failure
                                (emacs-jupyter-notebook-helper-session-disposed session)))
                 2.0))
        (should failure))
      (ejn-ag3--metric (concat "th1-" scenario)
                       (cons "wall" (- (float-time) started))))))

(ert-deftest ejn-ag3-credited-flood-keeps-emacs-responsive-and-bounded ()
  "Five-second credited flood has a separate 50 ms responsiveness canary."
  (let ((stats (make-temp-file "ejn-ag3-flood-"))
        (events 0))
    (unwind-protect
        (progn
          (setq ejn-ag3--started-at (float-time))
          (let ((ejn-ag3--helper-event-callback
                 (lambda (&rest _) (cl-incf events))))
            (ejn-ag3--with-helper (session "ag3-flood" "--stats" stats)
              (let ((ticks 0) (pings 0) (ping-errors nil) (max-ping-ms 0)
                  (peak-queue 0) (peak-raw 0)
                  ;; The fixture measures five seconds from first granted
                  ;; credit, which follows hello asynchronously.
                  (deadline (+ (float-time) 5.8)) canary sampler)
              (setq sampler
                    (lambda (&rest _)
                      (setq peak-queue
                            (max peak-queue
                                 (+ (emacs-jupyter-notebook-helper-session-event-queue-bytes session)
                                    (emacs-jupyter-notebook-helper-session-priority-queue-bytes session)))
                            peak-raw
                            (max peak-raw
                                 (+ (emacs-jupyter-notebook-helper-session-raw-bytes session)
                                    (ejn-helper-protocol-decoder-buffered-bytes
                                     (emacs-jupyter-notebook-helper-session-decoder session)))))))
              ;; Sampling after the mutation paths catches a transient queue
              ;; peak that a periodic observer could miss.
              (advice-add #'emacs-jupyter-notebook-helper--raw-append :after sampler)
              (advice-add #'emacs-jupyter-notebook-helper--queue-push :after sampler)
              (setq canary (run-at-time 0 0.05 (lambda () (cl-incf ticks))))
              (unwind-protect
                  (progn
                    (should (ejn-ag3--await (lambda () ready) 2))
                    (cl-labels
                        ((send-ping
                          ()
                          (let ((sent (float-time)))
                            (emacs-jupyter-notebook-helper-request
                             session "ping" (make-hash-table :test 'equal)
                             (lambda (_ response error)
                               (if (or error (null response))
                                   (push (or error "empty ping response") ping-errors)
                                 (cl-incf pings)
                                 (setq max-ping-ms
                                       (max max-ping-ms (* 1000 (- (float-time) sent))))))
                             :timeout 1 :internal t))))
                      ;; Test steady-state priority, not startup pipe ordering:
                      ;; the initial credit can legally place a full pipe of
                      ;; already-written events ahead of a later response.
                      (should (ejn-ag3--await (lambda () (> events 100)) 2))
                      (send-ping)
                      (should (ejn-ag3--await
                               (lambda () (or (>= pings 1) ping-errors)) 1.2))
                      (should-not ping-errors)
                      (ejn-ag3--drain-for 1.0)
                      (send-ping)
                      (should (ejn-ag3--await
                               (lambda () (or (>= pings 2) ping-errors)) 1.2)))
                    (while (< (float-time) deadline) (accept-process-output nil 0.01))
                    (should (>= ticks 50))
                    (should (> events 100))
                    ;; At least two independently timed requests must cross
                    ;; while the five-second stream is active.
                    (should (>= pings 2))
                    (should-not ping-errors)
                    (should (< max-ping-ms 1000))
                    (should (<= peak-queue emacs-jupyter-notebook-helper--max-event-queue))
                    (should (<= peak-raw ejn-helper-protocol-max-raw-accumulator))
                    (should (ejn-ag3--await (lambda () (file-regular-p stats)) 2))
                    (let ((fixture (ejn-ag3--json-file stats)))
                      (should (> (gethash "frames" fixture) 100))
                      (should (>= (gethash "pings_handled" fixture) 2))
                      (should (>= (gethash "cumulative_credit" fixture)
                                  (gethash "wire_bytes" fixture))))
                    (ejn-ag3--metric "credited-flood"
                                     (cons "canary_ticks" ticks) (cons "events" events)
                                     (cons "pings" pings) (cons "max_ping_ms" max-ping-ms)
                                     (cons "peak_queue" peak-queue) (cons "peak_raw" peak-raw)))
                (cancel-timer canary)
                (advice-remove #'emacs-jupyter-notebook-helper--raw-append sampler)
                (advice-remove #'emacs-jupyter-notebook-helper--queue-push sampler))))))
      (ignore-errors (delete-file stats)))))

(ert-deftest ejn-ag3-th3-relay-outage-keeps-ports-kernel-and-source ()
  "A real helper/core session observes a five-relay outage and reconnects.

The attach continuation is the same real core helper path AG2 uses; only the
SSH tunnel acquisition normally preceding it is test-local.  No fixture ever
relaunches the kernel during this scenario."
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source baseline modified)
    (let* ((before (ejn-ag3--bridge-state))
           (pid (gethash "kernel_pid" before))
           (ports (gethash "relay_ports" before))
           (ticks 0)
           (canary (run-at-time 0 0.05 (lambda () (cl-incf ticks)))))
      (unwind-protect
          (progn
            (should (gethash "ready" before))
            (should (= (hash-table-count ports) 5))
            (ejn-ag2--send-cell-containing "ag3_relay_value =")
            (ejn-ag2--await-phase
             "relay state setup"
             (lambda () (ejn-ag2--entry-terminal-p source "ag3_relay_value =")) 10)
          (ejn-ag3--bridge-request "stop-relays")
            (should (ejn-ag3--await (lambda () (>= ticks 20)) 2))
            (should (ejn-ag3--await (lambda () (null emacs-jupyter-notebook--client)) 5))
            (ejn-ag3--bridge-request "restart-relays")
            (let ((after (ejn-ag3--bridge-state)))
              (should (gethash "ready" after))
              (should (= pid (gethash "kernel_pid" after)))
              (should (ejn-ag3--same-ports-p ports (gethash "relay_ports" after)))
              ;; This is the public attach continuation after transport loss;
              ;; it deliberately does not start a fresh kernel or replay work.
              (ejn-ag2--copy-connection after local-file)
              (ejn-ag2--attach local-file after)
              (ejn-ag2--send-cell-containing "assert ag3_relay_value")
              (ejn-ag2--await-phase
               "relay reconnect state"
               (lambda () (ejn-ag2--entry-terminal-p source "assert ag3_relay_value")) 10)
              (ejn-ag2--assert-source-pristine source baseline modified)
              (ejn-ag3--metric "th3-outage"
                               (cons "canary_ticks" ticks)
                               (cons "kernel_pid" pid)
                               (cons "relay_ports" ports))))
        (cancel-timer canary)))))

(ert-deftest ejn-ag3-helper-death-marks-accepted-work-unknown-without-replay ()
  "An accepted execution survives only as unknown work, never as a replay."
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source baseline modified)
    ;; Establish durable kernel state before destroying the local transport.
    (ejn-ag2--send-cell-containing "ag3_relay_value =")
    (ejn-ag2--await-phase
     "helper-death setup"
     (lambda () (ejn-ag2--entry-terminal-p source "ag3_relay_value =")) 10)
    (ejn-ag2--send-cell-containing "time.sleep(8)")
    (ejn-ag2--await-phase
     "helper-death admission"
     (lambda () emacs-jupyter-notebook--execution-active-id) 5)
    (let* ((client emacs-jupyter-notebook--client)
           (state (emacs-jupyter-notebook-backend-session-data client))
           (helper (emacs-jupyter-notebook-helper-backend-state-helper state))
           (process (emacs-jupyter-notebook-helper-session-process helper))
           (pid (gethash "kernel_pid" (ejn-ag3--bridge-state))))
      (should (process-live-p process))
      (delete-process process)
      (ejn-ag2--await-phase
       "helper-death retirement" (lambda () (null emacs-jupyter-notebook--client)) 5)
      (should (eq (plist-get (ejn-ag2--entry-with-code source "time.sleep(8)") :status)
                  'outcome-unknown))
      (should (= pid (gethash "kernel_pid" (ejn-ag3--bridge-state))))
      ;; Allow the killed request ample time to demonstrate that it is not
      ;; reissued before explicitly attaching a new local helper.
      (ejn-ag3--drain-for 0.3)
      (let ((state (ejn-ag3--bridge-state)))
        (ejn-ag2--copy-connection state local-file)
        (ejn-ag2--attach local-file state))
      (ejn-ag2--send-cell-containing "assert ag3_relay_value")
      (ejn-ag2--await-phase
       "same-kernel no-replay proof"
       (lambda () (ejn-ag2--entry-terminal-p source "assert ag3_relay_value")) 10)
      (ejn-ag2--assert-source-pristine source baseline modified)
      (ejn-ag3--metric "helper-death-active"
                       (cons "kernel_pid" pid)
                       (cons "outcome" "unknown")))))

(provide 'emacs-jupyter-notebook-stress)
;;; emacs-jupyter-notebook-stress.el ends here
