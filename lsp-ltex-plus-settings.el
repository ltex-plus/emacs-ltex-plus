;;; lsp-ltex-plus-settings.el --- Settings and word lists for lsp-ltex-plus -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; The part of `lsp-ltex-plus' that knows nothing about the wire: every
;; user-facing setting, the debug log, the four language-keyed word lists
;; with their on-disk mirrors and merged views, a project's own copies of
;; those lists read through `.dir-locals.el', and the decision of where an
;; accepted suggestion is written.
;;
;; Nothing here talks to a server or to a protocol library.  The client
;; layer in `lsp-ltex-plus.el' reads these variables when it answers the
;; server's configuration requests and calls into this file when a code
;; action adds an entry to a list.  Keeping the two apart is what lets the
;; settings be tested, and reasoned about, without a connection.

;;; Code:

(require 'seq)
(require 'cl-lib)
(require 'lsp-ltex-plus-bootstrap)

;;;; -- Customization ----------------------------------------------------------

(defgroup lsp-ltex-plus nil
  "Customization group for the LTEX+ grammar checker."
  :group 'lsp-mode
  :prefix "lsp-ltex-plus-")

;; Directory-local safety, modelled on AUCTeX (and on Emacs core, which declares
;; `fill-column' safe for an integer and `indent-tabs-mode' for a boolean).  The
;; package vouches for a setting with `:safe' and a predicate rather than
;; leaving every user to answer the same question in every project:
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
;;     the set by adding `:safe' to them:
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
;;     Settings read only at server start or at client setup carry no `:safe'
;;     either — not because they are dangerous, but because a project-local
;;     value would silently do nothing, and vouching for it would imply
;;     otherwise.

(defcustom lsp-ltex-plus-ls-plus-executable "ltex-ls-plus"
  "The name or path of the ltex-ls-plus executable."
  :type 'string
  :group 'lsp-ltex-plus)

(defconst lsp-ltex-plus-minimum-server-version "18.7.0"
  "Oldest `ltex-ls-plus' this package works against.

Deliberately not a user option.  This is a fact about what the package
requires, not a preference: making it settable would mostly offer a way
to silence a real problem, and a silenced version mismatch reappears as
a diagnostic that never arrives.

An older server does not fail outright, it lacks features this package
assumes, so falling short is reported rather than refused.

Only the leading numbers are compared, so a pre-release such as
\"18.7.1-alpha.32+2026-08-26.g7977ac67\" counts as 18.7.1.")

(defcustom lsp-ltex-plus-require-minimum-server-version t
  "Whether to refuse a server older than the recommended floor.

`lsp-ltex-plus-minimum-server-version' is not a matter of taste: it is
the oldest `ltex-ls-plus' this package is written against.  With this
option at its default, `lsp-ltex-plus-mode' declines to start against
anything older and says so, rather than running with features that
quietly do not work.

Setting it to nil is allowed, not encouraged.  Installing an older
server is occasionally the only way round a bug in a newer one, and
being pushed onto a broken release is no better than being held on a
stale one -- which of the two you are facing is not something this
package can tell.  So the escape hatch exists; taking it means some
features may not work, and the version is still reported once.

Nothing is refused when the version cannot be determined at all."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-debug nil
  "When non-nil, enable verbose logging and JSON-RPC tracing.
Enabling this automatically sets `lsp-log-io' to t and creates
detailed log files in the system temporary directory (see the
variable `temporary-file-directory')."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-server-input-log
  (expand-file-name "ltex-server-input.log" (temporary-file-directory))
  "Log file for JSON-RPC input received by the server (from Emacs)."
  :type 'file
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-server-output-log
  (expand-file-name "ltex-server-output.log" (temporary-file-directory))
  "Log file for JSON-RPC output produced by the server (to Emacs)."
  :type 'file
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-check-programming-languages nil
  "When non-nil, enable grammar checking in programming language comments.

By default this is nil, matching LTeX+\\='s own default: only markup languages
\(LaTeX, Markdown, Org, …) are checked automatically.  Setting this to t lets
the dispatcher activate `lsp-ltex-plus-mode\\=' in buffers whose `major-mode\\='
is flagged as a programming language in `lsp-ltex-plus-major-modes\\=',
enabling comment checking in 30+ languages.

This flag only affects client-side activation.  The `ltex.enabled\\='
list sent to the server always contains every supported language ID from
`lsp-ltex-plus-major-modes\\='; the dispatcher is the authoritative
gate.  Explicit interactive calls (M-x `lsp-ltex-plus-mode\\=') always
proceed regardless of this flag, so on-demand grammar checks work in any
supported buffer without toggling this global setting.

Note: LTeX+ is selective about which comments it checks — the exact rule
is not documented and has to be read off the server source.  What is
verified empirically: standalone comment lines (the delimiter is the
first non-whitespace on the line) followed by a space before the text
are checked; trailing/inline comments after code on the same line are
*not*.  Other cases remain to be explored in the server's comment
regex tables.  The common effect is to minimise false positives from
commented-out code.  Python comments are parsed as reStructuredText;
all others are parsed as Markdown."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-show-progress t
  "When non-nil (default), show ltex-ls-plus progress in the mode line.

Progress updates from `ltex-ls-plus\\=' typically complete in ~100 ms,
so the `⌛\\=' prefix (plus optional spinner animation) can flicker
distractingly on every keystroke.  Users who find this bothersome
should set this variable to nil; progress is then silenced for
ltex-ls-plus only, while other LSP clients continue to render their
progress normally.

The default is t because the filtering mechanism is a narrow
`advice-add\\=' around `lsp-on-progress-modeline\\=' — the default
value of `lsp-progress-function\\=' in `lsp-mode\\='.  Advice on
third-party internals is fragile, so we ship in the pass-through
state by default and leave the opt-in to users who actually mind the
flicker.  Users who have replaced `lsp-progress-function\\=' with a
custom handler are not affected by the advice and should filter on
`lsp--workspace-server-id\\=' themselves."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-show-latency nil
  "When non-nil, echo the server round-trip time after every check.

Two distinct events are measured and reported with different wording
so the two regimes can be distinguished at a glance:

- `textDocument/didOpen\\='   → \"Completed initial spell check in N ms.\"
- `textDocument/didChange\\=' → \"Completed spell check in N ms.\"

The didOpen figure reflects a cold start: the server loads the
document for the first time and runs LanguageTool against the full
text.  The didChange figure reflects the warm path: incremental
re-checks triggered by edits, served from the sentence cache where
possible.  Reporting both makes it easy to quote numbers of the form
\"first open: X ms, incremental edit: Y ms\".

In both cases the timer runs from the moment the notification is
dispatched to ltex-ls-plus until the matching
`textDocument/publishDiagnostics\\=' arrives.

This reports server-side latency only.  It does *not* include the
subsequent `lsp-mode' / flycheck / flymake rendering step that draws
the squiggles on screen, which typically adds several hundred
milliseconds on top and dominates perceived responsiveness in Emacs.

Off by default: with a short debounce interval the didChange message
fires on essentially every keystroke and the constant echo-area
updates are distracting during normal editing.  Enable it when
investigating latency (e.g. comparing local vs. remote LanguageTool
backends) and disable it again afterwards."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-multi-root t
  "When non-nil, register the ltex-ls-plus client as multi-root.

This is the default and recommended setting.  With multi-root enabled,
a single `ltex-ls-plus\\=' JVM process handles all folders in the Emacs
session, avoiding the memory cost of one process per project root.

The feature works on any `ltex-ls-plus\\=' binary: multi-root is a
client-side decision about workspace reuse, and a `ltex-ls-plus\\='
server does not need to know about project roots to check documents
correctly.  When the server advertises `workspaceFolders\\=' support in
its `initialize\\=' response, the `workspaceFolders\\=' init param and
the `workspace/didChangeWorkspaceFolders\\=' notification are a proper
part of the handshake; when it does not, those messages are still sent
and silently ignored per the LSP spec (which `lsp4j'-based servers
honour).  Either way, a single JVM handles every folder.

Set this variable to nil only if you want to disable client-side
workspace reuse — for example, because you want per-project isolation
once the server gains per-project settings."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-language "en-US"
  "The language (e.g., \"en-US\") LanguageTool should check against.
If possible, use a specific variant like \"en-US\" or \"de-DE\" instead of the
generic language code like \"en\" or \"de\" to obtain spelling corrections (in
addition to grammar corrections).

When using the language code \"auto\", LTeX+ will try to detect the language of
the document.  This is not recommended, as only generic languages like \"en\" or
\"de\" will be detected and thus no spelling errors might be reported."
  :type 'string
  :safe #'stringp
  :group 'lsp-ltex-plus)

(defun lsp-ltex-plus--symbol-keyed-alist-p (value)
  "Non-nil when VALUE is an alist of symbol keys with string or boolean values.
The shape the parser tables take — `lsp-ltex-plus-bibtex-fields',
`-latex-commands', `-latex-environments', `-markdown-nodes'.  Used as
their `:safe' predicate: such a value only changes how a document is
parsed before it is checked, so a project may set one without asking."
  (and (listp value)
       (seq-every-p (lambda (cell)
                      (and (consp cell)
                           (symbolp (car cell))
                           (or (stringp (cdr cell))
                               (memq (cdr cell) '(t nil)))))
                    value)))

(defun lsp-ltex-plus--language-plist-p (value)
  "Non-nil when VALUE is a language-keyed plist of vectors of strings.
The shape the four language-keyed settings take, e.g.
\\='(:en-US [\"foo\"] :de-DE [\"bar\"]).  Used as the `:safe' predicate for
those settings: a value of this shape only ever adds words or rule
names to a check, so a project may set one without confirmation."
  (and (listp value)
       (cl-evenp (length value))
       (cl-loop for (key val) on value by #'cddr
                always (and (keywordp key)
                            (vectorp val)
                            (seq-every-p #'stringp val)))))

(defcustom lsp-ltex-plus-dictionary nil
  "Additional words accepted as correctly spelled, per language.
This setting is language-specific, so use a plist of the form
\\='(:en-US [\"WORD1\" \"WORD2\"] :de-DE [\"WORD1\" ...]) where the key is
the language code and the value is a vector of words.

Provides the user-seeded counterpart to entries added at runtime via the
_ltex.addToDictionary code action; the two sources are kept separate
and merged on the fly for the server.  For large, hand-curated word
lists, prefer editing the on-disk file (see the External settings
section in the README) rather than stuffing everything into this
variable."
  :type 'plist
  :safe #'lsp-ltex-plus--language-plist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-enabled-rules nil
  "Lists of rules that should be enabled (if disabled by default).
This setting is language-specific, so use an object of the format
\\='(:en-US [\"RULE1\" \"RULE2\"] :de-DE [\"RULE1\" ...]) where the key is
the language code and the value is a vector of rule IDs."
  :type 'plist
  :safe #'lsp-ltex-plus--language-plist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-disabled-rules nil
  "Lists of rules that should be disabled (if enabled by default).
This setting is language-specific, so use an object of the format
\\='(:en-US [\"RULE1\" \"RULE2\"] :de-DE [\"RULE1\" ...]) where the key is
the language code and the value is a vector of rule IDs."
  :type 'plist
  :safe #'lsp-ltex-plus--language-plist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-hidden-false-positives nil
  "False-positive diagnostics that should be hidden from reports.
This setting is language-specific, so use a plist of the form
\\='(:en-US [\"<jsonObject1>\" ...] :de-DE [\"<jsonObject1>\" ...]) where
each string is a JSON object of the form
`{\"rule\":\"RULE_ID\",\"sentence\":\"REGEX\"}' that matches a diagnostic's
rule ID and surrounding sentence regex.

Provides the user-seeded counterpart to entries added at runtime via the
_ltex.hideFalsePositives code action; the two sources are kept
separate and merged on the fly for the server.  See the LTeX+
documentation for the feature:
https://ltex-plus.github.io/ltex-plus/advanced-usage.html#hiding-false-positives-with-regular-expressions"
  :type 'plist
  :safe #'lsp-ltex-plus--language-plist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-bibtex-fields nil
  "List of BibTeX fields whose values are to be checked in BibTeX files.
This setting is an object with the field names as keys and Booleans as values,
where true means that the field value should be checked and false means that
the field value should be ignored.  Field names are listed as symbols
\(e.g., `title')."
  :type 'alist
  :safe #'lsp-ltex-plus--symbol-keyed-alist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-latex-commands nil
  "List of LaTeX commands to be handled by the LaTeX parser.
This setting is an object with the commands as keys and corresponding
actions as values (\"default\", \"ignore\", \"dummy\", \"pluralDummy\",
\"vowelDummy\"). Commands are listed as symbols (not strings) with empty
arguments and the initial backslash doubled, e.g. `\\\\ref{}',
`\\\\documentclass[]{}'."
  :type 'alist
  :safe #'lsp-ltex-plus--symbol-keyed-alist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-latex-environments nil
  "List of names of LaTeX environments to be handled by the LaTeX parser.
This setting is an object with the environment names as keys and corresponding
actions as values (\"default\", \"ignore\").  Environment names are listed as
symbols (e.g., `lstlisting')."
  :type 'alist
  :safe #'lsp-ltex-plus--symbol-keyed-alist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-markdown-nodes nil
  "List of Markdown node types to be handled by the Markdown parser.
This setting is an object with the node types as keys and corresponding
actions as values (\"default\", \"ignore\", \"dummy\", \"pluralDummy\",
\"vowelDummy\").  Node types are listed as symbols (e.g., `CodeBlock')."
  :type 'alist
  :safe #'lsp-ltex-plus--symbol-keyed-alist-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-enable-picky-rules nil
  "Enable LanguageTool rules that are marked as picky.
These are disabled by default, e.g., rules about passive voice, sentence length,
etc., at the cost of more false positives."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-mother-tongue nil
  "Optional mother tongue of the user (e.g., \"de-DE\").
If set, additional rules will be checked to detect false friends. Picky rules
may need to be enabled in order to see an effect.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "Language code"))
  :safe #'string-or-null-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-language-model nil
  "Optional path to a directory with rules of a language model with n-gram counts.
Set this to the parent directory that contains subdirectories for
languages.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (directory :tag "Directory"))
  :safe #'string-or-null-p
  :group 'lsp-ltex-plus)

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

(defcustom lsp-ltex-plus-lt-server-uri nil
  "Base URI for the LanguageTool HTTP server.
When nil (default), ltex-ls-plus uses its local, built-in LanguageTool.
To use an online service, set this to e.g.,
\"https://api.languagetoolplus.com\".
Note: ltex-ls-plus appends /v2/check to this, so omit the /v2 suffix here.

Whatever this points at receives the full text of every document you
edit.  A project may therefore select the built-in checker or
LanguageTool Premium through its `.dir-locals.el' without being asked,
but any other host goes through Emacs' usual confirmation; see
`lsp-ltex-plus--lt-server-uri-safe-p'."
  :type '(choice (const :tag "Local (Built-in)" nil)
                 (string :tag "Remote URI"))
  :safe #'lsp-ltex-plus--lt-server-uri-safe-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-lt-username nil
  "Username/email as used to log in at languagetool.org for Premium API access.
Only relevant if `lsp-ltex-plus-lt-server-uri' is set.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "Username/email"))
  :safe #'string-or-null-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-lt-api-key nil
  "API key for Premium API access.
Only relevant if `lsp-ltex-plus-lt-server-uri' is set.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "API key"))
  :safe #'string-or-null-p
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-ltex-ls-path nil
  "Path to the root directory of ltex-ls-plus.
It contains bin and lib subdirectories.  nil (or empty) means the
bundled version is used."
  :type '(choice (const :tag "Bundled" nil) (directory :tag "Directory"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-ltex-ls-log-level "fine"
  "Logging level (verbosity) of the ltex-ls-plus server log.
The levels in descending order are \"severe\", \"warning\", \"info\",
\"config\", \"fine\", \"finer\", and \"finest\"."
  :type '(choice (const "severe") (const "warning") (const "info")
                 (const "config") (const "fine") (const "finer")
                 (const "finest"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-java-path nil
  "Path to an existing Java installation on your computer.
Use the same path as you would use for the JAVA_HOME environment
variable.  nil means unset (the bundled or PATH Java is used)."
  :type '(choice (const :tag "Unset" nil) (directory :tag "Directory"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-java-initial-heap 64
  "Initial size of the Java heap memory in megabytes (corresponds to -Xms)."
  :type 'integer
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-java-max-heap 512
  "Maximum size of the Java heap memory in megabytes (corresponds to -Xmx)."
  :type 'integer
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-sentence-cache-size 0
  "Size of the LanguageTool ResultCache in sentences.
The default and recommended value is 0, which disables the local
LanguageTool server's own cache entirely.  ltex-ls-plus keeps its own
per-paragraph cache, which supersedes LanguageTool's caching.
Use a positive value to turn it back on, but be aware that this is
redundant and only adds CPU and memory overhead with no additional
benefit.  To go back to LanguageTool's caching instead of the
per-paragraph cache, set this to a positive value and also set
`lsp-ltex-plus-paragraph-cache-enabled' to nil."
  :type 'integer
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-max-request-size 20000
  "Largest amount of text, in characters, sent to LanguageTool in one request.
ltex-ls-plus caches results per paragraph and re-checks only the
paragraphs you edited.  When several changed paragraphs sit next to
each other they are batched into a single request (typically the
first, whole-document check); text larger than this is split across
several requests, but an individual paragraph is never split.  The
default fits within the per-request character limit of the free
remote LanguageTool service.  If you use a local server
\(`lsp-ltex-plus-lt-server-uri' is nil) or have a Premium account,
consider raising it to 60000.  This does not affect caching granularity,
which is always per paragraph."
  :type 'integer
  :safe #'integerp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-paragraph-cache-ttl-minutes 30
  "How long, in minutes, a document's cached results are kept unused.
The per-paragraph cache lets ltex-ls-plus reuse the results of
unchanged paragraphs after an edit.  Entries for the file you are
actively editing stay warm; a document left untouched for longer than
this is dropped from the cache.  A document's cache is also cleared as
soon as the file is closed."
  :type 'integer
  :safe #'integerp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-paragraph-cache-enabled t
  "Whether ltex-ls-plus reuses cached results for unchanged paragraphs.
When non-nil (the default and recommended), each paragraph's result is
stored and reused, so an edit only re-checks the paragraphs that
changed.  Set to nil to disable reuse of results, so every paragraph is
re-checked on each pass.  This does not affect
`lsp-ltex-plus-max-request-size': the text is always sliced into
paragraphs, which in turn are batched into requests.  If disabled,
sliced paragraphs are just never stored or served from the cache.
Disabling this and setting `lsp-ltex-plus-sentence-cache-size' to a
positive value restores LanguageTool's own caching instead."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-completion-enabled nil
  "Controls whether completion is enabled (IntelliSense)."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-diagnostic-severity "warning"
  "Severity of the diagnostics corresponding to the grammar and spelling errors.
Possible severities are \"error\", \"warning\", \"information\", and \"hint\"."
  :type '(choice (const "error") (const "warning") (const "information") (const "hint"))
  :safe #'stringp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-check-frequency "edit"
  "Controls when documents should be checked.
- \"edit\": checked when opened or edited (on every keystroke).
- \"save\": checked when opened or saved.
- \"manual\": use commands to manually trigger checks."
  :type '(choice (const "edit") (const "save") (const "manual"))
  :safe #'stringp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-clear-diagnostics-when-closing-file t
  "If set to true, diagnostics of a file are cleared when the file is closed."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-check-fileless-buffers t
  "When non-nil, grammar-check buffers that have no backing file.
File-less buffers (e.g. *scratch*, capture buffers) in a recognized major
mode are given a synthetic file:// URI under the variable
`temporary-file-directory' and share a single workspace, so one server
process serves them all.

This is orthogonal to `lsp-ltex-plus-check-programming-languages': a
file-less buffer in a programming mode (such as *scratch*, which uses
`lisp-interaction-mode') is still auto-activated only when programming
checks are also enabled, but an explicit \\[lsp-ltex-plus-mode] always
works."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-check-comint-input t
  "When non-nil, grammar-check the active input region of comint buffers.
In a `comint-mode' buffer (e.g. `agent-shell-mode', a shell, a REPL) only
the editable input the user is currently typing — the region from the
process mark to the end of the buffer — is sent to LTEX+.  Previously
submitted input and all process/agent output are never checked.

This relies on the same file-less identity machinery as
`lsp-ltex-plus-check-fileless-buffers' (comint buffers have no backing
file), but additionally restricts the checked document to the input
region via `lsp-mode''s virtual-buffer support.  See
`lsp-ltex-plus--setup-comint-buffer'."
  :type 'boolean
  :safe #'booleanp
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-apply-kind-first-patch nil
  "Whether to apply protocol patches to `lsp-mode' (Kind-First and related).
When non-nil, several surgical fixes are applied to `lsp-mode' to
improve protocol robustness:

1. Kind-First routing: prioritizes the \\='method\\=' field in
   `lsp--parser-on-message', preventing deadlocks when
   server-initiated requests (like `workspace/configuration')
   collide with client response IDs.

2. Resilient message dispatch: ensures that when the server sends
   multiple updates bundled together, an interruption in one
   (like typing during completion) doesn't cause the rest of the
   bundle to be discarded.

3. Stale callback protection: prevents synchronous requests from
   throwing after they have already timed out or been cancelled.

Note: These are global surgical patches affecting all LSP servers."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defvar lsp-ltex-plus-trace-server "off"
  "Debug setting to log the communication between language client and server.
- \"off\": Don't log any communication.
- \"messages\": Log the type of requests and responses.
- \"verbose\": Log the type and contents of requests and responses.")

;;;; -- Internal State & Logging -----------------------------------------------

(defvar lsp-ltex-plus--start-time nil
  "Timestamp of when `lsp-ltex-plus--setup' was executed.")

(defvar-local lsp-ltex-plus--fileless-uri nil
  "Synthetic file:// URI assigned to this file-less buffer, or nil.
Set by `lsp-ltex-plus--setup-fileless-buffer' and reused for the lifetime
of the buffer (or until it is saved to a real file).")

(defvar lsp-ltex-plus--fileless-counter 0
  "Monotonic counter for generating unique file-less buffer URIs.
Combined with the Emacs PID so synthetic paths never collide within or
across sessions; see `lsp-ltex-plus--make-fileless-uri'.")

(defvar-local lsp-ltex-plus--comint-active nil
  "Non-nil when this comint buffer's input region is being checked.
Set by the comint activation branch of `lsp-ltex-plus-mode' and cleared
by `lsp-ltex-plus--comint-teardown'.  Gates the submit re-sync and
tear-down so they no-op in buffers that never opted in.")

(defvar lsp-ltex-plus--dictionary-stored nil
  "Dictionary plist loaded from on-disk file.
File location: `lsp-ltex-plus-dictionary-file'.  Mutated by the
_ltex.addToDictionary code action and persisted back to the file.
Merged with the pristine defcustom `lsp-ltex-plus-dictionary' into
`lsp-ltex-plus--dictionary-merged' for the server.")

(defvar lsp-ltex-plus--enabled-rules-stored nil
  "Enabled-rules plist loaded from on-disk file.
File location: `lsp-ltex-plus-enabled-rules-file'.  Kept separate from
the user-facing defcustom `lsp-ltex-plus-enabled-rules' so `:custom'
values never get written to disk; the server sees the merge of the two
via `lsp-ltex-plus--enabled-rules-merged'.")

(defvar lsp-ltex-plus--disabled-rules-stored nil
  "Disabled-rules plist loaded from on-disk file.
File location: `lsp-ltex-plus-disabled-rules-file'.  Mutated by the
_ltex.disableRules code action and persisted back to the file.  Merged
with the pristine defcustom `lsp-ltex-plus-disabled-rules' into
`lsp-ltex-plus--disabled-rules-merged' for the server.")

(defvar lsp-ltex-plus--hidden-false-positives-stored nil
  "Hidden-false-positives plist loaded from on-disk file.
File location: `lsp-ltex-plus-hidden-false-positives-file'.  Mutated by
the _ltex.hideFalsePositives code action and persisted back.  Merged
with the pristine defcustom `lsp-ltex-plus-hidden-false-positives' into
`lsp-ltex-plus--hidden-false-positives-merged' for the server.")

(defvar lsp-ltex-plus--dictionary-merged nil
  "Merge of custom-defined words and on-disk-defined words.
Custom-defined words are stored in `lsp-ltex-plus-dictionary', while
on-disk-defined words are stored in `lsp-ltex-plus--dictionary-stored'.
Read by the server; recomputed whenever either source changes.")

(defvar lsp-ltex-plus--enabled-rules-merged nil
  "Merge of custom-defined rules and on-disk-defined rules.
Custom-defined rules are stored in `lsp-ltex-plus-enabled-rules', while
on-disk-defined rules are stored in
`lsp-ltex-plus--enabled-rules-stored'.  Read by the server; recomputed
whenever either source changes.")

(defvar lsp-ltex-plus--disabled-rules-merged nil
  "Merge of custom-defined rules and on-disk-defined rules.
Custom-defined rules are stored in `lsp-ltex-plus-disabled-rules', while
on-disk-defined rules are stored in
`lsp-ltex-plus--disabled-rules-stored'.  Read by the server; recomputed
whenever either source changes.")

(defvar lsp-ltex-plus--hidden-false-positives-merged nil
  "Merge of custom-defined false positives and on-disk-defined ones.
Custom-defined false positives are stored in
`lsp-ltex-plus-hidden-false-positives', while on-disk-defined ones are
stored in `lsp-ltex-plus--hidden-false-positives-stored'.  Read by the
server; recomputed whenever either source changes.")

(defvar lsp-ltex-plus--project-file-cache (make-hash-table :test #'equal)
  "Cache of project settings files: absolute path -> (MTIME . PLIST).
The server pulls settings on every check, so the files behind that pull
are read only when their modification time has moved.  MTIME is nil for
a file that does not exist, which is itself cached — creating the file
later moves the time off nil and the entry is refreshed.  Filled and
consulted by `lsp-ltex-plus--load-project-plist'; see the
`lsp-ltex-plus-project-*-file' settings.")

(defvar lsp-ltex-plus--server-name nil
  "Name the connected ltex-ls-plus reported via `serverInfo', or nil.
Captured in `:initialized-fn' from the `initialize' response.  Stays nil
on an `lsp-mode' that lacks the `serverInfo' accessors or against a
server that omits `serverInfo'.")

(defvar lsp-ltex-plus--server-version nil
  "Version string the connected ltex-ls-plus reported via `serverInfo', or nil.
Captured in `:initialized-fn' from the `initialize' response.  Stays nil
on an `lsp-mode' that lacks the `serverInfo' accessors or against a
server that omits the version.  The raw string is stored verbatim (e.g.
\"18.7.0-alpha.94+2026-05-31.gb2fd8fa0\"); no parsing is done here.")

;; -- JSON-serialization helpers -----------------------------------------------
;;
;; In Elisp `nil' is overloaded: it is `false', the empty list, the empty plist,
;; and the empty alist all at once.  `json-serialize' resolves this to JSON
;; `null'.  Several settings the server reads must be either a JSON object or a
;; JSON boolean — never `null'.  These helpers normalize the value at the
;; protocol boundary so that an unset Elisp variable serializes correctly.

(defvar lsp-ltex-plus--empty-ht (make-hash-table :test 'equal)
  "Shared, read-only empty hash-table used for nil object-typed settings.
Substituted for nil so `json-serialize' emits {} instead of null
for fields whose JSON type is a (possibly empty) object.  Pre-allocated
once and shared across all call sites: the structure is only ever read
by the JSON serializer, never mutated.")

(defsubst lsp-ltex-plus--obj-or-empty (val)
  "Return VAL if non-nil, else `lsp-ltex-plus--empty-ht'.
For settings whose JSON type is an object — they must never serialize
as null.  An empty hash-table is unambiguously a JSON object."
  (or val lsp-ltex-plus--empty-ht))

(defsubst lsp-ltex-plus--bool (val)
  "Return JSON-correct boolean for VAL: t for non-nil, `:json-false' otherwise.
For settings whose JSON type is a boolean.  Without this, a nil
defcustom would serialize as JSON null rather than false."
  (if val t :json-false))

(defsubst lsp-ltex-plus--str (val)
  "Return VAL if non-nil, else the empty string \"\".
For string-typed settings.  Storing nil for \"unset\" is the
Emacs-idiomatic choice; the server expects a string, so nil is
translated to \"\" at the protocol boundary.  An explicit \"\" left in
an existing user config passes through unchanged."
  (or val ""))

(defun lsp-ltex-plus--elapsed ()
  "Return seconds (float) since `lsp-ltex-plus--start-time' or Emacs init."
  (float-time (time-subtract (current-time)
                             (or lsp-ltex-plus--start-time before-init-time))))

(defun lsp-ltex-plus--log-to-buffer (msg)
  "Write MSG with a timestamp to the *lsp-ltex-plus::client* buffer."
  (with-current-buffer (get-buffer-create "*lsp-ltex-plus::client*")
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format "[%10.3f] %s\n" (lsp-ltex-plus--elapsed) msg))
      (setq buffer-read-only t))))

(defmacro lsp-ltex-plus--log (fmt &rest args)
  "Log a formatted message if `lsp-ltex-plus-debug' is enabled.
FMT is the format string, and ARGS are the arguments for it."
  `(when lsp-ltex-plus-debug
     (lsp-ltex-plus--log-to-buffer (format ,fmt ,@args))))

;;;; -- Dictionary Management --------------------------------------------------

(defvar lsp-ltex-plus-dictionary-file
  (expand-file-name "lsp-ltex-plus/stored-dictionary.eld" user-emacs-directory)
  "Path to the external dictionary file (plist format).")

(defvar lsp-ltex-plus-enabled-rules-file
  (expand-file-name "lsp-ltex-plus/enabled-rules.eld" user-emacs-directory)
  "Path to the external enabled rules file (plist format).")

(defvar lsp-ltex-plus-disabled-rules-file
  (expand-file-name "lsp-ltex-plus/disabled-rules.eld" user-emacs-directory)
  "Path to the external disabled rules file (plist format).")

(defvar lsp-ltex-plus-hidden-false-positives-file
  (expand-file-name "lsp-ltex-plus/hidden-false-positives.eld" user-emacs-directory)
  "Path to the external hidden false positives file (plist format).")

(defun lsp-ltex-plus--load-plist (file-path)
  "Load a plist from FILE-PATH.  Return nil if it doesn't exist or fails."
  (lsp-ltex-plus--log "Loading plist from %s" file-path)
  (if (not (file-exists-p file-path))
      (progn (lsp-ltex-plus--log "File not found: %s" file-path) nil)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file-path)
          (read (current-buffer)))
      (error
       (message "[lsp-ltex-plus] Failed to read %s: %S" file-path err)
       nil))))

(defun lsp-ltex-plus--save-plist (plist file-path)
  "Save PLIST to FILE-PATH."
  (lsp-ltex-plus--log "Saving plist to %s" file-path)
  (make-directory (file-name-directory file-path) t)
  (with-temp-file file-path
    (let ((print-length nil)
          (print-level nil))
      (prin1 plist (current-buffer)))))

;; TODO(2027-05): Remove `lsp-ltex-plus--migrate-extensionless-file'
;; and its caller in `lsp-ltex-plus--setup' once existing installs
;; have migrated to the .eld extension.
(defun lsp-ltex-plus--migrate-extensionless-file (current-path default-path)
  "Move the pre-.eld counterpart of DEFAULT-PATH into place.
Acts only when CURRENT-PATH equals DEFAULT-PATH — i.e. the user has not
explicitly customised the file location.  Users who have chosen their
own path are not affected.

When CURRENT-PATH equals DEFAULT-PATH and the extensionless
sibling of DEFAULT-PATH exists on disk:

- if DEFAULT-PATH does not yet exist, rename the old file into
  place;
- if DEFAULT-PATH also exists, emit a message asking the user to
  merge the two files manually; downstream code keeps reading
  DEFAULT-PATH."
  (when (equal current-path default-path)
    (let ((old-path (file-name-sans-extension default-path)))
      (when (file-exists-p old-path)
        (if (file-exists-p default-path)
            (message "[lsp-ltex-plus] Cannot migrate %s -> %s: both files exist; please merge them manually."
                     old-path default-path)
          (rename-file old-path default-path)
          (message "[lsp-ltex-plus] Migrated %s -> %s" old-path default-path))))))

(defun lsp-ltex-plus--merge-plists (p1 p2)
  "Merge plist P2 into P1 and return the result.
Items in vectors are merged and deduplicated using `string=`."
  (let ((res (copy-sequence p1)))
    (cl-loop for (key val) on p2 by #'cddr do
             (let* ((v1 (plist-get res key))
                    (l1 (if (vectorp v1) (append v1 nil) nil))
                    (l2 (if (vectorp val) (append val nil) nil))
                    (merged (vconcat (seq-uniq (append l1 l2) #'string=))))
               (setq res (plist-put res key merged))))
    res))

(defun lsp-ltex-plus--load-external-settings ()
  "Load external settings from disk and recompute merged views.
Reads each of the four on-disk plist files into its `-stored'
variable, then rebuilds the `-merged' variables by combining the
stored values with the pristine defcustoms.  The defcustoms
themselves are never mutated."
  (setq lsp-ltex-plus--dictionary-stored
        (lsp-ltex-plus--load-plist lsp-ltex-plus-dictionary-file))
  (setq lsp-ltex-plus--enabled-rules-stored
        (lsp-ltex-plus--load-plist lsp-ltex-plus-enabled-rules-file))
  (setq lsp-ltex-plus--disabled-rules-stored
        (lsp-ltex-plus--load-plist lsp-ltex-plus-disabled-rules-file))
  (setq lsp-ltex-plus--hidden-false-positives-stored
        (lsp-ltex-plus--load-plist lsp-ltex-plus-hidden-false-positives-file))
  ;; Project files carry their own modification-time check, so this only
  ;; matters for an edit that left the time untouched — but a reload is
  ;; meant to be the blunt instrument that always works.
  (clrhash lsp-ltex-plus--project-file-cache)
  (lsp-ltex-plus--recompute-merged))

(defun lsp-ltex-plus--recompute-merged ()
  "Rebuild the four `-merged' plists from defcustoms + `-stored' values.
Called after any change to a `-stored' variable (e.g. a code-action
write) and at the end of `lsp-ltex-plus--load-external-settings'."
  (setq lsp-ltex-plus--dictionary-merged
        (lsp-ltex-plus--merge-plists lsp-ltex-plus-dictionary
                                     lsp-ltex-plus--dictionary-stored))
  (setq lsp-ltex-plus--enabled-rules-merged
        (lsp-ltex-plus--merge-plists lsp-ltex-plus-enabled-rules
                                     lsp-ltex-plus--enabled-rules-stored))
  (setq lsp-ltex-plus--disabled-rules-merged
        (lsp-ltex-plus--merge-plists lsp-ltex-plus-disabled-rules
                                     lsp-ltex-plus--disabled-rules-stored))
  (setq lsp-ltex-plus--hidden-false-positives-merged
        (lsp-ltex-plus--merge-plists lsp-ltex-plus-hidden-false-positives
                                     lsp-ltex-plus--hidden-false-positives-stored)))

(defun lsp-ltex-plus--add-to-plist (plist-sym file-path lang items)
  "Add ITEMS for LANG to the plist stored in PLIST-SYM and save to FILE-PATH."
  (lsp-ltex-plus--log "Adding items for %s to %s: %S" lang (symbol-name plist-sym) items)
  (let* ((key (intern (concat ":" lang)))
         (new-data (list key (vconcat items)))
         (merged (lsp-ltex-plus--merge-plists (symbol-value plist-sym) new-data)))
    (set plist-sym merged)
    (lsp-ltex-plus--save-plist merged file-path)))

(defun lsp-ltex-plus-list-dictionary ()
  "Show the accepted words in force for the document in this buffer.

That is what the server is actually told: the global list -- the
defcustom `lsp-ltex-plus-dictionary\=' merged with the file
`lsp-ltex-plus-dictionary-file\=' names -- and, in a project keeping a
dictionary of its own, that project\='s words folded in on top.  The
project file is named in the output, so a word you did not expect can be
traced to the list it came from.

Called where no project dictionary applies -- outside a project, or in a
buffer with no file, such as `*scratch*\=' -- this is simply the global
list."
  (interactive)
  (let ((effective (lsp-ltex-plus--effective-plist 'dictionary))
        (project-file (lsp-ltex-plus--project-file-for 'dictionary)))
    (if project-file
        (message "[lsp-ltex-plus] Dictionary (global + %s): %S"
                 (abbreviate-file-name project-file) effective)
      (message "[lsp-ltex-plus] Dictionary (global): %S" effective))))

;;;; -- Project-local settings -------------------------------------------------

;; A project can keep its own word list and rule lists beside the global ones
;; under `user-emacs-directory'.  The four variables below mirror the global
;; `lsp-ltex-plus-*-file' ones and are normally set from a project's
;; `.dir-locals.el'; each names a file whose contents are merged with the
;; corresponding global list for documents in that project.  Neither side
;; shadows the other: a word present in either list is accepted, so a project
;; adds its jargon on top of the vocabulary you carry everywhere.  Each is
;; independent, so a project can bring its own dictionary while still using
;; your global rule lists.
;;
;; The project boundary is Emacs' own.  `.dir-locals.el' already decides which
;; files a setting governs, and the per-document handlers answer each pull from
;; the buffer the server named, so a document is checked against exactly the
;; lists that apply to it.  Nothing here needs a notion of "project root".
;;
;; Buffers with no file — `*scratch*', comint input — have no directory-local
;; variables and therefore no project files, so they see the global lists
;; alone.  That is the right answer: they belong to no project.

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

(defmacro lsp-ltex-plus--define-project-file (name file description)
  "Define NAME as the project counterpart of a global settings file.
FILE is the suggested basename shown in the docstring and DESCRIPTION
names what the file holds."
  `(defcustom ,name nil
     ,(format "File holding this project's %s, or nil for none.

Set this from a project's `.dir-locals.el' to give the project its own
list, merged with — never replacing — the global one:

  ((nil . ((%s
            . \"%s\"))))

A relative name is resolved against the directory holding the
`.dir-locals.el' that set it, so every file in the project agrees on one
location however deep it sits, and moving the project moves the setting
with it.  An absolute name (or one starting with `~') is used as given,
but is not treated as safe: Emacs will ask before applying it.

The format is the same plist the global files use — language codes as
keyword keys, vectors of strings as values, e.g.

  (:en-US [\"Wittgenstein\"] :de-DE [\"Widerspiegelung\"])"
              description name file)
     :type '(choice (const :tag "None" nil) file)
     :safe #'lsp-ltex-plus--project-file-safe-p
     :group 'lsp-ltex-plus))

(lsp-ltex-plus--define-project-file lsp-ltex-plus-project-dictionary-file
                                    ".ltex/dictionary.eld"
                                    "additional accepted words")
(lsp-ltex-plus--define-project-file lsp-ltex-plus-project-enabled-rules-file
                                    ".ltex/enabled-rules.eld"
                                    "rules to enable")
(lsp-ltex-plus--define-project-file lsp-ltex-plus-project-disabled-rules-file
                                    ".ltex/disabled-rules.eld"
                                    "rules to disable")
(lsp-ltex-plus--define-project-file lsp-ltex-plus-project-hidden-false-positives-file
                                    ".ltex/hidden-false-positives.eld"
                                    "false positives to hide")

(defconst lsp-ltex-plus--setting-kinds
  '((dictionary
     :merged        lsp-ltex-plus--dictionary-merged
     :stored        lsp-ltex-plus--dictionary-stored
     :global-file lsp-ltex-plus-dictionary-file
     :project-file  lsp-ltex-plus-project-dictionary-file
     :command       "_ltex.addToDictionary")
    (enabled-rules
     :merged        lsp-ltex-plus--enabled-rules-merged
     :stored        lsp-ltex-plus--enabled-rules-stored
     :global-file lsp-ltex-plus-enabled-rules-file
     :project-file  lsp-ltex-plus-project-enabled-rules-file
     :command       nil)
    (disabled-rules
     :merged        lsp-ltex-plus--disabled-rules-merged
     :stored        lsp-ltex-plus--disabled-rules-stored
     :global-file lsp-ltex-plus-disabled-rules-file
     :project-file  lsp-ltex-plus-project-disabled-rules-file
     :command       "_ltex.disableRules")
    (hidden-false-positives
     :merged        lsp-ltex-plus--hidden-false-positives-merged
     :stored        lsp-ltex-plus--hidden-false-positives-stored
     :global-file lsp-ltex-plus-hidden-false-positives-file
     :project-file  lsp-ltex-plus-project-hidden-false-positives-file
     :command       "_ltex.hideFalsePositives"))
  "The four language-keyed settings, by kind.
Each entry maps a kind to the variables behind it:

  :merged         the global value the server is shown
  :stored         the in-memory mirror of the global file
  :global-file  the global file under `user-emacs-directory'
  :project-file   the setting naming a project's own file, if it has one
  :command        the server command whose suggestion writes here, or nil
                  for `enabled-rules', which no suggestion writes to")

(defun lsp-ltex-plus--kind-get (kind property)
  "Return PROPERTY of KIND from `lsp-ltex-plus--setting-kinds'."
  (plist-get (alist-get kind lsp-ltex-plus--setting-kinds) property))

(defun lsp-ltex-plus--kind-for-command (command)
  "Return the settings kind COMMAND writes to, or nil if it writes to none.
COMMAND is a server command name.  A nil COMMAND — an action carrying a
command object with no name, which a malformed server can send — matches
nothing: `enabled-rules\=' has a nil `:command\=' because no suggestion
writes to it, and answering with it here would let this package claim an
action that is not its own."
  (and command
       (car (seq-find (lambda (entry)
                        (equal command (plist-get (cdr entry) :command)))
                      lsp-ltex-plus--setting-kinds))))

(defun lsp-ltex-plus--dir-locals-directory ()
  "Return the directory whose `.dir-locals.el' governs the current buffer.
Falls back to `default-directory' when the buffer has no file or no
directory-local variables apply, which is the sensible base for a value
that was set globally rather than per project."
  (or (when-let* ((file (buffer-file-name))
                  (found (dir-locals-find-file file)))
        ;; `dir-locals-find-file' answers with the directory itself, or with
        ;; (DIR CLASS MTIME) when the entry is already cached.
        (file-name-as-directory (if (consp found) (car found) found)))
      default-directory))

(defun lsp-ltex-plus--project-file (variable)
  "Return the absolute path VARIABLE names for the current buffer, or nil.
VARIABLE is one of the `lsp-ltex-plus-project-*-file' settings; a
relative value resolves against the directory holding the
`.dir-locals.el' that set it."
  (when-let* ((value (symbol-value variable)))
    (expand-file-name value (lsp-ltex-plus--dir-locals-directory))))

(defun lsp-ltex-plus--load-project-plist (path)
  "Return the plist stored at PATH, re-reading it only when it has changed."
  (let ((mtime (file-attribute-modification-time (file-attributes path)))
        (entry (gethash path lsp-ltex-plus--project-file-cache)))
    (if (and entry (equal (car entry) mtime))
        (cdr entry)
      (let ((plist (and mtime (lsp-ltex-plus--load-plist path))))
        (puthash path (cons mtime plist) lsp-ltex-plus--project-file-cache)
        plist))))

(defun lsp-ltex-plus--effective-plist (kind)
  "Return KIND as the server should see it for the document in this buffer.
The global value — the user's defcustom merged with the file under
`user-emacs-directory' — extended with this project's file, if it has
one.  KIND is a key of `lsp-ltex-plus--setting-kinds'."
  (let ((global (symbol-value (lsp-ltex-plus--kind-get kind :merged)))
        (file (lsp-ltex-plus--project-file-for kind)))
    (if file
        (lsp-ltex-plus--merge-plists
         global
         (lsp-ltex-plus--load-project-plist file))
      global)))

(defun lsp-ltex-plus--project-file-for (kind)
  "Return this buffer's project file for KIND, or nil if it has none."
  (lsp-ltex-plus--project-file (lsp-ltex-plus--kind-get kind :project-file)))

;;;; -- Where a suggestion's addition is saved ----------------------------------

;; Accepting a suggestion — a word to accept, a rule to switch off, a false
;; positive to hide — adds an entry to one of the lists.  Reading always
;; merges the global and project lists; this only decides which file a *new*
;; entry is written to.  Being an ordinary setting, it can itself be set from
;; a project's `.dir-locals.el', so one project can depart from the habit you
;; keep everywhere else.

(defun lsp-ltex-plus--save-additions-to-p (value)
  "Non-nil when VALUE is one of the `lsp-ltex-plus-save-additions-to' choices."
  (memq value '(globally-defined per-project-when-specified
                either-allowing-user-choice)))

(defcustom lsp-ltex-plus-save-additions-to 'either-allowing-user-choice
  "Where an addition goes when you accept one of LTeX+'s suggestions.

This never affects what is *read*: a document is always checked against
the union of your own lists and the project's.  It decides only where a
newly accepted word, silenced rule or hidden false positive is written.

  `globally-defined'
      Always your own file under `user-emacs-directory', even in a
      project that keeps its own list.  Choose this to have a project's
      list read but only ever edited by hand.

  `per-project-when-specified'
      The project's file when this project keeps one for that kind of
      entry, and your own file otherwise.  A project that configures
      only a dictionary therefore collects words while your global
      rule choices stay global.  Set this once you know which you
      want and would rather not be asked.

  `either-allowing-user-choice' (default)
      Decide each time.  Where a project keeps its own list, the two
      possibilities appear side by side among the suggestions, one
      saving everywhere and one saving to this project only, and you
      pick as you accept.  The entry is written to one of them, never
      to both.

      This is the default because it is also how the choice announces
      itself: a project that keeps its own lists is one you set up
      deliberately, and seeing both destinations offered is how you
      find out the choice exists.  If you always want the same one,
      say so with one of the two values above -- in your init file, or
      in a single project's `.dir-locals.el' if only that one differs.

Nothing changes for a project that keeps no lists of its own: all three
values then write to your own files, since there is nowhere else to
write."
  :type '(choice (const :tag "Always my own files" globally-defined)
                 (const :tag "This project's files when it has them"
                        per-project-when-specified)
                 (const :tag "Offer both and let me choose each time"
                        either-allowing-user-choice))
  :safe #'lsp-ltex-plus--save-additions-to-p
  :group 'lsp-ltex-plus)

;; Marker carried on the copies of a suggestion that
;; `either-allowing-user-choice' splits in two, naming which file that copy
;; saves to.  It rides on the client-side command object and is never sent
;; anywhere: these commands are handled entirely by this package, the server
;; never receives them back.
(defconst lsp-ltex-plus--target-marker :ltexPlusSaveTo)

(defun lsp-ltex-plus--addition-target (kind command)
  "Return `project' or `global': where KIND's addition from COMMAND goes.
A COMMAND carrying the marker left by `lsp-ltex-plus--split-suggestion'
says so itself; otherwise `lsp-ltex-plus-save-additions-to' decides.
Falls back to `global' whenever the project offers no file for KIND,
so a suggestion is never a dead end."
  (let ((marker (and command (lsp-get command lsp-ltex-plus--target-marker)))
        (project (lsp-ltex-plus--project-file-for kind)))
    (cond
     ((not project) 'global)
     ((equal marker "project") 'project)
     ((equal marker "global") 'global)
     ((eq lsp-ltex-plus-save-additions-to 'globally-defined) 'global)
     ((eq lsp-ltex-plus-save-additions-to 'per-project-when-specified) 'project)
     ;; `either-allowing-user-choice' with no marker: the suggestion was not
     ;; split (or arrived from elsewhere), so keep the conservative file.
     (t 'global))))

(defun lsp-ltex-plus--save-addition (kind lang items command)
  "Add ITEMS for LANG to KIND's list, in the file COMMAND's target names.
Writing to the global file goes through the `-stored' mirror and
rebuilds the merged views, exactly as before.  Writing to a project file
updates the file and refreshes its cache entry, so the next check sees
the new entry without waiting for a modification-time comparison."
  (if (eq (lsp-ltex-plus--addition-target kind command) 'project)
      (let* ((path (lsp-ltex-plus--project-file-for kind))
             (key (intern (concat ":" lang)))
             (merged (lsp-ltex-plus--merge-plists
                      (lsp-ltex-plus--load-project-plist path)
                      (list key (vconcat items)))))
        (lsp-ltex-plus--log "Saving %s for %s to project file %s" items lang path)
        (lsp-ltex-plus--save-plist merged path)
        (puthash path
                 (cons (file-attribute-modification-time (file-attributes path))
                       merged)
                 lsp-ltex-plus--project-file-cache))
    (lsp-ltex-plus--add-to-plist (lsp-ltex-plus--kind-get kind :stored)
                                 (symbol-value (lsp-ltex-plus--kind-get kind :global-file))
                                 lang items)
    (lsp-ltex-plus--recompute-merged)))

(provide 'lsp-ltex-plus-settings)
;;; lsp-ltex-plus-settings.el ends here
