;;; ltex-plus-settings-test.el --- Persisted lists and JSON helpers -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The three-tier storage the four language-keyed settings use: a pristine
;; defcustom the user seeds from `:custom', a `-stored' mirror of the file
;; on disk, and the `-merged' union the server is shown.
;;
;; The invariant worth guarding is that the defcustom is never written to.
;; If a code action ever mutated it, removing a word from `:custom' would
;; stop taking effect and there would be no way to tell the two sources
;; apart again -- and nothing about the running session would look wrong.

;;; Code:

(require 'ltex-plus-test-helper)

;;;; -- Merging ----------------------------------------------------------------

(ert-deftest ltex-plus-settings-test-merge-unions-languages ()
  "Keys present in either plist survive the merge."
  (let ((merged (lsp-ltex-plus--merge-plists '(:en-US ["a"]) '(:de-DE ["b"]))))
    (should (equal (ltex-plus-test-words merged) '("a")))
    (should (equal (ltex-plus-test-words merged :de-DE) '("b")))))

(ert-deftest ltex-plus-settings-test-merge-appends-within-a-language ()
  "Entries for the same language are concatenated, first list first."
  (should (equal (ltex-plus-test-words
                  (lsp-ltex-plus--merge-plists '(:en-US ["a"]) '(:en-US ["b"])))
                 '("a" "b"))))

(ert-deftest ltex-plus-settings-test-merge-deduplicates-by-string ()
  "A word already present is not added twice.
Deduplication is by `string=', not `eq': the two sides come from
different reads of different files and never share objects."
  (should (equal (ltex-plus-test-words
                  (lsp-ltex-plus--merge-plists
                   '(:en-US ["Kripke" "Quine"])
                   (list :en-US (vector (copy-sequence "Kripke") "Frege"))))
                 '("Kripke" "Quine" "Frege"))))

(ert-deftest ltex-plus-settings-test-merge-handles-empty-sides ()
  "Merging with nil on either side returns the other side's entries."
  (should (equal (ltex-plus-test-words
                  (lsp-ltex-plus--merge-plists nil '(:en-US ["a"])))
                 '("a")))
  (should (equal (ltex-plus-test-words
                  (lsp-ltex-plus--merge-plists '(:en-US ["a"]) nil))
                 '("a")))
  (should (equal (lsp-ltex-plus--merge-plists nil nil) nil)))

(ert-deftest ltex-plus-settings-test-merge-leaves-its-arguments-alone ()
  "Neither input plist is modified.
`lsp-ltex-plus--effective-plist' merges the global value with a project
file on every pull; a destructive merge would grow the global list with
one project's words and hand them to every other document."
  (let* ((global (list :en-US (vector "global")))
         (project (list :en-US (vector "project")))
         (global-copy (copy-tree global))
         (project-copy (copy-tree project)))
    (lsp-ltex-plus--merge-plists global project)
    (should (equal global global-copy))
    (should (equal project project-copy))))

;;;; -- Reading and writing the files ------------------------------------------

(ert-deftest ltex-plus-settings-test-plist-round-trips ()
  "A saved plist reads back unchanged, and its directory is created."
  (ltex-plus-test-with-project nil
    (let ((path (expand-file-name "nested/dir/words.eld" ltex-plus-test-root))
          (plist '(:en-US ["Wittgenstein"] :de-DE ["Widerspiegelung"])))
      (lsp-ltex-plus--save-plist plist path)
      (should (file-exists-p path))
      (should (equal (lsp-ltex-plus--load-plist path) plist)))))

(ert-deftest ltex-plus-settings-test-missing-file-reads-as-nil ()
  "A file that does not exist contributes nothing and signals nothing."
  (should (equal (lsp-ltex-plus--load-plist "/nonexistent/ltex/words.eld") nil)))

(ert-deftest ltex-plus-settings-test-unreadable-file-reads-as-nil ()
  "A truncated or hand-mangled file is reported and skipped, not raised.
These files are edited by hand; a stray paren must not stop the client
from starting."
  (ltex-plus-test-with-project '(("broken.eld" . "(:en-US [\"a\""))
    (let ((path (expand-file-name "broken.eld" ltex-plus-test-root))
          (inhibit-message t))
      (should (equal (lsp-ltex-plus--load-plist path) nil)))))

(ert-deftest ltex-plus-settings-test-add-to-plist-writes-and-merges ()
  "`--add-to-plist' grows the mirror, dedupes, and saves it."
  (ltex-plus-test-with-project nil
    (let ((path (expand-file-name "dict.eld" ltex-plus-test-root))
          (mirror nil))
      (defvar ltex-plus-settings-test--mirror)
      (setq ltex-plus-settings-test--mirror mirror)
      (lsp-ltex-plus--add-to-plist 'ltex-plus-settings-test--mirror
                                   path "en-US" '("Kripke"))
      (lsp-ltex-plus--add-to-plist 'ltex-plus-settings-test--mirror
                                   path "en-US" '("Kripke" "Quine"))
      (should (equal (ltex-plus-test-words ltex-plus-settings-test--mirror)
                     '("Kripke" "Quine")))
      (should (equal (ltex-plus-test-words (ltex-plus-test-read-file path))
                     '("Kripke" "Quine"))))))

(ert-deftest ltex-plus-settings-test-language-becomes-a-keyword ()
  "The wire's language code becomes the plist's keyword key.
The server sends \"de-DE\"; the file stores `:de-DE'."
  (ltex-plus-test-with-project nil
    (let ((path (expand-file-name "dict.eld" ltex-plus-test-root)))
      (defvar ltex-plus-settings-test--mirror)
      (setq ltex-plus-settings-test--mirror nil)
      (lsp-ltex-plus--add-to-plist 'ltex-plus-settings-test--mirror
                                   path "de-DE" '("Widerspiegelung"))
      (should (equal (ltex-plus-test-read-file path)
                     '(:de-DE ["Widerspiegelung"]))))))

;;;; -- The pristine-defcustom invariant ---------------------------------------

(ert-deftest ltex-plus-settings-test-merged-is-the-union ()
  "`-merged' is the defcustom and the file, both."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["from-custom"])
        lsp-ltex-plus--dictionary-stored '(:en-US ["from-file"]))
  (lsp-ltex-plus--recompute-merged)
  (should (equal (ltex-plus-test-words lsp-ltex-plus--dictionary-merged)
                 '("from-custom" "from-file"))))

(ert-deftest ltex-plus-settings-test-addition-never-touches-the-defcustom ()
  "A saved addition lands in the mirror and the file, never in `:custom'.
This is what keeps the two sources independent: a word deleted from
`:custom' has to disappear on the next start, which it cannot do if the
variable has been written to behind the user's back."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["from-custom"]))
  (lsp-ltex-plus--recompute-merged)
  (ltex-plus-test-with-project '(("doc.md" . "text\n"))
    (with-current-buffer (ltex-plus-test-visit
                          (expand-file-name "doc.md" ltex-plus-test-root))
      (lsp-ltex-plus--save-addition 'dictionary "en-US" '("accepted") nil)))
  (should (equal lsp-ltex-plus-dictionary '(:en-US ["from-custom"])))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--dictionary-stored)
                 '("accepted")))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--dictionary-merged)
                 '("from-custom" "accepted")))
  (should (equal (ltex-plus-test-words
                  (ltex-plus-test-read-file lsp-ltex-plus-dictionary-file))
                 '("accepted"))))

(ert-deftest ltex-plus-settings-test-reload-rereads-every-file ()
  "`--load-external-settings' refills all four mirrors and drops the cache."
  (ltex-plus-test-reset)
  (dolist (kind '(dictionary enabled-rules disabled-rules hidden-false-positives))
    (lsp-ltex-plus--save-plist (list :en-US (vector (symbol-name kind)))
                               (ltex-plus-test-global-file kind)))
  (puthash "/stale/path.eld" (cons nil '(:en-US ["stale"]))
           lsp-ltex-plus--project-file-cache)
  (lsp-ltex-plus--load-external-settings)
  (should (equal (ltex-plus-test-words lsp-ltex-plus--dictionary-stored)
                 '("dictionary")))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--enabled-rules-stored)
                 '("enabled-rules")))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--disabled-rules-stored)
                 '("disabled-rules")))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--hidden-false-positives-stored)
                 '("hidden-false-positives")))
  (should (= 0 (hash-table-count lsp-ltex-plus--project-file-cache))))

;;;; -- The kind table ---------------------------------------------------------

(ert-deftest ltex-plus-settings-test-every-kind-is-fully-described ()
  "Each of the four kinds names all of its variables, and they exist."
  (dolist (entry lsp-ltex-plus--setting-kinds)
    (let ((kind (car entry)))
      (dolist (property '(:merged :stored :global-file :project-file))
        (let ((variable (lsp-ltex-plus--kind-get kind property)))
          (should (symbolp variable))
          (should (boundp variable)))))))

(ert-deftest ltex-plus-settings-test-commands-map-back-to-their-kind ()
  "`--kind-for-command' inverts the `:command' column."
  (should (eq (lsp-ltex-plus--kind-for-command "_ltex.addToDictionary")
              'dictionary))
  (should (eq (lsp-ltex-plus--kind-for-command "_ltex.disableRules")
              'disabled-rules))
  (should (eq (lsp-ltex-plus--kind-for-command "_ltex.hideFalsePositives")
              'hidden-false-positives))
  (should-not (lsp-ltex-plus--kind-for-command "java.organizeImports")))

(ert-deftest ltex-plus-settings-test-enabled-rules-has-no-command ()
  "There is no \"enable rule\" suggestion, so nothing writes to that list.
`--kind-for-command' is asked with nil by any action carrying no command
name; it must not answer `enabled-rules' by matching nil against nil."
  (should-not (lsp-ltex-plus--kind-get 'enabled-rules :command))
  (should-not (lsp-ltex-plus--kind-for-command nil)))

;;;; -- Serialization helpers --------------------------------------------------

(ert-deftest ltex-plus-settings-test-str-translates-unset-to-empty ()
  "nil means \"unset\" in Elisp and \"\" on the wire.
An explicit \"\" left in an older config passes through unchanged, which
is what made the migration from \"\" defaults to nil harmless."
  (should (equal (lsp-ltex-plus--str nil) ""))
  (should (equal (lsp-ltex-plus--str "") ""))
  (should (equal (lsp-ltex-plus--str "https://example.invalid")
                 "https://example.invalid")))

(ert-deftest ltex-plus-settings-test-bool-never-serializes-as-null ()
  "A boolean setting is t or `:json-false', never nil."
  (should (eq (lsp-ltex-plus--bool t) t))
  (should (eq (lsp-ltex-plus--bool "anything") t))
  (should (eq (lsp-ltex-plus--bool nil) :json-false)))

(ert-deftest ltex-plus-settings-test-object-fields-are-never-null ()
  "An object-typed field is `{}' when unset, not `null'.
The server's TypeScript type for the four language-keyed maps is not
nullable, so an empty hash table stands in for nil."
  (should (equal (lsp-ltex-plus--obj-or-empty '(:en-US ["a"])) '(:en-US ["a"])))
  (should (hash-table-p (lsp-ltex-plus--obj-or-empty nil)))
  (should (= 0 (hash-table-count (lsp-ltex-plus--obj-or-empty nil)))))

;;;; -- Migration off the extensionless filenames ------------------------------

(ert-deftest ltex-plus-settings-test-migration-renames-the-old-file ()
  "The pre-.eld file is moved into place when the path is the default one."
  (ltex-plus-test-with-project '(("stored-dictionary" . "(:en-US [\"old\"])"))
    (let ((new (expand-file-name "stored-dictionary.eld" ltex-plus-test-root))
          (old (expand-file-name "stored-dictionary" ltex-plus-test-root))
          (inhibit-message t))
      (lsp-ltex-plus--migrate-extensionless-file new new)
      (should-not (file-exists-p old))
      (should (equal (ltex-plus-test-words (ltex-plus-test-read-file new))
                     '("old"))))))

(ert-deftest ltex-plus-settings-test-migration-skips-a-customised-path ()
  "A user who chose their own path is left alone.
The rename only happens when the current path is still the default; the
guard is the whole reason a customised location is safe."
  (ltex-plus-test-with-project '(("stored-dictionary" . "(:en-US [\"old\"])"))
    (let ((old (expand-file-name "stored-dictionary" ltex-plus-test-root))
          (default (expand-file-name "stored-dictionary.eld" ltex-plus-test-root))
          (chosen (expand-file-name "elsewhere.eld" ltex-plus-test-root))
          (inhibit-message t))
      (lsp-ltex-plus--migrate-extensionless-file chosen default)
      (should (file-exists-p old))
      (should-not (file-exists-p default)))))

(ert-deftest ltex-plus-settings-test-migration-refuses-to-merge ()
  "With both files present nothing is moved and the user is told.
Renaming would silently discard whichever file lost."
  (ltex-plus-test-with-project '(("stored-dictionary" . "(:en-US [\"old\"])")
                                 ("stored-dictionary.eld" . "(:en-US [\"new\"])"))
    (let ((old (expand-file-name "stored-dictionary" ltex-plus-test-root))
          (new (expand-file-name "stored-dictionary.eld" ltex-plus-test-root)))
      (let ((inhibit-message t))
        (lsp-ltex-plus--migrate-extensionless-file new new))
      (should (file-exists-p old))
      (should (equal (ltex-plus-test-words (ltex-plus-test-read-file new))
                     '("new"))))))

;;;; -- The reload command -----------------------------------------------------

(ert-deftest ltex-plus-settings-test-old-reload-names-still-resolve ()
  "Both commands the reload replaced survive as obsolete aliases."
  (dolist (name '(lsp-ltex-plus-reload-and-notify-server
                  lsp-ltex-plus-reload-external-settings))
    (should (fboundp name))
    (should (eq (indirect-function name)
                (indirect-function 'lsp-ltex-plus-reload-settings)))))


;;;; -- The server version guard -----------------------------------------------

;; Checked once the server has connected and said what it is.  A server
;; below the floor, or one that cannot say, is stopped -- unless the user
;; has opted out, in which case the warning stands and the server does not.

(ert-deftest ltex-plus-settings-test-version-comparison-ignores-build-metadata ()
  "A release version compares on its leading numbers alone.
Real versions carry a pre-release suffix and build metadata that
`version-to-list' will not read, so comparing whole strings signals."
  (should (lsp-ltex-plus--version-at-least-p "18.7" "18.7.0"))
  (should (lsp-ltex-plus--version-at-least-p "18.7.0" "18.7.0"))
  (should (lsp-ltex-plus--version-at-least-p
           "18.7.1-alpha.32+2026-08-26.g7977ac67" "18.7.0"))
  (should (lsp-ltex-plus--version-at-least-p "19.0" "18.7.0"))
  (should-not (lsp-ltex-plus--version-at-least-p "18.6.9" "18.7.0"))
  (should-not (lsp-ltex-plus--version-at-least-p "17.9" "18.7.0")))

(ert-deftest ltex-plus-settings-test-an-unreadable-version-is-never-new-enough ()
  "Anything that is not a version fails the comparison.
The guard treats that as a failure rather than a pass: a server that
completed the handshake should have been able to say what it is."
  (should-not (lsp-ltex-plus--version-at-least-p nil "18.7.0"))
  (should-not (lsp-ltex-plus--version-at-least-p "" "18.7.0"))
  (should-not (lsp-ltex-plus--version-at-least-p "unknown" "18.7.0")))

(defmacro ltex-plus-settings-test--enforcing (reported &rest body)
  "Run the version guard against a server REPORTED by the protocol.
REPORTED is what `serverInfo' gave, or nil for an lsp-mode that cannot
say.  Inside BODY, `stopped' says whether the workspace was shut down,
`warned' is what the user was told, and `asked-binary' whether the
binary was consulted."
  (declare (indent 1) (debug t))
  `(let ((lsp-ltex-plus--server-version ,reported)
         (stopped nil) (warned nil) (asked-binary nil))
     (cl-letf (((symbol-function 'lsp-ltex-plus--shutdown-workspace)
                (lambda (_workspace) (setq stopped t)))
               ((symbol-function 'message)
                (lambda (format &rest args) (setq warned (apply #'format format args)))))
       (ignore stopped warned asked-binary)
       ,@body)))

(ert-deftest ltex-plus-settings-test-an-old-server-is-stopped ()
  "A server below the floor is stopped, and the user is told which."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing "18.6.9"
      (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace))
      (should stopped)
      (should (string-match-p "18\\.6\\.9" warned))
      (should (string-match-p (regexp-quote lsp-ltex-plus-minimum-server-version)
                              warned)))))

(ert-deftest ltex-plus-settings-test-opting-out-keeps-the-server-running ()
  "Opting out leaves the server up, and still warns.
The user has said they know; that is a reason not to stop them, not a
reason to stop telling them."
  (let ((lsp-ltex-plus-require-minimum-server-version nil))
    (ltex-plus-settings-test--enforcing "18.6.9"
      (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace))
      (should-not stopped)
      (should warned)
      (should (string-match-p "18\\.6\\.9" warned)))))

(ert-deftest ltex-plus-settings-test-the-warning-names-the-way-out ()
  "When stopping, the warning names the setting that prevents it.
Being told the server was stopped is half an answer if the way to keep
it running is undocumented at the point it happens."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing "18.6.9"
      (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace))
      (should (string-match-p "lsp-ltex-plus-require-minimum-server-version"
                              warned)))))

(ert-deftest ltex-plus-settings-test-a-current-server-is-left-alone ()
  "A server meeting the floor is neither stopped nor mentioned."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing "18.7.1-alpha.32+2026-08-26.g7977ac67"
      (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace))
      (should-not stopped)
      (should-not warned))))

(ert-deftest ltex-plus-settings-test-an-undeterminable-version-is-stopped ()
  "A version nobody can read is treated as a failure, not a pass.
The server answered the handshake, so it should have been able to say
what it is; that it could not means something is wrong."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing nil
      (cl-letf (((symbol-function 'lsp-ltex-plus--installed-server-version)
                 (lambda () (setq asked-binary t) nil)))
        (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace)))
      (should stopped)
      (should (string-match-p "Cannot determine" warned)))))

(defmacro ltex-plus-settings-test--with-fake-server (contents mode &rest body)
  "Run BODY with a fake `ltex-ls-plus' of CONTENTS and file MODE.
`exec-path' holds only the directory that fake sits in, so a real
`ltex-ls-plus' installed on this machine cannot answer instead.
`messaged' is bound to whatever the probe reported to the user."
  (declare (indent 2) (debug t))
  `(let* ((dir (file-name-as-directory (make-temp-file "ltex-plus-bin-" t)))
          (binary (expand-file-name "ltex-ls-plus" dir))
          (exec-path (list dir))
          (lsp-ltex-plus-ls-plus-executable "ltex-ls-plus")
          (messaged nil))
     (unwind-protect
         (progn
           (with-temp-file binary (insert ,contents))
           (set-file-modes binary ,mode)
           (cl-letf (((symbol-function 'message)
                      (lambda (fmt &rest args)
                        (setq messaged (apply #'format fmt args)))))
             ,@body))
       (delete-directory dir t))))

(ert-deftest ltex-plus-settings-test-the-probe-reads-the-version ()
  "A binary that answers `--version' has its version parsed out."
  (ltex-plus-settings-test--with-fake-server
      "#!/bin/sh\necho '{\"ltex-ls\": \"18.7.1-alpha.32\", \"java\": \"21.0.10\"}'\n"
      #o755
    (should (equal (lsp-ltex-plus--installed-server-version) "18.7.1-alpha.32"))
    (should-not messaged)))

(ert-deftest ltex-plus-settings-test-an-unrunnable-binary-is-reported ()
  "A file the kernel refuses to run is named, with the reason.
`executable-find' checks only that the executable bit is set, so a
wrong-architecture binary, a truncated download, or a script whose
interpreter is gone all get this far.  Each is something to fix on disk,
and the caller's own message -- that no version could be determined --
would not point at any of them."
  ;; A script whose interpreter does not exist.
  (ltex-plus-settings-test--with-fake-server "#!/no/such/interpreter\n" #o755
    (should-not (lsp-ltex-plus--installed-server-version))
    (should (string-match-p "Cannot run" messaged))
    (should (string-match-p "ltex-ls-plus" messaged)))
  ;; An executable file that holds nothing the kernel can execute.
  (ltex-plus-settings-test--with-fake-server "" #o755
    (should-not (lsp-ltex-plus--installed-server-version))
    (should (string-match-p "Cannot run" messaged))))

(ert-deftest ltex-plus-settings-test-a-silent-binary-is-not-reported-as-unrunnable ()
  "A binary that runs but says nothing useful yields nil, quietly.
It ran, so there is nothing on disk to fix; the caller's own message
about an undeterminable version is the right one and the only one."
  (ltex-plus-settings-test--with-fake-server "#!/bin/sh\necho nonsense\n" #o755
    (should-not (lsp-ltex-plus--installed-server-version))
    (should-not messaged))
  (ltex-plus-settings-test--with-fake-server "#!/bin/sh\nexit 3\n" #o755
    (should-not (lsp-ltex-plus--installed-server-version))
    (should-not messaged)))

(ert-deftest ltex-plus-settings-test-the-probe-catches-only-file-errors ()
  "Anything that is not a `file-error' propagates.
The catch covers the binary refusing to run.  A fault in this function
is not that, and must not be quietly turned into a missing version."
  (ltex-plus-settings-test--with-fake-server "#!/bin/sh\necho hi\n" #o755
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (error "Bug in the probe"))))
      (should-error (lsp-ltex-plus--installed-server-version)
                    :type 'error))))

(ert-deftest ltex-plus-settings-test-the-binary-answers-when-the-protocol-cannot ()
  "With no version from `serverInfo', the binary is asked instead.
Which is every installation until the lsp-mode accessors are merged."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing nil
      (cl-letf (((symbol-function 'lsp-ltex-plus--installed-server-version)
                 (lambda () (setq asked-binary t) "18.6.9")))
        (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace)))
      (should asked-binary)
      (should stopped)
      (should (string-match-p "18\\.6\\.9" warned)))))

(ert-deftest ltex-plus-settings-test-the-protocol-answer-is-preferred ()
  "When `serverInfo' supplied a version, the binary is not run.
The running server is the authority on what it is, and asking the binary
costs a subprocess."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--enforcing "18.7.1"
      (cl-letf (((symbol-function 'lsp-ltex-plus--installed-server-version)
                 (lambda () (setq asked-binary t) "1.0")))
        (lsp-ltex-plus--enforce-server-version (ltex-plus-test-workspace)))
      (should-not asked-binary)
      (should-not stopped))))

(ert-deftest ltex-plus-settings-test-stopping-switches-the-mode-off ()
  "Shutting the server down turns the mode off in its buffers.
`:activation-fn' reads nothing but that variable, so a buffer left with
the mode on would invite lsp-mode to start the same server again."
  (let ((buffer (generate-new-buffer " *ltex-plus-settings-test-stop*"))
        (shut nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq-local lsp-ltex-plus-mode t))
          (cl-letf (((symbol-function 'lsp-workspace-shutdown)
                     (lambda (_workspace) (setq shut t))))
            (lsp-ltex-plus--shutdown-workspace
             (make-lsp--workspace :client (gethash 'ltex-ls-plus lsp-clients)
                                  :buffers (list buffer))))
          (should shut)
          (should-not (buffer-local-value 'lsp-ltex-plus-mode buffer)))
      (kill-buffer buffer))))

(provide 'ltex-plus-settings-test)
;;; ltex-plus-settings-test.el ends here
