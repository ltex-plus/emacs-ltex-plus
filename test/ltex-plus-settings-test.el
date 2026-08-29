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

(provide 'ltex-plus-settings-test)
;;; ltex-plus-settings-test.el ends here
