;;; ltex-plus-conn-test.el --- The connection layer, offline -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; What can be asserted about the connection without a server: how a
;; file name becomes a URI and comes back, what the `initialize' request
;; carries, and how the executable is found.  Nothing here starts a
;; process; the handshake itself is exercised against the fake server.

;;; Code:

(require 'ltex-plus-test-helper)

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

(provide 'ltex-plus-conn-test)
;;; ltex-plus-conn-test.el ends here
