;;; ltex-plus-conn-test.el --- The connection layer, offline -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; What can be asserted about the connection without a server: how a
;; file name becomes a URI and comes back, what the `initialize' request
;; carries, and how the executable is found -- and then, against the fake
;; server in `ltex-plus-fake-server.el', the handshake, the ready queue
;; and the shutdown sequence.  No real server process is ever started.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

;;;; -- URIs -------------------------------------------------------------------

(ert-deftest ltex-plus-conn-test-uri-round-trips-awkward-names ()
  "A file name with spaces and non-ASCII survives the trip to a URI and back.
The buffer the server asks about is looked up by the name that comes
back, so the round trip has to be exact."
  (dolist (path '("/tmp/plain.md" "/tmp/with space/ü.tex" "/tmp/a+b/c#d.org"))
    (should (equal (lsp-ltex-plus--uri-to-path (lsp-ltex-plus--path-to-uri path))
                   path))))

(ert-deftest ltex-plus-conn-test-uri-escapes-the-way-other-clients-do ()
  "The URI form is the one the rest of the LSP world produces."
  (should (equal (lsp-ltex-plus--path-to-uri "/tmp/with space/ü.tex")
                 "file:///tmp/with%20space/%C3%BC.tex")))

(ert-deftest ltex-plus-conn-test-uri-for-a-directory-has-no-trailing-slash ()
  "A directory's URI drops the trailing slash, as a workspace folder should."
  (should (equal (lsp-ltex-plus--path-to-uri "/tmp/project/")
                 "file:///tmp/project")))

;;;; -- The initialize request -------------------------------------------------

(defun ltex-plus-conn-test--params ()
  "Return the `initialize' parameters for a throwaway root."
  (lsp-ltex-plus--initialize-params "/tmp/ltex-plus-conn-test/"))

(ert-deftest ltex-plus-conn-test-initialize-opts-into-the-custom-capability ()
  "The one custom capability the server gates its configuration pulls on.
Without it the server checks a document once and never again after an
edit; see CLAUDE.md, \"Two config-pull requests\"."
  (let ((options (plist-get (ltex-plus-conn-test--params) :initializationOptions)))
    (should (eq t (plist-get (plist-get options :customCapabilities)
                             :workspaceSpecificConfiguration)))))

(ert-deftest ltex-plus-conn-test-initialize-names-this-emacs-and-the-root ()
  "The server learns the client's process id and where it was started."
  (let ((params (ltex-plus-conn-test--params)))
    (should (= (plist-get params :processId) (emacs-pid)))
    (should (equal (plist-get params :rootUri) "file:///tmp/ltex-plus-conn-test"))
    (let ((folders (plist-get params :workspaceFolders)))
      (should (vectorp folders))
      (should (= 1 (length folders)))
      (should (equal (plist-get (aref folders 0) :uri) (plist-get params :rootUri)))
      (should (equal (plist-get (aref folders 0) :name) "ltex-plus-conn-test")))))

(ert-deftest ltex-plus-conn-test-initialize-lets-the-server-pull-configuration ()
  "The workspace capabilities the two configuration pulls rely on are declared."
  (let ((workspace (plist-get (plist-get (ltex-plus-conn-test--params) :capabilities)
                              :workspace)))
    (should (eq t (plist-get workspace :configuration)))
    (should (eq t (plist-get workspace :workspaceFolders)))))

(ert-deftest ltex-plus-conn-test-initialize-carries-the-trace-setting ()
  "`lsp-ltex-plus-trace-server' goes out as the protocol's `trace' field."
  (let ((lsp-ltex-plus-trace-server "messages"))
    (should (equal (plist-get (ltex-plus-conn-test--params) :trace) "messages"))))

;;;; -- Finding the executable -------------------------------------------------

(defmacro ltex-plus-conn-test--with-binary (name &rest body)
  "Run BODY with an executable NAME in a fresh directory bound to `dir'.
`exec-path' holds only that directory, so a real `ltex-ls-plus' on this
machine cannot be found instead."
  (declare (indent 1) (debug t))
  `(let* ((dir (file-name-as-directory (make-temp-file "ltex-plus-bin-" t)))
          (exec-path (list dir)))
     (unwind-protect
         (progn
           (make-directory (file-name-directory (expand-file-name ,name dir)) t)
           (with-temp-file (expand-file-name ,name dir) (insert "#!/bin/sh\n"))
           (set-file-modes (expand-file-name ,name dir) #o755)
           ,@body)
       (delete-directory dir t))))

(ert-deftest ltex-plus-conn-test-executable-is-found-on-exec-path ()
  "The default setting is a bare name, looked up on `exec-path'."
  (ltex-plus-conn-test--with-binary "ltex-ls-plus"
    (let ((lsp-ltex-plus-ls-plus-executable "ltex-ls-plus")
          (lsp-ltex-plus-ltex-ls-path nil))
      (should (equal (lsp-ltex-plus--server-command)
                     (list (expand-file-name "ltex-ls-plus" dir)))))))

(ert-deftest ltex-plus-conn-test-an-absolute-executable-is-used-as-given ()
  "An absolute file name is not searched for anywhere."
  (ltex-plus-conn-test--with-binary "my-ltex"
    (let ((lsp-ltex-plus-ls-plus-executable (expand-file-name "my-ltex" dir))
          (exec-path nil))
      (should (equal (lsp-ltex-plus--server-command)
                     (list (expand-file-name "my-ltex" dir)))))))

(ert-deftest ltex-plus-conn-test-ltex-ls-path-supplies-a-bin-directory ()
  "`lsp-ltex-plus-ltex-ls-path' names the server's root; its `bin' is tried.
This is what the setting means in the VS Code extension, and what a
user who unpacked a release somewhere expects it to do here."
  (ltex-plus-conn-test--with-binary "bin/ltex-ls-plus"
    (let ((lsp-ltex-plus-ls-plus-executable "ltex-ls-plus")
          (lsp-ltex-plus-ltex-ls-path (directory-file-name dir))
          (exec-path nil))
      (should (equal (lsp-ltex-plus--server-command)
                     (list (expand-file-name "bin/ltex-ls-plus" dir)))))))

(ert-deftest ltex-plus-conn-test-a-missing-executable-names-the-setting ()
  "When nothing is found the error says which setting to fix."
  (let ((lsp-ltex-plus-ls-plus-executable "no-such-ltex-ls-plus")
        (lsp-ltex-plus-ltex-ls-path nil)
        (exec-path nil))
    (let ((err (should-error (lsp-ltex-plus--server-command) :type 'user-error)))
      (should (string-match-p "lsp-ltex-plus-ls-plus-executable" (cadr err))))))

(ert-deftest ltex-plus-conn-test-java-path-becomes-java-home ()
  "`lsp-ltex-plus-java-path' reaches the launcher script as `JAVA_HOME'."
  (let ((lsp-ltex-plus-java-path "/opt/java/"))
    (should (member "JAVA_HOME=/opt/java" (lsp-ltex-plus--process-environment))))
  (let ((lsp-ltex-plus-java-path nil))
    (should-not (seq-find (lambda (entry) (string-prefix-p "JAVA_HOME=" entry))
                          (seq-difference (lsp-ltex-plus--process-environment)
                                          process-environment)))))

;;;; -- Session state ----------------------------------------------------------

(ert-deftest ltex-plus-conn-test-no-connection-is-not-live ()
  "With nothing started there is no live connection to reuse."
  (let ((lsp-ltex-plus--connection nil))
    (should-not (lsp-ltex-plus--live-connection))))

(ert-deftest ltex-plus-conn-test-a-remote-directory-is-not-a-root ()
  "The server runs locally, so a remote directory cannot be its root."
  (should (equal (lsp-ltex-plus--local-directory "/ssh:host:/home/me/")
                 temporary-file-directory))
  (should (equal (lsp-ltex-plus--local-directory temporary-file-directory)
                 (file-name-as-directory (expand-file-name temporary-file-directory)))))

;;;; -- The handshake, against the fake ---------------------------------------

(ert-deftest ltex-plus-conn-test-handshake-completes ()
  "The client initializes, records what the server said, and says `initialized'."
  (ltex-plus-fake-with-connection
    (let ((conn (ltex-plus-fake-ready-connection)))
      (should (equal (plist-get (lsp-ltex-plus--connection-server-info conn) :name)
                     "ltex-ls-plus"))
      (should (= 1 (plist-get (lsp-ltex-plus--connection-capabilities conn)
                              :textDocumentSync)))
      (should (= 1 (length (ltex-plus-fake-received 'initialized))))
      ;; What actually went over the wire carried the opt-in.
      (let ((sent (car (ltex-plus-fake-received 'initialize))))
        (should (eq t (plist-get (plist-get (plist-get sent :initializationOptions)
                                            :customCapabilities)
                                 :workspaceSpecificConfiguration)))))))

(ert-deftest ltex-plus-conn-test-work-waits-for-the-handshake ()
  "A thunk queued before the reply runs after it; one queued after runs at once.
Queued thunks keep their order, and the after-initialize hook runs
before any of them, so configuration is pushed before documents open."
  (ltex-plus-fake-with-connection
    (let ((order nil))
      (let ((lsp-ltex-plus--after-initialize-functions
             (list (lambda (_conn) (push 'hook order)))))
        (let ((conn (lsp-ltex-plus--ensure-connection)))
          (lsp-ltex-plus--when-ready conn (lambda () (push 'first order)))
          (lsp-ltex-plus--when-ready conn (lambda () (push 'second order)))
          (should-not order)
          (ltex-plus-fake-wait-for (lambda () (lsp-ltex-plus--connection-ready conn)))
          (should (equal (reverse order) '(hook first second)))
          (lsp-ltex-plus--when-ready conn (lambda () (push 'third order)))
          (should (eq (car order) 'third)))))))

(ert-deftest ltex-plus-conn-test-the-connection-is-reused-while-it-lives ()
  "A second buffer asking for the server gets the same connection."
  (ltex-plus-fake-with-connection
    (let ((conn (ltex-plus-fake-ready-connection)))
      (with-temp-buffer
        (should (eq (lsp-ltex-plus--ensure-connection) conn))))))

(ert-deftest ltex-plus-conn-test-shutdown-follows-the-protocol ()
  "Stopping sends `shutdown' then `exit', ends the process, and forgets it."
  (ltex-plus-fake-with-connection
    (let ((conn (ltex-plus-fake-ready-connection))
          (closed nil))
      (let ((lsp-ltex-plus--after-shutdown-functions
             (list (lambda (c) (setq closed c)))))
        (lsp-ltex-plus--shutdown-connection)
        (should (= 1 (length (ltex-plus-fake-received 'shutdown))))
        (should (= 1 (length (ltex-plus-fake-received 'exit))))
        (should-not (jsonrpc-running-p conn))
        (should-not (lsp-ltex-plus--live-connection))
        (should (eq closed conn))))))

(ert-deftest ltex-plus-conn-test-a-dead-server-is-replaced ()
  "After the process ends, the next request for a connection starts a new one."
  (ltex-plus-fake-with-connection
    (let ((first (ltex-plus-fake-ready-connection)))
      (lsp-ltex-plus--shutdown-connection)
      (ltex-plus-fake-start)
      (let ((second (ltex-plus-fake-ready-connection)))
        (should-not (eq first second))
        (should (lsp-ltex-plus--connection-ready second))))))

(ert-deftest ltex-plus-conn-test-an-unknown-request-is-refused-properly ()
  "A request this client does not implement gets the protocol's own refusal.
Method-not-found is -32601; an internal error would tell the server the
client is broken rather than merely limited."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (let ((err (should-error (jsonrpc-request ltex-plus-fake-peer 'ltex/noSuchThing nil
                                              :timeout 2)
                             :type 'jsonrpc-error)))
      (should (= -32601 (alist-get 'jsonrpc-error-code (cdr err)))))))

(ert-deftest ltex-plus-conn-test-capability-registrations-are-accepted ()
  "The bookkeeping requests a server may send are answered, not refused."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (should-not (jsonrpc-request ltex-plus-fake-peer 'client/registerCapability
                                 '(:registrations []) :timeout 2))))

(ert-deftest ltex-plus-conn-test-show-message-reaches-the-user ()
  "`window/showMessage' is shown; `window/logMessage' is only logged."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (let ((shown nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
        (jsonrpc-notify ltex-plus-fake-peer 'window/showMessage
                        '(:type 3 :message "Hello from the server"))
        (jsonrpc-notify ltex-plus-fake-peer 'window/logMessage
                        '(:type 3 :message "Only for the log"))
        (ltex-plus-fake-wait-for (lambda () shown)))
      (should (equal shown '("[ltex-ls-plus] Hello from the server"))))))

;;;; -- Documents ---------------------------------------------------------------

(defmacro ltex-plus-conn-test--with-open-file (var contents &rest body)
  "Run BODY with VAR bound to a buffer visiting a `.rst' file of CONTENTS.
The buffer is in `rst-mode', a built-in mode the table maps to
\"restructuredtext\", so the language id is one the real server would
receive.  Not `.tex': visiting one runs `latexenc' coding detection,
which fails in a batch Emacs."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-test-with-project (list (cons "note.rst" ,contents))
     (let ((,var (ltex-plus-test-visit (project-file "note.rst"))))
       (with-current-buffer ,var (rst-mode))
       ,@body)))

(ert-deftest ltex-plus-conn-test-opening-sends-the-document ()
  "`didOpen' carries the URI, the language id, version 1 and the whole text."
  (ltex-plus-fake-with-connection
    (ltex-plus-conn-test--with-open-file buffer "Hello teh world.\n"
      (lsp-ltex-plus--open-document buffer)
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (let* ((sent (plist-get (car (ltex-plus-fake-received 'textDocument/didOpen))
                              :textDocument))
             (uri (plist-get sent :uri)))
        (should (equal uri (lsp-ltex-plus--path-to-uri (buffer-file-name buffer))))
        (should (equal (plist-get sent :languageId) "restructuredtext"))
        (should (= 1 (plist-get sent :version)))
        (should (equal (plist-get sent :text) "Hello teh world.\n"))
        (should (eq (lsp-ltex-plus--buffer-for-uri uri) buffer))
        (should (lsp-ltex-plus--document-open-p buffer))))))

(ert-deftest ltex-plus-conn-test-opening-waits-for-the-handshake ()
  "A buffer opened while the server starts is sent after `initialized'."
  (ltex-plus-fake-with-connection
    (ltex-plus-conn-test--with-open-file buffer "Text.\n"
      (lsp-ltex-plus--open-document buffer)
      (should-not (lsp-ltex-plus--document-open-p buffer))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (should (equal (mapcar #'car (reverse ltex-plus-fake-received))
                     '(initialize initialized textDocument/didOpen))))))

(ert-deftest ltex-plus-conn-test-opening-twice-sends-once ()
  "A second open of the same buffer is a no-op."
  (ltex-plus-fake-with-connection
    (ltex-plus-conn-test--with-open-file buffer "Text.\n"
      (lsp-ltex-plus--open-document buffer)
      (lsp-ltex-plus--open-document buffer)
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (lsp-ltex-plus--open-document buffer)
      (accept-process-output nil 0.2)
      (should (= 1 (length (ltex-plus-fake-received 'textDocument/didOpen)))))))

(ert-deftest ltex-plus-conn-test-killing-the-buffer-closes-the-document ()
  "Killing an open buffer sends `didClose' and drops it from the table."
  (ltex-plus-fake-with-connection
    (ltex-plus-conn-test--with-open-file buffer "Text.\n"
      (lsp-ltex-plus--open-document buffer)
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (let ((uri (lsp-ltex-plus--buffer-uri buffer)))
        (kill-buffer buffer)
        (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didClose)))
        (should (equal (plist-get (plist-get (car (ltex-plus-fake-received
                                                   'textDocument/didClose))
                                             :textDocument)
                                  :uri)
                       uri))
        (should-not (lsp-ltex-plus--buffer-for-uri uri))))))

(ert-deftest ltex-plus-conn-test-closing-an-unopened-buffer-is-harmless ()
  "Closing a buffer the server never heard of sends nothing."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (with-temp-buffer
      (lsp-ltex-plus--close-document)
      (accept-process-output nil 0.1)
      (should-not (ltex-plus-fake-received 'textDocument/didClose)))))

(ert-deftest ltex-plus-conn-test-a-dead-server-forgets-its-documents ()
  "When the process ends, no buffer is left believing it is open."
  (ltex-plus-fake-with-connection
    (ltex-plus-conn-test--with-open-file buffer "Text.\n"
      (lsp-ltex-plus--open-document buffer)
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (let ((conn lsp-ltex-plus--connection))
        (ltex-plus-fake-stop)
        (ltex-plus-fake-wait-for (lambda () (not (jsonrpc-running-p conn)))))
      (should-not (lsp-ltex-plus--document-open-p buffer))
      (should (zerop (hash-table-count lsp-ltex-plus--documents))))))

(ert-deftest ltex-plus-conn-test-language-id-comes-from-the-table ()
  "A listed mode sends its id; an unlisted one is sent as plain text."
  (with-temp-buffer
    (latex-mode)
    (should (equal (lsp-ltex-plus--language-id) "latex")))
  (with-temp-buffer
    (fundamental-mode)
    (should (equal (lsp-ltex-plus--language-id) "plaintext"))))

;;;; -- Edits ------------------------------------------------------------------

(defmacro ltex-plus-conn-test--with-open-document (var contents &rest body)
  "Run BODY with VAR bound to a buffer of CONTENTS that is open on the fake.
Waits for the `didOpen' so BODY starts from a quiet wire, with a short
change delay in force."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-fake-with-connection
     (ltex-plus-conn-test--with-open-file ,var ,contents
       (let ((lsp-ltex-plus-change-delay 0.1))
         (lsp-ltex-plus--open-document ,var)
         (ltex-plus-fake-wait-for
          (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
         ,@body))))

(ert-deftest ltex-plus-conn-test-a-burst-of-edits-is-sent-once ()
  "Edits inside the delay coalesce into one full-text `didChange'.
The version goes up by one, and the text sent is the buffer as it is
when the burst ends, not as it was at the first keystroke."
  (ltex-plus-conn-test--with-open-document buffer "One.\n"
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "Two.")
      (insert " Three.")
      (insert "\n"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didChange)))
    (accept-process-output nil 0.3)
    (let ((sent (ltex-plus-fake-received 'textDocument/didChange)))
      (should (= 1 (length sent)))
      (should (= 2 (plist-get (plist-get (car sent) :textDocument) :version)))
      (should (equal (plist-get (aref (plist-get (car sent) :contentChanges) 0) :text)
                     "One.\nTwo. Three.\n")))))

(ert-deftest ltex-plus-conn-test-each-pause-bumps-the-version ()
  "Two bursts separated by a pause are two sends, versions 2 and 3."
  (ltex-plus-conn-test--with-open-document buffer "One.\n"
    (with-current-buffer buffer (goto-char (point-max)) (insert "Two.\n"))
    (ltex-plus-fake-wait-for (lambda () (= 1 (length (ltex-plus-fake-received
                                                       'textDocument/didChange)))))
    (with-current-buffer buffer (goto-char (point-max)) (insert "Three.\n"))
    (ltex-plus-fake-wait-for (lambda () (= 2 (length (ltex-plus-fake-received
                                                       'textDocument/didChange)))))
    (should (equal (mapcar (lambda (p) (plist-get (plist-get p :textDocument) :version))
                           (ltex-plus-fake-received 'textDocument/didChange))
                   '(2 3)))))

(ert-deftest ltex-plus-conn-test-saving-sends-pending-edits-then-didsave ()
  "A save flushes what is pending first, so the server checks the saved text."
  (ltex-plus-conn-test--with-open-document buffer "One.\n"
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "Two.\n")
      (let ((inhibit-message t)) (save-buffer)))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didSave)))
    (let ((methods (mapcar #'car (reverse ltex-plus-fake-received))))
      (should (equal (seq-filter (lambda (m) (memq m '(textDocument/didChange
                                                      textDocument/didSave)))
                                 methods)
                     '(textDocument/didChange textDocument/didSave))))))

(ert-deftest ltex-plus-conn-test-closing-drops-a-pending-edit ()
  "Killing the buffer inside the delay sends `didClose' and no `didChange'."
  (ltex-plus-conn-test--with-open-document buffer "One.\n"
    (with-current-buffer buffer (goto-char (point-max)) (insert "Two.\n"))
    (kill-buffer buffer)
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didClose)))
    (accept-process-output nil 0.3)
    (should-not (ltex-plus-fake-received 'textDocument/didChange))))

(ert-deftest ltex-plus-conn-test-the-fake-rechecks-what-it-was-sent ()
  "The fake publishes for the text it holds, which is the full text sent.
This pins the fixture the diagnostics tests will rely on."
  (ltex-plus-conn-test--with-open-document buffer "Fine.\n"
    (with-current-buffer buffer (goto-char (point-max)) (insert "Now teh end.\n"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didChange)))
    (should (equal (cdr (assoc (lsp-ltex-plus--buffer-uri buffer) ltex-plus-fake-documents))
                   (cons 2 "Fine.\nNow teh end.\n")))
    (should (= 1 (length (ltex-plus-fake-diagnostics "Fine.\nNow teh end.\n"))))))

(provide 'ltex-plus-conn-test)
;;; ltex-plus-conn-test.el ends here
