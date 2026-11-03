;;; lsp-ltex-plus-bootstrap.el --- Bootstrap for lsp-ltex-plus -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-7
;; Version: 1.2.0
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; Lightweight bootstrap for lsp-ltex-plus.  This file is the only part of the
;; package that needs to be loaded at Emacs startup.  It defines the default
;; major-mode → language-ID alist and two autoloaded entry points that let the
;; full lsp-ltex-plus package load lazily — only when the user first opens a
;; file whose major mode is in the list.
;;
;; Users normally do not load this file directly; it is pulled in
;; automatically when `lsp-ltex-plus-enable-for-modes' is called from the
;; `:init' block of `use-package'.

;;; Code:

(require 'cl-lib)

;; lsp-ltex-plus-mode is defined in lsp-ltex-plus.el, which loads lazily.
;; This declaration silences the byte-compiler without creating a load-time dependency.
(declare-function lsp-ltex-plus-mode "lsp-ltex-plus")


;; This variable is defined here, in the bootstrap file, rather than in the main
;; `lsp-ltex-plus.el', so that it is available at Emacs startup without loading
;; the full package.  `lsp-ltex-plus-enable-for-modes' reads this list at `:init'
;; time to compute the effective set of enabled modes and install a single
;; dispatcher on `after-change-major-mode-hook'; that dispatcher is what
;; triggers the lazy load of `lsp-ltex-plus.el' — only when the user first
;; opens a buffer whose exact `major-mode' is in the enabled set.
;; If the list lived in `lsp-ltex-plus.el', calling `lsp-ltex-plus-enable-for-modes'
;; would force the entire package to load immediately, defeating deferred loading.
;;
;; By design, the list ships pre-populated with 80+ entries.  Many similar
;; packages ask the user to opt in to each major mode individually, but that
;; would be an unreasonable burden for a grammar checker that is useful across
;; virtually every language.  The default covers all commonly used modes; users
;; who want a narrower set can pass `:restrict-to' or `:exclude' to
;; `lsp-ltex-plus-enable-for-modes' without touching this variable at all.
(defvar lsp-ltex-plus-major-modes
  ;; Each entry is (MAJOR-MODE LANGUAGE-ID PROGRAMMING-P).
  ;; PROGRAMMING-P is nil for markup/writing languages (checked by default)
  ;; and t for programming languages (opt-in via
  ;; `lsp-ltex-plus-check-programming-languages').
  ;;
  ;; The entries are data: a mode the running Emacs does not have -- a
  ;; third-party mode that is not installed -- is a symbol nothing ever
  ;; matches, and costs nothing.  The tree-sitter modes Emacs 29.1 ships
  ;; are listed like any other; the modes that arrived with 30.1 and 31.1
  ;; (`lua-mode' among them, third-party until then) are added below
  ;; behind `fboundp', not because the table needs it but because
  ;; `package-lint' asks for a guard on any symbol newer than the declared
  ;; Emacs floor.
  (append
   ;; Markup languages (PROGRAMMING-P = nil)
   '((asciidoc-mode          "asciidoc"         nil)
     (bibtex-mode            "bibtex"           nil)
     (context-mode           "context"          nil)
     (gfm-mode               "markdown"         nil)
     (git-commit-mode        "plaintext"        nil)
     (html-mode              "html"             nil)
     (latex-mode             "latex"            nil)
     (LaTeX-mode             "latex"            nil)
     (markdown-mode          "markdown"         nil)
     (mdx-mode               "mdx"              nil)
     (norg-mode              "neorg"            nil)
     (org-mode               "org"              nil)
     (plain-tex-mode         "latex"            nil)
     (poly-markdown+r-mode   "rmd"              nil)
     (poly-noweb+r-mode      "rsweave"          nil)
     (quarto-mode            "quarto"           nil)
     (Rnw-mode               "rsweave"          nil)
     (rst-mode               "restructuredtext" nil)
     (tex-mode               "latex"            nil)
     (text-mode              "plaintext"        nil)
     (typst-mode             "typst"            nil)
     (typst-ts-mode          "typst"            nil)
     ;; Programming languages (PROGRAMMING-P = t)
     (bash-ts-mode           "shellscript"      t)
     (c++-mode               "cpp"              t)
     (c++-ts-mode            "cpp"              t)
     (c-mode                 "c"                t)
     (c-ts-mode              "c"                t)
     (clojure-mode           "clojure"          t)
     (clojure-ts-mode        "clojure"          t)
     (coffee-mode            "coffeescript"     t)
     (common-lisp-mode       "lisp"             t)
     (cperl-mode             "perl"             t)
     (csharp-mode            "csharp"           t)
     (csharp-ts-mode         "csharp"           t)
     (dart-mode              "dart"             t)
     (dart-ts-mode           "dart"             t)
     (elixir-mode            "elixir"           t)
     (elm-mode               "elm"              t)
     (emacs-lisp-mode        "elisp"            t)
     (erlang-mode            "erlang"           t)
     (ess-r-mode             "r"                t)
     (f90-mode               "fortran-modern"   t)
     (fortran-mode           "fortran-modern"   t)
     (fsharp-mode            "fsharp"           t)
     (go-mode                "go"               t)
     (go-ts-mode             "go"               t)
     (groovy-mode            "groovy"           t)
     (haskell-mode           "haskell"          t)
     (haskell-ts-mode        "haskell"          t)
     (java-mode              "java"             t)
     (java-ts-mode           "java"             t)
     (javascript-mode        "javascript"       t)
     (js-jsx-mode            "javascriptreact"  t)
     (js-mode                "javascript"       t)
     (js-ts-mode             "javascript"       t)
     (js2-mode               "javascript"       t)
     (julia-mode             "julia"            t)
     (julia-ts-mode          "julia"            t)
     (kotlin-mode            "kotlin"           t)
     (kotlin-ts-mode         "kotlin"           t)
     (lisp-mode              "lisp"             t)
     (matlab-mode            "matlab"           t)
     (perl-mode              "perl"             t)
     (perl6-mode             "perl6"            t)
     (php-mode               "php"              t)
     (powershell-mode        "powershell"       t)
     (puppet-mode            "puppet"           t)
     (python-mode            "python"           t)
     (python-ts-mode         "python"           t)
     (raku-mode              "perl6"            t)
     (rjsx-mode              "javascriptreact"  t)
     (ruby-mode              "ruby"             t)
     (ruby-ts-mode           "ruby"             t)
     (rust-mode              "rust"             t)
     (rust-ts-mode           "rust"             t)
     (rustic-mode            "rust"             t)
     (scala-mode             "scala"            t)
     (sh-mode                "shellscript"      t)
     (sql-mode               "sql"              t)
     (swift-mode             "swift"            t)
     (swift-ts-mode          "swift"            t)
     (tsx-ts-mode            "typescriptreact"  t)
     (typescript-mode        "typescript"       t)
     (typescript-ts-mode     "typescript"       t)
     (typescript-tsx-mode    "typescriptreact"  t)
     (verilog-mode           "verilog"          t)
     (visual-basic-mode      "vb"               t))
   ;; Tree-sitter modes newer than the floor; see the comment above.
   ;; Emacs 30.1:
   (when (fboundp 'elixir-ts-mode)   '((elixir-ts-mode   "elixir"   t)))
   (when (fboundp 'html-ts-mode)     '((html-ts-mode     "html"     nil)))
   (when (fboundp 'lua-ts-mode)      '((lua-ts-mode      "lua"      t)))
   (when (fboundp 'php-ts-mode)      '((php-ts-mode      "php"      t)))
   ;; Emacs 31.1:
   (when (fboundp 'lua-mode)         '((lua-mode         "lua"      t)))
   (when (fboundp 'markdown-ts-mode) '((markdown-ts-mode "markdown" nil)))
   (when (fboundp 'mhtml-ts-mode)    '((mhtml-ts-mode    "html"     nil))))
  "List of (MAJOR-MODE LANGUAGE-ID PROGRAMMING-P) entries for lsp-ltex-plus.

Each entry registers a major mode with its VS Code language identifier and
category:

  MAJOR-MODE    — Emacs major mode symbol.
  LANGUAGE-ID   — VS Code language identifier string, used in the LSP wire
                  protocol and by LTeX+ to select grammar rules.  The
                  canonical list is at URL
                  `https://code.visualstudio.com/docs/languages/identifiers'.
  PROGRAMMING-P — nil for markup/writing languages (LaTeX, Markdown, Org, …),
                  which LTeX+ checks by default.  t for programming languages
                  (Python, C, Rust, …), which LTeX+ checks only in comments
                  and only when `lsp-ltex-plus-check-programming-languages'
                  is non-nil.

This variable is intentionally not autoloaded; it is defined here so that
`lsp-ltex-plus-enable-for-modes' can read it at startup without loading the
full `lsp-ltex-plus' package.")

(defvar lsp-ltex-plus--enabled-modes nil
  "Effective set of major-mode symbols for which lsp-ltex-plus is enabled.
Populated by `lsp-ltex-plus-enable-for-modes' from the result of applying
`:restrict-to', `:exclude', and `:extend-to' to `lsp-ltex-plus-major-modes'.
Consulted at runtime by `lsp-ltex-plus--maybe-activate' (attached to
`after-change-major-mode-hook') to decide whether to turn on
`lsp-ltex-plus-mode' in the current buffer.  Matching is strict — only an
exact `eq' match against `major-mode' activates the client, so parent-mode
relationships (e.g. `org-mode' deriving from `text-mode') never leak
activation into buffers the user did not select.")

(defun lsp-ltex-plus--maybe-activate ()
  "Enable `lsp-ltex-plus-mode' when `major-mode' is in the enabled set.
Attached once to `after-change-major-mode-hook' by
`lsp-ltex-plus-enable-for-modes'.  The full `lsp-ltex-plus' package is loaded
lazily on the first call that reaches `lsp-ltex-plus-mode'.

Buffers without a file name are activated only when
`lsp-ltex-plus-check-fileless-buffers' says so, which it does by
default; set it to nil to filter out transient buffers created by other
modes (e.g., markdown-mode's syntax-highlighting helpers that spawn
buffers in `python-ts-mode').  The variable lives in the lazily-loaded
full package, so it is read with `bound-and-true-p' to avoid forcing
that load from the dispatcher."
  (when (and (memq major-mode lsp-ltex-plus--enabled-modes)
             (or (buffer-file-name)
                 (bound-and-true-p lsp-ltex-plus-check-fileless-buffers)))
    (lsp-ltex-plus-mode 1)))

;;;###autoload
(cl-defun lsp-ltex-plus-enable-for-modes (&key restrict-to exclude extend-to)
  "Enable `lsp-ltex-plus-mode' in the selected major modes.

Installs a single dispatcher on `after-change-major-mode-hook' that activates
the client in any buffer whose `major-mode' exactly matches one of the
selected modes.  Exact matching means parent-mode relationships do not cause
spurious activations: excluding `org-mode' keeps the client out of org
buffers even though `org-mode' derives from `text-mode'.

With no arguments, every major mode listed in `lsp-ltex-plus-major-modes\\='
is enabled.

The effective set of modes is built in three steps:

1. RESTRICT-TO — whitelist.  If non-nil, must be a list of major-mode symbols.
   Only modes present in both RESTRICT-TO and `lsp-ltex-plus-major-modes\\='
   are considered; any symbol not found in the alist is silently skipped.
   Omit this keyword to start from the full default list.

   (lsp-ltex-plus-enable-for-modes
     :restrict-to \\='(org-mode markdown-mode latex-mode LaTeX-mode))

2. EXCLUDE — blacklist.  If non-nil, must be a list of major-mode symbols.
   Those modes are removed from the list produced by step 1.  Use this to
   drop a few unwanted modes from the large default list without having to
   enumerate all the ones you do want:

   (lsp-ltex-plus-enable-for-modes
     :exclude \\='(python-mode c-mode c++-mode))

3. EXTEND-TO — additions.  If non-nil, must be a list of
   (MAJOR-MODE LANGUAGE-ID PROGRAMMING-P) entries following the same format
   as `lsp-ltex-plus-major-modes\\='.  These entries are appended after steps
   1 and 2, so they are never excluded.  Use this to enable modes that are
   absent from the built-in list:

   (lsp-ltex-plus-enable-for-modes
     :extend-to \\='((my-custom-mode \"plaintext\" nil)))

All three keywords may be combined:

  (lsp-ltex-plus-enable-for-modes
    :restrict-to \\='(org-mode markdown-mode)
    :exclude     \\='(markdown-mode)       ; hypothetical, for illustration
    :extend-to   \\='((my-custom-mode \"plaintext\" nil)))

The full lsp-ltex-plus package is loaded lazily — only when a selected major
mode is first activated in some buffer.

Because `lsp-ltex-plus-major-modes\\=' is read at call time, any direct
modification of that variable must happen BEFORE this function is called.
Since it is a plain `defvar\\=' (not a `defcustom\\='), use `setq\\=' before
the `use-package\\=' block:

  (setq lsp-ltex-plus-major-modes
        \\='((markdown-mode \"markdown\" nil)
          (org-mode      \"org\"      nil)))

  (use-package lsp-ltex-plus
    :defer t
    :init
    (lsp-ltex-plus-enable-for-modes))

In most cases the keyword arguments above are sufficient and direct
modification of `lsp-ltex-plus-major-modes\\=' is not needed.

Calling this function again replaces the enabled set; the dispatcher itself
is installed only once."
  (let ((pairs (if restrict-to
                   (delq nil (mapcar (lambda (m) (assq m lsp-ltex-plus-major-modes))
                                     restrict-to))
                 (copy-sequence lsp-ltex-plus-major-modes))))
    (when exclude
      (setq pairs (cl-remove-if (lambda (pair) (memq (car pair) exclude)) pairs)))
    (when extend-to
      (setq pairs (append pairs extend-to)))
    (setq lsp-ltex-plus--enabled-modes (mapcar #'car pairs))
    (lsp-ltex-plus-register-safe-variables)
    (add-hook 'after-change-major-mode-hook #'lsp-ltex-plus--maybe-activate)))

;;;; -- Directory-local safety -------------------------------------------------

;; These declarations live here, not on the defcustoms, because Emacs reads a
;; project's `.dir-locals.el' when it visits a file, before
;; `after-change-major-mode-hook' runs the dispatcher that loads the full
;; package.  A `:safe' on a defcustom in `lsp-ltex-plus-settings.el' does not
;; exist yet at that moment, so Emacs asked about every value the package
;; vouches for in the first file of the session.
;;
;; Directory-local safety, modelled on AUCTeX (and on Emacs core, which declares
;; `fill-column' safe for an integer and `indent-tabs-mode' for a boolean).  The
;; package vouches for a setting with a predicate rather than leaving every
;; user to answer the same question in every project:
;;
;;   - Settings that can only change how text is checked are declared safe on a
;;     type check alone.  The worst a `.dir-locals.el' can do with them is check
;;     in the wrong language, or accept a word you did not choose.
;;   - Settings naming a file this package *writes* are held to more than a type
;;     check: see `lsp-ltex-plus--project-file-safe-p', which follows AUCTeX's
;;     `TeX--output-dir-safe-p' in accepting only a name that cannot lead
;;     outside the tree its `.dir-locals.el' governs.
;;   - Four live settings are deliberately left unvouched for, so that Emacs
;;     asks before a repository you cloned can set them.  Do not "complete"
;;     the set by adding them to `lsp-ltex-plus--safe-variables':
;;
;;     The line is drawn at security threats, not at configurations a user
;;     might find surprising -- those are the user's responsibility.  So the
;;     LanguageTool credentials are vouched for (a `.dir-locals.el' can only
;;     set a variable, never read one, so a repository cannot learn a key
;;     this way; substituting its own is visible in its own file), and so is
;;     the n-gram model directory, whose worst case is that its extra rules
;;     do not work.
;;
;;     `lsp-ltex-plus-lt-server-uri' is the middle case: it names the host
;;     every document you edit is sent to, so it is vouched for by an
;;     allowlist of destinations rather than by a type check.  Unset and
;;     LanguageTool Premium pass; any other host still asks.  See
;;     `lsp-ltex-plus--lt-server-uri-safe-p'.
;;
;;     Settings read only at server start or at client setup are not in the
;;     table either — not because they are dangerous, but because a
;;     project-local value would silently do nothing, and vouching for it
;;     would imply otherwise.

(defun lsp-ltex-plus--symbol-keyed-alist-p (value)
  "Non-nil when VALUE is an alist of symbol keys with string or boolean values.
The shape the parser tables take — `lsp-ltex-plus-bibtex-fields',
`-latex-commands', `-latex-environments', `-markdown-nodes'.  Used as
their safety predicate: such a value only changes how a document is
parsed before it is checked, so a project may set one without asking."
  (and (listp value)
       (cl-every (lambda (cell)
                   (and (consp cell)
                        (symbolp (car cell))
                        (or (stringp (cdr cell))
                            (memq (cdr cell) '(t nil)))))
                 value)))

(defun lsp-ltex-plus--language-plist-p (value)
  "Non-nil when VALUE is a language-keyed plist of vectors of strings.
The shape the four language-keyed settings take, e.g.
\\='(:en-US [\"foo\"] :de-DE [\"bar\"]).  Used as the safety predicate for
those settings: a value of this shape only ever adds words or rule
names to a check, so a project may set one without confirmation."
  (and (listp value)
       (cl-evenp (length value))
       (cl-loop for (key val) on value by #'cddr
                always (and (keywordp key)
                            (vectorp val)
                            (cl-every #'stringp val)))))

(defconst lsp-ltex-plus--vouched-lt-server-uris
  '("https://api.languagetoolplus.com"
    "https://api.languagetoolplus.com/")
  "LanguageTool endpoints a project may select without being asked.
Only LanguageTool's own Premium service.  Everything reached through
this setting receives the full text of every document you edit, so the
list is an allowlist of destinations, not a syntax check: any other
host stays subject to Emacs' usual confirmation.")

(defun lsp-ltex-plus--lt-server-uri-safe-p (value)
  "Non-nil when VALUE is an endpoint safe to accept from a `.dir-locals.el'.
Unset (nil, or the empty string an older config may still carry) means
the local built-in LanguageTool and sends nothing anywhere.  The only
remote destination vouched for is LanguageTool's own Premium service;
see `lsp-ltex-plus--vouched-lt-server-uris'.  Between them these are
what nearly every configuration uses, so the prompt is reserved for the
case that genuinely warrants one: a project pointing your prose at some
other host."
  (or (null value)
      (and (stringp value)
           (or (equal value "")
               (member value lsp-ltex-plus--vouched-lt-server-uris)))))

(defun lsp-ltex-plus--project-file-safe-p (value)
  "Non-nil when VALUE is safe as a directory-local project settings file.
Safe means nil, or a relative name with no `..' component — one that
cannot reach outside the tree its `.dir-locals.el' governs.  This package
creates and writes these files, so a name that could escape that tree is
left for the user to confirm in the usual way.  Modelled on AUCTeX's
`TeX--output-dir-safe-p', which applies the same rule to `TeX-output-dir'
for the same reason."
  (or (null value)
      (and (stringp value)
           (not (file-name-absolute-p value))
           (not (member ".." (split-string value "/" t))))))

(defun lsp-ltex-plus--diagnostics-provider-p (value)
  "Non-nil when VALUE is one of the `lsp-ltex-plus-diagnostics-provider' choices."
  (memq value '(flymake flycheck)))

(defun lsp-ltex-plus--save-additions-to-p (value)
  "Non-nil when VALUE is one of the `lsp-ltex-plus-save-additions-to' choices."
  (memq value '(globally-defined per-project-when-specified
                either-allowing-user-choice)))

(defconst lsp-ltex-plus--safe-variables
  '((lsp-ltex-plus-language                            . stringp)
    (lsp-ltex-plus-offered-languages                   . list-of-strings-p)
    (lsp-ltex-plus-dictionary                          . lsp-ltex-plus--language-plist-p)
    (lsp-ltex-plus-enabled-rules                       . lsp-ltex-plus--language-plist-p)
    (lsp-ltex-plus-disabled-rules                      . lsp-ltex-plus--language-plist-p)
    (lsp-ltex-plus-hidden-false-positives              . lsp-ltex-plus--language-plist-p)
    (lsp-ltex-plus-bibtex-fields                       . lsp-ltex-plus--symbol-keyed-alist-p)
    (lsp-ltex-plus-latex-commands                      . lsp-ltex-plus--symbol-keyed-alist-p)
    (lsp-ltex-plus-latex-environments                  . lsp-ltex-plus--symbol-keyed-alist-p)
    (lsp-ltex-plus-markdown-nodes                      . lsp-ltex-plus--symbol-keyed-alist-p)
    (lsp-ltex-plus-additional-rules-enable-picky-rules . booleanp)
    (lsp-ltex-plus-additional-rules-mother-tongue      . string-or-null-p)
    (lsp-ltex-plus-additional-rules-language-model     . string-or-null-p)
    (lsp-ltex-plus-lt-server-uri                       . lsp-ltex-plus--lt-server-uri-safe-p)
    (lsp-ltex-plus-lt-username                         . string-or-null-p)
    (lsp-ltex-plus-lt-api-key                          . string-or-null-p)
    (lsp-ltex-plus-lt-offline-fallback                 . booleanp)
    (lsp-ltex-plus-lt-timeout-seconds                  . integerp)
    (lsp-ltex-plus-max-request-size                    . integerp)
    (lsp-ltex-plus-paragraph-cache-ttl-minutes         . integerp)
    (lsp-ltex-plus-paragraph-cache-enabled             . booleanp)
    (lsp-ltex-plus-completion-enabled                  . booleanp)
    (lsp-ltex-plus-diagnostic-severity                 . stringp)
    (lsp-ltex-plus-check-frequency                     . stringp)
    (lsp-ltex-plus-check-programming-languages         . booleanp)
    (lsp-ltex-plus-idle-delay                          . numberp)
    (lsp-ltex-plus-clear-diagnostics-when-closing-file . booleanp)
    (lsp-ltex-plus-check-fileless-buffers              . booleanp)
    (lsp-ltex-plus-disable-flyspell                    . booleanp)
    (lsp-ltex-plus-diagnostics-provider                . lsp-ltex-plus--diagnostics-provider-p)
    (lsp-ltex-plus-check-comint-input                  . booleanp)
    (lsp-ltex-plus-dictionary-project-file             . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-enabled-rules-project-file          . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-disabled-rules-project-file         . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-hidden-false-positives-project-file . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-save-additions-to                   . lsp-ltex-plus--save-additions-to-p)
    ;; Obsolete names.  `safe-local-variable' does not follow an alias, so
    ;; a project whose `.dir-locals.el' still names an old variable would
    ;; start asking the user to approve a value this package has always
    ;; vouched for.
    (lsp-ltex-plus-change-delay                        . numberp)
    (lsp-ltex-plus-project-dictionary-file             . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-project-enabled-rules-file          . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-project-disabled-rules-file         . lsp-ltex-plus--project-file-safe-p)
    (lsp-ltex-plus-project-hidden-false-positives-file . lsp-ltex-plus--project-file-safe-p))
  "Settings a `.dir-locals.el' may set without a prompt, with their predicates.
Each entry is (VARIABLE . PREDICATE); `lsp-ltex-plus-register-safe-variables'
puts PREDICATE on VARIABLE's `safe-local-variable' property.")

(defvar lsp-ltex-plus--safe-variables-registered nil
  "Non-nil once `lsp-ltex-plus-register-safe-variables' has run.")

;;;###autoload
(defun lsp-ltex-plus-register-safe-variables ()
  "Declare which values of this package's settings are safe as directory-local.
Emacs applies such a value from a project's `.dir-locals.el' without
asking.  `lsp-ltex-plus-enable-for-modes' calls this function, and so
does loading the package; call it yourself from `:init' only if you do
not call `lsp-ltex-plus-enable-for-modes', since Emacs reads the
directory-local values of the first file you visit before the package
is loaded.  Calling it again does nothing."
  (unless lsp-ltex-plus--safe-variables-registered
    (pcase-dolist (`(,variable . ,predicate) lsp-ltex-plus--safe-variables)
      (put variable 'safe-local-variable predicate))
    (setq lsp-ltex-plus--safe-variables-registered t)))

(provide 'lsp-ltex-plus-bootstrap)
;;; lsp-ltex-plus-bootstrap.el ends here
