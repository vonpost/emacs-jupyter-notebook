;;; emacs-jupyter-notebook-docker-lifecycle-tests.el --- Docker lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Deterministic registry and process-boundary regressions.  No Docker daemon,
;; Jupyter installation, SSH server, or remote host is used.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook)

(defun ejn-docker-lifecycle--entry (&optional provisional)
  "Return a Docker registry fixture, optionally PROVISIONAL."
  (list :profile "gpu" :remote-host "remote" :remote-cwd "/pluto"
        :kernelspec "python3" :session-id "docker-test"
        :launch-kind 'docker :provisional provisional
        :remote-connection-file "/cache/docker-docker-test/kernel-docker-test.json"
        :remote-pid-sidecar "/cache/docker-docker-test/kernel-docker-test.pid"
        :connection-file-tokens
        '("-f" "/cache/docker-docker-test/kernel-docker-test.json")
        :docker-container-name "ejn-1111111111111111-22222222222222222222"
        :docker-container-id (unless provisional (make-string 64 ?a))
        :docker-owner "docker-test" :docker-profile-key (make-string 64 ?d)
        :docker-image "example/image:gpu" :docker-image-id (concat "sha256:" (make-string 64 ?b))
        :docker-options '("--gpus" "all" "-v" "/pluto:/pluto:shared")
        :docker-python-command '("python")
        :remote-pid (unless provisional 4242)
        :registry-revision "original-revision"
        :local-file "/local/notebook.py"))

(defmacro ejn-docker-lifecycle--with-reply (output &rest body)
  "Run BODY with a successful terminal process reply containing OUTPUT."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
             ((symbol-function 'emacs-jupyter-notebook--async-process-failed-p)
              (lambda (_) nil))
             ((symbol-function 'emacs-jupyter-notebook--process-stdout)
              (lambda (_) ,output))
             ((symbol-function 'emacs-jupyter-notebook--process-output)
              (lambda (_) ,output))
             ((symbol-function 'emacs-jupyter-notebook--async-delete-process) #'ignore)
             ((symbol-function 'emacs-jupyter-notebook--async-cancel-process-timeout) #'ignore)
             ((symbol-function 'emacs-jupyter-notebook--async-arm-process-timeout) #'ignore)
             ((symbol-function 'emacs-jupyter-notebook--async-message) #'ignore))
     ,@body))

(ert-deftest ejn-docker-lifecycle-fixtures-use-real-durable-schema ()
  "Both provisional and promoted fixtures pass production launcher validation."
  (dolist (provisional '(nil t))
    (should (emacs-jupyter-notebook-launcher-entry-valid-p
             (ejn-docker-lifecycle--entry provisional)))))

(ert-deftest ejn-docker-lifecycle-durable-launcher-survives-profile-edits ()
  "Registry container configuration wins, while current SSH routing survives."
  (let* ((entry (ejn-docker-lifecycle--entry))
         (emacs-jupyter-notebook-remote-profiles
          '(("gpu" :host "new-host" :launcher direct
             :python-command ("different-python") :port 2207
             :ssh-options ("-J" "new-jump"))))
         (profile (emacs-jupyter-notebook--entry-profile entry)))
    (should (eq (plist-get profile :launcher) 'docker))
    (should (equal (plist-get profile :host) "remote"))
    (should (equal (plist-get profile :docker-image) "example/image:gpu"))
    (should (equal (plist-get profile :python-command) '("python")))
    (should (equal (plist-get profile :docker-profile-key) (make-string 64 ?d)))
    (should (equal (plist-get profile :docker-options) (plist-get entry :docker-options)))
    (should (= (plist-get profile :port) 2207))
    (should (equal (plist-get profile :ssh-options) '("-J" "new-jump")))
    (should (equal (plist-get profile :docker-connection-file)
                   (plist-get entry :remote-connection-file)))))

(ert-deftest ejn-docker-lifecycle-direct-session-stays-direct-after-profile-edit ()
  "Changing a profile to Docker never changes an existing direct kernel."
  (let ((emacs-jupyter-notebook-remote-profiles
         '(("gpu" :host "new-host" :launcher docker)))
        (entry (plist-put (ejn-docker-lifecycle--entry) :launch-kind 'direct)))
    (should (eq (plist-get (emacs-jupyter-notebook--entry-profile entry) :launcher)
                'direct))))

(ert-deftest ejn-docker-lifecycle-admission-precedes-launch-and-is-not-repeated ()
  "Container name/image/options are durable before any potentially ambiguous launch."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry t))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'resolve
                     :session-id "docker-test" :entry entry
                     :launch '(:launch-kind docker :argv ("ssh" "launch"))))
           saved callback calls)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-registry-create-async)
                 (lambda (value success &rest _)
                   (setq saved (copy-tree value) callback success)))
                ((symbol-function 'emacs-jupyter-notebook--registry-context-owner) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                 (lambda (&rest _) (push 'launch calls) 'fake-process))
                ((symbol-function 'emacs-jupyter-notebook--async-arm-process-timeout) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--async-message) #'ignore))
        (emacs-jupyter-notebook--async-launch context)
        (should-not calls)
        (should (equal (plist-get saved :docker-container-name) "ejn-1111111111111111-22222222222222222222"))
        (should (plist-get saved :docker-image-id))
        (should (plist-get saved :docker-options))
        (should (eq (plist-get saved :launch-kind) 'docker))
        (should (plist-get saved :provisional))
        (should-not (plist-get saved :docker-container-id))
        (funcall callback saved nil)
        (emacs-jupyter-notebook--async-launch context)
        (should (equal calls '(launch)))))))

(ert-deftest ejn-docker-lifecycle-lost-launch-reply-keeps-provisional-entry ()
  "No launch acknowledgement means unknown outcome, never cleanup or retry launch."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry t))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'launch :entry entry))
           reason)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply ""
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-fail)
                   (lambda (_ctx value) (setq reason value)))
                  ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                   (lambda (&rest _) (ert-fail "ambiguous launch terminated kernel")))
                  ((symbol-function 'emacs-jupyter-notebook--async-launch)
                   (lambda (&rest _) (ert-fail "ambiguous launch replayed"))))
          (emacs-jupyter-notebook--async-launch-sentinel context 'fake-process)))
      (should (string-match-p "outcome is unknown" reason))
      (should (eq (plist-get context :entry) entry)))))

(ert-deftest ejn-docker-lifecycle-provisional-reconnect-recovers-container-identity ()
  "Reconnecting an admitted Docker launch reads identity without relaunching."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry t))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'retrieve :entry entry))
           read)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-read-pid-sidecar)
                 (lambda (value) (setq read value)))
                ((symbol-function 'emacs-jupyter-notebook--async-launch)
                 (lambda (&rest _) (ert-fail "reconnect launched a container"))))
        (emacs-jupyter-notebook--async-probe-pid-alive context))
      (should (eq read context)))))

(ert-deftest ejn-docker-lifecycle-reconnect-probes-container-without-host-pid ()
  "The immutable container ID is sufficient when no informational host PID exists."
  (with-temp-buffer
    (let* ((entry (plist-put (ejn-docker-lifecycle--entry) :remote-pid nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'retrieve :entry entry
                     :profile '(:launcher docker :host "remote")))
           probed sentinel retrieved)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "__EJN_ALIVE_MATCH__\n__EJN_DONE__\n"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-launcher-build-probe)
                   (lambda (_profile value) (setq probed value) '("ssh" "inspect")))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (_name _argv _bound callback)
                     (setq sentinel callback) 'fake-process))
                  ((symbol-function 'emacs-jupyter-notebook--async-retrieve)
                   (lambda (value) (setq retrieved value)))
                  ((symbol-function 'emacs-jupyter-notebook--async-fail)
                   (lambda (&rest _) (ert-fail "container identity was treated as no PID")))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-build-pid-alive)
                   (lambda (&rest _) (ert-fail "Docker used host PID probe"))))
          (emacs-jupyter-notebook--async-probe-pid-alive context)
          (funcall sentinel 'fake-process "finished")))
      (should (eq probed entry))
      (should (eq retrieved context)))))

(ert-deftest ejn-docker-lifecycle-prune-distinguishes-daemon-failure-from-death ()
  "Only successful exact Docker absence permits pruning; never probe its host PID."
  (dolist (reply '("__EJN_EXISTENCE_UNAVAILABLE__\n__EJN_DONE__\n"
                   "__EJN_DEAD__\n__EJN_DONE__\n"))
    (with-temp-buffer
      (let ((entry (ejn-docker-lifecycle--entry)) result)
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--management-active-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'emacs-jupyter-notebook-launcher-build-probe)
                   (lambda (&rest _) '("ssh" "docker-inspect")))
                  ((symbol-function 'emacs-jupyter-notebook--management-launch)
                   (lambda (_token _name _argv success &rest _) (funcall success reply)))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-build-batch-pid-alive)
                   (lambda (&rest _) (ert-fail "Docker PID entered host batch"))))
          (emacs-jupyter-notebook--classify-registry-liveness-async
           (list entry) 'token (lambda (value _reason) (setq result value))))
        (should (eq (cdr (assq entry result))
                    (if (string-match-p "__EJN_DEAD__" reply) 'dead 'unknown)))))))

(ert-deftest ejn-docker-lifecycle-restart-pins-new-incarnation-before-launch ()
  "Admission clears the previous ID and records the new name before launching."
  (with-temp-buffer
    (let* ((entry (emacs-jupyter-notebook--transition-lease
                   (ejn-docker-lifecycle--entry) 'restart "token" 'kernel-dead))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'restart-publish
                     :entry entry :restart-operation t
                     :launch '(:entry-fields (:docker-container-name "ejn-1111111111111111-33333333333333333333"
                                              :docker-container-id nil))))
           persisted launched)
      (setq emacs-jupyter-notebook--async-context context)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--registry-context-owner) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                 (lambda (value _revision success &rest _)
                   (setq persisted (copy-tree value)) (funcall success value nil)))
                ((symbol-function 'emacs-jupyter-notebook--async-launch)
                 (lambda (value) (setq launched (plist-get value :entry)))))
        (emacs-jupyter-notebook--restart-admit-launch context))
      (should (equal (plist-get persisted :docker-container-name) "ejn-1111111111111111-33333333333333333333"))
      (should-not (plist-get persisted :docker-container-id))
      (should-not (plist-get persisted :remote-pid))
      (should (eq (plist-get persisted :transition-stage) 'launch-admitted))
      (should (equal launched persisted))
      (should (equal (plist-get entry :docker-container-id) (make-string 64 ?a))))))

(ert-deftest ejn-docker-lifecycle-restart-stopped-container-check-is-guarded ()
  "A duplicated stopped-container callback cannot upload a replacement twice."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'restart-provisional
                     :entry entry :restart-operation t))
           sentinel (uploads 0))
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "__EJN_CLEANUP_DONE__\n"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-launcher-build-restart-cleanup)
                   (lambda (_profile value)
                     (should (eq value entry)) '("ssh" "remove-stopped-container")))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (_name _argv _bound callback)
                     (setq sentinel callback) 'fake-process))
                  ((symbol-function 'emacs-jupyter-notebook--restart-upload-seed)
                   (lambda (_) (cl-incf uploads))))
          (emacs-jupyter-notebook--restart-retire-container context)
          (should (= uploads 0))
          (funcall sentinel 'fake-process "finished")
          (funcall sentinel 'fake-process "finished")
          (should (= uploads 1)))))))

(ert-deftest ejn-docker-lifecycle-retry-fresh-admits-provisional-identity-recovery ()
  "A lost first launch reply can be recovered by explicit retry-fresh."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry t))
           (emacs-jupyter-notebook--session-entry entry)
           leased)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--ensure-no-replacement-operation) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook--confirm) (lambda (&rest _) t))
                ((symbol-function 'emacs-jupyter-notebook-launcher-entry-valid-p)
                 (lambda (_) t))
                ((symbol-function 'emacs-jupyter-notebook--management-registry-owner) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                 (lambda (value &rest _) (setq leased value)))
                ((symbol-function 'emacs-jupyter-notebook-launcher-build-cleanup)
                 (lambda (&rest _) (ert-fail "cleanup before identity recovery"))))
        (emacs-jupyter-notebook-retry-fresh-kernel "gpu"))
      (should (eq (plist-get leased :transition-stage) 'launch-admitted))
      (should (equal (plist-get leased :docker-container-name)
                     (plist-get entry :docker-container-name)))
      (should-not (plist-get leased :docker-container-id)))))

(ert-deftest ejn-docker-lifecycle-local-cancellation-keeps-container-and-registry ()
  "Local context disposal reclaims its new process without durable cleanup."
  (with-temp-buffer
    (let ((context (emacs-jupyter-notebook--async-new-context
                    :origin-buffer (current-buffer) :phase 'restart-container
                    :entry (ejn-docker-lifecycle--entry)
                    :restart-container-process 'docker-inspection))
          disposed)
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-delete-process)
                 (lambda (process) (when process (push process disposed))))
                ((symbol-function 'emacs-jupyter-notebook--cleanup-remote-entry)
                 (lambda (&rest _) (ert-fail "local cleanup killed container")))
                ((symbol-function 'emacs-jupyter-notebook-registry-remove-async)
                 (lambda (&rest _) (ert-fail "local cleanup removed registry"))))
        (emacs-jupyter-notebook--cancel-async-context-locally context))
      (should (equal disposed '(docker-inspection)))
      (should (plist-get (plist-get context :entry) :docker-container-id)))))

(ert-deftest ejn-docker-lifecycle-restart-resolver-keeps-old-container-authority ()
  "Resolving a replacement must not overwrite the old container before shutdown."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'resolve
                     :entry entry :session-id "docker-test" :restart-preflight t))
           ready)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "resolver-output"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-launcher-parse-resolved)
                   (lambda (&rest _) 'resolved))
                  ((symbol-function 'emacs-jupyter-notebook-launcher-build-launch)
                   (lambda (&rest _)
                     (list :connection-file (plist-get entry :remote-connection-file)
                           :sidecar-file (plist-get entry :remote-pid-sidecar)
                           :connection-tokens (plist-get entry :connection-file-tokens)
                           :entry-fields '(:docker-container-name "new-name"
                                          :docker-container-id nil))))
                  ((symbol-function 'emacs-jupyter-notebook--restart-preflight-ready)
                   (lambda (value) (setq ready value))))
          (emacs-jupyter-notebook--async-resolve-sentinel context 'fake-process)))
      (should (eq ready context))
      (should (equal (plist-get (plist-get context :entry) :docker-container-id)
                     (make-string 64 ?a)))
      (should (equal (plist-get (plist-get context :entry) :docker-container-name)
                     "ejn-1111111111111111-22222222222222222222"))
      (should (equal (plist-get (plist-get (plist-get context :launch) :entry-fields)
                               :docker-container-name) "new-name")))))

(ert-deftest ejn-docker-lifecycle-restart-promotes-container-only-after-helper-verification ()
  "Replacement container ID stays transient until fresh helper installation."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry t))
           (candidate (plist-put (copy-tree entry) :docker-container-id (make-string 64 ?c)))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'launch-probe
                     :entry entry :candidate-entry candidate :restart-epoch 7))
           tunneled promoted)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "__EJN_ALIVE_MATCH__\n__EJN_DONE__\n"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-tunnel)
                   (lambda (_) (setq tunneled t)))
                  ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                   (lambda (&rest _) (ert-fail "container promoted before helper verification"))))
          (emacs-jupyter-notebook--async-launch-pid-sentinel context nil 'fake-process)))
      (should tunneled)
      (should-not (plist-get (plist-get context :entry) :docker-container-id))
      (plist-put context :phase 'connect)
      (setq context (emacs-jupyter-notebook--async-put context :client-unverified 'helper))
      (setq context (emacs-jupyter-notebook--async-put
                     context :remote-ports '(:shell_port 41000 :iopub_port 41001
                                            :stdin_port 41002 :hb_port 41003 :control_port 41004)))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook--async-connect-transport-current-p)
                 (lambda (&rest _) t))
                ((symbol-function 'emacs-jupyter-notebook--registry-context-owner) #'ignore)
                ((symbol-function 'emacs-jupyter-notebook-registry-replace-async)
                 (lambda (value &rest _) (setq promoted value))))
        (emacs-jupyter-notebook--async-connect-finalize
         context (current-buffer) (copy-tree entry) nil "/tmp/new-local.json" 'helper))
      (should (equal (plist-get promoted :docker-container-id) (make-string 64 ?c)))
      (should-not (plist-get promoted :provisional)))))

(ert-deftest ejn-docker-lifecycle-restart-unknown-container-state-retains-durable-entry ()
  "A failed Docker stopped-state check never publishes or launches a replacement."
  (with-temp-buffer
    (let* ((entry (ejn-docker-lifecycle--entry))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'restart-provisional
                     :entry entry :restart-operation t))
           sentinel reason)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "__EJN_CLEANUP_DONE__\n"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-launcher-build-restart-cleanup)
                   (lambda (&rest _) '("ssh" "remove-stopped-container")))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (_name _argv _bound callback)
                     (setq sentinel callback) 'fake-process))
                  ((symbol-function 'emacs-jupyter-notebook--async-process-failed-p)
                   (lambda (_) t))
                  ((symbol-function 'emacs-jupyter-notebook--restart-upload-seed)
                   (lambda (_) (ert-fail "unknown state published a replacement")))
                  ((symbol-function 'emacs-jupyter-notebook--async-fail)
                   (lambda (_context detail) (setq reason detail))))
          (emacs-jupyter-notebook--restart-retire-container context)
          (funcall sentinel 'fake-process "failed")
          (should (string-match-p "stop was not confirmed" reason))
          (should (eq (plist-get context :entry) entry))
          (setq reason nil)
          (plist-put context :cancelled t)
          (plist-put context :phase 'error)
          (funcall sentinel 'fake-process "late failure")
          (should-not reason))))))

(ert-deftest ejn-docker-lifecycle-busy-reconnect-uses-container-identity ()
  "A busy Docker kernel can reconnect with its immutable ID and no host PID."
  (with-temp-buffer
    (let* ((entry (plist-put (ejn-docker-lifecycle--entry) :remote-pid nil))
           (context (emacs-jupyter-notebook--async-new-context
                     :origin-buffer (current-buffer) :phase 'connect
                     :entry entry :client-unverified 'helper))
           sentinel busy)
      (setq emacs-jupyter-notebook--async-context context)
      (ejn-docker-lifecycle--with-reply "__EJN_ALIVE_MATCH__\n__EJN_DONE__\n"
        (cl-letf (((symbol-function 'emacs-jupyter-notebook-backend-session-attached-p)
                   (lambda (_) t))
                  ((symbol-function 'emacs-jupyter-notebook-launcher-build-probe)
                   (lambda (_profile value)
                     (should (eq value entry)) '("ssh" "container-probe")))
                  ((symbol-function 'emacs-jupyter-notebook-ssh-start-bounded-process)
                   (lambda (_name _argv _bound callback)
                     (setq sentinel callback) 'fake-process))
                  ((symbol-function 'emacs-jupyter-notebook--async-connect-finalize)
                   (lambda (_context _buffer _entry _ports _file _client state)
                     (setq busy state)))
                  ((symbol-function 'emacs-jupyter-notebook--async-fail)
                   (lambda (&rest _) (ert-fail "busy Docker kernel rejected"))))
          (emacs-jupyter-notebook--async-connect-timeout context (current-buffer))
          (funcall sentinel 'fake-process "finished")
          (should (eq busy 'busy)))))))

(provide 'emacs-jupyter-notebook-docker-lifecycle-tests)
;;; emacs-jupyter-notebook-docker-lifecycle-tests.el ends here
