;;; emacs-jupyter-notebook-launcher.el --- Kernel launcher dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Direct host processes and Docker containers share the async lifecycle but
;; retain separate durable identities and exact cleanup implementations.

;;; Code:

(require 'emacs-jupyter-notebook-ssh)
(require 'emacs-jupyter-notebook-docker)

(declare-function emacs-jupyter-notebook--parse-resolved-kernelspec
                  "emacs-jupyter-notebook" (output session name path))
(declare-function emacs-jupyter-notebook--parse-pid-sidecar
                  "emacs-jupyter-notebook" (output session))

(defun emacs-jupyter-notebook-launcher-kind (profile)
  "Return normalized PROFILE's launcher, defaulting to direct."
  (plist-get (emacs-jupyter-notebook-ssh-profile profile) :launcher))

(defun emacs-jupyter-notebook-launcher-build-resolution (profile session)
  "Build PROFILE SESSION kernelspec resolution in its launch environment."
  (if (eq (emacs-jupyter-notebook-launcher-kind profile) 'docker)
      (emacs-jupyter-notebook-docker-build-resolution profile session)
    (emacs-jupyter-notebook-ssh-build-kernelspec-resolution profile session)))

(defun emacs-jupyter-notebook-launcher-parse-resolved
    (profile output session kernelspec expected-path &optional resolution)
  "Parse OUTPUT for PROFILE SESSION KERNELSPEC and EXPECTED-PATH.
RESOLUTION preserves Docker's preallocated incarnation across remote work."
  (if (not (eq (emacs-jupyter-notebook-launcher-kind profile) 'docker))
      (emacs-jupyter-notebook--parse-resolved-kernelspec
       output session kernelspec expected-path)
    (unless (and (stringp output)
                 (<= (string-bytes output)
                     emacs-jupyter-notebook-ssh-kernelspec-max-bytes)
                 (string-match "\\`EJN_DOCKER_IMAGE=\\(sha256:[0-9a-f]\\{64\\}\\)\n" output))
      (error "Docker resolver returned no validated immutable image ID"))
    (let* ((image (match-string 1 output))
           (body (substring output (match-end 0)))
           (parsed (emacs-jupyter-notebook--parse-resolved-kernelspec
                    body session kernelspec expected-path))
           (fields (copy-sequence (plist-get resolution :entry-fields))))
      (unless (and (eq (plist-get fields :launch-kind) 'docker)
                   (equal session (plist-get fields :docker-owner)))
        (error "Docker resolver lost its provisional incarnation identity"))
      (setq fields (plist-put fields :docker-image-id image))
      (plist-put parsed :entry-fields fields))))

(defun emacs-jupyter-notebook-launcher-build-launch (profile session resolved)
  "Build PROFILE SESSION launch from RESOLVED environment data."
  (if (eq (emacs-jupyter-notebook-launcher-kind profile) 'docker)
      (emacs-jupyter-notebook-docker-build-launch profile session resolved)
    (let ((launch (emacs-jupyter-notebook-ssh-build-remote-direct-launch
                   profile session resolved)))
      (plist-put launch :entry-fields '(:launch-kind direct :launcher direct)))))

(defun emacs-jupyter-notebook-launcher-entry-valid-p (entry)
  "Whether ENTRY contains a complete durable launcher identity."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-entry-valid-p entry)
    (emacs-jupyter-notebook-ssh-direct-entry-valid-p entry)))

(defun emacs-jupyter-notebook-launcher-entry-cleanup-valid-p (entry)
  "Whether ENTRY can authorize exact explicit remote cleanup."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (and (emacs-jupyter-notebook-docker-entry-valid-p entry)
           (emacs-jupyter-notebook-docker--id-p (plist-get entry :docker-container-id)))
    (emacs-jupyter-notebook-ssh-direct-entry-cleanup-valid-p entry)))

(defun emacs-jupyter-notebook-launcher-build-read-identity (profile entry)
  "Build a read-only identity read for PROFILE ENTRY."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-build-read-identity profile entry)
    (emacs-jupyter-notebook-ssh-build-remote-read-pid-sidecar
     profile (plist-get entry :remote-pid-sidecar))))

(defun emacs-jupyter-notebook-launcher-parse-identity (entry output)
  "Return candidate ENTRY enriched with exact identity OUTPUT, or nil."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-parse-identity entry output)
    (when-let ((pid (emacs-jupyter-notebook--parse-pid-sidecar
                    output (plist-get entry :session-id))))
      (plist-put (copy-sequence entry) :remote-pid pid))))

(defun emacs-jupyter-notebook-launcher-build-probe (profile entry)
  "Build the identity-aware liveness probe for PROFILE ENTRY."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-build-probe profile entry)
    (emacs-jupyter-notebook-ssh-build-pid-alive
     profile (plist-get entry :remote-pid)
     (plist-get entry :connection-file-tokens))))

(defun emacs-jupyter-notebook-launcher-build-inspect-identity (profile entry)
  "Build a read-only identity-or-absence inspection for PROFILE ENTRY."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-build-read-identity profile entry t)
    (emacs-jupyter-notebook-ssh-build-remote-inspect-pid-sidecar profile entry)))

(defun emacs-jupyter-notebook-launcher-build-cleanup (profile entry)
  "Build exact explicit cleanup for PROFILE ENTRY."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-build-cleanup profile entry)
    (emacs-jupyter-notebook-ssh-build-remote-cleanup profile entry)))

(defun emacs-jupyter-notebook-launcher-build-restart-cleanup (profile entry)
  "Return container retirement argv for PROFILE ENTRY, or nil for direct.
The Docker command requires the old kernel to have stopped already and
preserves all connection metadata for the explicit restart sequence."
  (when (eq (plist-get entry :launch-kind) 'docker)
    (emacs-jupyter-notebook-docker-build-cleanup profile entry t)))

(defun emacs-jupyter-notebook-launcher-build-cleanup-all (profile)
  "Build explicit profile-wide cleanup for PROFILE, when supported."
  (if (eq (emacs-jupyter-notebook-launcher-kind profile) 'docker)
      (emacs-jupyter-notebook-docker-build-cleanup-all profile)
    (emacs-jupyter-notebook-ssh-build-remote-cleanup-all profile)))

(defun emacs-jupyter-notebook-launcher-build-log (profile entry)
  "Build bounded log retrieval for PROFILE ENTRY."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (emacs-jupyter-notebook-docker-build-log profile entry)
    (emacs-jupyter-notebook-ssh-build-remote-cat-log
     profile (plist-get entry :remote-connection-file))))

(defun emacs-jupyter-notebook-launcher-build-list (profile)
  "Build read-only remote process listing for PROFILE."
  (if (eq (emacs-jupyter-notebook-launcher-kind profile) 'docker)
      (emacs-jupyter-notebook-docker-build-list profile)
    (emacs-jupyter-notebook-ssh-build-remote-ps-command profile)))

(defun emacs-jupyter-notebook-launcher-entry-profile-fields (entry)
  "Return launcher config pinned to durable ENTRY for reconnect/restart."
  (if (eq (plist-get entry :launch-kind) 'docker)
      (list :launcher 'docker
            :docker-image (plist-get entry :docker-image)
            :docker-image-id (plist-get entry :docker-image-id)
            :docker-options (copy-sequence (plist-get entry :docker-options))
            :python-command (copy-sequence (plist-get entry :docker-python-command))
            :docker-profile-key (plist-get entry :docker-profile-key)
            :docker-connection-file (plist-get entry :remote-connection-file))
    '(:launcher direct)))

(provide 'emacs-jupyter-notebook-launcher)
;;; emacs-jupyter-notebook-launcher.el ends here
