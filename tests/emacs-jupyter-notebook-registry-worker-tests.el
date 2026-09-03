;;; emacs-jupyter-notebook-registry-worker-tests.el --- Registry bridge tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:
;; Remote-free ERT coverage for the external JSON/CAS registry worker bridge.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emacs-jupyter-notebook-registry)

(defconst ejn-registry-worker-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (file-truename load-file-name)))))

(defconst ejn-registry-worker-test--checkout-command
  (expand-file-name "registry_worker/bin/ejn-registry-worker"
                    ejn-registry-worker-test--root))

(defun ejn-registry-worker-test--wait (predicate &optional seconds)
  "Run process events until PREDICATE is true or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 3))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun ejn-registry-worker-test--await (starter)
  "Run STARTER with success/failure callbacks and return both callback values."
  (let (done success failure operation)
    (setq operation
          (funcall starter
                   (lambda (&rest values) (setq success values done t))
                   (lambda (&rest values) (setq failure values done t))))
    (should (ejn-registry-worker-test--wait (lambda () done)))
    (list :success success :failure failure :operation operation)))

(cl-defmacro ejn-registry-worker-test-with-registry ((file) &body body)
  "Run BODY with FILE in a private temporary registry directory."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((directory (file-truename
                      (make-temp-file "ejn-registry-worker-test-" t)))
          (,file (expand-file-name "registry-v1.json" directory))
          (emacs-jupyter-notebook-registry-file ,file)
          (emacs-jupyter-notebook-registry-worker-command
           (list ejn-registry-worker-test--checkout-command))
          (emacs-jupyter-notebook-registry-worker-request-timeout 2)
          (emacs-jupyter-notebook-registry-worker-retry-deadline 3)
          (emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.01)
          (emacs-jupyter-notebook-registry-worker-retry-max-delay 0.05))
     (unwind-protect
         (progn (ignore ,file) ,@body)
       (ignore-errors (delete-directory directory t)))))

(defun ejn-registry-worker-test--entry (session &optional extra)
  "Return a representative current registry entry for SESSION plus EXTRA."
  (append (list :profile "profile" :remote-host "example.test"
                :remote-cwd "/srv/notebook" :kernelspec "python3"
                :remote-connection-file (format "/srv/cache/kernel-%s.json" session)
                :remote-pid 4242 :created-at "2026-09-02T00:00:00+0000"
                :tunnel-ports '(:shell_port 51001 :iopub_port 51002)
                :remote-ports '(:shell_port 41001 :iopub_port 41002)
                :connection-file-tokens (list "-f" (format "/srv/cache/kernel-%s.json" session))
                :launch-kind 'direct :provisional t :display-name "example:python3"
                :session-id session :registry-owner "test-owner")
          extra))

(defun ejn-registry-worker-test--write-fixture (directory name body)
  "Write executable Python fixture BODY under DIRECTORY and return its path."
  (let ((file (expand-file-name name directory)))
    (with-temp-file file
      (insert "#!/usr/bin/env python3\n")
      (insert body))
    (set-file-modes file #o700)
    file))

(defun ejn-registry-worker-test--entry-wire (entry revision)
  "Return worker wire encoding of ENTRY carrying exact REVISION."
  (append (emacs-jupyter-notebook-registry--entry-to-wire entry)
          (list (cons "revision" revision))))

(defun ejn-registry-worker-test--write-state (file entries &optional mutations)
  "Write fixture worker FILE state containing ENTRIES and MUTATIONS."
  (with-temp-file file
    (insert (json-encode
             (list (cons "generation" 1)
                   (cons "entries" entries)
                   (cons "mutations" (or mutations 0)))))))

(defun ejn-registry-worker-test--read-state (file)
  "Return fixture worker state hash table from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'hash-table :array-type 'list
                       :null-object nil :false-object :false)))

(defconst ejn-registry-worker-test--lost-response-worker
  (concat
   "import json, pathlib, sys, time\n"
   "request=json.load(sys.stdin)\n"
   "state_path=pathlib.Path(sys.argv[1])\n"
   "mode=sys.argv[2]\n"
   "state=json.loads(state_path.read_text()) if state_path.exists() else {'generation':0,'entries':[],'mutations':0}\n"
   "state.setdefault('entries', [])\n"
   "state.setdefault('mutations', 0)\n"
   "def save(): state_path.write_text(json.dumps(state, separators=(',', ':')))\n"
   "def emit(value): sys.stdout.write(json.dumps(value, separators=(',', ':')))\n"
   "if request['op'] == 'read':\n"
   " emit({'v':1,'ok':True,'result':{'generation':state['generation'],'entries':state['entries']}})\n"
   " sys.exit(0)\n"
   "key=(request.get('entry') or {}).get('key', request.get('key'))\n"
   "entries=state['entries']\n"
   "current=next((entry for entry in entries if entry['key'] == key), None)\n"
   "if request['op'] == 'create-if-absent' and current is not None:\n"
   " emit({'v':1,'ok':False,'error':{'code':'conflict','message':'entry exists'}})\n"
   " sys.exit(0)\n"
   "if request['op'] == 'create-if-absent':\n"
   " durable=dict(request['entry']); durable['revision']='a'*32; entries.append(durable)\n"
   "elif request['op'] == 'replace-if-revision':\n"
   " if current is None or current['revision'] != request['expected_revision']:\n"
   "  emit({'v':1,'ok':False,'error':{'code':'conflict','message':'revision changed'}}); sys.exit(0)\n"
   " durable=dict(request['entry']); durable['revision']='b'*32; entries[entries.index(current)]=durable\n"
   "elif request['op'] == 'remove-if-revision':\n"
   " if current is None or current['revision'] != request['expected_revision']:\n"
   "  emit({'v':1,'ok':False,'error':{'code':'conflict','message':'revision changed'}}); sys.exit(0)\n"
   " entries.remove(current)\n"
   "else:\n"
   " emit({'v':1,'ok':False,'error':{'code':'protocol','message':'unsupported'}}); sys.exit(0)\n"
   "state['generation'] += 1\n"
   "state['mutations'] += 1\n"
   "save()\n"
   "if mode == 'delay': time.sleep(10)\n"
   "if mode == 'malformed': sys.stdout.write('{')\n"
   "# With mode 'none', the committed worker exits without a response.\n"))

(ert-deftest ejn-registry-worker-rejects-remote-program-before-file-predicates ()
  "A remote worker command cannot reach synchronous file handlers."
  (let (file-predicate-called truename-called)
    (cl-letf (((symbol-function 'file-remote-p)
               (lambda (path &rest _)
                 (and (stringp path) (string-prefix-p "/ssh:" path))))
              ((symbol-function 'file-executable-p)
               (lambda (&rest _)
                 (setq file-predicate-called t)
                 (error "must not inspect a remote worker")))
              ((symbol-function 'file-truename)
               (lambda (&rest _)
                 (setq truename-called t)
                 (error "must not canonicalize a remote worker"))))
      (should-error
       (emacs-jupyter-notebook-registry-worker-resolve-argv
        '("/ssh:example.test:/opt/ejn-registry-worker")))
      (should-not file-predicate-called)
      (should-not truename-called))))

(ert-deftest ejn-registry-worker-ignores-remote-exec-path-elements ()
  "Program discovery skips remote `exec-path' elements without handler I/O."
  (let (checked)
    (cl-letf (((symbol-function 'file-remote-p)
               (lambda (path &rest _)
                 (and (stringp path) (string-prefix-p "/ssh:" path))))
              ((symbol-function 'file-executable-p)
               (lambda (path)
                 (push path checked)
                 (equal path "/tmp/ejn-local-bin/ejn-registry-worker"))))
      (let ((exec-path '("/ssh:example.test:/bin" "/tmp/ejn-local-bin")))
        (should
         (equal (emacs-jupyter-notebook-registry-worker-resolve-argv
                 '("ejn-registry-worker" "--fixture"))
                '("/tmp/ejn-local-bin/ejn-registry-worker" "--fixture")))
        (should-not (cl-find-if (lambda (path) (string-prefix-p "/ssh:" path))
                                checked))))))

(ert-deftest ejn-registry-worker-lost-create-and-replace-responses-stay-uncertain ()
  "A lost mutation reply stays uncertain and is never replayed or inferred."
  (ejn-registry-worker-test-with-registry (_file)
    (let* ((directory (make-temp-file "ejn-registry-lost-create-" t))
           (state (expand-file-name "state.json" directory))
           (worker (ejn-registry-worker-test--write-fixture
                    directory "lost-response.py"
                    ejn-registry-worker-test--lost-response-worker))
           (entry (ejn-registry-worker-test--entry "lost-create"))
           (emacs-jupyter-notebook-registry-worker-command (list worker state "none")))
      (unwind-protect
          (let* ((created-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-create-async
                      entry success failure))))
                 (created-failure (car (plist-get created-result :failure))))
            (should-not (plist-get created-result :success))
            (should (eq (plist-get created-failure :kind) 'durability-uncertain))
            (should (= (gethash "mutations" (ejn-registry-worker-test--read-state state)) 1))
            (let* ((replacement (plist-put (copy-sequence entry) :remote-pid 9999))
                   (emacs-jupyter-notebook-registry-worker-command
                    (list worker state "malformed"))
                   (replaced-result
                    (ejn-registry-worker-test--await
                     (lambda (success failure)
                       (emacs-jupyter-notebook-registry-replace-async
                        replacement (make-string 32 ?a)
                        success failure))))
                   (replaced-failure (car (plist-get replaced-result :failure))))
              (should-not (plist-get replaced-result :success))
              (should (eq (plist-get replaced-failure :kind) 'durability-uncertain))
              (should (= (gethash "mutations" (ejn-registry-worker-test--read-state state)) 2))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-lost-remove-response-stays-uncertain ()
  "A committed removal with no reply is never inferred from later absence."
  (ejn-registry-worker-test-with-registry (_file)
    (let* ((directory (make-temp-file "ejn-registry-lost-remove-" t))
           (state (expand-file-name "state.json" directory))
           (worker (ejn-registry-worker-test--write-fixture
                    directory "lost-response.py"
                    ejn-registry-worker-test--lost-response-worker))
           (entry (ejn-registry-worker-test--entry "lost-remove"))
           (revision (make-string 32 ?c))
           (emacs-jupyter-notebook-registry-worker-command (list worker state "none")))
      (unwind-protect
          (progn
            (ejn-registry-worker-test--write-state
             state (list (ejn-registry-worker-test--entry-wire entry revision)))
            (let ((result
                   (ejn-registry-worker-test--await
                    (lambda (success failure)
                      (emacs-jupyter-notebook-registry-remove-async
                       "lost-remove" revision success failure)))))
              (should-not (plist-get result :success))
              (should (eq (plist-get (car (plist-get result :failure)) :kind)
                          'durability-uncertain))
              (let ((after (ejn-registry-worker-test--read-state state)))
                (should-not (gethash "entries" after))
                (should (= (gethash "mutations" after) 1)))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-deadline-keeps-committed-mutation-uncertain ()
  "An expired mutation deadline does not infer a commit from a later read."
  (ejn-registry-worker-test-with-registry (_file)
    (let* ((directory (make-temp-file "ejn-registry-deadline-settle-" t))
           (state (expand-file-name "state.json" directory))
           (worker (ejn-registry-worker-test--write-fixture
                    directory "deadline-settle.py"
                    ejn-registry-worker-test--lost-response-worker))
           (entry (ejn-registry-worker-test--entry "deadline-settle"))
           (emacs-jupyter-notebook-registry-worker-command
            (list worker state "delay")))
      (unwind-protect
          (let* ((result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-create-async
                      entry success failure :deadline 0.1))))
                 (failure (car (plist-get result :failure))))
            (should-not (plist-get result :success))
            (should (eq (plist-get failure :kind) 'durability-uncertain))
            (should (= (gethash "mutations"
                                (ejn-registry-worker-test--read-state state))
                       1)))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-conflict-stays-conflict-for-same-data-new-revision ()
  "A same-data row at another revision remains an explicit CAS conflict."
  (ejn-registry-worker-test-with-registry (_file)
    (let* ((directory (make-temp-file "ejn-registry-conflict-" t))
           (state (expand-file-name "state.json" directory))
           (worker (ejn-registry-worker-test--write-fixture
                    directory "lost-response.py"
                    ejn-registry-worker-test--lost-response-worker))
           (wanted (ejn-registry-worker-test--entry "same-key"))
           (emacs-jupyter-notebook-registry-worker-command (list worker state "none")))
      (unwind-protect
          (progn
             (ejn-registry-worker-test--write-state
             state (list (ejn-registry-worker-test--entry-wire
                          wanted (make-string 32 ?d))))
            (let* ((result
                    (ejn-registry-worker-test--await
                     (lambda (success failure)
                       (emacs-jupyter-notebook-registry-create-async
                        wanted success failure))))
                   (failure (car (plist-get result :failure))))
              (should-not (plist-get result :success))
              (should (eq (plist-get failure :kind) 'conflict))
              (should (= (gethash "mutations" (ejn-registry-worker-test--read-state state)) 0))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-start-failure-reaps-allocated-stderr-pipe ()
  "A `make-process' error cannot leak a pipe created for worker stderr."
  (ejn-registry-worker-test-with-registry (_file)
    (let ((real-make-pipe-process (symbol-function 'make-pipe-process)) pipe)
      (unwind-protect
          (cl-letf (((symbol-function 'make-pipe-process)
                     (lambda (&rest args)
                       (setq pipe (apply real-make-pipe-process args))))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (error "fixture start failure"))))
            (let* ((result
                    (ejn-registry-worker-test--await
                     (lambda (success failure)
                       (emacs-jupyter-notebook-registry-read-async success failure))))
                   (failure (car (plist-get result :failure))))
              (should-not (plist-get result :success))
              (should (eq (plist-get failure :kind) 'local-start))
              (should (processp pipe))
              (should-not (process-live-p pipe))))
        (when (processp pipe)
          (ignore-errors (delete-process pipe)))))))

(ert-deftest ejn-registry-worker-roundtrip-cas-and-prune ()
  "Real worker preserves current entry shapes and enforces exact revisions."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((entry (ejn-registry-worker-test--entry "one"))
           (created-result
            (ejn-registry-worker-test--await
             (lambda (success failure)
               (emacs-jupyter-notebook-registry-create-async entry success failure))))
           (created (car (plist-get created-result :success))))
      (should-not (plist-get created-result :failure))
      (should (stringp (plist-get created :registry-revision)))
      (should (equal (plist-get created :launch-kind) 'direct))
      (should (equal (plist-get created :tunnel-ports)
                     '(:shell_port 51001 :iopub_port 51002)))
      (let* ((read-result
              (ejn-registry-worker-test--await
               (lambda (success failure)
                 (emacs-jupyter-notebook-registry-read-async success failure))))
             (read-entry (car (car (plist-get read-result :success)))))
        (should-not (plist-get read-result :failure))
        (should (equal read-entry created))
        (let* ((replacement (plist-put (copy-sequence created) :remote-pid 9999))
               (replace-result
                (ejn-registry-worker-test--await
                 (lambda (success failure)
                   (emacs-jupyter-notebook-registry-replace-async
                    replacement (plist-get created :registry-revision) success failure))))
               (replaced (car (plist-get replace-result :success))))
          (should-not (plist-get replace-result :failure))
          (should (= (plist-get replaced :remote-pid) 9999))
          (should-not (equal (plist-get replaced :registry-revision)
                             (plist-get created :registry-revision)))
          (let ((stale-result
                 (ejn-registry-worker-test--await
                  (lambda (success failure)
                    (emacs-jupyter-notebook-registry-remove-async
                     "one" (plist-get created :registry-revision) success failure)))))
            (should-not (plist-get stale-result :success))
            (should (eq (plist-get (car (plist-get stale-result :failure)) :kind)
                        'conflict)))
          (let* ((other-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-create-async
                      (ejn-registry-worker-test--entry "two") success failure))))
                 (other (car (plist-get other-result :success)))
                 (prune-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-prune-async
                      (list created other) success failure)))))
            (should-not (plist-get prune-result :failure))
            (should (equal (nth 0 (plist-get prune-result :success)) '("two")))
            (should (equal (nth 1 (plist-get prune-result :success)) '("one")))
            (let ((after-prune
                   (ejn-registry-worker-test--await
                    (lambda (success failure)
                      (emacs-jupyter-notebook-registry-read-async success failure)))))
              (should (equal (mapcar (lambda (item) (plist-get item :session-id))
                                     (car (plist-get after-prune :success)))
                             '("one"))))))))))

(ert-deftest ejn-registry-worker-real-concurrent-creates-preserve-union ()
  "Two real one-shot workers cannot lose independent concurrent entries."
  (ejn-registry-worker-test-with-registry (file)
    (let (completed failures)
      (dolist (session '("first" "second"))
        (emacs-jupyter-notebook-registry-create-async
         (ejn-registry-worker-test--entry session)
         (lambda (_entry _operation) (setq completed (1+ (or completed 0))))
         (lambda (failure _operation) (push failure failures))))
      (should (ejn-registry-worker-test--wait
               (lambda () (= (+ (or completed 0) (length failures)) 2))))
      (should-not failures)
      (let ((read-result
             (ejn-registry-worker-test--await
              (lambda (success failure)
                (emacs-jupyter-notebook-registry-read-async success failure)))))
        (should (equal (sort (mapcar (lambda (entry) (plist-get entry :session-id))
                                     (car (plist-get read-result :success)))
                             #'string<)
                       '("first" "second")))))))

(ert-deftest ejn-registry-worker-read-local-file-resolves-symlink-and-hardlink ()
  "A local-file read returns the exact durable row for both alias kinds."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (file-name-directory file))
           (source (expand-file-name "notebook.py" directory))
           (symlink (expand-file-name "notebook-symlink.py" directory))
           (hardlink (expand-file-name "notebook-hardlink.py" directory)))
      (with-temp-file source
        (insert "# %%\nprint('test')\n"))
      (make-symbolic-link source symlink)
      (add-name-to-file source hardlink)
      (unwind-protect
          (let* ((entry (ejn-registry-worker-test--entry
                         "local-file-owner" (list :local-file source)))
                 (created-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-create-async
                      entry success failure))))
                 (durable (car (plist-get created-result :success)))
                 (before (ejn-registry-worker-test--read-state file)))
            (should-not (plist-get created-result :failure))
            (dolist (alias (list symlink hardlink))
              (let* ((read-result
                      (ejn-registry-worker-test--await
                       (lambda (success failure)
                         (emacs-jupyter-notebook-registry-read-async
                          success failure :local-file alias))))
                     (values (plist-get read-result :success))
                     (entries (nth 0 values))
                     (matching (nth 2 values)))
                (should-not (plist-get read-result :failure))
                (should (= (length values) 3))
                (should (equal (car entries) durable))
                (should (equal matching durable))
                (should (equal (plist-get matching :registry-revision)
                               (plist-get durable :registry-revision)))))
            ;; Local-file lookup is read-only: neither generation nor the
            ;; durable entry/revision may change while resolving aliases.
            (let ((after (ejn-registry-worker-test--read-state file)))
              (should (= (gethash "generation" after)
                         (gethash "generation" before)))
              (should (equal (json-encode (gethash "entries" after))
                             (json-encode (gethash "entries" before))))))
        (ignore-errors (delete-file symlink))
        (ignore-errors (delete-file hardlink))
        (ignore-errors (delete-file source))))))

(ert-deftest ejn-registry-worker-read-local-file-reports-absent-match ()
  "A local-file read returns a nil third value for an unrelated file."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (file-name-directory file))
           (source (expand-file-name "claimed.py" directory))
           (other (expand-file-name "other.py" directory)))
      (with-temp-file source (insert "# claimed\n"))
      (with-temp-file other (insert "# unrelated\n"))
      (unwind-protect
          (let* ((entry (ejn-registry-worker-test--entry
                         "claimed" (list :local-file source)))
                 (created-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-create-async
                      entry success failure))))
                 (before (ejn-registry-worker-test--read-state file))
                 (read-result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-read-async
                      success failure :local-file other))))
                 (values (plist-get read-result :success)))
            (should-not (plist-get created-result :failure))
            (should-not (plist-get read-result :failure))
            (should (= (length values) 3))
            (should (null (nth 2 values)))
            (let ((after (ejn-registry-worker-test--read-state file)))
              (should (= (gethash "generation" after)
                         (gethash "generation" before)))))
        (ignore-errors (delete-file source))
        (ignore-errors (delete-file other))))))

(ert-deftest ejn-registry-worker-read-local-file-rejects-malformed-schema ()
  "A local-file lookup without its matching-entry field fails closed."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-malformed-local-read-" t))
           (worker (ejn-registry-worker-test--write-fixture
                    directory "malformed-local-read.py"
                    (concat
                     "import json, sys\n"
                     "sys.stdin.buffer.read()\n"
                     "json.dump({'v':1,'ok':True,'result':"
                     "{'entries':[],'generation':0}},sys.stdout)\n")))
           (local-file (expand-file-name "source.py" directory))
           (emacs-jupyter-notebook-registry-worker-command (list worker)))
      (unwind-protect
          (let* ((result
                  (ejn-registry-worker-test--await
                   (lambda (success failure)
                     (emacs-jupyter-notebook-registry-read-async
                      success failure :local-file local-file))))
                 (failure (car (plist-get result :failure))))
            (should-not (plist-get result :success))
            (should (eq (plist-get failure :kind) 'protocol))
            (should (equal (plist-get failure :code) "protocol")))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-busy-retries-by-timer-under-one-deadline ()
  "Busy replies use a timer and eventually deliver exactly one continuation."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-busy-" t))
           (state (expand-file-name "count" directory))
           (worker
            (ejn-registry-worker-test--write-fixture
             directory "busy.py"
             (concat
              "import json, pathlib, sys\n"
              "sys.stdin.buffer.read()\n"
              "p=pathlib.Path(sys.argv[1]); n=int(p.read_text()) if p.exists() else 0\n"
              "p.write_text(str(n+1))\n"
              "if n < 2: out={'v':1,'ok':False,'error':{'code':'busy','message':'held'}}\n"
              "else: out={'v':1,'ok':True,'result':{'generation':0,'entries':[]}}\n"
              "sys.stdout.write(json.dumps(out))\n"))))
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-worker-command (list worker state))
                (emacs-jupyter-notebook-registry-worker-retry-deadline 1)
                (emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.01)
                done failures)
            (emacs-jupyter-notebook-registry-read-async
             (lambda (entries _operation) (should-not entries) (setq done t))
             (lambda (failure _operation) (push failure failures) (setq done t)))
            (should (ejn-registry-worker-test--wait (lambda () done)))
            (should-not failures)
            (should (>= (string-to-number
                         (with-temp-buffer (insert-file-contents state) (buffer-string))) 3)))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-flood-malformed-and-killed-fail-closed ()
  "Malformed, flooding, and killed workers expose no trusted continuation."
  (ejn-registry-worker-test-with-registry (file)
    (dolist (fixture
             `(("malformed.py" . "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('{')\n")
               ("flood.py" . "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('x'*4096)\n")
               ("killed.py" . "import os, sys\nsys.stdin.buffer.read()\nos.kill(os.getpid(), 9)\n")))
      (let* ((directory (make-temp-file "ejn-registry-fixture-" t))
             (worker (ejn-registry-worker-test--write-fixture
                      directory (car fixture) (cdr fixture)))
             (emacs-jupyter-notebook-registry-worker-command (list worker))
             (emacs-jupyter-notebook-registry-worker-output-max-bytes 64)
             (emacs-jupyter-notebook-registry-worker-retry-deadline 0.15)
             (emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.01)
             (result
              (ejn-registry-worker-test--await
               (lambda (success failure)
                 (emacs-jupyter-notebook-registry-read-async success failure)))))
        (unwind-protect
            (progn
              (should-not (plist-get result :success))
              (let ((failure (car (plist-get result :failure))))
                (pcase (car fixture)
                  ("killed.py"
                   ;; A read-only child cannot commit, so early exit is safely
                   ;; retried until the finite logical deadline.
                   (should (eq (plist-get failure :kind) 'deadline)))
                  ("flood.py"
                   (should (equal (plist-get failure :code) "output-overflow")))
                  (_ (should (eq (plist-get failure :kind) 'protocol))))))
          (ignore-errors (delete-directory directory t)))))))

(ert-deftest ejn-registry-worker-cancel-and-stale-guard-are-inert ()
  "Cancellation and stale guards stop only local continuation state."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-sleep-" t))
           (sleeper (ejn-registry-worker-test--write-fixture
                     directory "sleep.py"
                     "import sys, time\nsys.stdin.buffer.read()\ntime.sleep(10)\n")))
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-worker-command (list sleeper))
                callbacks operation)
            (setq operation
                  (emacs-jupyter-notebook-registry-read-async
                   (lambda (&rest _) (setq callbacks t))
                   (lambda (&rest _) (setq callbacks t))))
            (should (processp (emacs-jupyter-notebook-registry-operation-process operation)))
            (emacs-jupyter-notebook-registry-operation-cancel operation)
            (should (emacs-jupyter-notebook-registry-operation-finished operation))
            (accept-process-output nil 0.05)
            (should-not callbacks))
        (ignore-errors (delete-directory directory t))))
    (let ((live t) callback)
      (let* ((owner (emacs-jupyter-notebook-registry-owner-create
                     :guard (lambda () live)))
             (operation
              (emacs-jupyter-notebook-registry-create-async
               (ejn-registry-worker-test--entry "stale")
               (lambda (&rest _) (setq callback t))
               (lambda (&rest _) (setq callback t))
               :owner owner)))
        (setq live nil)
        (should (ejn-registry-worker-test--wait
                 (lambda () (emacs-jupyter-notebook-registry-operation-finished operation))))
        (should-not callback)
        ;; The stale callback is inert, but a racing worker commit is durable
        ;; recovery evidence and must never be removed automatically.
        (let ((read-result
               (ejn-registry-worker-test--await
                (lambda (success failure)
                  (emacs-jupyter-notebook-registry-read-async success failure)))))
          (should (equal (mapcar (lambda (entry) (plist-get entry :session-id))
                                 (car (plist-get read-result :success)))
                         '("stale"))))))))

(ert-deftest ejn-registry-worker-read-timeout-retries-to-deadline ()
  "A timed-out read is safely retried under one finite deadline."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-timeout-" t))
           (sleeper (ejn-registry-worker-test--write-fixture
                     directory "sleep.py"
                     "import sys, time\nsys.stdin.buffer.read()\ntime.sleep(10)\n")))
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-worker-command (list sleeper))
                (emacs-jupyter-notebook-registry-worker-request-timeout 0.05)
                (emacs-jupyter-notebook-registry-worker-retry-deadline 0.15)
                (emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.01))
            (let ((result
                   (ejn-registry-worker-test--await
                    (lambda (success failure)
                      (emacs-jupyter-notebook-registry-read-async success failure)))))
              (should-not (plist-get result :success))
              (let ((failure (car (plist-get result :failure))))
                (should (eq (plist-get failure :kind) 'deadline)))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-read-local-file-timeout-retries-to-deadline ()
  "A timed-out local-file lookup is a read and safely retries to its deadline."
  (ejn-registry-worker-test-with-registry (_file)
    (let* ((directory (make-temp-file "ejn-registry-local-read-timeout-" t))
           (source (expand-file-name "source.py" directory))
           (sleeper (ejn-registry-worker-test--write-fixture
                     directory "sleep.py"
                     "import sys, time\nsys.stdin.buffer.read()\ntime.sleep(10)\n")))
      (unwind-protect
          (progn
            (with-temp-file source (insert "# %%\n"))
            (let ((emacs-jupyter-notebook-registry-worker-command (list sleeper))
                  (emacs-jupyter-notebook-registry-worker-request-timeout 0.05)
                  (emacs-jupyter-notebook-registry-worker-retry-deadline 0.15)
                  (emacs-jupyter-notebook-registry-worker-retry-initial-delay 0.01))
              (let ((result
                     (ejn-registry-worker-test--await
                      (lambda (success failure)
                        (emacs-jupyter-notebook-registry-read-async
                         success failure :local-file source)))))
                (should-not (plist-get result :success))
                (let ((failure (car (plist-get result :failure))))
                  (should (eq (plist-get failure :kind) 'deadline))
                  (should-not (plist-get failure :durability-uncertain))))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-mutation-timeout-is-durability-uncertain ()
  "A timed-out mutation is never retried because it may have committed."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-mutation-timeout-" t))
           (sleeper (ejn-registry-worker-test--write-fixture
                     directory "sleep.py"
                     "import sys, time\nsys.stdin.buffer.read()\ntime.sleep(10)\n")))
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-worker-command (list sleeper))
                (emacs-jupyter-notebook-registry-worker-request-timeout 0.05))
            (let ((result
                   (ejn-registry-worker-test--await
                    (lambda (success failure)
                      (emacs-jupyter-notebook-registry-create-async
                       (ejn-registry-worker-test--entry "ambiguous")
                       success failure)))))
              (should-not (plist-get result :success))
              (let ((failure (car (plist-get result :failure))))
                (should (eq (plist-get failure :kind) 'durability-uncertain))
                (should (equal (plist-get failure :code) "worker-timeout")))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-framed-mutation-response-finishes-before-exit ()
  "A complete mutation response is authoritative before the child exits."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-framed-response-" t))
           (worker
            (ejn-registry-worker-test--write-fixture
             directory "respond-then-sleep.py"
             (concat
              "import json, sys, time\n"
              "json.load(sys.stdin)\n"
              "raw=json.dumps({'v':1,'ok':True,'result':{}},separators=(',',':'))\n"
              "sys.stdout.write(raw+'\\n'); sys.stdout.flush()\n"
              "time.sleep(10)\n")))
           (emacs-jupyter-notebook-registry-worker-command (list worker))
           (emacs-jupyter-notebook-registry-worker-request-timeout 0.05)
           (started (float-time)))
      (unwind-protect
          (let ((result
                 (ejn-registry-worker-test--await
                  (lambda (success failure)
                    (emacs-jupyter-notebook-registry-request-async
                     (list (cons "v" 1)
                           (cons "op" "replace-if-revision")
                           (cons "path" file))
                     success failure)))))
            (should (plist-get result :success))
            (should-not (plist-get result :failure))
            (should (< (- (float-time) started) 1.0))
            (should
             (emacs-jupyter-notebook-registry-operation-finished
              (plist-get result :operation))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-invalid-mutation-result-is-durability-uncertain ()
  "A success envelope with invalid mutation data cannot prove commit state."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-invalid-result-" t))
           (worker
            (ejn-registry-worker-test--write-fixture
             directory "invalid-result.py"
             (concat
              "import json, sys\n"
              "request=json.load(sys.stdin)\n"
              "op=request['op']\n"
              "if op in ('create-if-absent','replace-if-revision'):\n"
              " result={'generation':1,'entry':{}}\n"
              "elif op == 'remove-if-revision':\n"
              " result={'generation':1,'removed':42}\n"
              "else:\n"
              " result={'generation':1,'removed':[42],'retained':[]}\n"
              "json.dump({'v':1,'ok':True,'result':result},sys.stdout)\n")))
           (emacs-jupyter-notebook-registry-worker-command (list worker))
           (entry (ejn-registry-worker-test--entry "ambiguous-nested"))
           (revision "0123456789abcdef0123456789abcdef"))
      (unwind-protect
          (dolist
              (starter
               (list
                (lambda (success failure)
                  (emacs-jupyter-notebook-registry-create-async
                   entry success failure))
                (lambda (success failure)
                  (emacs-jupyter-notebook-registry-replace-async
                   entry revision success failure))
                (lambda (success failure)
                  (emacs-jupyter-notebook-registry-remove-async
                   "ambiguous-nested" revision success failure))
                (lambda (success failure)
                  (emacs-jupyter-notebook-registry-prune-async
                   (list (plist-put (copy-sequence entry)
                                    :registry-revision revision))
                   success failure))))
            (let* ((result (ejn-registry-worker-test--await starter))
                   (failure (car (plist-get result :failure))))
              (should-not (plist-get result :success))
              (should (eq (plist-get failure :kind) 'durability-uncertain))
              (should (plist-get failure :durability-uncertain))))
        (ignore-errors (delete-directory directory t))))))

(ert-deftest ejn-registry-worker-buffer-kill-cancels-local-process-only ()
  "Killing the owner buffer cancels the worker without a durable rollback."
  (ejn-registry-worker-test-with-registry (file)
    (let* ((directory (make-temp-file "ejn-registry-owner-kill-" t))
           (sleeper (ejn-registry-worker-test--write-fixture
                     directory "sleep.py"
                     "import sys, time\nsys.stdin.buffer.read()\ntime.sleep(10)\n"))
           (buffer (generate-new-buffer " *ejn-registry-owner*"))
           operation callbacks)
      (unwind-protect
          (let ((emacs-jupyter-notebook-registry-worker-command (list sleeper)))
            (setq operation
                  (emacs-jupyter-notebook-registry-read-async
                   (lambda (&rest _) (setq callbacks t))
                   (lambda (&rest _) (setq callbacks t))
                   :owner (emacs-jupyter-notebook-registry-owner-create :buffer buffer)))
            (kill-buffer buffer)
            (should (emacs-jupyter-notebook-registry-operation-finished operation))
            (accept-process-output nil 0.05)
            (should-not callbacks))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (ignore-errors (delete-directory directory t))))))

(defconst ejn-registry-worker-test--forbidden-calls
  '(insert-file-contents insert-file-contents-literally write-region with-temp-file
    rename-file file-readable-p file-exists-p directory-files directory-files-recursively
    call-process process-file shell-command shell-command-to-string
    accept-process-output sleep-for sit-for)
  "Synchronous APIs forbidden in the production registry bridge.")

(defun ejn-registry-worker-test--forbidden-calls-in-file (file)
  "Return executable forbidden calls in Lisp FILE, ignoring comments/strings."
  (let (found)
    (cl-labels ((walk
                 (form)
                 (cond
                  ((consp form)
                   (when (memq (car form) ejn-registry-worker-test--forbidden-calls)
                     (push (car form) found))
                   ;; Dotted lists occur in char-to-value tables; inspect their
                   ;; cars without assuming every cons is a proper call form.
                   (let ((tail form))
                     (while (consp tail)
                       (walk (car tail))
                       (setq tail (cdr tail)))
                     (when tail (walk tail))))
                  ((vectorp form) (mapc #'walk form)))))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t (walk (read (current-buffer))))
          (end-of-file nil))))
    (delete-dups found)))

(ert-deftest ejn-registry-worker-static-no-sync-registry-io-or-legacy-api ()
  "Bridge source has no synchronous registry I/O and exposes no old API."
  (should (string-suffix-p "emacs-jupyter-notebook/registry-v1.json"
                           emacs-jupyter-notebook-registry-file))
  (should-not
   (ejn-registry-worker-test--forbidden-calls-in-file
    (expand-file-name "emacs-jupyter-notebook-registry.el"
                      ejn-registry-worker-test--root)))
  (let ((file (make-temp-file "ejn-registry-static-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(insert-file-contents \"x\")\n"))
          (should (equal (ejn-registry-worker-test--forbidden-calls-in-file file)
                         '(insert-file-contents))))
      (ignore-errors (delete-file file))))
  (dolist (symbol '(emacs-jupyter-notebook-registry-load
                    emacs-jupyter-notebook-registry-save
                    emacs-jupyter-notebook-registry-save-entry
                    emacs-jupyter-notebook-registry-remove-entry
                    emacs-jupyter-notebook-registry-upsert
                    emacs-jupyter-notebook-registry-remove))
    (should-not (fboundp symbol))))

(ert-deftest ejn-registry-worker-strict-response-parser-rejects-duplicate-envelope ()
  "Duplicate protocol fields at any depth cannot become trusted replies."
  (dolist
      (raw
       '("{\"ok\":true,\"ok\":true,\"result\":{\"entries\":[],\"generation\":0},\"v\":1}"
         "{\"ok\":true,\"result\":{\"entries\":[],\"entries\":[],\"generation\":0},\"v\":1}"))
    (let ((response (emacs-jupyter-notebook-registry--parse-response raw)))
      (should-not (plist-get response :ok))
      (should (equal (plist-get response :code) "protocol")))))

(ert-deftest ejn-registry-worker-response-depth-is-bounded-before-json-parse ()
  "Deep worker output is rejected before recursive JSON parsing owns Emacs."
  (let* ((depth (1+ emacs-jupyter-notebook-registry--hard-json-depth))
         (raw (concat "{\"v\":1,\"ok\":true,\"result\":"
                      (make-string depth ?\[) "null"
                      (make-string depth ?\]) "}"))
         parser-called)
    (cl-letf (((symbol-function 'json-read)
               (lambda (&rest _) (setq parser-called t) (error "must not parse"))))
      (let ((response (emacs-jupyter-notebook-registry--parse-response raw)))
        (should-not (plist-get response :ok))
        (should (equal (plist-get response :code) "protocol"))
        (should-not parser-called))))
  (should
   (emacs-jupyter-notebook-registry--json-depth-valid-p
    "{\"quoted\":\"[[[\\\"still quoted\\\"]]]\",\"value\":[1]}"))
  (let ((parser-called nil)
        (raw (concat "{\"v\":1,\"ok\":true,\"result\":{\"generation\":"
                     (make-string
                      (1+ emacs-jupyter-notebook-registry--hard-json-number-chars)
                      ?9)
                     ",\"entries\":[]}}")))
    (cl-letf (((symbol-function 'json-read)
               (lambda (&rest _) (setq parser-called t) (error "must not parse"))))
      (let ((response (emacs-jupyter-notebook-registry--parse-response raw)))
        (should-not (plist-get response :ok))
        (should (equal (plist-get response :code) "protocol"))
        (should-not parser-called)))))

(ert-deftest ejn-registry-worker-hostile-structure-is-rejected-before-json-read ()
  "A local worker's valid-sized field flood never reaches recursive JSON parsing."
  (let* ((fields (mapcar (lambda (index) (format "\\\"k%03d\\\":0" index))
                         (number-sequence 0 128)))
         (raw (concat "{\"v\":1,\"ok\":true,\"result\":{"
                      (mapconcat #'identity fields ",") "}}"))
         parser-called)
    (cl-letf (((symbol-function 'json-read)
               (lambda (&rest _) (setq parser-called t) (error "must not parse"))))
      (let ((response (emacs-jupyter-notebook-registry--parse-response raw)))
        (should-not (plist-get response :ok))
        (should (equal (plist-get response :code) "protocol"))
        (should-not parser-called)))))

(provide 'emacs-jupyter-notebook-registry-worker-tests)

;;; emacs-jupyter-notebook-registry-worker-tests.el ends here
