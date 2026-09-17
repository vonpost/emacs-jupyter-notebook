;;; emacs-jupyter-notebook-docker-launcher-tests.el --- Docker command contract -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-jupyter-notebook-launcher)

(defun ejn-docker-launcher-test-profile (&rest values)
  "Return a normalized Docker fixture with VALUES overriding defaults."
  (let ((profile '(:profile "gpu" :host "host.test" :launcher docker
                   :remote-cache-dir "/tmp/private cache" :remote-cwd "/pluto"
                   :docker-image "my/image" :python-command ("python")
                   :kernelspec "python3")))
    (while values
      (setq profile (plist-put (copy-sequence profile) (pop values) (pop values))))
    profile))

(defun ejn-docker-launcher-test-resolved (resolution)
  "Return validated-shape resolved data derived from RESOLUTION."
  (let ((path (plist-get resolution :connection-file)))
    (list :argv (list "/opt/python" "-m" "ipykernel_launcher" "-f" path)
          :env '(("ENV" . "$(do-not-run)")) :connection-file path
          :connection-tokens (list "-f" path)
          :entry-fields (plist-put (copy-sequence (plist-get resolution :entry-fields))
                                   :docker-image-id (concat "sha256:" (make-string 64 ?a))))))

(defun ejn-docker-launcher-test-entry (&optional promoted)
  "Return Docker identity fixture, PROMOTED when requested."
  (let* ((resolution (emacs-jupyter-notebook-launcher-build-resolution
                      (ejn-docker-launcher-test-profile) "session"))
         (resolved (ejn-docker-launcher-test-resolved resolution))
         (path (plist-get resolved :connection-file)))
    (append (list :session-id "session" :remote-connection-file path
                  :remote-pid-sidecar (concat (string-remove-suffix ".json" path) ".pid")
                  :connection-file-tokens (list "-f" path)
                  :provisional (not promoted))
            (if promoted (list :docker-container-id (make-string 64 ?b)))
            (plist-get resolved :entry-fields))))

(ert-deftest ejn-cc28-launcher-default-is-direct ()
  (should (eq (emacs-jupyter-notebook-launcher-kind '(:host "host")) 'direct))
  (should (eq (emacs-jupyter-notebook-launcher-kind '(:host "host" :launcher direct)) 'direct))
  (dolist (kind '(nil other "docker"))
    (should-error (emacs-jupyter-notebook-launcher-kind (list :host "host" :launcher kind)))))

(ert-deftest ejn-cc28-docker-resource-options-are-structured ()
  (let* ((options '("--gpus" "all" "--ipc=host" "-v" "/pluto:/pluto:shared"
                   "-v" "local2:/local2" "--env" "VALUE=$(unsafe); space"))
         (profile (ejn-docker-launcher-test-profile :docker-options options))
         (resolution (emacs-jupyter-notebook-launcher-build-resolution profile "session"))
         (launch (emacs-jupyter-notebook-launcher-build-launch
                  profile "session" (ejn-docker-launcher-test-resolved resolution))))
    (dolist (metadata (list resolution launch))
      (let ((command (plist-get metadata :remote-command)))
        (should (string-match-p (regexp-quote (mapconcat #'shell-quote-argument options " ")) command))
        (should (string-match-p "--network host" command))
        (should (string-match-p "--user" command))
        (should (string-match-p "--host unix:///var/run/docker.sock" command))
        (should-not (string-match-p "--restart\\|--tty\\|nohup" command))))
    (should (string-match-p "--detach" (plist-get launch :remote-command)))
    (should-not (string-match-p "--detach" (plist-get resolution :remote-command)))
    (should (string-match-p "--entrypoint /opt/python" (plist-get launch :remote-command)))
    (should (string-match-p (regexp-quote (shell-quote-argument "ENV=$(do-not-run)"))
                            (plist-get launch :remote-command)))))

(ert-deftest ejn-cc28-docker-reserved-options-rejected-before-ssh ()
  (dolist (options '(("-it") ("--rm") ("--restart=always") ("--network" "host")
                     ("--net=host") ("--name" "other") ("--label" "x=y")
                     ("--entrypoint" "sh") ("--user" "root") ("--workdir" "/")
                     ("--privileged") ("image") ("--gpus")
                     ("-v" "local2:local2") ("--mount" "source=x,target=relative")
                     ("--gpus" "--detach")))
    (let ((ssh-called nil))
      (cl-letf (((symbol-function 'emacs-jupyter-notebook-ssh-command)
                 (lambda (&rest _) (setq ssh-called t))))
        (should-error
         (emacs-jupyter-notebook-launcher-build-resolution
          (ejn-docker-launcher-test-profile :docker-options options) "session"))
        (should-not ssh-called)))))

(ert-deftest ejn-cc28-docker-profile-validation-bounds ()
  (dolist (overrides (list (list :docker-image nil) (list :docker-image "")
                           (list :docker-image "--bad")
                           (list :docker-options (make-list 65 "--read-only"))
                           (list :remote-cache-dir "relative")
                           (list :remote-cache-dir "/tmp/bad:path")
                           (list :docker-image-id "--invalid")
                           (list :docker-profile-key "invalid")
                           (list :kernelspec (make-string 4097 ?x))
                           (list :remote-cache-dir (concat "/" (make-string 4095 ?a)))
                           (list :remote-cwd "bad\npath")))
    (should-error
     (emacs-jupyter-notebook-launcher-build-resolution
      (apply #'ejn-docker-launcher-test-profile overrides) "session"))))

(ert-deftest ejn-cc28-docker-restart-incarnation-is-fresh-and-image-pinned ()
  (let* ((entry (ejn-docker-launcher-test-entry t))
         (profile (append (emacs-jupyter-notebook-launcher-entry-profile-fields entry)
                          (ejn-docker-launcher-test-profile)))
         (one (emacs-jupyter-notebook-launcher-build-resolution profile "session"))
         (two (emacs-jupyter-notebook-launcher-build-resolution profile "session")))
    (should (equal (plist-get one :connection-file) (plist-get entry :remote-connection-file)))
    (should-not (equal (plist-get (plist-get one :entry-fields) :docker-container-name)
                       (plist-get (plist-get two :entry-fields) :docker-container-name)))
    (should (plist-member (plist-get one :entry-fields) :docker-container-id))
    (should-not (plist-get (plist-get one :entry-fields) :docker-container-id))
    (should (string-match-p (regexp-quote (shell-quote-argument (plist-get entry :docker-image-id)))
                            (plist-get one :remote-command)))))

(ert-deftest ejn-cc28-docker-identity-does-not-authorize-host-pid ()
  (let* ((provisional (ejn-docker-launcher-test-entry))
         (id (make-string 64 ?c))
         (output (format "EJN_PID=1234\nEJN_SESSION=session\nEJN_CONTAINER_ID=%s\n" id))
         (promoted (emacs-jupyter-notebook-launcher-parse-identity provisional output)))
    (should (emacs-jupyter-notebook-launcher-entry-valid-p provisional))
    (should-not (emacs-jupyter-notebook-launcher-entry-cleanup-valid-p provisional))
    (should (equal (plist-get promoted :docker-container-id) id))
    (should (emacs-jupyter-notebook-launcher-entry-cleanup-valid-p promoted))
    (should-not (plist-get provisional :remote-pid))
    (let ((probe (car (last (emacs-jupyter-notebook-launcher-build-probe
                            (ejn-docker-launcher-test-profile) promoted)))))
      (should (string-match-p (regexp-quote id) probe))
      (should-not (string-match-p "kill -0\\|/proc/\\|1234" probe)))
    (should-not (emacs-jupyter-notebook-launcher-parse-identity
                 promoted (replace-regexp-in-string id (make-string 64 ?d) output)))
    (should-not (emacs-jupyter-notebook-launcher-parse-identity
                 provisional (concat "banner\n" output)))))

(ert-deftest ejn-cc28-docker-cleanup-and-restart-preserve-scope ()
  (let* ((profile (ejn-docker-launcher-test-profile))
         (entry (ejn-docker-launcher-test-entry t))
         (cleanup (car (last (emacs-jupyter-notebook-launcher-build-cleanup profile entry))))
         (restart (car (last (emacs-jupyter-notebook-launcher-build-restart-cleanup profile entry)))))
    (should (string-match-p "stop --time 5" cleanup))
    (should (string-match-p "rm -f --" cleanup))
    (should-not (string-match-p "stop --time\\|rm -f --" restart))
    (should (string-match-p "container rm" restart))
    (should (string-match-p "waited.*50" restart))
    (dolist (command (list cleanup restart))
      (should (string-match-p "EJN_CLEANUP_DONE" command))
      (should-not (string-match-p "pkill\\|kill [0-9]" command)))))

(ert-deftest ejn-cc28-docker-parser-preserves-provisional-identity ()
  (let* ((profile (ejn-docker-launcher-test-profile))
         (resolution (emacs-jupyter-notebook-launcher-build-resolution profile "session"))
         (image (concat "sha256:" (make-string 64 ?a)))
         (expected (plist-get resolution :connection-file))
         (body (concat "EJN_CONNECTION_FILE=" expected "\n{}"))
         (output (concat "EJN_DOCKER_IMAGE=" image "\n" body)))
    (cl-letf (((symbol-function 'emacs-jupyter-notebook--parse-resolved-kernelspec)
               (lambda (actual session name path)
                 (should (equal actual body))
                 (should (equal session "session"))
                 (should (equal name "python3"))
                 (should (equal path expected))
                 '(:argv ("/python")))))
      (let* ((parsed (emacs-jupyter-notebook-launcher-parse-resolved
                      profile output "session" "python3" expected resolution))
             (fields (plist-get parsed :entry-fields)))
        (should (equal image (plist-get fields :docker-image-id)))
        (should (equal (plist-get fields :docker-container-name)
                       (plist-get (plist-get resolution :entry-fields) :docker-container-name)))
        (should-not (plist-member (plist-get resolution :entry-fields) :docker-image-id)))
      (should-error (emacs-jupyter-notebook-launcher-parse-resolved
                     profile body "session" "python3" expected resolution))
      (should-error (emacs-jupyter-notebook-launcher-parse-resolved
                     profile output "session" "python3" expected)))))

(provide 'emacs-jupyter-notebook-docker-launcher-tests)
;;; emacs-jupyter-notebook-docker-launcher-tests.el ends here
