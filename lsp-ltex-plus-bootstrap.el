;;; lsp-ltex-plus-bootstrap.el --- Bootstrap for lsp-ltex-plus -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Version: 0.3.4
;; Package-Requires: ((emacs "27.1"))
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/alberti42/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; Lightweight bootstrap for lsp-ltex-plus.  This file is the only part of
;; the package that needs to be loaded at Emacs startup.  It defines the
;; default major-mode → language-ID alist and two autoloaded entry points
;; that let the full lsp-ltex-plus package load lazily — only when the user
;; first opens a file whose major mode is in the list.
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
  ;; Entries for modes that ship with newer Emacs (mainly tree-sitter modes
  ;; introduced in 29.1 / 30.1) are appended below via per-symbol `fboundp'
  ;; guards.  This keeps the package's minimum-Emacs floor at 27.1 while
  ;; still picking up the newer modes when the user is on a recent Emacs
  ;; (or has the matching third-party package installed on an older one).
  (append
   ;; Always available (Emacs 27.1+, or long-standing third-party MELPA
   ;; packages).
   ;;
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
     (markdown-ts-mode       "markdown"         nil)
     (mdx-mode               "mdx"              nil)
     (mhtml-ts-mode          "html"             nil)
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
     (c-mode                 "c"                t)
     (c++-mode               "cpp"              t)
     (clojure-mode           "clojure"          t)
     (clojure-ts-mode        "clojure"          t)
     (coffee-mode            "coffeescript"     t)
     (common-lisp-mode       "lisp"             t)
     ;; (emacs-lisp-mode     "lisp"             t)
     (cperl-mode             "perl"             t)
     (dart-mode              "dart"             t)
     (dart-ts-mode           "dart"             t)
     (elixir-mode            "elixir"           t)
     (elm-mode               "elm"              t)
     (erlang-mode            "erlang"           t)
     (ess-r-mode             "r"                t)
     (f90-mode               "fortran-modern"   t)
     (fortran-mode           "fortran-modern"   t)
     (fsharp-mode            "fsharp"           t)
     (go-mode                "go"               t)
     (groovy-mode            "groovy"           t)
     (haskell-mode           "haskell"          t)
     (haskell-ts-mode        "haskell"          t)
     (java-mode              "java"             t)
     (javascript-mode        "javascript"       t)
     (js-mode                "javascript"       t)
     (js-jsx-mode            "javascriptreact"  t)
     (js2-mode               "javascript"       t)
     (julia-mode             "julia"            t)
     (julia-ts-mode          "julia"            t)
     (kotlin-mode            "kotlin"           t)
     (kotlin-ts-mode         "kotlin"           t)
     (lisp-mode              "lisp"             t)
     (lua-mode               "lua"              t)
     (matlab-mode            "matlab"           t)
     (perl-mode              "perl"             t)
     (perl6-mode             "perl6"            t)
     (php-mode               "php"              t)
     (powershell-mode        "powershell"       t)
     (puppet-mode            "puppet"           t)
     (python-mode            "python"           t)
     (raku-mode              "perl6"            t)
     (rjsx-mode              "javascriptreact"  t)
     (ruby-mode              "ruby"             t)
     (rust-mode              "rust"             t)
     (rustic-mode            "rust"             t)
     (scala-mode             "scala"            t)
     (sh-mode                "shellscript"      t)
     (sql-mode               "sql"              t)
     (swift-mode             "swift"            t)
     (swift-ts-mode          "swift"            t)
     (typescript-mode        "typescript"       t)
     (typescript-tsx-mode    "typescriptreact"  t)
     (verilog-mode           "verilog"          t)
     (visual-basic-mode      "vb"               t))
   ;; Modes added in newer Emacs releases (mostly tree-sitter built-ins).
   ;; Each entry is gated by its own `fboundp' check, so it appears when
   ;; the mode is available (built-in on Emacs 29.1+/30.1+, or third-party
   ;; on older Emacs) and stays silent otherwise.  The same idiom is what
   ;; `package-lint' expects for any reference to a symbol added after the
   ;; declared minimum-Emacs floor.
   (when (fboundp 'bash-ts-mode)       '((bash-ts-mode       "shellscript"      t)))
   (when (fboundp 'c-ts-mode)          '((c-ts-mode          "c"                t)))
   (when (fboundp 'c++-ts-mode)        '((c++-ts-mode        "cpp"              t)))
   (when (fboundp 'csharp-mode)        '((csharp-mode        "csharp"           t)))
   (when (fboundp 'csharp-ts-mode)     '((csharp-ts-mode     "csharp"           t)))
   (when (fboundp 'elixir-ts-mode)     '((elixir-ts-mode     "elixir"           t)))
   (when (fboundp 'go-ts-mode)         '((go-ts-mode         "go"               t)))
   (when (fboundp 'html-ts-mode)       '((html-ts-mode       "html"             nil)))
   (when (fboundp 'java-ts-mode)       '((java-ts-mode       "java"             t)))
   (when (fboundp 'js-ts-mode)         '((js-ts-mode         "javascript"       t)))
   (when (fboundp 'lua-ts-mode)        '((lua-ts-mode        "lua"              t)))
   (when (fboundp 'php-ts-mode)        '((php-ts-mode        "php"              t)))
   (when (fboundp 'python-ts-mode)     '((python-ts-mode     "python"           t)))
   (when (fboundp 'ruby-ts-mode)       '((ruby-ts-mode       "ruby"             t)))
   (when (fboundp 'rust-ts-mode)       '((rust-ts-mode       "rust"             t)))
   (when (fboundp 'tsx-ts-mode)        '((tsx-ts-mode        "typescriptreact"  t)))
   (when (fboundp 'typescript-ts-mode) '((typescript-ts-mode "typescript"       t))))
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

Buffers without a file name are skipped, since `lsp-mode's machinery
is built around `file://' URIs.  This filters out transient buffers
created by other modes (e.g., markdown-mode's syntax-highlighting
helpers that spawn buffers in `python-ts-mode')."
  (when (and (memq major-mode lsp-ltex-plus--enabled-modes)
             (buffer-file-name))
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
    (add-hook 'after-change-major-mode-hook #'lsp-ltex-plus--maybe-activate)))

;;;###autoload
(define-obsolete-function-alias 'lsp-ltex-plus-install-hooks
  'lsp-ltex-plus-enable-for-modes "0.2.0")


(provide 'lsp-ltex-plus-bootstrap)
;;; lsp-ltex-plus-bootstrap.el ends here
