;;; ltex-plus-settings-test.el --- Persisted lists and JSON helpers -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The three-tier storage the four language-keyed settings use: a pristine
;; defcustom the user seeds from `:custom', a `-stored' mirror of the file
;; on disk, and the union of the two the server is shown.
;;
;; The invariant worth guarding is that the defcustom is never written to.
;; If a code action ever mutated it, removing a word from `:custom' would
;; stop taking effect and there would be no way to tell the two sources
;; apart again -- and nothing about the running session would look wrong.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

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

(ert-deftest ltex-plus-settings-test-the-global-list-is-the-union ()
  "The server is shown the defcustom and the file, both."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["from-custom"])
        lsp-ltex-plus--dictionary-stored '(:en-US ["from-file"]))
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--global-plist 'dictionary))
                 '("from-custom" "from-file"))))

(ert-deftest ltex-plus-settings-test-a-changed-defcustom-is-live ()
  "A `setq' of a list setting is in force at once, with nothing to reload.
The merge is made when the server asks; there is no cache of it that a
change to the defcustom could leave stale."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["first"]))
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--effective-plist 'dictionary))
                 '("first")))
  (setq lsp-ltex-plus-dictionary '(:en-US ["second"]))
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--effective-plist 'dictionary))
                 '("second"))))

(ert-deftest ltex-plus-settings-test-addition-never-touches-the-defcustom ()
  "A saved addition lands in the mirror and the file, never in `:custom'.
This is what keeps the two sources independent: a word deleted from
`:custom' has to disappear on the next start, which it cannot do if the
variable has been written to behind the user's back."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["from-custom"]))
  (ltex-plus-test-with-project '(("doc.md" . "text\n"))
    (with-current-buffer (ltex-plus-test-visit
                          (expand-file-name "doc.md" ltex-plus-test-root))
      (lsp-ltex-plus--save-addition 'dictionary "en-US" '("accepted") nil)))
  (should (equal lsp-ltex-plus-dictionary '(:en-US ["from-custom"])))
  (should (equal (ltex-plus-test-words lsp-ltex-plus--dictionary-stored)
                 '("accepted")))
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--global-plist 'dictionary))
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

(ert-deftest ltex-plus-settings-test-reload-rereads-the-files ()
  "A hand-edited global file is read back into the global list by the reload."
  (ltex-plus-test-reset)
  (lsp-ltex-plus--save-plist '(:en-US ["Flimberry"]) lsp-ltex-plus-dictionary-file)
  (should-not (ltex-plus-test-words (lsp-ltex-plus--global-plist 'dictionary)))
  (let ((inhibit-message t))
    (lsp-ltex-plus-reload-settings))
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--global-plist 'dictionary))
                 '("Flimberry"))))

(ert-deftest ltex-plus-settings-test-reload-tells-the-server ()
  "With a server running, the reload pushes the configuration again.
The push is what makes the server pull its settings afresh, so the
edited file reaches the next check."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (ltex-plus-fake-wait-for
     (lambda () (ltex-plus-fake-received 'workspace/didChangeConfiguration)))
    (let ((inhibit-message t))
      (lsp-ltex-plus-reload-settings))
    (ltex-plus-fake-wait-for
     (lambda () (= 2 (length (ltex-plus-fake-received 'workspace/didChangeConfiguration)))))))

;;;; -- Changing the language ---------------------------------------------------

(ert-deftest ltex-plus-settings-test-every-language-is-offered-by-name-and-code ()
  "Each menu entry shows name, code and note, and maps back to the code."
  (let ((candidates (lsp-ltex-plus--language-candidates)))
    (should (= (length candidates) (length lsp-ltex-plus--languages)))
    (pcase-dolist (`(,code ,name ,note) lsp-ltex-plus--languages)
      (let ((entry (rassoc code candidates)))
        (should entry)
        (should (string-prefix-p name (car entry)))
        (should (string-suffix-p (concat " " code (and note (format "  (%s)" note)))
                                 (car entry)))))))

(ert-deftest ltex-plus-settings-test-customize-offers-only-the-languages ()
  "The Customize type matches every listed code, and no code it does not list.
A `setq' of an unlisted code still reaches the server; see
`ltex-plus-scope-test-sections-are-read-the-way-the-protocol-spells-them'."
  (let ((widget (widget-convert (get 'lsp-ltex-plus-language 'custom-type))))
    (dolist (language lsp-ltex-plus--languages)
      (should (widget-apply widget :match (car language))))
    (should-not (widget-apply widget :match "en"))))

(ert-deftest ltex-plus-settings-test-the-offered-languages-come-in-their-order ()
  "A list of codes offers those languages in its order, the current one after."
  (let ((lsp-ltex-plus-offered-languages '("it-IT" "de-DE" "en-GB"))
        (lsp-ltex-plus-language "en-US"))
    (should (equal (mapcar #'cdr (lsp-ltex-plus--language-candidates))
                   '("it-IT" "de-DE" "en-GB" "en-US"))))
  (let ((lsp-ltex-plus-offered-languages '("it-IT" "de-DE"))
        (lsp-ltex-plus-language "de-DE"))
    (should (equal (mapcar #'cdr (lsp-ltex-plus--language-candidates))
                   '("it-IT" "de-DE")))))

(ert-deftest ltex-plus-settings-test-a-listed-language-is-sent-as-the-table-spells-it ()
  "Case is ignored against the table; the server gets the table's spelling."
  (should (equal (lsp-ltex-plus--canonical-language "en-us") "en-US"))
  (should (equal (lsp-ltex-plus--canonical-language "DE-de-X-SIMPLE-LANGUAGE")
                 "de-DE-x-simple-language"))
  (with-temp-buffer
    (setq-local lsp-ltex-plus-language "fr-fr")
    (should (equal (lsp-ltex-plus--configuration-section "ltex.language") "fr-FR"))))

(ert-deftest ltex-plus-settings-test-an-unlisted-language-is-sent-and-logged-once ()
  "A code the table does not hold goes to the server unchanged, logged once."
  (let ((buffer "*lsp-ltex-plus log*")
        (lsp-ltex-plus-debug t)
        (lsp-ltex-plus--logged-unlisted-language nil))
    (when (get-buffer buffer) (kill-buffer buffer))
    (should (equal (lsp-ltex-plus--canonical-language "fr") "fr"))
    (should (equal (lsp-ltex-plus--canonical-language "fr") "fr"))
    (with-current-buffer buffer
      (should (= 1 (how-many "Language \"fr\" is not in the list" (point-min) (point-max)))))
    (kill-buffer buffer)))

(ert-deftest ltex-plus-settings-test-offered-and-current-languages-ignore-case ()
  "The offered list and the current language match the table with case ignored."
  (let ((lsp-ltex-plus-offered-languages '("en-us" "DE-DE"))
        (lsp-ltex-plus-language "it-it")
        (lsp-ltex-plus--warned-offered-languages nil)
        (annotate nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (error "No warning expected"))))
      (should (equal (mapcar #'cdr (lsp-ltex-plus--language-candidates))
                     '("en-US" "de-DE" "it-IT")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq annotate (completion-metadata-get
                                   (completion-metadata "" table nil)
                                   'annotation-function))
                   (car (rassoc "en-US" (lsp-ltex-plus--language-candidates))))))
        (lsp-ltex-plus--read-language "? ")))
    (should (funcall annotate (car (rassoc "it-IT" (lsp-ltex-plus--language-candidates)))))))

(ert-deftest ltex-plus-settings-test-an-unknown-offered-code-is-warned-about-once ()
  "A code the table does not hold is left out, with one warning per value."
  (let ((lsp-ltex-plus-offered-languages '("en-XX" "de-DE"))
        (lsp-ltex-plus-language "de-DE")
        (lsp-ltex-plus--warned-offered-languages nil)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (should (equal (mapcar #'cdr (lsp-ltex-plus--language-candidates)) '("de-DE")))
      (lsp-ltex-plus--language-candidates)
      (should (= 1 (length warnings)))
      (should (string-match-p "\"en-XX\"" (car warnings)))
      (setq lsp-ltex-plus-offered-languages '("de-DE" "xx"))
      (lsp-ltex-plus--language-candidates)
      (should (= 2 (length warnings))))))

(ert-deftest ltex-plus-settings-test-no-supported-offered-language-is-an-error ()
  "A list with nothing the menu could offer says so instead of an empty menu."
  (let ((lsp-ltex-plus-offered-languages '("xx"))
        (lsp-ltex-plus-language "yy")
        (lsp-ltex-plus--warned-offered-languages '("xx")))
    (should-error (lsp-ltex-plus--language-candidates) :type 'user-error)))

(ert-deftest ltex-plus-settings-test-customize-ticks-the-offered-languages ()
  "The Customize type of the offered languages is a set of the listed codes."
  (let ((widget (widget-convert (get 'lsp-ltex-plus-offered-languages 'custom-type))))
    (should (widget-apply widget :match nil))
    (should (widget-apply widget :match '("en-US" "de-DE")))
    (should-not (widget-apply widget :match '("en")))))

(ert-deftest ltex-plus-settings-test-the-language-changes-in-this-buffer-only ()
  "Without a prefix the value is set in the current buffer, and the server told.
The next pull from that buffer answers the new language; another buffer
keeps the global one."
  (ltex-plus-fake-with-connection
    (ltex-plus-fake-ready-connection)
    (ltex-plus-fake-wait-for
     (lambda () (ltex-plus-fake-received 'workspace/didChangeConfiguration)))
    (let ((global (default-value 'lsp-ltex-plus-language)))
      (with-temp-buffer
        (let ((inhibit-message t))
          (lsp-ltex-plus-change-language "de-CH"))
        (should (local-variable-p 'lsp-ltex-plus-language))
        (should (equal (lsp-ltex-plus--configuration-section "ltex.language") "de-CH"))
        (should (equal (default-value 'lsp-ltex-plus-language) global)))
      (with-temp-buffer
        (should (equal (lsp-ltex-plus--configuration-section "ltex.language") global))))
    (ltex-plus-fake-wait-for
     (lambda () (= 2 (length (ltex-plus-fake-received 'workspace/didChangeConfiguration)))))))

(ert-deftest ltex-plus-settings-test-the-language-changes-globally-with-a-prefix ()
  "With a prefix the global value changes; a buffer with its own value keeps it."
  (let ((lsp-ltex-plus-language "en-US")
        (lsp-ltex-plus--connection nil))
    (with-temp-buffer
      (setq-local lsp-ltex-plus-language "it-IT")
      (let ((inhibit-message t))
        (lsp-ltex-plus-change-language "fr-FR" t))
      (should (equal lsp-ltex-plus-language "it-IT"))
      (should (equal (default-value 'lsp-ltex-plus-language) "fr-FR")))
    (with-temp-buffer
      (should (equal lsp-ltex-plus-language "fr-FR")))))

(ert-deftest ltex-plus-settings-test-the-hook-runs-in-the-buffer-with-the-choice ()
  "The hook gets the table's spelling and GLOBAL, in the buffer it was run in."
  (let ((lsp-ltex-plus-language "en-US")
        (lsp-ltex-plus--connection nil)
        (lsp-ltex-plus-change-language-functions nil)
        (calls nil))
    (add-hook 'lsp-ltex-plus-change-language-functions
              (lambda (language global)
                (push (list language global (current-buffer)) calls)))
    (with-temp-buffer
      (let ((inhibit-message t))
        (lsp-ltex-plus-change-language "de-ch")
        (lsp-ltex-plus-change-language "fr-FR" t))
      (should (equal calls `(("fr-FR" t ,(current-buffer))
                             ("de-CH" nil ,(current-buffer))))))))

(ert-deftest ltex-plus-settings-test-a-failing-hook-leaves-the-change-in-place ()
  "The hook runs after the change, so its error does not undo it."
  (let ((lsp-ltex-plus-language "en-US")
        (lsp-ltex-plus--connection nil)
        (lsp-ltex-plus-change-language-functions
         (list (lambda (_language _global) (error "Broken hook")))))
    (with-temp-buffer
      (let ((inhibit-message t))
        (should-error (lsp-ltex-plus-change-language "it-IT")))
      (should (equal lsp-ltex-plus-language "it-IT")))))

(ert-deftest ltex-plus-settings-test-the-menu-marks-the-current-language ()
  "The buffer's language is annotated \"(current)\", and none is the default."
  (let* ((candidates (lsp-ltex-plus--language-candidates))
         (current (car (rassoc "de-CH" candidates)))
         (other (car (rassoc "en-US" candidates)))
         annotate default)
    (with-temp-buffer
      (setq-local lsp-ltex-plus-language "de-CH")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest args)
                   (setq annotate (completion-metadata-get
                                   (completion-metadata "" table nil)
                                   'annotation-function)
                         default (nth 5 args))
                   current)))
        (should (equal (lsp-ltex-plus--read-language "? ") "de-CH"))))
    (should (equal (funcall annotate current) "  (current)"))
    (should-not (funcall annotate other))
    (should-not default)))

(ert-deftest ltex-plus-settings-test-the-menu-accepts-only-its-own-entries ()
  "Picking an entry gives its code, and the menu requires a match."
  (let ((candidates (lsp-ltex-plus--language-candidates))
        require-match)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _table _predicate match &rest _)
                 (setq require-match match)
                 (car (rassoc "pt-BR" candidates)))))
      (should (equal (lsp-ltex-plus--read-language "? ") "pt-BR")))
    (should (eq require-match t))))

(ert-deftest ltex-plus-settings-test-setup-is-idempotent ()
  "Running setup twice leaves the lists as one run left them."
  (ltex-plus-test-reset)
  (lsp-ltex-plus--save-plist '(:en-US ["once"]) lsp-ltex-plus-dictionary-file)
  (lsp-ltex-plus--setup)
  (lsp-ltex-plus--setup)
  (should (equal (ltex-plus-test-words (lsp-ltex-plus--global-plist 'dictionary))
                 '("once"))))

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

(defmacro ltex-plus-settings-test--connecting-to (version &rest body)
  "Run BODY with the fake reporting VERSION and the client connected to it.
Inside BODY, `conn' is the connection and `warned' the package's
messages to the user, joined, or nil.  VERSION nil makes the fake omit
it from `serverInfo', as every ltex-ls-plus before 18.7.0 does."
  (declare (indent 1) (debug t))
  `(ltex-plus-fake-with-connection
     (let ((ltex-plus-fake-server-version ,version)
           (said nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (format &rest args)
                    (push (apply #'format format args) said))))
         (let ((conn (lsp-ltex-plus--ensure-connection)))
           (ltex-plus-fake-wait-for
            (lambda () (or (not (jsonrpc-running-p conn))
                           (and (lsp-ltex-plus--connection-ready conn)
                                (ltex-plus-fake-received 'workspace/didChangeConfiguration)))))
           (let ((warned (let ((ours (seq-filter (lambda (m) (string-prefix-p "[lsp-ltex-plus]" m))
                                                 (reverse said))))
                           (and ours (string-join ours "\n")))))
             (ignore conn warned)
             ,@body))))))

(ert-deftest ltex-plus-settings-test-an-old-server-is-stopped ()
  "A server below the floor is stopped, and the user is told which.
Nothing is pushed to a server about to be stopped, and the protocol's
two steps are still observed on the way out."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--connecting-to "18.6.9"
      (should-not (jsonrpc-running-p conn))
      (should-not (lsp-ltex-plus--live-connection))
      (should (string-match-p "18\\.6\\.9" warned))
      (should (string-match-p (regexp-quote lsp-ltex-plus-minimum-server-version) warned))
      (should (string-match-p "lsp-ltex-plus-require-minimum-server-version" warned))
      (should-not (ltex-plus-fake-received 'workspace/didChangeConfiguration))
      (should (ltex-plus-fake-received 'shutdown)))))

(ert-deftest ltex-plus-settings-test-opting-out-keeps-the-server-running ()
  "Opting out leaves the server up, and still warns.
The user has said they know; that is a reason not to stop them, not a
reason to stop telling them."
  (let ((lsp-ltex-plus-require-minimum-server-version nil))
    (ltex-plus-settings-test--connecting-to "18.6.9"
      (should (jsonrpc-running-p conn))
      (should warned)
      (should (string-match-p "18\\.6\\.9" warned))
      (should (ltex-plus-fake-received 'workspace/didChangeConfiguration)))))

(ert-deftest ltex-plus-settings-test-a-current-server-is-left-alone ()
  "A server meeting the floor is neither stopped nor mentioned, and is recorded."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--connecting-to "18.7.1-alpha.32+2026-08-26.g7977ac67"
      (should (jsonrpc-running-p conn))
      (should-not warned)
      (should (equal lsp-ltex-plus--server-name "ltex-ls-plus"))
      (should (equal lsp-ltex-plus--server-version "18.7.1-alpha.32+2026-08-26.g7977ac67")))))

(ert-deftest ltex-plus-settings-test-a-server-that-gives-no-version-is-stopped ()
  "A server whose `serverInfo' has no version is stopped, and told why.
Every ltex-ls-plus before 18.7.0 is silent about its version, and 18.7.0
is the floor, so silence means too old; the message says so rather than
\"cannot determine\", and the binary is not run to find out more."
  (let ((lsp-ltex-plus-require-minimum-server-version t))
    (ltex-plus-settings-test--connecting-to nil
      (should-not (jsonrpc-running-p conn))
      (should (string-match-p "predates 18\\.7\\.0" warned))
      (should (string-match-p (regexp-quote lsp-ltex-plus-minimum-server-version) warned))
      (should-not (ltex-plus-fake-received 'workspace/didChangeConfiguration)))))

(ert-deftest ltex-plus-settings-test-a-stopped-server-switches-the-mode-off ()
  "The mode goes off in a buffer that was waiting for a server the guard stopped.
Its didOpen never goes out, and its mode line does not claim a check."
  (let ((lsp-ltex-plus-require-minimum-server-version t)
        (ltex-plus-fake-server-version "18.6.9")
        (inhibit-message t))
    (ltex-plus-fake-with-connection
      (ltex-plus-test-with-project '(("note.rst" . "Text.\n"))
        (let ((buffer (ltex-plus-test-visit (project-file "note.rst"))))
          (with-current-buffer buffer
            (rst-mode)
            (lsp-ltex-plus-mode 1)
            (should lsp-ltex-plus-mode))
          (let ((conn lsp-ltex-plus--connection))
            (ltex-plus-fake-wait-for (lambda () (not (jsonrpc-running-p conn)))))
          (should-not (buffer-local-value 'lsp-ltex-plus-mode buffer))
          (should-not (ltex-plus-fake-received 'textDocument/didOpen)))))))

;;;; -- The settings object ----------------------------------------------------

(defconst ltex-plus-settings-test--documented-keys
  '("additionalRules.enablePickyRules" "additionalRules.languageModel"
    "additionalRules.motherTongue" "bibtex.fields" "checkFrequency"
    "clearDiagnosticsWhenClosingFile" "completionEnabled" "diagnosticSeverity"
    "enabled" "languageToolHttpServerOfflineFallback"
    "languageToolHttpServerTimeoutSeconds" "languageToolHttpServerUri"
    "languageToolOrg.apiKey"
    "languageToolOrg.username" "language" "latex.commands"
    "latex.environments" "ltex-ls.logLevel" "markdown.nodes"
    "maxRequestSize" "paragraphCacheEnabled" "paragraphCacheTtlMinutes"
    "sentenceCacheSize")
  "Every `ltex.*' setting the client sends, in the server's dotted spelling.
Each is one the server's own settings parser reads; a key added to the
object without being added here is one nobody checked against the
server.  The four language-keyed lists are deliberately absent: they
travel over the server's own request.")

(defun ltex-plus-settings-test--keys (object)
  "Return the dotted leaf paths of the nested settings OBJECT, sorted.
The four language-keyed lists are leaves: their plists are keyed by
language, not by setting, and look nested only by accident."
  (let (keys)
    (cl-labels ((walk (prefix plist)
                  (while plist
                    (let* ((key (substring (symbol-name (pop plist)) 1))
                           (value (pop plist))
                           (path (if prefix (concat prefix "." key) key)))
                      (if (and value (listp value) (keywordp (car value))
                               (not (member key '("dictionary" "enabledRules"
                                                  "disabledRules"
                                                  "hiddenFalsePositives"))))
                          (walk path value)
                        (push path keys))))))
      (walk nil object))
    (sort keys #'string<)))

(ert-deftest ltex-plus-settings-test-the-object-carries-every-documented-key ()
  "The settings object has exactly the keys the README documents."
  (ltex-plus-test-reset)
  (should (equal (ltex-plus-settings-test--keys (lsp-ltex-plus--settings-object))
                 (sort (copy-sequence ltex-plus-settings-test--documented-keys)
                       #'string<))))

(ert-deftest ltex-plus-settings-test-unset-values-have-their-json-type ()
  "Nil never reaches the wire where the server expects a string or a boolean.
An unset string goes out as \"\", a false boolean as false, and an empty
list-valued setting as an empty object, never as null."
  (ltex-plus-test-reset)
  (let ((lsp-ltex-plus-lt-server-uri nil)
        (lsp-ltex-plus-lt-api-key nil)
        (lsp-ltex-plus-lt-offline-fallback nil)
        (lsp-ltex-plus-completion-enabled nil)
        (lsp-ltex-plus-bibtex-fields nil)
        (lsp-ltex-plus-latex-commands nil))
    (let ((object (lsp-ltex-plus--settings-object)))
      (should (equal (plist-get object :languageToolHttpServerUri) ""))
      (should (eq (plist-get object :languageToolHttpServerOfflineFallback)
                  :json-false))
      (should (equal (plist-get (plist-get object :languageToolOrg) :apiKey) ""))
      (should (eq (plist-get object :completionEnabled) :json-false))
      (should (hash-table-p (plist-get (plist-get object :bibtex) :fields)))
      (should (hash-table-p (plist-get (plist-get object :latex) :commands))))))

(ert-deftest ltex-plus-settings-test-the-object-is-read-in-the-current-buffer ()
  "A buffer-local value is what goes out when the object is built there.
This is what lets a `.dir-locals.el' decide a document's language: the
handler builds the object in the document's own buffer."
  (with-temp-buffer
    (setq-local lsp-ltex-plus-language "de-DE")
    (should (equal (plist-get (lsp-ltex-plus--settings-object) :language) "de-DE")))
  (with-temp-buffer
    (should (equal (plist-get (lsp-ltex-plus--settings-object) :language)
                   (default-value 'lsp-ltex-plus-language)))))

(ert-deftest ltex-plus-settings-test-enabled-names-the-document-s-own-language ()
  "`enabled' is the one language id of the buffer the object is read in.
The server skips a document whose id is not in the set, and its default
set has no programming language; the client decides per buffer, so a
document it opened is enabled by definition and nothing else needs
naming.  Outside any document the answer is plain text, which the
server never skips."
  (with-temp-buffer
    (setq major-mode 'python-mode)
    (should (equal (plist-get (lsp-ltex-plus--settings-object) :enabled) ["python"])))
  (with-temp-buffer
    (should (equal (plist-get (lsp-ltex-plus--settings-object) :enabled) ["plaintext"]))))

(ert-deftest ltex-plus-settings-test-the-client-log-is-written-only-under-debug ()
  "`lsp-ltex-plus--log' writes to `*lsp-ltex-plus log*', and only when asked.
The buffer is the client's own record -- which buffer was checked, which
was skipped and why -- and it is not created at all with the option
off."
  (let ((buffer "*lsp-ltex-plus log*"))
    (when (get-buffer buffer) (kill-buffer buffer))
    (let ((lsp-ltex-plus-debug nil))
      (lsp-ltex-plus--log "nothing to see %s" 'here)
      (should-not (get-buffer buffer)))
    (let ((lsp-ltex-plus-debug t))
      (lsp-ltex-plus--log "checked %s" "war-and-peace.org")
      (should (get-buffer buffer))
      (should (string-match-p "checked war-and-peace.org"
                              (with-current-buffer buffer (buffer-string)))))
    (kill-buffer buffer)))

(ert-deftest ltex-plus-settings-test-debug-turns-on-nothing-else ()
  "`lsp-ltex-plus-debug' writes the client log and does nothing further.
It used to uncap the events buffer and ask the server for a trace as
well; each of those has its own setting now, and a setting that quietly
overrode another would be back where we started."
  (let ((lsp-ltex-plus-debug t)
        (lsp-ltex-plus-trace-server "off")
        (lsp-ltex-plus-events-buffer-size 0)
        (lsp-ltex-plus-server-log-file nil))
    (lsp-ltex-plus--setup)
    (should (equal lsp-ltex-plus-trace-server "off"))
    (should (eql lsp-ltex-plus-events-buffer-size 0))
    (should-not lsp-ltex-plus-server-log-file)))

(provide 'ltex-plus-settings-test)
;;; ltex-plus-settings-test.el ends here
