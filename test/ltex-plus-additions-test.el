;;; ltex-plus-additions-test.el --- Where an accepted suggestion goes -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Reading always merges the global and project lists; writing picks one
;; of them, and `lsp-ltex-plus-save-additions-to' is the choice.  Its
;; default offers both destinations as two suggestions, which means
;; touching lsp-mode's code-action list -- in two places, since the
;; modeline counts suggestions through a different path than the menu
;; that shows them.
;;
;; The advice on both places must stay a strict pass-through for anything
;; this package does not own.  A regression there does not break
;; lsp-ltex-plus; it corrupts the code actions of whatever other server
;; the user happens to be running, which is a far worse failure and one
;; nothing in this package would report.

;;; Code:

(require 'ltex-plus-test-helper)

;; The handlers finish by telling the server its configuration changed.
;; There is no server here, and `lsp-notify' without a workspace signals.
(advice-add 'lsp-notify :override #'ignore)

(defconst ltex-plus-additions-test--spec
  '((".dir-locals.el"
     . "((nil . ((lsp-ltex-plus-project-dictionary-file
                  . \".ltex/dictionary.eld\"))))")
    ("doc.md" . "text\n"))
  "A project keeping its own dictionary -- and no rules or false-positives file.
The asymmetry is deliberate: it is what lets one fixture cover both
\"the project has a file for this kind\" and \"it does not\".")

(defmacro ltex-plus-additions-test--in-project (&rest body)
  "Run BODY with empty lists, a project buffer, and its dictionary path.
`buffer' visits a file in a project keeping its own dictionary,
`outside' one in a tree keeping nothing, and `project-dictionary' is the
path of the former's file.  Every list starts empty, so anything found
afterwards was written by the test itself."
  (declare (indent 0) (debug t))
  `(progn
     (ltex-plus-test-reset)
     (ltex-plus-test-with-project ltex-plus-additions-test--spec
       (let ((outside-root (file-name-as-directory
                            (make-temp-file "ltex-plus-test-outside-" t))))
         (unwind-protect
             (progn
               (ltex-plus-test-write-file
                (expand-file-name "doc.md" outside-root) "text\n")
               (let ((buffer (ltex-plus-test-visit
                              (expand-file-name "doc.md" ltex-plus-test-root)))
                     (outside (ltex-plus-test-visit
                               (expand-file-name "doc.md" outside-root)))
                     (project-dictionary
                      (expand-file-name ".ltex/dictionary.eld"
                                        ltex-plus-test-root)))
                 (ignore buffer outside project-dictionary)
                 ,@body))
           (delete-directory outside-root t))))))

(defun ltex-plus-additions-test--global-words (&optional kind)
  "Return the words written to KIND's global file, default `dictionary'."
  (ltex-plus-test-words
   (ltex-plus-test-read-file (ltex-plus-test-global-file (or kind 'dictionary)))))

;;;; -- The three values of the setting ----------------------------------------

(ert-deftest ltex-plus-additions-test-default-is-to-ask ()
  "The shipped default offers the choice rather than deciding.
Either other value silences the offer permanently, so a user who set up
a project dictionary would never learn the choice exists."
  (should (eq (default-value 'lsp-ltex-plus-save-additions-to)
              'either-allowing-user-choice)))

(ert-deftest ltex-plus-additions-test-per-project-prefers-the-project-file ()
  "`per-project-when-specified' writes to the project's own file."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'per-project-when-specified))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.addToDictionary" "Add 'Kripke'"
                                    :words '("Kripke")))))
    (should (equal (ltex-plus-test-words
                    (ltex-plus-test-read-file project-dictionary))
                   '("Kripke")))
    (should-not (ltex-plus-additions-test--global-words))))

(ert-deftest ltex-plus-additions-test-per-project-falls-back-to-global ()
  "With no project file of that kind the addition still lands somewhere.
A suggestion must never be a dead end -- in a scratch buffer above all,
where there is no project to write to at all."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'per-project-when-specified))
      (with-current-buffer outside
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.addToDictionary" "Add 'Quine'"
                                    :words '("Quine")))))
    (should (equal (ltex-plus-additions-test--global-words) '("Quine")))
    (should-not (ltex-plus-test-read-file project-dictionary))))

(ert-deftest ltex-plus-additions-test-per-project-falls-back-per-kind ()
  "The fallback is decided per kind, not per project.
This project keeps a dictionary but no rules file, so a disabled rule
goes global while a word would not."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'per-project-when-specified))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.disableRules" "Disable"
                                    :ruleIds '("EN_QUOTES")))))
    (should (equal (ltex-plus-additions-test--global-words 'disabled-rules)
                   '("EN_QUOTES")))))

(ert-deftest ltex-plus-additions-test-globally-defined-ignores-the-project ()
  "`globally-defined' writes to the user's own file even in a project.
Choose it to have a project's list read but only ever edited by hand."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'globally-defined))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.addToDictionary" "Add 'Frege'"
                                    :words '("Frege")))))
    (should (equal (ltex-plus-additions-test--global-words) '("Frege")))
    (should-not (ltex-plus-test-read-file project-dictionary))))

(ert-deftest ltex-plus-additions-test-project-write-is-visible-at-once ()
  "The next check sees the new word without waiting on a timestamp.
The project branch refreshes the cache entry itself; a whole-second
modification-time granularity would otherwise hide the write."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'per-project-when-specified))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.addToDictionary" "Add 'Tarski'"
                                    :words '("Tarski")))
        (should (equal (ltex-plus-test-words
                        (lsp-ltex-plus--effective-plist 'dictionary))
                       '("Tarski")))))))

(ert-deftest ltex-plus-additions-test-all-three-kinds-are-routed ()
  "Each of the three suggestion commands writes to its own list."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'globally-defined))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.addToDictionary" "Add"
                                    :words '("Godel")))
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.disableRules" "Disable"
                                    :ruleIds '("EN_QUOTES")))
        (ltex-plus-test-accept
         (ltex-plus-test-suggestion "_ltex.hideFalsePositives" "Hide"
                                    :falsePositives '("{\"rule\":\"X\"}")))))
    (should (equal (ltex-plus-additions-test--global-words) '("Godel")))
    (should (equal (ltex-plus-additions-test--global-words 'disabled-rules)
                   '("EN_QUOTES")))
    (should (equal (ltex-plus-additions-test--global-words 'hidden-false-positives)
                   '("{\"rule\":\"X\"}")))))

(ert-deftest ltex-plus-additions-test-malformed-arguments-are-reported ()
  "An action carrying nothing usable is reported, not raised.
The arguments come from the server; a shape change upstream should
produce a message, not a backtrace in the middle of the user's editing."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let ((inhibit-message t))
        (lsp-ltex-plus--action-add-to-dictionary
         (ltex-plus-test-obj :command "_ltex.addToDictionary"
                             :arguments (vector (ltex-plus-test-obj))))))
    (should-not (ltex-plus-additions-test--global-words))
    (should-not (ltex-plus-test-read-file project-dictionary))))

(ert-deftest ltex-plus-additions-test-every-language-in-one-action-is-saved ()
  "An action carrying several languages writes an entry for each."
  (ltex-plus-additions-test--in-project
    (let ((lsp-ltex-plus-save-additions-to 'globally-defined))
      (with-current-buffer buffer
        (ltex-plus-test-accept
         (ltex-plus-test-obj
          :title "Add"
          :command (ltex-plus-test-obj
                    :command "_ltex.addToDictionary"
                    :arguments (vector (ltex-plus-test-obj
                                        :words (ltex-plus-test-obj
                                                :en-US ["English"]
                                                :de-DE ["Deutsch"]))))))))
    (let ((saved (ltex-plus-test-read-file (ltex-plus-test-global-file 'dictionary))))
      (should (equal (ltex-plus-test-words saved) '("English")))
      (should (equal (ltex-plus-test-words saved :de-DE) '("Deutsch"))))))

;;;; -- Offering both destinations ---------------------------------------------

(ert-deftest ltex-plus-additions-test-suggestion-splits-in-two ()
  "One suggestion becomes two, project first, without touching the original.
The server's own object is shared with lsp-mode's caches; both variants
are built on copies."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let* ((original (ltex-plus-test-suggestion
                        "_ltex.addToDictionary" "Add 'Godel'" :words '("Godel")))
             (split (lsp-ltex-plus--expand-suggestions (list original))))
        (should (= (length split) 2))
        (should (equal (ltex-plus-test-titles split)
                       '("Add 'Godel' to project dictionary"
                         "Add 'Godel' to global dictionary")))
        (should (equal (lsp-get original :title) "Add 'Godel'"))
        (should-not (lsp-get (lsp-get original :command)
                             lsp-ltex-plus--target-marker))))))

(ert-deftest ltex-plus-additions-test-each-variant-writes-to-its-own-file ()
  "Picking a variant writes to exactly one file, never both."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let ((split (lsp-ltex-plus--expand-suggestions
                    (list (ltex-plus-test-suggestion
                           "_ltex.addToDictionary" "Add 'Godel'"
                           :words '("Godel"))))))
        (ltex-plus-test-accept (nth 0 split))
        (should (equal (ltex-plus-test-words
                        (ltex-plus-test-read-file project-dictionary))
                       '("Godel")))
        (should-not (ltex-plus-additions-test--global-words))
        (ltex-plus-test-reset)
        (delete-file project-dictionary)
        (ltex-plus-test-accept (nth 1 split))
        (should (equal (ltex-plus-additions-test--global-words) '("Godel")))
        (should-not (ltex-plus-test-read-file project-dictionary))))))

(ert-deftest ltex-plus-additions-test-titles-name-the-scope ()
  "Every kind gets a pair of titles naming project and global.
The vocabulary matches the setting's own values -- project and global,
never \"personal\": the distinction is scope, not ownership."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let ((lsp-ltex-plus-project-disabled-rules-file ".ltex/disabled-rules.eld")
            (lsp-ltex-plus-project-hidden-false-positives-file ".ltex/fps.eld"))
        (should (equal (ltex-plus-test-titles
                        (lsp-ltex-plus--expand-suggestions
                         (list (ltex-plus-test-suggestion
                                "_ltex.disableRules" "Disable rule"
                                :ruleIds '("EN_QUOTES")))))
                       '("Disable rule for this project" "Disable rule globally")))
        (should (equal (ltex-plus-test-titles
                        (lsp-ltex-plus--expand-suggestions
                         (list (ltex-plus-test-suggestion
                                "_ltex.hideFalsePositives" "Hide"
                                :falsePositives '("{}")))))
                       '("Hide false positive for this project"
                         "Hide false positive globally")))))))

(ert-deftest ltex-plus-additions-test-title-counts-several-words ()
  "A suggestion carrying more than one word says how many."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (should (equal (ltex-plus-test-titles
                      (lsp-ltex-plus--expand-suggestions
                       (list (ltex-plus-test-suggestion
                              "_ltex.addToDictionary" "Add"
                              :words '("Godel" "Kripke")))))
                     '("Add 2 words to project dictionary"
                       "Add 2 words to global dictionary"))))))

(ert-deftest ltex-plus-additions-test-no-project-file-means-no-split ()
  "With nowhere else to write, the single suggestion is left as it was.
Nothing changes for a project that keeps no lists of its own."
  (ltex-plus-additions-test--in-project
    (with-current-buffer outside
      (let* ((original (ltex-plus-test-suggestion
                        "_ltex.addToDictionary" "Add 'x'" :words '("x")))
             (result (lsp-ltex-plus--expand-suggestions (list original))))
        (should (= (length result) 1))
        (should (eq (car result) original))))))

(ert-deftest ltex-plus-additions-test-other-values-do-not-split ()
  "Only `either-allowing-user-choice' splits; the other two decide silently."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (dolist (value '(globally-defined per-project-when-specified))
        (let ((lsp-ltex-plus-save-additions-to value))
          (should (= 1 (length (lsp-ltex-plus--expand-suggestions
                                (list (ltex-plus-test-suggestion
                                       "_ltex.addToDictionary" "Add 'x'"
                                       :words '("x"))))))))))))

;;;; -- Strict pass-through for everything else --------------------------------

(ert-deftest ltex-plus-additions-test-foreign-actions-pass-through ()
  "Another server's actions come back as the same objects, not copies.
The advice is global: it sees every code action in the session,
whichever server produced it."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let* ((foreign (ltex-plus-test-obj
                       :title "Organize imports"
                       :command (ltex-plus-test-obj
                                 :command "java.organizeImports")))
             (edit-only (ltex-plus-test-obj :title "Rename symbol"))
             (nameless (ltex-plus-test-obj
                        :title "Odd"
                        :command (ltex-plus-test-obj :title "no command name")))
             (input (list foreign edit-only nameless))
             (result (lsp-ltex-plus--expand-suggestions input)))
        (should (= (length result) 3))
        (should (cl-every #'eq result input))))))

(ert-deftest ltex-plus-additions-test-sequence-type-is-preserved ()
  "A vector comes back a vector, a list a list.
`lsp-code-actions-at-point' and the modeline path do not agree on which
they use, and both are advised."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (should (vectorp (lsp-ltex-plus--expand-suggestions
                        (vector (ltex-plus-test-obj :title "x")))))
      (should (listp (lsp-ltex-plus--expand-suggestions
                      (list (ltex-plus-test-obj :title "x")))))
      (should (= 0 (length (lsp-ltex-plus--expand-suggestions nil)))))))

(ert-deftest ltex-plus-additions-test-modeline-sees-the-same-split ()
  "The modeline's count agrees with the menu.
`lsp-modeline-code-actions-segments' includes `count' by default, so
advising only the menu would leave the modeline saying one where the
list offers two."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let* ((actions (list (ltex-plus-test-suggestion
                             "_ltex.addToDictionary" "Add 'x'" :words '("x"))))
             (args (lsp-ltex-plus--expand-modeline-args (list actions 'other-arg))))
        (should (= (length (car args)) 2))
        (should (equal (cdr args) '(other-arg)))))))

(ert-deftest ltex-plus-additions-test-both-collection-points-are-advised ()
  "Both places lsp-mode collects code actions carry the advice."
  (should (advice-member-p #'lsp-ltex-plus--expand-suggestions
                           'lsp-code-actions-at-point))
  (should (advice-member-p #'lsp-ltex-plus--expand-modeline-args
                           'lsp--modeline-update-code-actions)))

;;;; -- The marker -------------------------------------------------------------

(ert-deftest ltex-plus-additions-test-marker-overrides-the-setting ()
  "A variant says where it saves, whatever the setting would have chosen.
The user picked that entry; the setting has already had its say by
producing two of them."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let ((tagged (lsp-put (lsp-copy (ltex-plus-test-obj
                                        :command "_ltex.addToDictionary"))
                             lsp-ltex-plus--target-marker "project"))
            (lsp-ltex-plus-save-additions-to 'globally-defined))
        (should (eq (lsp-ltex-plus--addition-target 'dictionary tagged)
                    'project))))))

(ert-deftest ltex-plus-additions-test-target-is-global-without-a-project ()
  "With no project file the target is global, marker or not."
  (ltex-plus-additions-test--in-project
    (with-current-buffer outside
      (let ((tagged (lsp-put (lsp-copy (ltex-plus-test-obj
                                        :command "_ltex.addToDictionary"))
                             lsp-ltex-plus--target-marker "project")))
        (should (eq (lsp-ltex-plus--addition-target 'dictionary tagged) 'global))
        (should (eq (lsp-ltex-plus--addition-target 'dictionary nil) 'global))))))

(ert-deftest ltex-plus-additions-test-unsplit-suggestion-saves-globally ()
  "Under the default, an unmarked suggestion keeps the conservative file.
It reaches the handler unsplit only if it came from somewhere other than
`lsp-ltex-plus--split-suggestion'."
  (ltex-plus-additions-test--in-project
    (with-current-buffer buffer
      (let ((lsp-ltex-plus-save-additions-to 'either-allowing-user-choice))
        (should (eq (lsp-ltex-plus--addition-target 'dictionary nil) 'global))))))

(provide 'ltex-plus-additions-test)
;;; ltex-plus-additions-test.el ends here
