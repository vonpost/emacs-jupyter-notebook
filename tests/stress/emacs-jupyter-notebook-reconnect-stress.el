;;; emacs-jupyter-notebook-reconnect-stress.el --- AG3 public reconnect stress -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;;
;; TH3 owns the real local kernel and five TCP relay listeners.  This test
;; deliberately replaces only SSH acquisition: the remote PID probe, SCP
;; retrieval, registry picker probe, and tunnel child are represented by local
;; bounded processes.  The public interactive reconnect command still drives
;; EJN's picker, reconnect context, connection-file parser, tunnel readiness,
;; helper backend connect, and finalization state machine.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-stress)

(defun ejn-ag3-reconnect--relay-ports (state)
  "Return STATE's five relay ports as a validated EJN plist."
  (let ((ports (emacs-jupyter-notebook-connection-ports
                (emacs-jupyter-notebook-connection-read-file
                 (ejn-ag2--state-connection-file state)))))
    (should (emacs-jupyter-notebook-connection-valid-ports-p ports))
    ports))

(defun ejn-ag3-reconnect--start-successful-bounded-process
    (starter name argv limit sentinel connection-file)
  "Run the local test equivalent of one bounded reconnect SSH child.
STARTER is the real bounded process constructor.  A PID probe emits the
strict production liveness marker.  An SCP process first copies the current
TH3 connection file to its production-selected destination, then exits.
Nothing else is admitted: extending the public reconnect flow requires an
intentional update to this test seam."
  (cond
   ((string-match-p "emacs-jupyter-notebook-pid-probe-" name)
    (funcall starter name
             (list "sh" "-c"
                   "printf '__EJN_ALIVE_MATCH__\\n__EJN_DONE__\\n'")
             limit sentinel))
   ((string-match-p "emacs-jupyter-notebook-scp-" name)
    (let ((destination (car (last argv))))
      (should (and (stringp destination) (file-name-absolute-p destination)))
      (copy-file connection-file destination t)
      (set-file-modes destination #o600)
      (funcall starter name (list "sh" "-c" ":") limit sentinel)))
   (t
    (ert-fail (format "unexpected reconnect SSH child %s: %S" name argv)))))

(defun ejn-ag3-reconnect--start-picker-probe
    (name pid success)
  "Return a bounded local stand-in for the picker's SSH liveness child.
The success callback runs on the next timer turn, preserving the production
management-operation ownership ordering rather than completing reentrantly."
  (let ((process (make-pipe-process
                  :name (format "ejn-ag3-picker-%s" name) :buffer nil :noquery t)))
    (run-at-time
     0 nil
     (lambda ()
       (when (process-live-p process)
         (delete-process process))
       ;; The picker only needs its complete host response to list this
       ;; session as alive; the reconnect's later identity-aware probe is
       ;; separately exercised by its own bounded child above.
       (funcall success (format "%s\\n__EJN_DONE__\\n" pid))))
    process))

(ert-deftest ejn-ag3-th3-public-reconnect-preserves-kernel-and-source ()
  "The interactive public reconnect path recovers a real TH3 relay outage.

The five relay listeners are stopped until the production heartbeat retires
the helper client.  `emacs-jupyter-notebook-reconnect-remote-kernel' is then
called interactively with its normal registry picker.  Test seams model just
the unavailable SSH server; the reconnect context must traverse probe,
retrieve, tunnel, connect, and done while retaining the one remote kernel."
  (setq ejn-ag3--started-at (float-time))
  (ejn-ag3--with-source (source baseline modified)
    (let* ((before (ejn-ag3--bridge-state))
           (kernel-pid (gethash "kernel_pid" before))
           (kernel-pgid (gethash "kernel_pgid" before))
           (relay-ports (gethash "relay_ports" before))
           (connection-file (ejn-ag2--state-connection-file before))
           (real-bounded (symbol-function
                          'emacs-jupyter-notebook-ssh-start-bounded-process))
           (ticks 0)
           (canary (run-at-time 0 0.05 (lambda () (cl-incf ticks))))
           (ticks-at-outage nil)
           (phases nil)
           (picker-probes 0)
           (reconnect-probes 0)
           (retrievals 0)
           (tunnels 0)
           (phase-advice
            (lambda (context)
              (push (plist-get context :phase) phases))))
      (unwind-protect
          (progn
            (should (gethash "ready" before))
            (should (= (hash-table-count relay-ports) 5))
            (should (= kernel-pid (gethash "kernel_pid" before)))
            (should (= kernel-pgid (gethash "kernel_pgid" before)))
            ;; State from this real execution must remain available through
            ;; the entire transport outage and public reconnect.
            (ejn-ag2--send-cell-containing "ag3_relay_value =")
            (ejn-ag2--await-phase
             "public reconnect state setup"
             (lambda ()
               (ejn-ag2--entry-terminal-p source "ag3_relay_value =")) 10)
            (ejn-ag3--bridge-request "stop-relays")
            (setq ticks-at-outage ticks)
            ;; The real helper heartbeat has a one second tick and a 0.2 s
            ;; timeout in `ejn-ag3--with-source'.  This proves both that it
            ;; declares liveness failure and that Emacs's event loop kept its
            ;; 50 ms canary moving while every Jupyter channel was absent.
            (should (ejn-ag3--await
                     (lambda () (null emacs-jupyter-notebook--client)) 5))
            (should (>= (- ticks ticks-at-outage) 12))
            (should emacs-jupyter-notebook--tunnel-dead)
            (should (equal (plist-get emacs-jupyter-notebook--session-entry
                                      :remote-pid)
                           kernel-pid))
            (ejn-ag3--bridge-request "restart-relays")
            (let ((after-relay (ejn-ag3--bridge-state)))
              (should (gethash "ready" after-relay))
              (should (= kernel-pid (gethash "kernel_pid" after-relay)))
              (should (= kernel-pgid (gethash "kernel_pgid" after-relay)))
              (should (ejn-ag3--same-ports-p
                       relay-ports (gethash "relay_ports" after-relay)))
              (setq connection-file (ejn-ag2--state-connection-file after-relay)))
            ;; `--async-connect' changes the phase itself, so observe it
            ;; after its handoff rather than recording the preceding tunnel
            ;; phase at function entry.
            (advice-add #'emacs-jupyter-notebook--async-connect :after phase-advice)
            (unwind-protect
                (cl-letf
                    (((symbol-function
                       'emacs-jupyter-notebook-ssh-start-management-operation)
                      (lambda (name argv success failure &optional timeout)
                        (ignore argv failure timeout)
                        (cl-incf picker-probes)
                        (ejn-ag3-reconnect--start-picker-probe
                         name kernel-pid success)))
                     ((symbol-function
                       'emacs-jupyter-notebook-ssh-start-bounded-process)
                      (lambda (name argv limit sentinel)
                        (cond
                         ((string-match-p "pid-probe-" name)
                          (cl-incf reconnect-probes)
                          (should (eq (plist-get emacs-jupyter-notebook--async-context
                                                 :phase)
                                      'probe)))
                         ((string-match-p "scp-" name)
                          (cl-incf retrievals)
                          (should (eq (plist-get emacs-jupyter-notebook--async-context
                                                 :phase)
                                      'retrieve))))
                        (ejn-ag3-reconnect--start-successful-bounded-process
                         real-bounded name argv limit sentinel connection-file)))
                     ((symbol-function
                       'emacs-jupyter-notebook-connection-allocate-local-ports)
                      (lambda ()
                        ;; Relay listeners are the test's existing local
                        ;; stand-in for all five SSH forward destinations.
                        (ejn-ag3-reconnect--relay-ports
                         (ejn-ag3--bridge-state))))
                     ((symbol-function 'emacs-jupyter-notebook--start-tunnel)
                      (lambda (_profile remote-ports local-ports _session-id)
                        (cl-incf tunnels)
                        (should (equal remote-ports local-ports))
                        (ejn-ag2--make-tunnel)))
                     ((symbol-function 'completing-read)
                      (lambda (_prompt collection &rest _)
                        ;; Preserve the production registry picker and select
                        ;; its advertised sole durable entry without user I/O.
                        (caar collection))))
                  ;; This is a real interactive invocation.  In particular it
                  ;; enters `--read-registry-entry-async' before the public
                  ;; selected-entry path, not the direct `ejn-ag2--attach'
                  ;; continuation used by the pre-Gate-7 stress test.
                  (call-interactively
                   #'emacs-jupyter-notebook-reconnect-remote-kernel)
                  (should (ejn-ag3--await
                           (lambda ()
                             (and emacs-jupyter-notebook--client
                                  (eq (plist-get emacs-jupyter-notebook--async-context
                                                 :phase)
                                      'done)
                                  (not emacs-jupyter-notebook--tunnel-dead)))
                           12))
                  (should (>= picker-probes 1))
                  (should (= reconnect-probes 1))
                  (should (= retrievals 1))
                  (should (= tunnels 1))
                  (should (memq 'connect phases))
                  ;; One last state read proves the bridge never substituted
                  ;; a replacement kernel while EJN rebuilt local transport.
                  (let ((after (ejn-ag3--bridge-state)))
                    (should (= kernel-pid (gethash "kernel_pid" after)))
                    (should (= kernel-pgid (gethash "kernel_pgid" after)))
                    (should (ejn-ag3--same-ports-p
                             relay-ports (gethash "relay_ports" after))))
                  ;; This assertion is both a same-kernel proof and a normal
                  ;; post-reconnect execution proof.
                  (ejn-ag2--send-cell-containing "assert ag3_relay_value")
                  (ejn-ag2--await-phase
                   "public reconnect preserved kernel state"
                   (lambda ()
                     (ejn-ag2--entry-terminal-p
                      source "assert ag3_relay_value")) 10)
                  (ejn-ag2--assert-source-pristine source baseline modified)
                  (should (>= ticks 25))
                  (ejn-ag3--metric
                   "th3-public-reconnect"
                   (cons "canary_ticks" ticks)
                   (cons "outage_canary_ticks" (- ticks ticks-at-outage))
                   (cons "picker_probes" picker-probes)
                   (cons "reconnect_probes" reconnect-probes)
                   (cons "retrievals" retrievals)
                   (cons "tunnels" tunnels)
                   (cons "kernel_pid" kernel-pid)
                   (cons "kernel_pgid" kernel-pgid)
                   (cons "relay_ports" relay-ports)))
              (advice-remove #'emacs-jupyter-notebook--async-connect phase-advice)))
        (cancel-timer canary)))))

(provide 'emacs-jupyter-notebook-reconnect-stress)

;;; emacs-jupyter-notebook-reconnect-stress.el ends here
