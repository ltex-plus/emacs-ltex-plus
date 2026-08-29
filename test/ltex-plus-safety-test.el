;;; ltex-plus-safety-test.el --- Safe directory-local values -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Every setting this client reads per document is declared `:safe', so a
;; project's `.dir-locals.el' applies without a prompt.  The policy behind
;; those declarations is the thing worth pinning down, because it is a
;; judgement rather than a mechanism, and both directions of drift are
;; easy and quiet:
;;
;;   * A predicate loosened to `stringp' stops asking about something that
;;     should ask.  Two settings are qualified rather than type-checked --
;;     the LanguageTool endpoint, which names the host documents are sent
;;     to, and the four project file paths, which this package writes to.
;;
;;   * A predicate added where a type check was enough starts asking about
;;     something harmless, once per project per session.  The line is
;;     security threats, not configurations a user might regret; the
;;     credentials and the n-gram model directory are on the near side of
;;     it and the reasons are recorded in the source.
;;
;; The list of settings at the bottom is the other half: a new
;; project-scopable defcustom that forgets its `:safe' declaration works
;; perfectly for its author and prompts everyone else.

;;; Code:

(require 'ltex-plus-test-helper)

;;;; -- The LanguageTool endpoint ----------------------------------------------

(ert-deftest ltex-plus-safety-test-endpoint-allows-the-known-destinations ()
  "Unset, or LanguageTool's own API, applies without asking.
The empty string is the value older configurations carry, from before
these settings defaulted to nil."
  (should (lsp-ltex-plus--lt-server-uri-safe-p nil))
  (should (lsp-ltex-plus--lt-server-uri-safe-p ""))
  (should (lsp-ltex-plus--lt-server-uri-safe-p "https://api.languagetoolplus.com"))
  (should (lsp-ltex-plus--lt-server-uri-safe-p "https://api.languagetoolplus.com/")))

(ert-deftest ltex-plus-safety-test-endpoint-is-an-allowlist-not-a-type-check ()
  "Anything else falls through to Emacs' confirmation.
This setting decides which host every document in the project is sent
to, so the predicate names destinations rather than checking a type.  A
lookalike hostname is the case that matters: it is a string, it parses,
and it is not LanguageTool."
  (should-not (lsp-ltex-plus--lt-server-uri-safe-p "https://evil.example"))
  (should-not (lsp-ltex-plus--lt-server-uri-safe-p
               "https://api.languagetoolplus.com.evil.example"))
  (should-not (lsp-ltex-plus--lt-server-uri-safe-p
               "https://api.languagetoolplus.com.evil.example/"))
  (should-not (lsp-ltex-plus--lt-server-uri-safe-p
               "http://api.languagetoolplus.com"))
  ;; The server appends `/v2/check', so a path here is wrong as well as
  ;; unvouched-for; see the README's note on the doubled `/v2'.
  (should-not (lsp-ltex-plus--lt-server-uri-safe-p
               "https://api.languagetoolplus.com/v2")))

;;;; -- Project file paths -----------------------------------------------------

(ert-deftest ltex-plus-safety-test-project-path-must-stay-inside-the-tree ()
  "A relative name with no `..' applies; anything that can escape asks.
This package creates and writes these files.  Vouching for a plain
`stringp' would let any cloned repository redirect where word lists are
read from and written to, without a prompt.  Modelled on AUCTeX's
`TeX--output-dir-safe-p', for the same reason."
  (should (lsp-ltex-plus--project-file-safe-p nil))
  (should (lsp-ltex-plus--project-file-safe-p ".ltex/dictionary.eld"))
  (should (lsp-ltex-plus--project-file-safe-p "words.eld"))
  (should-not (lsp-ltex-plus--project-file-safe-p "/etc/words.eld"))
  (should-not (lsp-ltex-plus--project-file-safe-p "~/words.eld"))
  (should-not (lsp-ltex-plus--project-file-safe-p "../words.eld"))
  (should-not (lsp-ltex-plus--project-file-safe-p "a/../../words.eld"))
  (should-not (lsp-ltex-plus--project-file-safe-p 42)))

;;;; -- Shapes -----------------------------------------------------------------

(ert-deftest ltex-plus-safety-test-language-plist-shape ()
  "The four word lists are language keywords mapped to string vectors."
  (should (lsp-ltex-plus--language-plist-p nil))
  (should (lsp-ltex-plus--language-plist-p '(:en-US ["a"] :de-DE ["b"])))
  (should-not (lsp-ltex-plus--language-plist-p '(:en-US [1 2])))
  (should-not (lsp-ltex-plus--language-plist-p '(:en-US ("a"))))
  (should-not (lsp-ltex-plus--language-plist-p '(:en-US)))
  (should-not (lsp-ltex-plus--language-plist-p "not a plist")))

(ert-deftest ltex-plus-safety-test-symbol-keyed-alist-shape ()
  "The four parser tables are symbol-keyed alists of strings."
  (should (lsp-ltex-plus--symbol-keyed-alist-p nil))
  (should (lsp-ltex-plus--symbol-keyed-alist-p '((\\footnote . "ignore"))))
  (should-not (lsp-ltex-plus--symbol-keyed-alist-p '(("string-key" . "ignore"))))
  (should-not (lsp-ltex-plus--symbol-keyed-alist-p "not an alist")))

(ert-deftest ltex-plus-safety-test-save-additions-to-shape ()
  "Only the three documented choices are accepted."
  (dolist (value '(globally-defined per-project-when-specified
                   either-allowing-user-choice))
    (should (lsp-ltex-plus--save-additions-to-p value)))
  (should-not (lsp-ltex-plus--save-additions-to-p 'sometimes))
  (should-not (lsp-ltex-plus--save-additions-to-p nil)))

;;;; -- Which predicate is on which setting ------------------------------------

(ert-deftest ltex-plus-safety-test-qualified-predicates-are-in-place ()
  "The two settings that need more than a type check carry it."
  (should (eq (get 'lsp-ltex-plus-lt-server-uri 'safe-local-variable)
              #'lsp-ltex-plus--lt-server-uri-safe-p))
  (dolist (setting '(lsp-ltex-plus-project-dictionary-file
                     lsp-ltex-plus-project-enabled-rules-file
                     lsp-ltex-plus-project-disabled-rules-file
                     lsp-ltex-plus-project-hidden-false-positives-file))
    (should (eq (get setting 'safe-local-variable)
                #'lsp-ltex-plus--project-file-safe-p))))

(ert-deftest ltex-plus-safety-test-credentials-are-vouched-for ()
  "Credentials and the n-gram directory pass on a type check, deliberately.
A `.dir-locals.el' can set a variable but never read one, so a
repository cannot learn an API key by declaring it; substituting its own
is written plainly in its own file.  Adding a predicate here would cost
a prompt every time and buy nothing."
  (dolist (setting '(lsp-ltex-plus-lt-username
                     lsp-ltex-plus-lt-api-key
                     lsp-ltex-plus-additional-rules-language-model
                     lsp-ltex-plus-additional-rules-mother-tongue))
    (should (eq (get setting 'safe-local-variable) #'string-or-null-p))))

(ert-deftest ltex-plus-safety-test-every-per-document-setting-is-declared ()
  "Each setting read per document can be set from a `.dir-locals.el'.
A missing declaration is invisible to whoever added the setting -- they
have already answered the prompt once -- and prompts everybody else on
every project.  Settings read only at server start or client setup are
deliberately absent from this list: vouching for a value that would
silently do nothing would say it works."
  (let ((undeclared
         (seq-remove
          (lambda (setting) (get setting 'safe-local-variable))
          '(lsp-ltex-plus-language
            lsp-ltex-plus-dictionary
            lsp-ltex-plus-enabled-rules
            lsp-ltex-plus-disabled-rules
            lsp-ltex-plus-hidden-false-positives
            lsp-ltex-plus-check-frequency
            lsp-ltex-plus-diagnostic-severity
            lsp-ltex-plus-check-programming-languages
            lsp-ltex-plus-check-fileless-buffers
            lsp-ltex-plus-check-comint-input
            lsp-ltex-plus-additional-rules-enable-picky-rules
            lsp-ltex-plus-additional-rules-mother-tongue
            lsp-ltex-plus-additional-rules-language-model
            lsp-ltex-plus-bibtex-fields
            lsp-ltex-plus-latex-commands
            lsp-ltex-plus-latex-environments
            lsp-ltex-plus-markdown-nodes
            lsp-ltex-plus-lt-server-uri
            lsp-ltex-plus-lt-username
            lsp-ltex-plus-lt-api-key
            lsp-ltex-plus-max-request-size
            lsp-ltex-plus-paragraph-cache-ttl-minutes
            lsp-ltex-plus-paragraph-cache-enabled
            lsp-ltex-plus-completion-enabled
            lsp-ltex-plus-clear-diagnostics-when-closing-file
            lsp-ltex-plus-save-additions-to
            lsp-ltex-plus-project-dictionary-file
            lsp-ltex-plus-project-enabled-rules-file
            lsp-ltex-plus-project-disabled-rules-file
            lsp-ltex-plus-project-hidden-false-positives-file))))
    (should-not undeclared)))

(ert-deftest ltex-plus-safety-test-declared-predicates-accept-the-default ()
  "Every declaration vouches for the value the setting ships with.
A predicate that rejects its own default is wrong about something --
usually nil, which is what a setting reads as before a project sets it."
  (mapatoms
   (lambda (symbol)
     (when (and (string-prefix-p "lsp-ltex-plus-" (symbol-name symbol))
                (custom-variable-p symbol)
                (get symbol 'safe-local-variable))
       (let ((predicate (get symbol 'safe-local-variable))
             (default (default-value symbol)))
         (should (funcall predicate default)))))))

(provide 'ltex-plus-safety-test)
;;; ltex-plus-safety-test.el ends here
