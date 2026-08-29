;;; ltex-plus-live-test.el --- Tests against a real ltex-ls-plus -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Opt-in: `make test-live', or LTEX_PLUS_LIVE=1.  Without it, and on any
;; machine with no `ltex-ls-plus' on PATH, every test here reports as
;; skipped -- visible, so nobody forgets they exist.
;;
;; These start a real server and assert on what it actually publishes.
;; That is worth the five seconds for two reasons.  It covers the paths a
;; mock cannot reach without becoming a second implementation of
;; `lsp-mode': the mode's startup and teardown, `--rejoin-workspace', the
;; reload broadcast.  And it is the only place the wire contract is
;; checked against the server rather than against this package's reading
;; of the protocol -- the assertion is not "we sent the right JSON" but
;; "the word stopped being flagged".

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
  "Prepare a batch session and empty every list before the first test."
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
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "clean.md" "He goes to school.\n"))))
    (should-not (ltex-plus-live-diagnostics buffer))))

(ltex-plus-live-deftest ltex-plus-live-test-server-info-matches-the-binary
    "The version the client captured is the one the server actually is.
`--capture-server-info' reads it through accessors that come from an
`lsp-mode' pull request which is approved but still unmerged, so it is
guarded with `fboundp'.  A guard like that is exactly what a test must
not be written around: wrapping the assertions in the same `fboundp'
would make this pass by asserting nothing wherever the plumbing is
missing, which is the case it exists to detect.  So the expected value
comes from the binary instead, and an `lsp-mode' without the accessors
is reported as a skip rather than as a pass."
  (ltex-plus-live-open (ltex-plus-live-write "info.md" "Text.\n"))
  (unless (and (fboundp 'lsp-workspace-server-name)
               (fboundp 'lsp-workspace-server-version))
    (ert-skip (concat "this lsp-mode has no serverInfo accessors, so the "
                      "package cannot know what it is connected to")))
  (should (equal lsp-ltex-plus--server-name "ltex-ls-plus"))
  (should (equal lsp-ltex-plus--server-version (ltex-plus-live-server-version))))

(ltex-plus-live-deftest ltex-plus-live-test-the-server-meets-the-floor
    "The server under test is new enough for the package's assumptions.
Nothing in the package itself enforces this -- the README calls 18.7
recommended and the client never looks -- so an older server shows up as
features quietly not working rather than as a message.  Asserting it
here at least keeps the live results honest about what they were run
against."
  (should (ltex-plus-live-version-at-least-p (ltex-plus-live-server-version)
                                             ltex-plus-live-server-floor)))

;;;; -- Editing -----------------------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-an-edit-is-rechecked
    "Editing the buffer produces fresh diagnostics.
This is what the custom-capability opt-in buys: without it the server
skips both configuration pulls, checks the document once from the
startup push, and then publishes nothing further as the user types."
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "edit.md" "He go to school.\n"))))
    (with-current-buffer buffer
      (should (ltex-plus-live-diagnostics))
      (ltex-plus-live-after-publish
       (lambda () (erase-buffer) (insert "He goes to school.\n"))
       "the re-check after an edit")
      (should-not (ltex-plus-live-diagnostics)))))

;;;; -- Accepting a suggestion --------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-an-accepted-word-stops-being-flagged
    "Adding a word to the dictionary silences it on the next check.
The package's central mechanism, asserted at the only level that
matters.  Everything in between -- writing the file, rebuilding the
merged view, notifying the server, answering the pull it makes in reply
-- is covered by unit tests one link at a time; this is the chain."
  (ltex-plus-live-test--setup)
  (let* ((word "Zorbulax")
         (buffer (ltex-plus-live-open
                  (ltex-plus-live-write
                   "dictionary.md" (format "The %s is here.\n" word)))))
    (with-current-buffer buffer
      (should (ltex-plus-live-flagged-p word))
      (ltex-plus-live-after-publish
       (lambda ()
         (ltex-plus-test-accept
          (ltex-plus-test-suggestion "_ltex.addToDictionary"
                                     (format "Add '%s'" word)
                                     :words (list word))))
       "the re-check after the word was accepted")
      (should-not (ltex-plus-live-flagged-p word)))))

;;;; -- Per-document settings ---------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-each-project-is-checked-in-its-language
    "Two projects open at once are each checked in their own language.
The reason the configuration pulls are answered per `scopeUri' rather
than from whichever buffer lsp-mode reaches first.  \"Widerspiegelung\"
is a German word and an English misspelling, so the same text gives
opposite answers in the two projects -- which it cannot do if one
project's `.dir-locals.el' is answering for the other's documents."
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

;;;; -- Buffers with no file ----------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-a-fileless-buffer-is-checked
    "A buffer visiting no file is checked under its synthetic URI.
`--rejoin-workspace' attaching it to the shared root, the pass-through
virtual buffer, and diagnostics filed under a key that routes back to
the buffer -- none of which a mock can tell apart from a buffer lsp-mode
has quietly filtered out of the workspace."
  (ltex-plus-live-test--setup)
  ;; One file-backed document first, so the server is already running.
  (ltex-plus-live-open (ltex-plus-live-write "anchor.md" "Text.\n"))
  (let ((buffer (generate-new-buffer "*ltex-plus-live-scratch*")))
    (push buffer ltex-plus-live--buffers)
    (with-current-buffer buffer
      (text-mode)
      (insert "He go to school.\n")
      (ltex-plus-live-after-publish
       (lambda () (lsp-ltex-plus-mode 1))
       "the check of a file-less buffer")
      (should lsp-ltex-plus--fileless-uri)
      (should (ltex-plus-live-diagnostics)))))

(ltex-plus-live-deftest ltex-plus-live-test-one-server-serves-every-root
    "A second root joins the running server instead of starting another.
That is the whole promise of `lsp-ltex-plus-multi-root', and its default
is on.  It is also the only claim here that nothing else would notice
being broken: two JVMs check documents exactly as correctly as one, so
every other test in this file passed while the package was quietly
starting a second server for `*scratch*' -- half a gigabyte of Java, for
a buffer with no file.

A file-less buffer is the sharp case because it anchors at
`temporary-file-directory', which is nobody's project root, so the
per-root lookup in `--rejoin-workspace' can never hit.  Two ordinary
projects reach it too."
  (ltex-plus-live-test--setup)
  (ltex-plus-live-open (ltex-plus-live-write "first/doc.md" "Text.\n"))
  (ltex-plus-live-open (ltex-plus-live-write "second/doc.md" "Text.\n"))
  (let ((buffer (generate-new-buffer "*ltex-plus-live-second-server*")))
    (push buffer ltex-plus-live--buffers)
    (with-current-buffer buffer
      (text-mode)
      (insert "He go to school.\n")
      (ltex-plus-live-after-publish (lambda () (lsp-ltex-plus-mode 1))
                                    "the check of a file-less buffer")))
  (should (= 1 (seq-count (lambda (workspace)
                            (eq 'ltex-ls-plus (lsp--workspace-server-id workspace)))
                          (lsp--session-workspaces (lsp-session))))))

;;;; -- Turning the mode off ----------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-teardown-clears-and-keeps-the-server
    "Switching the mode off drops the diagnostics and leaves the JVM up.
`lsp-keep-workspace-alive' is what makes this safe for file-less
buffers: disabling the mode in one scratch buffer must not tear down the
server the others are using."
  (ltex-plus-live-test--setup)
  (let ((buffer (ltex-plus-live-open
                 (ltex-plus-live-write "teardown.md" "He go to school.\n"))))
    (with-current-buffer buffer
      (should (ltex-plus-live-diagnostics))
      (lsp-ltex-plus-mode -1)
      (should-not lsp-ltex-plus-mode)
      (should-not (ltex-plus-live-diagnostics)))
    (should (ltex-plus-live-workspace))
    ;; And the mode is re-entrant: turning it back on checks again.
    (with-current-buffer buffer
      (ltex-plus-live-after-publish
       (lambda () (lsp-ltex-plus-mode 1))
       "the check after re-enabling the mode")
      (should (ltex-plus-live-diagnostics)))))

;;;; -- The reload command ------------------------------------------------------

(ltex-plus-live-deftest ltex-plus-live-test-reload-reaches-the-server
    "`lsp-ltex-plus-reload-settings' makes a hand-edited file take effect.
Its broadcast half -- `--notify-ltex-workspaces' -- has no meaning
without a workspace to broadcast to, so this is the only place it runs.
The scenario is the documented one: edit the file by hand, run the
command, expect the word to stop being flagged."
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
       (lambda () (lsp-ltex-plus-reload-settings))
       "the re-check after reloading settings")
      (should-not (ltex-plus-live-flagged-p word)))))

;; Shut the server down once, however the run ended.
(add-hook 'kill-emacs-hook #'ltex-plus-live-teardown)

(provide 'ltex-plus-live-test)
;;; ltex-plus-live-test.el ends here
