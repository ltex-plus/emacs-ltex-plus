;;; ltex-plus-live-test.el --- Tests against a real ltex-ls-plus -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Opt-in: `make test-live', or LTEX_PLUS_LIVE=1.  Without it, and on any
;; machine with no `ltex-ls-plus', every test here reports as skipped --
;; visible, so nobody forgets they exist.
;;
;; These start a real server and assert on what it actually publishes.
;; The offline suite already covers the client's side of every exchange
;; against a fake; this is the only place the other side is checked
;; against the server rather than against this package's reading of the
;; protocol.  The assertion is not "we sent the right JSON" but "the
;; word stopped being flagged".
;;
;; Every test works from any server state: the first buffer to need a
;; server starts one, so a test that stops the server costs the next one
;; a start and nothing more.

;;; Code:

(require 'ltex-plus-live-helper)

(defmacro ltex-plus-live-deftest (name docstring &rest body)
  "Define a live test NAME, skipped unless a server is available."
  (declare (indent 2) (doc-string 2) (debug (symbolp stringp body)))
  `(ert-deftest ,name ()
     ,docstring
     (skip-unless (or (ltex-plus-live-p) (ert-skip (ltex-plus-live-reason))))
     ,@body))

(defun ltex-plus-live-test--setup ()
  "Prepare a batch session and empty every list before a test."
  (ltex-plus-live-configure)
  (ltex-plus-test-reset))

;;;; -- The pipeline end to end -------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-a-real-error-is-flagged
    "The server checks a document and the client receives the result.
If this fails nothing else here means anything: it is the handshake, the
configuration pull, `didOpen', and `publishDiagnostics' in one."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "basic.md" "He go to school.\n"))))
    (should (ltex-plus-live-diagnostics buffer))
    (should (seq-some (lambda (message) (string-match-p "pronoun" message))
                      (ltex-plus-live-messages buffer)))))

(ltex-plus-live-deftest ltex-plus-live-test-clean-text-is-not-flagged
    "A correct sentence produces nothing.
The other half of the test above: a client that reported diagnostics for
everything would pass that one too."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "clean.md" "He goes to school.\n"))))
    (should-not (ltex-plus-live-diagnostics buffer))))

(ltex-plus-live-deftest ltex-plus-live-test-server-info-matches-the-binary
    "The version the client recorded is the one the server actually is.
Read straight from the `initialize' result now, with nothing between
the client and the protocol to be missing."
  (ltex-plus-live-test--setup)
  (ltex-plus-live-open (ltex-plus-live-write "info.md" "Text.\n"))
  (let ((info (lsp-ltex-plus--connection-server-info (lsp-ltex-plus--live-connection))))
    (should (equal (plist-get info :name) "ltex-ls-plus"))
    (should (equal (plist-get info :version) (ltex-plus-live-server-version)))))

(ltex-plus-live-deftest ltex-plus-live-test-the-server-meets-the-floor
    "The server under test is new enough for the package's assumptions.
Keeps the live results honest about what they were run against."
  (should (ltex-plus-live-version-at-least-p (ltex-plus-live-server-version)
                                             ltex-plus-live-server-floor)))

;;;; -- Editing -----------------------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-an-edit-is-rechecked
    "Editing the buffer produces fresh diagnostics.
This is what the custom-capability opt-in buys: without it the server
skips both configuration pulls, checks the document once, and then
publishes nothing further as the user types."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "edit.md" "He go to school.\n"))))
    (with-current-buffer buffer
      (should (ltex-plus-live-diagnostics))
      (ltex-plus-live-after-publish
       (lambda () (erase-buffer) (insert "He goes to school.\n"))
       "the re-check after an edit")
      (should-not (ltex-plus-live-diagnostics)))))

(ltex-plus-live-deftest ltex-plus-live-test-the-server-pulls-configuration-per-check
    "The real server asks for configuration before every check, both ways.
The fake was written to do this because the real one was seen to; this
keeps the two in step.  Both pulls carry the document's URI, which is
what answering per document depends on."
  (ltex-plus-live-test--setup)
  (let ((asked nil))
    (advice-add 'lsp-ltex-plus--handle-request :before
                (lambda (_conn method params) (push (cons method params) asked))
                '((name . ltex-plus-live-watch)))
    (unwind-protect
        (let ((buffer (ltex-plus-live-open
                       (ltex-plus-live-write "pulls.md" "He go to school.\n"))))
          (let ((uri (lsp-ltex-plus--buffer-uri buffer)))
            (dolist (method '(workspace/configuration ltex/workspaceSpecificConfiguration))
              (let ((pull (seq-find (lambda (entry) (eq (car entry) method)) asked)))
                (should pull)
                (should (equal (plist-get (aref (plist-get (cdr pull) :items) 0) :scopeUri)
                               uri))))))
      (advice-remove 'lsp-ltex-plus--handle-request 'ltex-plus-live-watch))))

;;;; -- Code actions -------------------------------------------------------------

(defun ltex-plus-live-test--actions-at (buffer point)
  "Return the expanded code actions the menu would offer at POINT in BUFFER."
  (with-current-buffer buffer
    (goto-char point)
    (lsp-ltex-plus--expand-suggestions (lsp-ltex-plus--request-code-actions point point))))

(ltex-plus-live-deftest ltex-plus-live-test-a-suggestion-can-be-accepted
    "The server's replacement for a grammar error, applied, fixes the text.
The edit arrives as documentChanges on the version the server checked;
applying it and seeing the underline go is the whole code-action path
against the real thing."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "accept.md" "He go to school.\n"))))
    (let* ((actions (ltex-plus-live-test--actions-at buffer 5))
           (fix (seq-find (lambda (action) (equal (plist-get action :title) "Use 'goes'"))
                          actions)))
      (should fix)
      (with-current-buffer buffer
        (ltex-plus-live-after-publish
         (lambda () (lsp-ltex-plus--run-action fix))
         "the re-check after accepting the suggestion")
        (should (equal (buffer-string) "He goes to school.\n"))
        (should-not (ltex-plus-live-diagnostics))))))

(ltex-plus-live-deftest ltex-plus-live-test-an-accepted-word-stops-being-flagged
    "Adding a word to the dictionary silences it on the next check.
The package's central mechanism, asserted at the only level that
matters.  Everything in between -- writing the file, rebuilding the
merged view, pushing to the server, answering the pull it makes in
reply -- is covered offline one link at a time; this is the chain."
  (ltex-plus-live-test--setup)
  (let* ((word "Zorbulax")
         (buffer (ltex-plus-live-open
                  (ltex-plus-live-write
                   "dictionary.md" (format "The %s is here.\n" word))))
         (lsp-ltex-plus-save-additions-to 'globally-defined))
    (with-current-buffer buffer
      (should (ltex-plus-live-flagged-p word))
      (let* ((actions (ltex-plus-live-test--actions-at buffer 6))
             (add (seq-find (lambda (action)
                              (equal (plist-get (plist-get action :command) :command)
                                     "_ltex.addToDictionary"))
                            actions)))
        (should add)
        (ltex-plus-live-after-publish
         (lambda () (lsp-ltex-plus--run-action add))
         "the re-check after the word was accepted"))
      (should-not (ltex-plus-live-flagged-p word))
      (should (equal (ltex-plus-test-words
                      (ltex-plus-test-read-file lsp-ltex-plus-dictionary-file))
                     (list word))))))

(ltex-plus-live-deftest ltex-plus-live-test-the-project-variant-writes-only-there
    "In a project with its own dictionary the offer is doubled and each writes once.
The split and the marker are decided offline; that the real server's
suggestion carries what the split needs, and that the project file it
lands in is what the next check reads, is only visible here."
  (ltex-plus-live-test--setup)
  (let* ((word "Grimblewort")
         (root (file-name-as-directory
                (expand-file-name "split" (ltex-plus-live-root))))
         (project-file (expand-file-name ".ltex/words.eld" root))
         (lsp-ltex-plus-save-additions-to 'either-allowing-user-choice))
    (ltex-plus-live-write
     ".dir-locals.el"
     "((nil . ((lsp-ltex-plus-project-dictionary-file . \".ltex/words.eld\"))))"
     root)
    (let ((buffer (ltex-plus-live-open
                   (ltex-plus-live-write "doc.md" (format "A %s appeared.\n" word) root))))
      (with-current-buffer buffer
        (should (ltex-plus-live-flagged-p word))
        (let* ((actions (ltex-plus-live-test--actions-at buffer 4))
               (adds (seq-filter (lambda (action)
                                   (equal (plist-get (plist-get action :command) :command)
                                          "_ltex.addToDictionary"))
                                 actions)))
          (should (equal (ltex-plus-test-titles adds)
                         (list (format "Add '%s' to project dictionary" word)
                               (format "Add '%s' to global dictionary" word))))
          (ltex-plus-live-after-publish
           (lambda () (lsp-ltex-plus--run-action (car adds)))
           "the re-check after the project variant was accepted"))
        (should-not (ltex-plus-live-flagged-p word))
        (should (equal (ltex-plus-test-words (ltex-plus-test-read-file project-file))
                       (list word)))
        (should-not (ltex-plus-test-words
                     (ltex-plus-test-read-file lsp-ltex-plus-dictionary-file)))))))

;;;; -- Per-document settings ---------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-each-project-is-checked-in-its-language
    "Two projects open at once are each checked in their own language.
The reason the configuration pulls are answered per `scopeUri' rather
than from whichever buffer is current.  \"Widerspiegelung\" is a German
word and an English misspelling, so the same text gives opposite answers
in the two projects -- which it cannot do if one project's
`.dir-locals.el' is answering for the other's documents."
  (ltex-plus-live-test--setup)
  (let* ((german (file-name-as-directory
                  (expand-file-name "german" (ltex-plus-live-root))))
         (english (file-name-as-directory
                   (expand-file-name "english" (ltex-plus-live-root))))
         (text "Die Widerspiegelung ist hier.\n"))
    (ltex-plus-live-write ".dir-locals.el"
                          "((nil . ((lsp-ltex-plus-language . \"de-DE\"))))"
                          german)
    (let ((in-german (ltex-plus-live-open
                      (ltex-plus-live-write "doc.md" text german)))
          (in-english (ltex-plus-live-open
                       (ltex-plus-live-write "doc.md" text english))))
      (should (equal (buffer-local-value 'lsp-ltex-plus-language in-german)
                     "de-DE"))
      (should-not (ltex-plus-live-flagged-p "Widerspiegelung" in-german))
      (should (ltex-plus-live-flagged-p "Widerspiegelung" in-english)))))

(ltex-plus-live-deftest ltex-plus-live-test-a-project-dictionary-is-honoured
    "A project's own word list is accepted in that project and nowhere else.
Read through `ltex/workspaceSpecificConfiguration', which the server
prefers over the standard reply for exactly these four settings -- so
this is the only path that proves the custom handler is the one being
listened to."
  (ltex-plus-live-test--setup)
  (let* ((word "Grumbleweed")
         (inside (file-name-as-directory
                  (expand-file-name "with-dictionary" (ltex-plus-live-root))))
         (outside (file-name-as-directory
                   (expand-file-name "without" (ltex-plus-live-root))))
         (text (format "The %s grows here.\n" word)))
    (ltex-plus-live-write
     ".dir-locals.el"
     "((nil . ((lsp-ltex-plus-project-dictionary-file . \".ltex/words.eld\"))))"
     inside)
    (ltex-plus-live-write ".ltex/words.eld" (format "(:en-US [\"%s\"])" word) inside)
    (let ((in-project (ltex-plus-live-open
                       (ltex-plus-live-write "doc.md" text inside)))
          (elsewhere (ltex-plus-live-open
                      (ltex-plus-live-write "doc.md" text outside))))
      (should-not (ltex-plus-live-flagged-p word in-project))
      (should (ltex-plus-live-flagged-p word elsewhere)))))

(ltex-plus-live-deftest ltex-plus-live-test-a-global-word-is-still-accepted-in-a-project
    "The global list extends a project's list; the project never shadows it.
A word in the global dictionary stays accepted inside a project that
keeps a dictionary of its own, since the two are merged."
  (ltex-plus-live-test--setup)
  (let* ((word "Snorfblatt")
         (inside (file-name-as-directory
                  (expand-file-name "merged" (ltex-plus-live-root))))
         (text (format "The %s is global.\n" word)))
    (lsp-ltex-plus--save-plist (list :en-US (vector word)) lsp-ltex-plus-dictionary-file)
    (lsp-ltex-plus--load-external-settings)
    (ltex-plus-live-write
     ".dir-locals.el"
     "((nil . ((lsp-ltex-plus-project-dictionary-file . \".ltex/words.eld\"))))"
     inside)
    (ltex-plus-live-write ".ltex/words.eld" "(:en-US [\"Unrelated\"])" inside)
    (let ((buffer (ltex-plus-live-open (ltex-plus-live-write "doc.md" text inside))))
      (should-not (ltex-plus-live-flagged-p word buffer)))))

;;;; -- The reload command ------------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-reload-reaches-the-server
    "`lsp-ltex-plus-reload-settings' makes a hand-edited file take effect.
The scenario is the documented one: edit the global file by hand, run
the command, expect the word to stop being flagged on the next check."
  (ltex-plus-live-test--setup)
  (let* ((word "Flimberry")
         (buffer (ltex-plus-live-open
                  (ltex-plus-live-write
                   "reload.md" (format "A %s appeared.\n" word)))))
    (with-current-buffer buffer
      (should (ltex-plus-live-flagged-p word))
      (lsp-ltex-plus--save-plist (list :en-US (vector word))
                                 lsp-ltex-plus-dictionary-file)
      (ltex-plus-live-after-publish
       (lambda () (let ((inhibit-message t)) (lsp-ltex-plus-reload-settings)))
       "the re-check after reloading settings")
      (should-not (ltex-plus-live-flagged-p word)))))

;;;; -- One server for the session ----------------------------------------------

(defun ltex-plus-live-test--server-processes ()
  "Return the live processes running the server binary.
By command rather than by name: the pipe Emacs creates for the server's
standard error is a process too, named after the server."
  (seq-filter (lambda (process)
                (and (process-command process)
                     (string-match-p "ltex-ls-plus" (car (process-command process)))))
              (process-list)))

(ltex-plus-live-deftest ltex-plus-live-test-one-server-serves-every-root
    "A document from a second project joins the running server.
Two JVMs check documents exactly as correctly as one, so nothing else
here would notice a second server being started; this is the claim on
its own."
  (ltex-plus-live-test--setup)
  (ltex-plus-live-open (ltex-plus-live-write "first/doc.md" "Text.\n"))
  (let ((first (lsp-ltex-plus--live-connection)))
    (ltex-plus-live-open (ltex-plus-live-write "second/doc.md" "Text.\n"))
    (should (eq first (lsp-ltex-plus--live-connection)))
    (should (= 1 (length (ltex-plus-live-test--server-processes))))))

;;;; -- Turning the mode off ----------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-teardown-clears-and-keeps-the-server
    "Switching the mode off drops the diagnostics and leaves the JVM up.
Disabling the mode in one buffer must not stop the server the others
are using; and the mode is re-entrant, so turning it back on checks
again."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "teardown.md" "He go to school.\n"))))
    (with-current-buffer buffer
      (should (ltex-plus-live-diagnostics))
      (lsp-ltex-plus-mode -1)
      (should-not lsp-ltex-plus-mode)
      (should-not (ltex-plus-live-diagnostics)))
    (should (lsp-ltex-plus--live-connection))
    (with-current-buffer buffer
      (ltex-plus-live-after-publish
       (lambda () (lsp-ltex-plus-mode 1))
       "the check after re-enabling the mode")
      (should (ltex-plus-live-diagnostics)))))

(ltex-plus-live-deftest ltex-plus-live-test-the-shutdown-command-stops-the-server
    "`lsp-ltex-plus-shutdown-server' ends the process and the mode with it.
The protocol's two steps and then the exit; a server that ignored them
would be deleted after a grace period and show up here as a warning."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "shutdown.md" "Text.\n"))))
    (let ((inhibit-message t))
      (lsp-ltex-plus-shutdown-server))
    (should-not (lsp-ltex-plus--live-connection))
    (should-not (buffer-local-value 'lsp-ltex-plus-mode buffer))
    (ltex-plus-live-until
     (lambda () (null (ltex-plus-live-test--server-processes)))
     "the server process to end")))

;; Shut the server down once, however the run ended.
(add-hook 'kill-emacs-hook #'ltex-plus-live-teardown)

(provide 'ltex-plus-live-test)
;;; ltex-plus-live-test.el ends here
