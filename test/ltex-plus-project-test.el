;;; ltex-plus-project-test.el --- Project-local word and rule lists -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; A project can keep its own copies of the four language-keyed lists,
;; named by `.dir-locals.el' and merged with the global ones.
;;
;; The invariant the tests here exist for is that the two sources *merge*.
;; Making a project file win instead would narrow the user's vocabulary
;; the moment they opened a project, which is the opposite of what a
;; project list is for -- and it would look like the feature working.

;;; Code:

(require 'ltex-plus-test-helper)

(defconst ltex-plus-project-test--spec
  '((".dir-locals.el"
     . "((nil . ((lsp-ltex-plus-project-dictionary-file
                  . \".ltex/dictionary.eld\")
                 (lsp-ltex-plus-project-disabled-rules-file
                  . \".ltex/disabled-rules.eld\"))))")
    (".ltex/dictionary.eld"     . "(:en-US [\"Wittgenstein\"])")
    (".ltex/disabled-rules.eld" . "(:en-US [\"PROJECT_RULE\"])")
    ("doc.md"                   . "text\n")
    ("sub/deeper/nested.md"     . "text\n"))
  "A project keeping a dictionary and a disabled-rules list, and nothing else.
Deliberately no enabled-rules or hidden-false-positives file: the four
settings are independent, and a project that configures one of them must
keep using the global lists for the other three.")

(defmacro ltex-plus-project-test--in-project (&rest body)
  "Run BODY with a project tree, a global list, and three buffers bound.
`top' and `nested' visit files in the project, at different depths;
`outside' visits a file in a separate tree governed by no
`.dir-locals.el'.  The global dictionary holds \"everywhere\" and the
global disabled rules \"GLOBAL_RULE\", so a merge is visible as a merge
rather than as one list happening to be empty."
  (declare (indent 0) (debug t))
  `(progn
     (ltex-plus-test-reset)
     (setq lsp-ltex-plus--dictionary-merged '(:en-US ["everywhere"])
           lsp-ltex-plus--disabled-rules-merged '(:en-US ["GLOBAL_RULE"]))
     (ltex-plus-test-with-project ltex-plus-project-test--spec
       (let ((outside-root (file-name-as-directory
                            (make-temp-file "ltex-plus-test-outside-" t))))
         (unwind-protect
             (progn
               (ltex-plus-test-write-file
                (expand-file-name "doc.md" outside-root) "text\n")
               (let ((top (ltex-plus-test-visit
                           (expand-file-name "doc.md" ltex-plus-test-root)))
                     (nested (ltex-plus-test-visit
                              (expand-file-name "sub/deeper/nested.md"
                                                ltex-plus-test-root)))
                     (outside (ltex-plus-test-visit
                               (expand-file-name "doc.md" outside-root)))
                     (dictionary-file
                      (expand-file-name ".ltex/dictionary.eld"
                                        ltex-plus-test-root)))
                 (ignore top nested outside dictionary-file)
                 ,@body))
           (delete-directory outside-root t))))))

;;;; -- What `.dir-locals.el' puts in the buffer -------------------------------

(ert-deftest ltex-plus-project-test-setting-reaches-the-buffer ()
  "The project's files are named in its buffers and nowhere else."
  (ltex-plus-project-test--in-project
    (should (equal (buffer-local-value 'lsp-ltex-plus-project-dictionary-file top)
                   ".ltex/dictionary.eld"))
    (should-not (buffer-local-value 'lsp-ltex-plus-project-dictionary-file
                                    outside))))

(ert-deftest ltex-plus-project-test-settings-are-independent ()
  "Configuring one list leaves the other three unset.
A project that brings a dictionary keeps using the global rule lists."
  (ltex-plus-project-test--in-project
    (should-not (buffer-local-value 'lsp-ltex-plus-project-enabled-rules-file top))
    (should-not (buffer-local-value
                 'lsp-ltex-plus-project-hidden-false-positives-file top))))

;;;; -- Resolving the path -----------------------------------------------------

(ert-deftest ltex-plus-project-test-relative-path-resolves-against-dir-locals ()
  "One project, one file, however deep the document sits.
A relative name resolves against the directory holding the
`.dir-locals.el' -- not against the document's own directory, which
would give `sub/deeper/' a dictionary of its own."
  (ltex-plus-project-test--in-project
    (should (equal (with-current-buffer top
                     (lsp-ltex-plus--project-file
                      'lsp-ltex-plus-project-dictionary-file))
                   dictionary-file))
    (should (equal (with-current-buffer nested
                     (lsp-ltex-plus--project-file
                      'lsp-ltex-plus-project-dictionary-file))
                   dictionary-file))))

(ert-deftest ltex-plus-project-test-no-project-resolves-to-nil ()
  "A buffer no `.dir-locals.el' governs has no project file."
  (ltex-plus-project-test--in-project
    (should-not (with-current-buffer outside
                  (lsp-ltex-plus--project-file
                   'lsp-ltex-plus-project-dictionary-file)))))

(ert-deftest ltex-plus-project-test-fileless-buffer-has-no-project ()
  "A buffer with no file belongs to no project and sees the global lists.
`*scratch*' and comint input have no directory-local variables; the
fallback to `default-directory' must not pick up whatever project the
Emacs process happens to be sitting in."
  (ltex-plus-project-test--in-project
    (with-temp-buffer
      (let ((default-directory ltex-plus-test-root))
        (should-not (lsp-ltex-plus--project-file-for 'dictionary))
        (should (equal (ltex-plus-test-words
                        (lsp-ltex-plus--effective-plist 'dictionary))
                       '("everywhere")))))))

;;;; -- Merging, not shadowing -------------------------------------------------

(ert-deftest ltex-plus-project-test-project-words-extend-the-global-ones ()
  "A word accepted anywhere stays accepted inside a project."
  (ltex-plus-project-test--in-project
    (should (equal (with-current-buffer top
                     (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary)))
                   '("everywhere" "Wittgenstein")))
    (should (equal (with-current-buffer nested
                     (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary)))
                   '("everywhere" "Wittgenstein")))))

(ert-deftest ltex-plus-project-test-outside-the-project-only-the-global-list ()
  "The project's words do not leak into documents elsewhere."
  (ltex-plus-project-test--in-project
    (should (equal (with-current-buffer outside
                     (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary)))
                   '("everywhere")))))

(ert-deftest ltex-plus-project-test-rules-merge-the-same-way ()
  "The merge is per kind, not special to the dictionary."
  (ltex-plus-project-test--in-project
    (should (equal (with-current-buffer top
                     (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'disabled-rules)))
                   '("GLOBAL_RULE" "PROJECT_RULE")))))

(ert-deftest ltex-plus-project-test-unconfigured-kind-contributes-nothing ()
  "A kind the project keeps no file for falls back to the global list."
  (ltex-plus-project-test--in-project
    (should (equal (with-current-buffer top
                     (lsp-ltex-plus--effective-plist 'enabled-rules))
                   lsp-ltex-plus--enabled-rules-merged))))

;;;; -- Both replies agree -----------------------------------------------------

(ert-deftest ltex-plus-project-test-both-replies-see-the-same-lists ()
  "The custom reply and the standard one cannot disagree.
Both go through `lsp-ltex-plus--effective-plist'.  The server prefers
the custom one, so a divergence would be invisible until someone turned
the custom capability off."
  (ltex-plus-project-test--in-project
    (with-current-buffer top
      (should (equal (ltex-plus-test-words
                      (plist-get (lsp-ltex-plus--workspace-specific-entry)
                                 :dictionary))
                     '("everywhere" "Wittgenstein")))
      (should (equal (ltex-plus-test-words
                      (gethash "dictionary"
                               (lsp-ltex-plus--configuration-section "ltex")))
                     '("everywhere" "Wittgenstein"))))))

;;;; -- The modification-time cache --------------------------------------------

(ert-deftest ltex-plus-project-test-file-is-read-through-the-cache ()
  "The file is not re-read on every pull.
The server pulls settings before every check, so this is a hot path.
The cache entry is poisoned here: if the disk were consulted instead,
the poison would not come back."
  (ltex-plus-project-test--in-project
    (with-current-buffer top
      (lsp-ltex-plus--effective-plist 'dictionary)
      (puthash dictionary-file
               (cons (file-attribute-modification-time
                      (file-attributes dictionary-file))
                     '(:en-US ["poison"]))
               lsp-ltex-plus--project-file-cache)
      (should (equal (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary))
                     '("everywhere" "poison"))))))

(ert-deftest ltex-plus-project-test-newer-timestamp-invalidates-the-cache ()
  "An edit to the file is picked up on the next pull."
  (ltex-plus-project-test--in-project
    (with-current-buffer top
      (lsp-ltex-plus--effective-plist 'dictionary)
      (ltex-plus-test-write-file dictionary-file "(:en-US [\"Kripke\"])")
      (set-file-times dictionary-file (time-add (current-time) 10))
      (should (equal (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary))
                     '("everywhere" "Kripke"))))))

(ert-deftest ltex-plus-project-test-deleted-file-drops-back-to-global ()
  "Removing the file returns the project to the global lists."
  (ltex-plus-project-test--in-project
    (with-current-buffer top
      (lsp-ltex-plus--effective-plist 'dictionary)
      (delete-file dictionary-file)
      (should (equal (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary))
                     '("everywhere"))))))

(ert-deftest ltex-plus-project-test-file-created-later-is-picked-up ()
  "A project file that did not exist at first is noticed once written.
A missing file caches an mtime of nil, so creating it invalidates the
entry naturally -- no reload command needed."
  (ltex-plus-project-test--in-project
    (with-current-buffer top
      (delete-file dictionary-file)
      (should (equal (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary))
                     '("everywhere")))
      (ltex-plus-test-write-file dictionary-file "(:en-US [\"Frege\"])")
      (should (equal (ltex-plus-test-words
                      (lsp-ltex-plus--effective-plist 'dictionary))
                     '("everywhere" "Frege"))))))

;;;; -- The interactive listing ------------------------------------------------

(defun ltex-plus-project-test--listing ()
  "Return what `lsp-ltex-plus-list-dictionary' reports in this buffer."
  (let ((inhibit-message t))
    (lsp-ltex-plus-list-dictionary)))

(ert-deftest ltex-plus-project-test-listing-names-the-project-file ()
  "In a project the listing shows both lists and names the file.
It answers \"why is this word accepted here\", so the file it came from
is the part that matters."
  (ltex-plus-project-test--in-project
    (let ((report (with-current-buffer top (ltex-plus-project-test--listing))))
      (should (string-match-p "everywhere" report))
      (should (string-match-p "Wittgenstein" report))
      (should (string-match-p "dictionary\\.eld" report)))))

(ert-deftest ltex-plus-project-test-listing-outside-a-project ()
  "Outside a project the listing is the global list, with no file named."
  (ltex-plus-project-test--in-project
    (let ((report (with-current-buffer outside (ltex-plus-project-test--listing))))
      (should (string-match-p "everywhere" report))
      (should-not (string-match-p "Wittgenstein" report))
      (should (string-match-p "(global)" report)))))

(provide 'ltex-plus-project-test)
;;; ltex-plus-project-test.el ends here
