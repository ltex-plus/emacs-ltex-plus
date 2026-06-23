;;; lsp-ltex-plus.el --- Grammar and spell checking for LaTeX, Markdown, Org and more -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-7
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1") (lsp-mode "6.0"))
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; `lsp-ltex-plus' is an `lsp-mode' client for LTeX+, a LanguageTool-based
;; grammar, spell, and style checker.  It brings professional-grade writing
;; feedback into Emacs for:
;;
;;   * Markup and writing languages — LaTeX, Markdown, Org, RestructuredText,
;;     HTML, BibTeX, AsciiDoc, Typst, Quarto, Magit commit messages, plain
;;     text, and many others (checked by default).
;;   * Comments and string literals in 30+ programming languages — Python,
;;     C/C++, Rust, Java, JavaScript/TypeScript, Go, Ruby, … (opt-in via
;;     `lsp-ltex-plus-check-programming-languages').
;;
;; Highlights:
;;
;;   * Add-on integration — registers with `:add-on? t' and `:priority -1',
;;     so it runs concurrently with primary LSP servers (texlab, pyright,
;;     etc.) without competing for features such as Go-to-Definition or
;;     Completion.
;;   * Offline by default — the local `ltex-ls-plus' binary checks documents
;;     entirely on your machine, no network involved.  An optional remote
;;     LanguageTool server (with optional LanguageTool Premium credentials)
;;     is supported for users who want it.
;;   * Multilingual — every external setting is keyed by language code
;;     (`:en-US', `:de-DE', `:fr', …), so dictionaries, disabled rules,
;;     enabled rules, and hidden false-positives are tracked per language.
;;   * Persistent state — words you "add to dictionary", rules you disable,
;;     and false positives you hide are saved as plist files under
;;     `user-emacs-directory' and survive Emacs restarts.  User-level
;;     `:custom' entries seed the defaults and remain pristine (never
;;     mutated by the package at runtime).
;;   * Lazy loading — split into a tiny bootstrap file loaded at Emacs
;;     startup and a full client loaded only on first use, so installing
;;     the package costs essentially no startup time.
;;   * Simple setup — one call to `lsp-ltex-plus-enable-for-modes' from
;;     the `:init' block of `use-package' activates the client across
;;     every supported major mode.  Narrow the set with the `:restrict-to'
;;     or `:exclude' keywords, or add your own modes with `:extend-to',
;;     without editing `lsp-ltex-plus-major-modes'.  All settings are
;;     defcustoms under the `lsp-ltex-plus-' prefix, configurable via
;;     `:custom' or `M-x customize-group RET lsp-ltex-plus RET'.
;;
;; Minimal setup with `use-package':
;;
;;   (use-package lsp-ltex-plus
;;     :init (lsp-ltex-plus-enable-for-modes))
;;
;; See the README at URL `https://github.com/ltex-plus/emacs-ltex-plus' for
;; full configuration, multi-language setup, performance tuning, and a
;; comparison with the older `lsp-ltex' package.
;;
;; External dependencies:
;;
;;   - `ltex-ls-plus' binary on `exec-path'.
;;   - Java runtime — platform-specific `ltex-ls-plus' releases include a
;;     bundled JRE; otherwise Java 21 or later must be installed.
;;   - Optional: LanguageTool.org account for premium rules.

;;; Code:

(require 'lsp-mode)
(require 'seq)
(require 'cl-lib)
(require 'lsp-ltex-plus-bootstrap)

;; Optional diagnostic front-ends; checked via `bound-and-true-p' at runtime.
(declare-function flycheck-buffer "ext:flycheck")
(declare-function flymake-start "flymake")

;; Forward declaration: the minor mode is defined further down the file
;; but is referenced earlier (e.g. in the lsp client's `:activation-fn').
(defvar lsp-ltex-plus-mode)

;;;; -- Customization ----------------------------------------------------------

(defgroup lsp-ltex-plus nil
  "Customization group for the LTEX+ grammar checker."
  :group 'lsp-mode
  :prefix "lsp-ltex-plus-")

(defcustom lsp-ltex-plus-ls-plus-executable "ltex-ls-plus"
  "The name or path of the ltex-ls-plus executable."
  :type 'string
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
  :group 'lsp-ltex-plus)

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
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-enabled-rules nil
  "Lists of rules that should be enabled (if disabled by default).
This setting is language-specific, so use an object of the format
\\='(:en-US [\"RULE1\" \"RULE2\"] :de-DE [\"RULE1\" ...]) where the key is
the language code and the value is a vector of rule IDs."
  :type 'plist
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-disabled-rules nil
  "Lists of rules that should be disabled (if enabled by default).
This setting is language-specific, so use an object of the format
\\='(:en-US [\"RULE1\" \"RULE2\"] :de-DE [\"RULE1\" ...]) where the key is
the language code and the value is a vector of rule IDs."
  :type 'plist
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
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-bibtex-fields nil
  "List of BibTeX fields whose values are to be checked in BibTeX files.
This setting is an object with the field names as keys and Booleans as values,
where true means that the field value should be checked and false means that
the field value should be ignored.  Field names are listed as symbols
(e.g., `title')."
  :type 'alist
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-latex-commands nil
  "List of LaTeX commands to be handled by the LaTeX parser.
This setting is an object with the commands as keys and corresponding
actions as values (\"default\", \"ignore\", \"dummy\", \"pluralDummy\",
\"vowelDummy\"). Commands are listed as symbols (not strings) with empty
arguments and the initial backslash doubled, e.g. `\\\\ref{}',
`\\\\documentclass[]{}'."
  :type 'alist
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-latex-environments nil
  "List of names of LaTeX environments to be handled by the LaTeX parser.
This setting is an object with the environment names as keys and corresponding
actions as values (\"default\", \"ignore\").  Environment names are listed as
symbols (e.g., `lstlisting')."
  :type 'alist
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-markdown-nodes nil
  "List of Markdown node types to be handled by the Markdown parser.
This setting is an object with the node types as keys and corresponding
actions as values (\"default\", \"ignore\", \"dummy\", \"pluralDummy\",
\"vowelDummy\").  Node types are listed as symbols (e.g., `CodeBlock')."
  :type 'alist
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-enable-picky-rules nil
  "Enable LanguageTool rules that are marked as picky.
These are disabled by default, e.g., rules about passive voice, sentence length,
etc., at the cost of more false positives."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-mother-tongue nil
  "Optional mother tongue of the user (e.g., \"de-DE\").
If set, additional rules will be checked to detect false friends. Picky rules
may need to be enabled in order to see an effect.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "Language code"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-additional-rules-language-model nil
  "Optional path to a directory with rules of a language model with n-gram counts.
Set this to the parent directory that contains subdirectories for
languages.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (directory :tag "Directory"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-lt-server-uri nil
  "Base URI for the LanguageTool HTTP server.
When nil (default), ltex-ls-plus uses its local, built-in LanguageTool.
To use an online service, set this to e.g.,
\"https://api.languagetoolplus.com\".
Note: ltex-ls-plus appends /v2/check to this, so omit the /v2 suffix here."
  :type '(choice (const :tag "Local (Built-in)" nil)
                 (string :tag "Remote URI"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-lt-username nil
  "Username/email as used to log in at languagetool.org for Premium API access.
Only relevant if `lsp-ltex-plus-lt-server-uri' is set.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "Username/email"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-lt-api-key nil
  "API key for Premium API access.
Only relevant if `lsp-ltex-plus-lt-server-uri' is set.  nil means unset."
  :type '(choice (const :tag "Unset" nil) (string :tag "API key"))
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
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-paragraph-cache-ttl-minutes 30
  "How long, in minutes, a document's cached results are kept unused.
The per-paragraph cache lets ltex-ls-plus reuse the results of
unchanged paragraphs after an edit.  Entries for the file you are
actively editing stay warm; a document left untouched for longer than
this is dropped from the cache.  A document's cache is also cleared as
soon as the file is closed."
  :type 'integer
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
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-completion-enabled nil
  "Controls whether completion is enabled (IntelliSense)."
  :type 'boolean
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-diagnostic-severity "warning"
  "Severity of the diagnostics corresponding to the grammar and spelling errors.
Possible severities are \"error\", \"warning\", \"information\", and \"hint\"."
  :type '(choice (const "error") (const "warning") (const "information") (const "hint"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-check-frequency "edit"
  "Controls when documents should be checked.
- \"edit\": checked when opened or edited (on every keystroke).
- \"save\": checked when opened or saved.
- \"manual\": use commands to manually trigger checks."
  :type '(choice (const "edit") (const "save") (const "manual"))
  :group 'lsp-ltex-plus)

(defcustom lsp-ltex-plus-clear-diagnostics-when-closing-file t
  "If set to true, diagnostics of a file are cleared when the file is closed."
  :type 'boolean
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

(defun lsp-ltex-plus--enabled-languages ()
  "Return the unique language IDs from `lsp-ltex-plus-major-modes'.
All supported IDs are always returned.  Filtering happens client-side,
via the dispatcher (`lsp-ltex-plus--maybe-activate') and the
`lsp-ltex-plus-mode' guard: the server only ever sees documents for
buffers in which the minor mode is active, so `ltex.enabled' can safely
cover every registered language without triggering unwanted checks.

This design differs from the VS Code LTeX+ extension, which (to the best
of our knowledge) registers a static document selector covering every
supported language and relies on `ltex.enabled' as a server-side runtime
filter: the client always fires `textDocument/didChange' and the server
drops notifications whose language ID is not enabled.  In the Emacs
client the filter lives in the dispatcher instead, so the server only
ever sees documents the user intended to check, and `ltex.enabled' is
effectively a no-op by construction."
  (seq-uniq (mapcar #'cadr lsp-ltex-plus-major-modes) #'string=))

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
  "Print the merged dictionary currently in effect to the echo area.
The value shown is `lsp-ltex-plus--dictionary-merged' — the union of
the user-provided defcustom `lsp-ltex-plus-dictionary' and the
on-disk `lsp-ltex-plus-dictionary-file'."
  (interactive)
  (message "[lsp-ltex-plus] Dictionary: %S" lsp-ltex-plus--dictionary-merged))

(defun lsp-ltex-plus--notify-ltex-workspaces ()
  "Send `workspace/didChangeConfiguration' to every ltex-ls-plus workspace.
No-op if `lsp-mode' is not loaded or no ltex-ls-plus workspace is active."
  (when (fboundp 'lsp-session)
    (dolist (ws (lsp--session-workspaces (lsp-session)))
      (when (eq 'ltex-ls-plus (lsp--workspace-server-id ws))
        (with-lsp-workspace ws
          (lsp-notify "workspace/didChangeConfiguration" '(:settings nil)))))))

(defun lsp-ltex-plus-reload-and-notify-server ()
  "Reload settings from disk and push them to every ltex-ls-plus workspace.
Two steps run together:

  1. Re-read the four external plist files under
     the `lsp-ltex-plus/' subdirectory of `user-emacs-directory'
     and rebuild the merged views
     (each merged view combines a file's contents with its
     corresponding user defcustom).
  2. Send `workspace/didChangeConfiguration' to every running
     ltex-ls-plus workspace so the new state takes effect on the
     next check, with no server restart.

Use this whenever you change anything that the server reads —
either by editing one of the on-disk files by hand (bulk-adding
words, removing stale disabled rules) or by setting an
`lsp-ltex-plus-*' defcustom in an active session and wanting the
change applied without reloading."
  (interactive)
  (lsp-ltex-plus--load-external-settings)
  (lsp-ltex-plus--notify-ltex-workspaces)
  (message "[lsp-ltex-plus] Settings reloaded and pushed to server."))

;; Deprecated alias (introduced in v0.3.0, renamed in v0.3.1).
;; The previous name described only the disk-reload half; the function
;; also pushes to the server, which is what makes settings take effect.
(define-obsolete-function-alias 'lsp-ltex-plus-reload-external-settings
  #'lsp-ltex-plus-reload-and-notify-server
  "0.3.1"
  "Renamed to better describe what the function does (reload + push to server).")

;;;; -- Action Handlers --------------------------------------------------------

;; Use abstract `lsp-get' / `lsp-map' (from `lsp-protocol.el') rather low-level
;; than `gethash' / `maphash' directly: lsp-mode represents JSON objects as hash
;; tables by default but as plists when `lsp-use-plists' is set at byte-compile
;; time (the default in Doom Emacs).  The `lsp-get' / `lsp-map' helpers pick the
;; right accessor for the active representation and normalise the key to a
;; string.

(defun lsp-ltex-plus--action-add-to-dictionary (action)
  "Process the _ltex.addToDictionary ACTION from the server."
  (lsp-ltex-plus--log "Action: addToDictionary")
  (let* ((args (lsp-get action :arguments))
         (arg0 (and (vectorp args) (aref args 0)))
         (words-by-lang (and arg0 (lsp-get arg0 :words))))
    (if (null words-by-lang)
        (message "[lsp-ltex-plus] addToDictionary: Malformed arguments %S" args)
      (lsp-map (lambda (lang words-arr)
                 (lsp-ltex-plus--add-to-plist 'lsp-ltex-plus--dictionary-stored
                                              lsp-ltex-plus-dictionary-file
                                              lang (append words-arr nil)))
               words-by-lang)
      (lsp-ltex-plus--recompute-merged)))
  ;; Notify server of config change so it re-fetches settings.
  (lsp-notify "workspace/didChangeConfiguration" '(:settings nil)))

(defun lsp-ltex-plus--action-disable-rules (action)
  "Process the _ltex.disableRules ACTION."
  (lsp-ltex-plus--log "Action: disableRules")
  (let* ((args (lsp-get action :arguments))
         (arg0 (and (vectorp args) (aref args 0)))
         (rules-by-lang (and arg0 (lsp-get arg0 :ruleIds))))
    (if (null rules-by-lang)
        (message "[lsp-ltex-plus] disableRules: Malformed arguments %S" args)
      (lsp-map (lambda (lang rules-arr)
                 (lsp-ltex-plus--add-to-plist 'lsp-ltex-plus--disabled-rules-stored
                                              lsp-ltex-plus-disabled-rules-file
                                              lang (append rules-arr nil)))
               rules-by-lang)
      (lsp-ltex-plus--recompute-merged)))
  (lsp-notify "workspace/didChangeConfiguration" '(:settings nil)))

(defun lsp-ltex-plus--action-hide-false-positives (action)
  "Process the _ltex.hideFalsePositives ACTION."
  (lsp-ltex-plus--log "Action: hideFalsePositives")
  (let* ((args (lsp-get action :arguments))
         (arg0 (and (vectorp args) (aref args 0)))
         (fps-by-lang (and arg0 (lsp-get arg0 :falsePositives))))
    (if (null fps-by-lang)
        (message "[lsp-ltex-plus] hideFalsePositives: Malformed arguments %S" args)
      (lsp-map (lambda (lang fps-arr)
                 (lsp-ltex-plus--add-to-plist 'lsp-ltex-plus--hidden-false-positives-stored
                                              lsp-ltex-plus-hidden-false-positives-file
                                              lang (append fps-arr nil)))
               fps-by-lang)
      (lsp-ltex-plus--recompute-merged)))
  (lsp-notify "workspace/didChangeConfiguration" '(:settings nil)))

;;;; -- Custom Request Handlers ------------------------------------------------

(defun lsp-ltex-plus--request-workspace-specific-configuration (_workspace params)
  "Handle the custom `ltex/workspaceSpecificConfiguration' request.

PARAMS carries `items', a vector of `(scopeUri URI, section SECTION)'.
For each requested item we return the same merged language-keyed maps
\(`dictionary', `disabledRules', `enabledRules', `hiddenFalsePositives'),
mirroring VS Code's `WorkspaceConfigurationRequestHandler'.

Per-scope differentiation is intentionally not implemented: every URI
receives the same global merged values.  See the \"Hierarchical scope
support\" item in CLAUDE.md for what would be needed to honour scopeUri.

PARAMS may arrive as either a plist (when `lsp-use-plists' is non-nil)
or a hash-table (the default).  We read it via `lsp-get', the
representation-agnostic accessor exported by lsp-mode, and count the
items defensively for both vector and list shapes.

The result is a vector — one entry per requested item — to match the
shape `vscode-languageclient' returns to the server.  Each entry is a
plist with keyword keys; `json-serialize' converts those to JSON object
keys regardless of `lsp-use-plists', so no hash-table conversion on the
outgoing side is needed (except for empty maps, where
`lsp-ltex-plus--obj-or-empty' substitutes the shared empty hash-table)."
  (lsp-ltex-plus--log "ltex/workspaceSpecificConfiguration request: %S" params)
  (let* ((items (lsp-get params :items))
         (count (cond ((vectorp items) (length items))
                      ((listp items) (length items))
                      (t 0)))
         ;; The four fields below are JSON objects per VS Code's TS type
         ;; `LanguageSpecificSettingValue' — never nullable.  Use
         ;; `lsp-ltex-plus--obj-or-empty' to substitute the shared empty
         ;; hash-table for nil so `json-serialize' emits `{}' rather than
         ;; `null'.  See the helper's docstring for the underlying ambiguity.
         (entry (list :dictionary           (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--dictionary-merged)
                      :disabledRules        (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--disabled-rules-merged)
                      :enabledRules         (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--enabled-rules-merged)
                      :hiddenFalsePositives (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--hidden-false-positives-merged)))
         (result (make-vector count nil)))
    (dotimes (i count)
      (aset result i (copy-sequence entry)))
    result))


;;;; -- Lsp-mode Protocol Patches -----------------------------------------------

;; This section contains surgical protocol-level fixes for `lsp-mode`.
;; They are applied only when `lsp-ltex-plus-apply-kind-first-patch' is non-nil.
;;
;; 1. Kind-First Routing: prioritizes the \\='method\\=' field over \\='id\\=',
;;    preventing deadlocks when server-initiated requests collide with client
;;    response IDs.
;;
;; 2. Resilient Batch Dispatch: patches the process filter to salvage messages
;;    on framing errors and ensure that a non-local exit (like a
;;    completion-interrupt) from one message doesn't abandon the rest of the
;;    batch.
;;
;; 3. Stale Callback Protection: prevents synchronous requests from throwing
;;    after they have already timed out or been cancelled.

(defun lsp-ltex-plus--parser-on-message-patch (json-data workspace)
  "Patched `lsp--parser-on-message' implementing Kind-First routing.

JSON-DATA is the parsed JSON message; WORKSPACE is the active lsp workspace.

This patch prevents server-initiated requests from being misrouted as responses
to client requests when IDs collide.

Status: deprecated.  The same fix has been merged into `lsp-mode'
upstream as PR #5055 (commit fbc926fd, 2026-05-11).  This function
is installed as `:override' advice on `lsp--parser-on-message' by
`lsp-ltex-plus--apply-lsp-mode-patch', which is called only when the
user has set `lsp-ltex-plus-apply-kind-first-patch' to t AND
`lsp-ltex-plus--maybe-upstream-fixes-present-p' returns nil (i.e. the
installed `lsp-mode' does not yet contain the upstream fix).  On a
recent `lsp-mode' this advice is therefore not installed; on an
older `lsp-mode' it still serves as the backport."
  ;; Define a local helper for JSON parsing. This is an auxiliary function
  ;; used exclusively by the patch to ensure the package remains standalone.
  (cl-labels ((json-get (obj key)
                (cond
                 ((hash-table-p obj)
                  (gethash key obj))
                 ((listp obj)
                  (or (plist-get obj (intern (concat ":" key)))
                      (plist-get obj (intern key))))
                 (t nil))))
    ;; Silently catch and log any errors during message processing. This prevents
    ;; a single malformed message from crashing the entire LSP client.
    (with-demoted-errors "Error processing message %S."
      (with-lsp-workspace workspace
        (let* ((client (lsp--workspace-client workspace))
               (method (json-get json-data "method"))
               (raw-id (json-get json-data "id"))
               (has-method (and method t))
               (has-id (and raw-id t))
               (has-error (and (json-get json-data "error") t))
               ;; Kind-First routing: if a method exists, it's a server-initiated
               ;; message (request/notification) regardless of ID collisions.
               (message-type (cond
                              (has-method (if has-id 'request 'notification))
                              (has-id (if has-error 'response-error 'response))
                              (t 'notification)))
               ;; Normalize response IDs only (client-generated ids are numeric).
               (id (and (memq message-type '(response response-error))
                        raw-id
                        (if (stringp raw-id) (string-to-number raw-id) raw-id))))
          (pcase message-type
            ('response
             (when id
               (let ((handler (gethash id (lsp--client-response-handlers client))))
                 (when handler
                   (let ((callback (nth 0 handler))
                         (cb-method (nth 2 handler))
                         (before-send (nth 4 handler))
                         (result (json-get json-data "result")))
                     (when (lsp--log-io-p cb-method)
                       (lsp--log-entry-new
                        (lsp--make-log-entry cb-method id result 'incoming-resp
                                             (lsp--ms-since before-send))
                        workspace))
                     (when callback
                       (remhash id (lsp--client-response-handlers client))
                       (funcall callback result)))))))
            ('response-error
             (when id
               (let ((handler (gethash id (lsp--client-response-handlers client))))
                 (when handler
                   (let ((err-callback (nth 1 handler))
                         (cb-method (nth 2 handler))
                         (before-send (nth 4 handler))
                         (err (json-get json-data "error")))
                     (when (lsp--log-io-p cb-method)
                       (lsp--log-entry-new
                        (lsp--make-log-entry cb-method id err 'incoming-resp
                                             (lsp--ms-since before-send))
                        workspace))
                     (when err-callback
                       (remhash id (lsp--client-response-handlers client))
                       (funcall err-callback err)))))))
            ('notification
             (lsp--on-notification workspace json-data))
            ('request
             (lsp--on-request workspace json-data))))))))

(defun lsp-ltex-plus--create-filter-function-patch (workspace)
  "Patched `lsp--create-filter-function' with resilient message dispatch.
WORKSPACE is the active workspace.

This patch ensures that when the server sends multiple updates
bundled together, an interruption in one (like typing during
completion) doesn\\='t cause the rest of the bundle to be
discarded.

Status: deprecated.  The same fix has been merged into `lsp-mode'
upstream as PR #5057 (commit 0951bf38, 2026-05-15).  This function
is installed as `:override' advice on `lsp--create-filter-function'
by `lsp-ltex-plus--apply-lsp-mode-patch', which is called only when
the user has set `lsp-ltex-plus-apply-kind-first-patch' to t AND
`lsp-ltex-plus--maybe-upstream-fixes-present-p' returns nil (i.e. the
installed `lsp-mode' does not yet contain the upstream fix).  On a
recent `lsp-mode' this advice is therefore not installed; on an
older `lsp-mode' it still serves as the backport."
  (let ((body-received 0)
        leftovers body-length body chunk)
    (lambda (_proc input)
      (setf chunk (if (s-blank? leftovers)
                      (encode-coding-string input 'utf-8-unix t)
                    (concat leftovers (encode-coding-string input 'utf-8-unix t))))

      (let (messages)
        (condition-case framing-err
            (while (not (s-blank? chunk))
              (if (not body-length)
                  ;; Read headers
                  (if-let* ((body-sep-pos (string-match-p "\r\n\r\n" chunk)))
                      ;; We've got all the headers, handle them all at once:
                      (setf body-length (lsp--get-body-length
                                         (mapcar #'lsp--parse-header
                                                 (split-string
                                                  (substring-no-properties chunk
                                                                           (or (string-match-p "Content-Length" chunk)
                                                                               (error "Unable to find Content-Length header"))
                                                                           body-sep-pos)
                                                  "\r\n")))
                            body-received 0
                            leftovers nil
                            chunk (substring-no-properties chunk (+ body-sep-pos 4)))

                    ;; Haven't found the end of the headers yet. Save everything
                    ;; for when the next chunk arrives and await further input.
                    (setf leftovers chunk
                          chunk nil))
                (let* ((chunk-length (string-bytes chunk))
                       (left-to-receive (- body-length body-received))
                       (this-body (if (< left-to-receive chunk-length)
                                      (prog1 (substring-no-properties chunk 0 left-to-receive)
                                        (setf chunk (substring-no-properties chunk left-to-receive)))
                                    (prog1 chunk
                                      (setf chunk nil))))
                       (body-bytes (string-bytes this-body)))
                  (push this-body body)
                  (setf body-received (+ body-received body-bytes))
                  (when (>= chunk-length left-to-receive)
                    (condition-case err
                        (with-temp-buffer
                          (apply #'insert
                                 (nreverse
                                  (prog1 body
                                    (setf leftovers nil
                                          body-length nil
                                          body-received nil
                                          body nil))))
                          (decode-coding-region (point-min)
                                                (point-max)
                                                'utf-8)
                          (goto-char (point-min))
                          (push (lsp-json-read-buffer) messages))

                      (error
                       (lsp-warn "Failed to parse the following chunk:\n'''\n%s\n'''\nwith message %s"
                                 (concat leftovers input)
                                 err)))))))
          (error
           ;; Framing error escaped the loop (e.g. mid-body bytes mistaken for
           ;; headers after a JSON parse cleared framing state). Reset framing
           ;; state and fall through so already-parsed messages still reach the
           ;; dispatcher instead of being silently discarded.
           (lsp-warn "[lsp-filter] framing-error-salvage: salvaged %d parsed message(s); error: %S"
                     (length messages) framing-err)
           (setf leftovers nil
                 body-length nil
                 body-received 0
                 body nil)))
        ;; Per-message dispatch: catch known throw tags so a single
        ;; message's non-local exit doesn't abandon the rest of the batch.
        ;; The throw is re-issued after all messages have been dispatched,
        ;; so the original target catch (e.g. (catch 'lsp-done ...) in
        ;; `lsp-request-while-no-input' or (lsp--catch 'input ...) in
        ;; lsp-completion.el) still receives it.
        (let ((sentinel (cons nil nil))
              queued-tag queued-value)
          (dolist (msg (nreverse messages))
            (let ((r (catch 'lsp-done
                       (let ((r2 (catch 'input
                                   (lsp--parser-on-message msg workspace)
                                   sentinel)))
                         (unless (eq r2 sentinel)
                           (setq queued-tag 'input queued-value r2))
                         sentinel))))
              (unless (eq r sentinel)
                (setq queued-tag 'lsp-done queued-value r))))
          (when queued-tag
            (throw queued-tag queued-value)))))))

(cl-defun lsp-ltex-plus--request-while-no-input-patch (method params)
  "Patched `lsp-request-while-no-input' with stale callback protection.

Send METHOD with PARAMS, but prevent the success/error callbacks
from throwing \\='lsp-done after the function has already unwound
\(e.g. due to timeout or cancellation), which would otherwise
cause the throw to escape to the top level.

Status: deprecated.  The same fix has been merged into `lsp-mode'
upstream as PR #5056 (commit e5cdc6c8, 2026-05-12).  This function
is installed as `:override' advice on `lsp-request-while-no-input'
by `lsp-ltex-plus--apply-lsp-mode-patch', which is called only when
the user has set `lsp-ltex-plus-apply-kind-first-patch' to t AND
`lsp-ltex-plus--maybe-upstream-fixes-present-p' returns nil (i.e. the
installed `lsp-mode' does not yet contain the upstream fix).  On a
recent `lsp-mode' this advice is therefore not installed; on an
older `lsp-mode' it still serves as the backport."
  (if (or non-essential (not lsp-request-while-no-input-may-block))
      (let* ((send-time (float-time))
             ;; max time by which we must get a response
             (expected-time
              (and
               lsp-response-timeout
               (+ send-time lsp-response-timeout)))
             resp-result resp-error done?
             (catch-active t))
        (unwind-protect
            (progn
              (lsp-request-async method params
                                 (lambda (res)
                                   (when catch-active
                                     (setf resp-result (or res :finished))
                                     (throw 'lsp-done '_)))
                                 :error-handler (lambda (err)
                                                  (when catch-active
                                                    (setf resp-error err)
                                                    (throw 'lsp-done '_)))
                                 :mode 'detached
                                 :cancel-token :sync-request)
              (while (not (or resp-error resp-result (input-pending-p)))
                (catch 'lsp-done
                  (sit-for
                   (if expected-time (- expected-time send-time) 1)))
                (setq send-time (float-time))
                (when (and expected-time (< expected-time send-time))
                  (error "Timeout while waiting for response.  Method: %s" method)))
              (setq done? (or resp-error resp-result))
              (cond
               ((eq resp-result :finished) nil)
               (resp-result resp-result)
               ((lsp-json-error? resp-error) (error (lsp:json-error-message resp-error)))
               ((lsp-json-error? (cl-first resp-error))
                (error (lsp:json-error-message (cl-first resp-error))))))
          (setq catch-active nil)
          (unless done?
            (lsp-cancel-request-by-token :sync-request))
          (when (and (input-pending-p) lsp--throw-on-input)
            (throw 'input :interrupted))))
    (lsp-request method params)))

(defun lsp-ltex-plus--maybe-upstream-fixes-present-p ()
  "Return non-nil when upstream `lsp-mode' already carries the protocol fixes.

Five LSP-protocol bugs that this package previously worked around have
since been fixed upstream in `lsp-mode' (all on master as of
2026-05-15, commit 0951bf38):

  - PR #5052 — bare-array CompletionItem[] responses
  - PR #5055 — Kind-First routing (server requests vs client responses)
  - PR #5056 — stale callbacks throwing after a sync request unwinds
  - PR #5057 — resilient batch dispatch on framing errors and throws
  - PR #5059 — empty-object capabilities preserved under `lsp-use-plists'

This probe is purely advisory.  It is NOT the gate that decides
whether to install the patches.  That gate is the user-facing option
`lsp-ltex-plus-apply-kind-first-patch', which the user opts into
explicitly; when that option is set, the patches are always applied
regardless of what this probe returns.

The probe's role is the opposite direction: when the user has the
option enabled but their `lsp-mode' already carries the fixes
upstream — typically because they forgot to remove the option after
upgrading `lsp-mode', or set it without realising the fixes had since
landed — we emit a deprecation warning suggesting they drop the
option from their config.  Nothing is skipped.

Skipping based on this probe would be dangerous: the probe relies on
a marker symbol (`lsp--inlay-hint-tooltip-text') that could in
principle be renamed, removed, or moved in a future `lsp-mode'
release without the underlying protocol fixes being reverted, or vice
versa.  Trusting the probe to suppress the patches would risk leaving
the user unprotected from the very bugs they opted in to work around.
A spurious deprecation warning, by contrast, is harmless.

The probe checks for `lsp--inlay-hint-tooltip-text', a function added
to `lsp-mode.el' in commit 8b04cf63 (2026-05-17) — the commit
immediately after the last protocol fix (0951bf38, 2026-05-15).  It
lives in a file `lsp-mode' loads by default and survives byte and
native compilation, so `fboundp' is a reliable best-effort marker
that the user's `lsp-mode' is at or past the protocol-fix series.

The user-facing recommendation in the README is to install `lsp-mode'
from a commit on or after 0951bf38 (2026-05-15) and remove
`lsp-ltex-plus-apply-kind-first-patch' from their config.  On a recent
`lsp-mode' the patches in this package are effectively a no-op anyway:
the `:override' advices replace upstream code that already mirrors what
the patches do.  Nothing breaks if the user leaves the option enabled.
The recommendation to disable it is purely about being future-proof:
keep the configuration tied to the upstream implementation that is now
fixed, rather than carrying a local patch that no longer adds value
and could in principle drift from upstream over time."
  (fboundp 'lsp--inlay-hint-tooltip-text))

(defun lsp-ltex-plus--apply-lsp-mode-patch ()
  "Apply the protocol patches to `lsp-mode'.
These patch `lsp--parser-on-message', `lsp--create-filter-function',
and `lsp-request-while-no-input' using :override advice to improve
protocol robustness."
  (advice-add 'lsp--parser-on-message :override #'lsp-ltex-plus--parser-on-message-patch)
  (advice-add 'lsp--create-filter-function :override #'lsp-ltex-plus--create-filter-function-patch)
  (advice-add 'lsp-request-while-no-input :override #'lsp-ltex-plus--request-while-no-input-patch))

(defun lsp-ltex-plus--restore-completion-capability (workspace)
  "Restore the completionProvider on WORKSPACE under `lsp-use-plists' t.
The server advertises `completionProvider: {}' (a valid empty options
object).  Emacs\\='s `json-parse-string' with `:object-type \\='plist'
parses an empty JSON object as nil, which is indistinguishable from a
missing field, so `lsp:server-capabilities-completion-provider?'
returns nil and `lsp-mode' treats the server as not supporting
completion.  Replace the collapsed nil with a single-key plist that
survives downstream accessors and accurately reflects the server\\='s
behaviour: `(:resolveProvider nil)' — ltex-ls-plus implements no
`completionItem/resolve' handler, so the declaration is honest.

Status: effectively a no-op on recent `lsp-mode'.  The same fix has
been merged upstream as PR #5059 (commit 7c5b5263, 2026-05-10),
where empty JSON objects are preserved through a non-nil sentinel
under `lsp-use-plists'.  This function is called unconditionally
from `:initialized-fn' on every workspace: on a recent `lsp-mode'
the slot is no longer nil so the `when' guard fails and the call
does nothing; on an older `lsp-mode' it still serves as the
backport.  Calling unconditionally — rather than gating on
`lsp-ltex-plus--maybe-upstream-fixes-present-p' — is intentional:
the function is self-guarding and free, while gating would risk
silently dropping the workaround if a future `lsp-mode' keeps the
probe's marker symbol but regresses or relocates the PR #5059 fix."
  (when lsp-use-plists
    (let ((caps (lsp--workspace-server-capabilities workspace)))
      (when (and caps
                 (plist-member caps :completionProvider)
                 (null (plist-get caps :completionProvider)))
        (plist-put caps :completionProvider '(:resolveProvider nil))))))

(defun lsp-ltex-plus--capture-server-info (workspace)
  "Store WORKSPACE's reported server name and version, if available.
Reads the `serverInfo' the server returned in its `initialize' response
via the `lsp-workspace-server-name' / `-server-version' accessors and
records them in `lsp-ltex-plus--server-name' and
`lsp-ltex-plus--server-version'.

Those accessors only exist on an `lsp-mode' that carries the
`serverInfo' plumbing, so the call is guarded with `fboundp': on an
older `lsp-mode' this is a no-op and both variables stay nil.  A server
that omits `serverInfo' (or its version) also leaves the corresponding
variable nil."
  (when (and (fboundp 'lsp-workspace-server-name)
             (fboundp 'lsp-workspace-server-version))
    (setq lsp-ltex-plus--server-name (lsp-workspace-server-name workspace)
          lsp-ltex-plus--server-version (lsp-workspace-server-version workspace))
    (lsp-ltex-plus--log "Connected server: %s %s"
                        (or lsp-ltex-plus--server-name "<unknown>")
                        (or lsp-ltex-plus--server-version "<no version>"))))

(defun lsp-ltex-plus--suppress-progress (orig-fn workspace params)
  "Swallow ltex-ls-plus progress notifications.
Notifications are silenced when `lsp-ltex-plus-show-progress' is nil.
Around-advice for `lsp-on-progress-modeline'; passes PARAMS through to
ORIG-FN for every other WORKSPACE."
  (if (and (not lsp-ltex-plus-show-progress)
           (eq 'ltex-ls-plus (lsp--workspace-server-id workspace)))
      nil
    (funcall orig-fn workspace params)))

;;;; -- Latency Benchmarking ---------------------------------------------------

;; Measure the round-trip between trigger notifications sent to ltex-ls-plus
;; (`textDocument/didOpen', `textDocument/didChange') and the matching
;; `textDocument/publishDiagnostics' that the server returns.  Two independent
;; reporters consume the measurement:
;;
;; - `lsp-ltex-plus-debug'         → timestamped entry in the
;;                                   `*lsp-ltex-plus::client*' log buffer.
;; - `lsp-ltex-plus-show-latency'  → one-line echo-area message; phrased
;;                                   differently for the cold-start (didOpen)
;;                                   and warm-path (didChange) cases so the
;;                                   two numbers can be read off at a glance.
;;
;; The benchmark only reflects server-side latency; the subsequent
;; flycheck/flymake rendering step is not included (see the
;; `lsp-ltex-plus-show-latency' docstring).
;;
;; When lsp-mode flushes a debounced didChange, we time from that flush — not
;; from the user's keystroke — so the number reflects "server became aware of
;; the new state → diagnostics returned", which is what we want to report.
;;
;; The two advices are installed at setup time only when
;; `lsp-ltex-plus-show-latency' is non-nil.  `lsp-ltex-plus-debug' does not gate
;; installation directly; instead, when debug mode is on, the sticky-defaults
;; block inside `lsp-ltex-plus--setup' turns `lsp-ltex-plus-show-latency' on
;; implicitly, so the debug user gets the benchmark "for free".
;;
;; Flipping `lsp-ltex-plus-show-latency' later in the session does not install
;; the advice retroactively: `lsp-ltex-plus--setup' fires once at
;; package load time, and is not re-entered by `lsp-restart-workspace'
;; (that only restarts the server
;; process).  To start measuring mid-session, either re-evaluate the two
;; `advice-add' forms below or call `lsp-ltex-plus--setup' again (it is
;; idempotent).  This prevent the benchmark — a basic, investigative tool that
;; is off in everyday use — from installing leaving advice on
;; `lsp--on-diagnostics', which is a private `lsp-mode' function whose signature
;; may change between versions.
;;
;; CURRENT LIMITATIONS OF BENCHMARKS
;;
;; A `publishDiagnostics' notification does not carry a reference to the
;; trigger it answers: no JSON-RPC `id' (it is a notification, not a
;; response), and `ltex-ls-plus' does not echo `textDocument.version' in its
;; params (verified in the wire log).  We therefore cannot match a response
;; to its originating request.
;;
;; Practical solution: we keep a *single* pending-measurement slot per
;; workspace.  Every outgoing trigger overwrites it; the first
;; publishDiagnostics that arrives claims whatever is in the slot.  This is the
;; simplest workable scheme with no correlation ID available, and it is correct
;; in the common case (one trigger → one response, with nothing else in flight).
;;
;; CAVEAT: OPTIMISTIC TIMING IN PATHOLOGICAL SITUATIONS
;;
;;  When more than one trigger fires before the first response returns, we
;;  measure from the *most recent* trigger, even though the server may still be
;;  answering an earlier, now-overwritten one.  The reported elapsed is
;;  therefore always ≤ true latency: we can underestimate but never
;;  overestimate.  Example timeline:
;;
;;        t=0    didChange v2 sent     (slot := T0, label incremental)
;;        t=50   didChange v3 sent     (slot := T1, overwrite)
;;        t=100  didChange v4 sent     (slot := T2, overwrite)
;;        t=180  publishDiagnostics    (elapsed reported: 180-100 = 80 ms)
;;
;;    If that diagnostic was really the server's answer to v2 (true latency
;;    180 ms), the bias is 100 ms downward.  If it was the answer to v4, the
;;    report is exact.
;;
;; In practice, this situation is rare.  `lsp-mode' coalesces rapid edits into
;; one didChange because of `lsp-debounce-full-sync-notifications-interval'
;; before flushing, and `ltex-ls-plus' publishes diagnostics for the latest
;; processed version rather than every intermediate one, so the "most recent
;; trigger" slot usually is the one the server is actually answering.  In
;; conclusion: a bias rarely occurs and, when present, is silent and always
;; optimistic.

(defvar lsp-ltex-plus--pending-measurements (make-hash-table :test 'eq)
  "Per-workspace map of pending latency measurements.
Each value is a list (TIMESTAMP BUFFER LABEL) where LABEL is one of
\"initial\" (didOpen) or \"incremental\" (didChange).  Consumed when the
matching `textDocument/publishDiagnostics' arrives.")

(defconst lsp-ltex-plus--benchmark-method-labels
  '(("textDocument/didOpen"   . "initial")
    ("textDocument/didChange" . "incremental"))
  "Mapping of outgoing LSP method names to benchmark labels.")

(defun lsp-ltex-plus--benchmark-outgoing (orig-fn method params)
  "Record the dispatch time of trigger notifications sent to ltex-ls-plus.
Around-advice for `lsp-notify'.  METHOD is matched against
`lsp-ltex-plus--benchmark-method-labels'; unrelated methods are ignored.
ORIG-FN and PARAMS are forwarded unchanged; the advice only observes the
call.

Gated on `lsp-ltex-plus-show-latency' so toggling the flag off mid-session
silences reporting immediately, even though the advice itself remains
installed until Emacs is restarted (it is only installed at startup when
the flag is on in the first place)."
  (when-let* ((lsp-ltex-plus-show-latency)
              ((bound-and-true-p lsp--cur-workspace))
              ((eq 'ltex-ls-plus
                   (lsp--workspace-server-id lsp--cur-workspace)))
              (label (cdr (assoc method
                                 lsp-ltex-plus--benchmark-method-labels))))
    (puthash lsp--cur-workspace
             (list (current-time) (current-buffer) label)
             lsp-ltex-plus--pending-measurements))
  (funcall orig-fn method params))

(defun lsp-ltex-plus--benchmark-diagnostics (workspace &rest _args)
  "Report server latency for ltex-ls-plus after diagnostics arrive.
After-advice for `lsp--on-diagnostics'; WORKSPACE is the workspace that
just published diagnostics.  The echo-area message is emitted
unconditionally (reaching this advice implies
`lsp-ltex-plus-show-latency' was non-nil at setup time); the log-buffer
entry is additionally emitted when `lsp-ltex-plus-debug' is non-nil.

The echo-area wording differs for cold-start (didOpen → \"initial
spell check\") and warm-path (didChange → \"spell check\")
measurements."
  (when (and lsp-ltex-plus-show-latency
             (eq 'ltex-ls-plus (lsp--workspace-server-id workspace)))
    (when-let* ((entry   (gethash workspace lsp-ltex-plus--pending-measurements))
                (ts      (nth 0 entry))
                (buf     (nth 1 entry))
                (label   (nth 2 entry))
                (elapsed (lsp--ms-since ts))
                (phrase  (pcase label
                           ("initial"     "initial spell check")
                           ("incremental" "spell check")
                           (_             "spell check"))))
      (when lsp-ltex-plus-debug
        (lsp-ltex-plus--log "%s → publishDiagnostics: %d ms (buffer: %s)"
                            (if (equal label "initial")
                                "didOpen"
                              "didChange")
                            elapsed (buffer-name buf)))
      (let ((message-log-max nil))
        (message "Completed %s in %d ms." phrase elapsed))
      (remhash workspace lsp-ltex-plus--pending-measurements))))

;;;; -- Lsp-mode Registration --------------------------------------------------

(defun lsp-ltex-plus--setup ()
  "Initialize and register the ltex-ls-plus client with `lsp-mode'."
  (setq lsp-ltex-plus--start-time (current-time))
  (lsp-ltex-plus--log "Initializing lsp-ltex-plus...")

  ;; Register all our modes into lsp-mode's global language-ID table so that
  ;; `lsp-buffer-language' returns a value for them and no "Unable to
  ;; calculate the languageId" warning is emitted.  We only add entries that
  ;; are not already present; lsp-mode's built-in defaults take precedence.
  (dolist (entry lsp-ltex-plus-major-modes)
    (let ((mode    (car entry))
          (lang-id (cadr entry)))
      (unless (assq mode lsp-language-id-configuration)
        (push (cons mode lang-id) lsp-language-id-configuration))))

  (when lsp-ltex-plus-apply-kind-first-patch
    (when (lsp-ltex-plus--maybe-upstream-fixes-present-p)
      (lsp-ltex-plus--log
       (concat "`lsp-ltex-plus-apply-kind-first-patch' looks deprecated: "
               "the underlying `lsp-mode' bugs appear to be fixed upstream "
               "(PRs #5055, #5056, #5057, #5059) in your installed "
               "`lsp-mode'. The patch will still be applied since you opted "
               "in, but you can likely remove this option from your config; "
               "it defaults to nil. If you believe the patch is still "
               "needed, please open an issue at "
               "https://github.com/ltex-plus/emacs-ltex-plus.")))
    (lsp-ltex-plus--apply-lsp-mode-patch))

  ;; Progress-silencing advice — only installed when the user has opted
  ;; in to hiding ltex-ls-plus progress updates by setting
  ;; `lsp-ltex-plus-show-progress' to nil.  Flipping the flag mid-session
  ;; does not install or remove the advice retroactively; re-evaluate the
  ;; form below (or call `lsp-ltex-plus--setup' again) to change state.
  ;; The advice body additionally re-checks the flag, so a mid-session
  ;; toggle back to t already-installed-advice correctly falls through to
  ;; the original modeline handler.
  (unless lsp-ltex-plus-show-progress
    (advice-add 'lsp-on-progress-modeline :around
                #'lsp-ltex-plus--suppress-progress))

  ;; Apply sticky debug defaults.  Must run before the benchmark advice install
  ;; below, because enabling debug mode here implicitly turns on
  ;; `lsp-ltex-plus-show-latency' — the sole gate for the benchmark advice
  ;; install — so a debug-only user still gets latency readings.
  (when lsp-ltex-plus-debug
    (setq lsp-log-io t)
    (setq lsp-ltex-plus-show-latency t)
    (when (string= lsp-ltex-plus-trace-server "off")
      ;; We already record the raw JSON-RPC exchange to
      ;; `lsp-ltex-plus-server-input-log' and `lsp-ltex-plus-server-output-log',
      ;; therefore
      ;; setting "verbose" here would be too noisy for essentially no gain.  We
      ;; choose messages for pretty-print, which is especially useful for large
      ;; payloads.
      (setq lsp-ltex-plus-trace-server "messages")))

  ;; Latency benchmark advice — only installed if the user asked for it at
  ;; startup (directly via `lsp-ltex-plus-show-latency', or indirectly by
  ;; enabling `lsp-ltex-plus-debug' above).  Flipping the flag mid-session does
  ;; not install the advice retroactively; see the Latency Benchmarking section
  ;; comment for why we prefer not to keep this advice around when nobody is
  ;; measuring.
  (when lsp-ltex-plus-show-latency
    (advice-add 'lsp-notify :around
                #'lsp-ltex-plus--benchmark-outgoing)
    (advice-add 'lsp--on-diagnostics :after
                #'lsp-ltex-plus--benchmark-diagnostics))

  ;; TODO(2027-05): Remove this migration block (see
  ;; `lsp-ltex-plus--migrate-extensionless-file').
  (dolist (pair `((,lsp-ltex-plus-dictionary-file
                   . ,(expand-file-name "lsp-ltex-plus/stored-dictionary.eld" user-emacs-directory))
                  (,lsp-ltex-plus-enabled-rules-file
                   . ,(expand-file-name "lsp-ltex-plus/enabled-rules.eld" user-emacs-directory))
                  (,lsp-ltex-plus-disabled-rules-file
                   . ,(expand-file-name "lsp-ltex-plus/disabled-rules.eld" user-emacs-directory))
                  (,lsp-ltex-plus-hidden-false-positives-file
                   . ,(expand-file-name "lsp-ltex-plus/hidden-false-positives.eld" user-emacs-directory))))
    (lsp-ltex-plus--migrate-extensionless-file (car pair) (cdr pair)))

  (lsp-ltex-plus--load-external-settings)

  (lsp-ltex-plus--log "Registering settings and client...")
  (lsp-ltex-plus--log "Registering ltex-ls-plus client (priority: -1)...")
  ;; Object- and boolean-typed fields are wrapped via the
  ;; `--obj-or-empty' / `--bool' helpers so `nil' serializes as `{}' or
  ;; `false' rather than `null' (which would violate the JSON schema).
  (lsp-register-custom-settings
   `(("ltex.enabled"                             ,(lambda () (vconcat (lsp-ltex-plus--enabled-languages))))
     ("ltex.language"                            lsp-ltex-plus-language)
     ("ltex.dictionary"                          ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--dictionary-merged)))
     ("ltex.enabledRules"                        ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--enabled-rules-merged)))
     ("ltex.disabledRules"                       ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--disabled-rules-merged)))
     ("ltex.hiddenFalsePositives"                ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus--hidden-false-positives-merged)))
     ("ltex.bibtex.fields"                       ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus-bibtex-fields)))
     ("ltex.latex.commands"                      ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus-latex-commands)))
     ("ltex.latex.environments"                  ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus-latex-environments)))
     ("ltex.markdown.nodes"                      ,(lambda () (lsp-ltex-plus--obj-or-empty lsp-ltex-plus-markdown-nodes)))
     ("ltex.additionalRules.enablePickyRules"    ,(lambda () (lsp-ltex-plus--bool lsp-ltex-plus-additional-rules-enable-picky-rules)))
     ("ltex.additionalRules.motherTongue"        ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-additional-rules-mother-tongue)))
     ("ltex.additionalRules.languageModel"       ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-additional-rules-language-model)))
     ("ltex.languageToolHttpServerUri"           ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-lt-server-uri)))
     ("ltex.languageToolOrg.username"            ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-lt-username)))
     ("ltex.ltex-ls.languageToolOrgApiKey"       ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-lt-api-key)))
     ("ltex.ltex-ls.path"                        ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-ltex-ls-path)))
     ("ltex.ltex-ls.logLevel"                    lsp-ltex-plus-ltex-ls-log-level)
     ("ltex.java.path"                           ,(lambda () (lsp-ltex-plus--str lsp-ltex-plus-java-path)))
     ("ltex.java.initialHeapSize"                lsp-ltex-plus-java-initial-heap)
     ("ltex.java.maximumHeapSize"                lsp-ltex-plus-java-max-heap)
     ("ltex.sentenceCacheSize"                   lsp-ltex-plus-sentence-cache-size)
     ("ltex.maxRequestSize"                      lsp-ltex-plus-max-request-size)
     ("ltex.paragraphCacheTtlMinutes"            lsp-ltex-plus-paragraph-cache-ttl-minutes)
     ("ltex.paragraphCacheEnabled"               ,(lambda () (lsp-ltex-plus--bool lsp-ltex-plus-paragraph-cache-enabled)))
     ("ltex.completionEnabled"                   ,(lambda () (lsp-ltex-plus--bool lsp-ltex-plus-completion-enabled)))
     ("ltex.diagnosticSeverity"                  lsp-ltex-plus-diagnostic-severity)
     ("ltex.checkFrequency"                      lsp-ltex-plus-check-frequency)
     ("ltex.clearDiagnosticsWhenClosingFile"     ,(lambda () (lsp-ltex-plus--bool lsp-ltex-plus-clear-diagnostics-when-closing-file)))
     ("ltex.trace.server"                        lsp-ltex-plus-trace-server)))

  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     (lambda ()
                       (if (and lsp-ltex-plus-debug (executable-find "tee"))
                           (list "sh" "-c"
                                 (format "tee %s | %s | tee %s"
                                         (shell-quote-argument lsp-ltex-plus-server-input-log)
                                         (shell-quote-argument lsp-ltex-plus-ls-plus-executable)
                                         (shell-quote-argument lsp-ltex-plus-server-output-log)))
                         (list lsp-ltex-plus-ls-plus-executable))))
    ;; `lsp-ltex-plus-mode' is the sole gate: if the minor mode is on,
    ;; the user (or a permitted hook) has decided this buffer should be
    ;; checked.  The programming-language guard lives in the mode body,
    ;; not here, so that explicit interactive calls always succeed.
    :activation-fn (lambda (_file-name _mode)
                     lsp-ltex-plus-mode)
    :language-id (lambda (buf)
                   (cadr (assq (buffer-local-value 'major-mode buf)
                               lsp-ltex-plus-major-modes)))
    :server-id 'ltex-ls-plus
    ;; :add-on? t tells lsp-mode to start this client alongside any already-
    ;; selected primary server (e.g. pyright, texlab) rather than competing
    ;; with it by priority.  Without this flag, lsp-mode would pick only the
    ;; highest-priority client and never start ltex-ls-plus when another server
    ;; is present.  :priority -1 is kept as a safeguard so that if, for some
    ;; reason, ltex-ls-plus ends up in a priority contest, it will never
    ;; "hijack" primary LSP features (Go to Definition, Completion, etc.).
    :add-on? t
    :priority -1
    ;; `:multi-root' is latched at registration time (when this
    ;; `lsp-register-client' call fires).  Changing `lsp-ltex-plus-multi-root'
    ;; after that has no effect until Emacs restarts.
    :multi-root lsp-ltex-plus-multi-root
    :initialized-fn (lambda (workspace)
                      ;; Always call unconditionally: the function is
                      ;; self-guarding (it only mutates a `nil'
                      ;; `:completionProvider' slot), so on a recent
                      ;; `lsp-mode' where PR #5059 already preserves the
                      ;; empty-object capability it is a harmless no-op.
                      ;; Gating it on `--maybe-upstream-fixes-present-p'
                      ;; would risk silently dropping the workaround on a
                      ;; future `lsp-mode' where the marker happens to
                      ;; exist but the fix has regressed or moved.
                      (lsp-ltex-plus--restore-completion-capability workspace)
                      (lsp-ltex-plus--capture-server-info workspace)
                      (lsp-ltex-plus--log "Server initialized; pushing configuration...")
                      ;; Object- and boolean-typed fields go through the
                      ;; `--obj-or-empty' / `--bool' helpers so `nil' serializes
                      ;; as `{}' or `false' instead of `null'.
                      (lsp-notify "workspace/didChangeConfiguration"
                                  `(:settings (:ltex (:enabled ,(vconcat (lsp-ltex-plus--enabled-languages))
                                                               :language ,lsp-ltex-plus-language
                                                               :dictionary ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus--dictionary-merged)
                                                               :enabledRules ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus--enabled-rules-merged)
                                                               :disabledRules ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus--disabled-rules-merged)
                                                               :hiddenFalsePositives ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus--hidden-false-positives-merged)
                                                               :bibtex (:fields ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus-bibtex-fields))
                                                               :latex (:commands ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus-latex-commands)
                                                                                 :environments ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus-latex-environments))
                                                               :markdown (:nodes ,(lsp-ltex-plus--obj-or-empty lsp-ltex-plus-markdown-nodes))
                                                               :additionalRules (:enablePickyRules ,(lsp-ltex-plus--bool lsp-ltex-plus-additional-rules-enable-picky-rules)
                                                                                                   :motherTongue ,(lsp-ltex-plus--str lsp-ltex-plus-additional-rules-mother-tongue)
                                                                                                   :languageModel ,(lsp-ltex-plus--str lsp-ltex-plus-additional-rules-language-model))
                                                               :languageToolHttpServerUri ,(lsp-ltex-plus--str lsp-ltex-plus-lt-server-uri)
                                                               :languageToolOrg (:username ,(lsp-ltex-plus--str lsp-ltex-plus-lt-username))
                                                               :ltex-ls (:languageToolOrgApiKey ,(lsp-ltex-plus--str lsp-ltex-plus-lt-api-key)
                                                                                                :path ,(lsp-ltex-plus--str lsp-ltex-plus-ltex-ls-path)
                                                                                                :logLevel ,lsp-ltex-plus-ltex-ls-log-level)
                                                               :java (:path ,(lsp-ltex-plus--str lsp-ltex-plus-java-path)
                                                                            :initialHeapSize ,lsp-ltex-plus-java-initial-heap
                                                                            :maximumHeapSize ,lsp-ltex-plus-java-max-heap)
                                                               :sentenceCacheSize ,lsp-ltex-plus-sentence-cache-size
                                                               :maxRequestSize ,lsp-ltex-plus-max-request-size
                                                               :paragraphCacheTtlMinutes ,lsp-ltex-plus-paragraph-cache-ttl-minutes
                                                               :paragraphCacheEnabled ,(lsp-ltex-plus--bool lsp-ltex-plus-paragraph-cache-enabled)
                                                               :completionEnabled ,(lsp-ltex-plus--bool lsp-ltex-plus-completion-enabled)
                                                               :diagnosticSeverity ,lsp-ltex-plus-diagnostic-severity
                                                               :checkFrequency ,lsp-ltex-plus-check-frequency
                                                               :clearDiagnosticsWhenClosingFile ,(lsp-ltex-plus--bool lsp-ltex-plus-clear-diagnostics-when-closing-file)
                                                               :trace (:server ,lsp-ltex-plus-trace-server))))))
    :action-handlers
    (lsp-ht ("_ltex.addToDictionary"     #'lsp-ltex-plus--action-add-to-dictionary)
            ("_ltex.disableRules"        #'lsp-ltex-plus--action-disable-rules)
            ("_ltex.hideFalsePositives"  #'lsp-ltex-plus--action-hide-false-positives))
    ;; Advertise the custom capability so ltex-ls-plus issues per-document
    ;; configuration pulls on every check.
    ;;
    ;; ltex-ls-plus gates BOTH the standard `workspace/configuration' request
    ;; and the LTEX-specific `ltex/workspaceSpecificConfiguration' request on
    ;; this single capability advertisement.  Without it, the server skips
    ;; both pulls and falls back to whatever state was last pushed via
    ;; `workspace/didChangeConfiguration' in `:initialized-fn' — sufficient for
    ;; the initial `textDocument/didOpen' check, but subsqequent edits produce no
    ;; fresh diagnostics because the server cannot retrieve the per-language
    ;; dictionaries / disabled rules / etc. that it needs to re-check the
    ;; document.
    ;;
    ;; See `lsp-ltex-plus--request-workspace-specific-configuration' below for
    ;; the handler that answers the custom request.  `workspace/configuration'
    ;; is answered automatically by lsp-mode from the data registered above via
    ;; `lsp-register-custom-settings'.
    ;;
    ;; This custom capability mirrors VS Code's `vscode-ltex-plus' extension,
    ;; specifically its
    ;; `initializationOptions.customCapabilities.workspaceSpecificConfiguration'
    ;; declaration (see `extension.ts' in `vscode-ltex-plus').
    :initialization-options
    (lambda ()
      '(:customCapabilities (:workspaceSpecificConfiguration t)))
    :request-handlers
    (lsp-ht ("ltex/workspaceSpecificConfiguration"
             #'lsp-ltex-plus--request-workspace-specific-configuration))))
  (lsp-ltex-plus--log "lsp-ltex-plus--setup completed."))

;;;; -- Activation -------------------------------------------------------------

(defun lsp-ltex-plus--make-fileless-uri ()
  "Return a fresh, unique synthetic file:// URI for a file-less buffer.
For convenience, the path of the synthetic file is placed under the
temporary directory that is defined by the variable
`temporary-file-directory'.  The synthetic file is never read or
written, only used as the document's identity, so any existing local
directory works and the temp dir avoids creating one of our own.  The
basename embeds the Emacs PID and a monotonic counter so distinct
file-less buffers map to distinct documents inside the one shared
workspace.  The buffer name is deliberately NOT used: it can be renamed,
uniquified (\"foo<2>\"), or collide.  The \".txt\" suffix only keeps the
synthetic path well-formed — the wire language ID still comes from the
`:language-id' lambda in `lsp-register-client'."
  ;; Plain `setq'/`1+' rather than `cl-incf': `cl-incf' is deprecated in
  ;; favour of the built-in `incf' added in Emacs 31.1, but `incf' does not
  ;; exist on our 27.1 floor, so neither macro is portable here.
  (lsp--path-to-uri
   (expand-file-name (format "lsp-ltex-plus-scratch-%d-%d.txt"
                             (emacs-pid)
                             (setq lsp-ltex-plus--fileless-counter
                                   (1+ lsp-ltex-plus--fileless-counter)))
                     temporary-file-directory)))

(defun lsp-ltex-plus--setup-fileless-buffer ()
  "Give the current file-less buffer a synthetic identity for `lsp-mode'.
Sets the buffer-local URI override, a whole-buffer pass-through
`lsp--virtual-buffer' plist (so `lsp-mode' has a complete buffer identity
and diagnostics route back here), and disables auto-touch so no file is
written.  Idempotent: reuses an already-assigned URI.

The plist is a \"pass-through\": `lsp-mode' addresses non-file buffers
through `lsp--virtual-buffer' rather than the variable `buffer-file-name',
so once it is set, `lsp-current-buffer' returns the plist and every
dereference — `lsp-with-current-buffer', `lsp-buffer-live-p', diagnostics
keying — goes through it.  A partial plist therefore breaks document
open/close; we must supply every key `lsp-mode' reads.  Region-mapping
keys such as `:real->virtual-line' and `:line/character->point' are
omitted on purpose — `lsp-virtual-buffer-call' returns nil for them, so
positions map straight through to the real buffer, which is exactly right
for a whole buffer (as opposed to an embedded source block).  The
`:workspaces' entry is filled in by the caller once the workspace is
attached."
  (let* ((buf (current-buffer))
         (uri (or lsp-ltex-plus--fileless-uri
                  (setq lsp-ltex-plus--fileless-uri
                        (lsp-ltex-plus--make-fileless-uri))))
         ;; KEY must equal the storage key computed in `lsp--on-diagnostics'
         ;; (`(lsp--fix-path-casing (lsp--uri-to-path uri))').  We never
         ;; register URI in `lsp--virtual-buffer-mappings', so `lsp--uri-to-path'
         ;; round-trips it unchanged both here and there, and
         ;; `lsp--get-buffer-diagnostics' (which prefers the virtual-buffer
         ;; `:buffer-file-name') finds our overlays under the same KEY.
         (key (lsp--fix-path-casing (lsp--uri-to-path uri))))
    (setq-local lsp-buffer-uri uri)
    (setq-local
     lsp--virtual-buffer
     (list :buffer buf
           :buffer-uri uri
           :buffer-file-name key
           :major-mode major-mode
           :workspaces nil
           :in-range (lambda (&optional _point) t)
           :goto-buffer (lambda () nil)
           :with-current-buffer (lambda (fn) (with-current-buffer buf (funcall fn)))
           :buffer-live? (lambda (_) (buffer-live-p buf))
           :buffer-name (lambda (_) (buffer-name buf))))
    (setq-local lsp-auto-touch-files nil)
    ;; Standalone-buffer ergonomics, mirroring what file buffers get.
    (setq-local lsp-auto-guess-root t)
    (setq-local lsp-enable-file-watchers nil)
    lsp--virtual-buffer))

(defun lsp-ltex-plus--fileless-on-save ()
  "Drop a file-less buffer's synthetic identity once it is saved to a file.
Added buffer-locally to `after-set-visited-file-name-hook' when the
file-less path activates, and prepended so it runs before `lsp-mode's own
`lsp--after-set-visited-file-name' handler (installed by `lsp-managed-mode').

When the buffer gains a real file name, this closes the synthetic document
in the shared workspace and clears the buffer-local overrides — but does
NOT reconnect.  `lsp-mode's handler runs next and does `(lsp-disconnect)'
followed by `(lsp)', which reattaches the buffer under its real-file URI.
Doing the close/clear here (while `lsp-buffer-uri' still points at the
synthetic URI) is what lets that handoff be clean: it sends the synthetic
`didClose' before the override is gone, so the server doesn't leak the
synthetic document."
  (when (and lsp-ltex-plus--fileless-uri (buffer-file-name))
    ;; Close the synthetic document and detach from the shared workspace,
    ;; while the synthetic URI is still the buffer's identity.
    (when (bound-and-true-p lsp--buffer-workspaces)
      (let ((ltex-ws (seq-find
                      (lambda (ws)
                        (eq 'ltex-ls-plus (lsp--workspace-server-id ws)))
                      lsp--buffer-workspaces)))
        (when ltex-ws
          (with-lsp-workspace ltex-ws
            (cl-callf2 delq (lsp-current-buffer)
                       (lsp--workspace-buffers ltex-ws))
            (with-demoted-errors
                "[lsp-ltex-plus] Error closing synthetic document: %S"
              (lsp-notify "textDocument/didClose"
                          `(:textDocument ,(lsp--text-document-identifier)))))
          (setq lsp--buffer-workspaces
                (delete ltex-ws lsp--buffer-workspaces)))))
    ;; Clear the synthetic overrides so lsp-mode's reconnect sees the real
    ;; file URI rather than the synthetic one.
    (kill-local-variable 'lsp-buffer-uri)
    (kill-local-variable 'lsp-auto-touch-files)
    (setq-local lsp--virtual-buffer nil)
    (setq lsp-ltex-plus--fileless-uri nil)
    ;; Our work is done; remove ourselves so a later `set-visited-file-name'
    ;; on the now file-backed buffer is a no-op here.  `lsp-mode's
    ;; `lsp--after-set-visited-file-name' (next on the hook) handles the
    ;; disconnect + reconnect under the real file.
    (remove-hook 'after-set-visited-file-name-hook
                 #'lsp-ltex-plus--fileless-on-save t)))

(defun lsp-ltex-plus--rejoin-workspace (&optional explicit-root)
  "Attach the current buffer to the ltex-ls-plus workspace only.
Used when `lsp-ltex-plus-mode' activates in a buffer where `lsp-mode'
is already running for another client (e.g. pyright, texlab).  A plain
`(lsp)' would re-send `textDocument/didOpen' to every matching client,
producing a \"redundant open text document\" warning from co-tenants.

With EXPLICIT-ROOT non-nil, use it as the project root instead of
deriving one from the variable `buffer-file-name'.  This is how
file-less buffers attach: they all pass the variable
`temporary-file-directory' as the shared root, so one server process
serves them while their distinct synthetic URIs keep them as separate
documents.

If an ltex-ls-plus workspace already exists for the project root, the
buffer is opened in it.  Otherwise, a new ltex-ls-plus connection is
started for the root."
  (let* ((session (lsp-session))
         (client (gethash 'ltex-ls-plus lsp-clients))
         (project-root (or explicit-root
                           (when-let* ((buf-file (buffer-file-name))
                                       (root (lsp--calculate-root session buf-file)))
                             (lsp-f-canonical root))))
         (workspace (and client project-root
                         (seq-find
                          (lambda (ws)
                            (eq 'ltex-ls-plus (lsp--workspace-server-id ws)))
                          (gethash project-root
                                   (lsp-session-folder->servers session))))))
    (cond
     (workspace
      (lsp--open-in-workspace workspace)
      (cl-pushnew workspace lsp--buffer-workspaces))
     ((and client project-root)
      (let ((new-ws (lsp--start-connection session client project-root)))
        (when new-ws
          (cl-pushnew new-ws lsp--buffer-workspaces))))
     (t
      (lsp--warn "[lsp-ltex-plus] Could not rejoin workspace.")))))

;;;; -- Comint input-region checking ------------------------------------------
;;
;; A comint buffer (shell, REPL, `agent-shell-mode', …) is mostly read-only
;; process/agent output, with a single editable input region at the bottom —
;; everything from the process mark to `point-max'.  We only want to check
;; that input region, never the output and never previously submitted input.
;;
;; The lever is `lsp-mode''s virtual-buffer support, the same mechanism that
;; presents one org-babel source block as an isolated document.  Two of its
;; behaviours give us exactly what we need:
;;
;;   * `lsp--buffer-content' consults the virtual buffer's `:buffer-string'
;;     first, so the document sent over the wire is just the input region.
;;   * `lsp-virtual-buffer-on-change' (installed by `lsp-patch-on-change-event')
;;     only emits a `didChange' when the edit falls inside `:in-range', so
;;     output arriving above the input region produces no check at all.
;;
;; Unlike org's static source blocks, the comint input region moves on every
;; line of output and resets on every submission.  We anchor on the process
;; mark, which comint maintains as a live marker, so the region tracks itself;
;; the only thing left to handle explicitly is clearing diagnostics when the
;; user submits (`lsp-ltex-plus--comint-on-submit').
;;
;; The input shares its line with the prompt (e.g. "OpenCode> "), which is not
;; editable and must not be checked, yet flycheck positions diagnostics by
;; column from the line beginning.  So the first document line is left-padded
;; with spaces equal to the prompt width (see
;; `lsp-ltex-plus--comint-input-prompt-width'): the checker ignores the
;; leading spaces, but the columns it reports then line up with the real
;; buffer columns, prompt included.

(defun lsp-ltex-plus--comint-input-start ()
  "Return the buffer position where the active comint input region begins.
This is the process mark — the boundary between read-only output/history
above and the editable input the user is currently typing below.  Falls
back to the end of the last prompt, then to `point-max', when no live
process mark is available."
  (let ((proc (get-buffer-process (current-buffer))))
    (cond
     ((and proc (marker-position (process-mark proc)))
      (marker-position (process-mark proc)))
     ((and (boundp 'comint-last-prompt) comint-last-prompt)
      (cdr comint-last-prompt))
     (t (point-max)))))

(defun lsp-ltex-plus--comint-input-prompt-width ()
  "Return the column width of the prompt preceding the active input.
The input shares its line with the prompt (e.g. \"OpenCode> \"), so this is
the number of characters between the true beginning of the input line and
the input start.  `inhibit-field-text-motion' is bound so the line motion
crosses the comint prompt field instead of stopping at its boundary.

The first line of the checked document is padded with this many spaces (see
`lsp-ltex-plus--setup-comint-buffer'), so the column coordinates the server
reports line up with the real buffer columns even though the prompt itself
is never sent for checking."
  (let ((start (lsp-ltex-plus--comint-input-start))
        (inhibit-field-text-motion t))
    (save-excursion
      (goto-char start)
      (- start (line-beginning-position)))))

(defun lsp-ltex-plus--setup-comint-buffer ()
  "Give the current comint buffer a region-restricted synthetic identity.
Like `lsp-ltex-plus--setup-fileless-buffer' this assigns a synthetic
file:// URI and disables auto-touch (comint buffers have no backing file),
but the `lsp--virtual-buffer' plist carries the region-mapping keys that
the whole-buffer file-less path deliberately omits.  Those keys are all
computed from `lsp-ltex-plus--comint-input-start' (the live process mark),
so the mapped document is the editable input region and it tracks the
region as output scrolls it down the buffer.

Also installs `lsp-patch-on-change-event' on the buffer-local
`lsp-after-open-hook'.  The hook runs after `lsp--text-document-did-open'
has enabled `lsp-managed-mode' (which adds the ordinary `lsp-on-change'),
so the swap to the range-aware change handlers survives both the
synchronous (workspace already initialized) and the asynchronous (first
connection) open paths.  Returns the plist."
  (let* ((buf (current-buffer))
         (uri (or lsp-ltex-plus--fileless-uri
                  (setq lsp-ltex-plus--fileless-uri
                        (lsp-ltex-plus--make-fileless-uri))))
         ;; Same KEY reasoning as the file-less path: it must equal the
         ;; storage key computed in `lsp--on-diagnostics' so overlays route
         ;; back to this buffer.  The URI is never registered in
         ;; `lsp--virtual-buffer-mappings', so `lsp--uri-to-path' round-trips
         ;; it unchanged here and there.
         (key (lsp--fix-path-casing (lsp--uri-to-path uri))))
    (setq-local lsp-buffer-uri uri)
    (setq-local
     lsp--virtual-buffer
     (list
      :buffer buf
      :buffer-uri uri
      :buffer-file-name key
      :major-mode major-mode
      :workspaces nil
      :with-current-buffer (lambda (fn) (with-current-buffer buf (funcall fn)))
      :buffer-live? (lambda (_) (buffer-live-p buf))
      :buffer-name (lambda (_) (buffer-name buf))
      ;; A point is "in" the document when it is at or after the input start.
      :in-range (lambda (&optional point)
                  (>= (or point (point))
                      (lsp-ltex-plus--comint-input-start)))
      :goto-buffer (lambda () (goto-char (lsp-ltex-plus--comint-input-start)))
      ;; The document content: the editable input region only, with the
      ;; first line left-padded by the prompt width so column coordinates
      ;; align with the real buffer (the prompt shares the input's line but
      ;; is not itself checked — the pad is plain spaces the checker ignores).
      :buffer-string (lambda ()
                       (concat
                        (make-string (lsp-ltex-plus--comint-input-prompt-width)
                                     ?\s)
                        (buffer-substring-no-properties
                         (lsp-ltex-plus--comint-input-start)
                         (point-max))))
      :last-point (lambda () (point-max))
      ;; Real point -> document position (line/character within the region).
      ;; The character offset is measured from the true line beginning so on
      ;; the first line it includes the prompt width, matching the padded
      ;; document `:buffer-string' produces.
      :cur-position
      (lambda ()
        (let ((inhibit-field-text-motion t))
          (lsp-save-restriction-and-excursion
            (let ((start (lsp-ltex-plus--comint-input-start)))
              (list :line (max 0 (- (lsp--cur-line) (lsp--cur-line start)))
                    :character (max 0 (- (point) (line-beginning-position))))))))
      ;; Document position -> real point.  Anchored on the true beginning of
      ;; the input line (crossing the prompt field) rather than the input
      ;; start, since the document's first-line columns include the prompt pad.
      :line/character->point
      (lambda (line character)
        (let ((inhibit-field-text-motion t))
          (lsp-save-restriction-and-excursion
            (goto-char (lsp-ltex-plus--comint-input-start))
            (beginning-of-line)
            (forward-line line)
            (let ((line-end (line-end-position)))
              (if (> character (- line-end (point)))
                  line-end
                (forward-char character)
                (point))))))
      :real->virtual-line (lambda (line)
                            (+ line
                               (line-number-at-pos
                                (lsp-ltex-plus--comint-input-start))
                               -1))
      ;; Identity: the prompt offset lives in the padded document content
      ;; (see `:buffer-string'), so columns need no further adjustment here.
      :real->virtual-char (lambda (char) char)))
    (setq-local lsp-auto-touch-files nil)
    (setq-local lsp-auto-guess-root t)
    (setq-local lsp-enable-file-watchers nil)
    (add-hook 'lsp-after-open-hook #'lsp-patch-on-change-event nil t)
    lsp--virtual-buffer))

(defun lsp-ltex-plus--comint-resync ()
  "Re-send the current comint input region to LTEX+.
After a submission the editable region empties and the process mark jumps
below the freshly inserted output; because that change is out of range no
`didChange' fires on its own, so previously published diagnostics would
linger on the submitted (now read-only) text.  Pushing a full-document
change carrying the current — empty — input region makes the server
republish diagnostics for the synthetic URI and clears those overlays."
  (when (and lsp-ltex-plus--comint-active lsp--virtual-buffer)
    (with-demoted-errors "[lsp-ltex-plus] comint resync error: %S"
      (lsp-with-current-buffer lsp--virtual-buffer
        ;; Under full document sync `lsp-on-change' ignores the position
        ;; arguments and sends `(lsp--buffer-content)' = the input region.
        (let ((p (point)))
          (lsp-on-change p p 0))))))

(defun lsp-ltex-plus--comint-on-submit (_input)
  "Re-sync after the user submits input in a comint buffer.
Added to `comint-input-filter-functions'.  Deferred to a zero-delay timer
so comint has finished moving the process mark and inserting the echoed
input before we recompute the (now empty) input region."
  (when lsp-ltex-plus--comint-active
    (let ((buf (current-buffer)))
      (run-with-timer 0 nil
                      (lambda ()
                        (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (lsp-ltex-plus--comint-resync))))))))

(defun lsp-ltex-plus--comint-teardown ()
  "Detach comint input-region checking from the current buffer.
Idempotent.  Removes the submit hook and drops this buffer's virtual
buffer from `lsp--virtual-buffer-connections'.  Server tear-down and
diagnostic clean-up are handled by the shared deactivation path in
`lsp-ltex-plus-mode' (or, on buffer kill, by `lsp-managed-mode')."
  (when lsp-ltex-plus--comint-active
    (setq lsp-ltex-plus--comint-active nil)
    (remove-hook 'comint-input-filter-functions
                 #'lsp-ltex-plus--comint-on-submit t)
    (when (bound-and-true-p lsp--virtual-buffer)
      (setq lsp--virtual-buffer-connections
            (delq lsp--virtual-buffer lsp--virtual-buffer-connections)))))

;;;###autoload
(define-minor-mode lsp-ltex-plus-mode
  "Minor mode for LTEX+ grammar checking via `lsp-mode'.

When enabled, this mode starts the ltex-ls-plus server for the current
buffer.  Run `lsp-ltex-plus-mode-hook' to apply any per-buffer tweaks.

If the current major mode is not in `lsp-ltex-plus-major-modes', it is
registered automatically before the server starts.  When called
interactively the language identifier is requested from the user (default:
\"plaintext\"); when called from a hook or from Lisp, \"plaintext\" is used
silently."
  :lighter " LTeX+"
  :group 'lsp-ltex-plus
  (if lsp-ltex-plus-mode
      (let* ((entry (assq major-mode lsp-ltex-plus-major-modes))
             (programming-p (and entry (nth 2 entry)))
             (comint-p (and (not (buffer-file-name))
                            (derived-mode-p 'comint-mode)
                            (get-buffer-process (current-buffer))
                            lsp-ltex-plus-check-comint-input))
             (fileless-p (and (not (buffer-file-name))
                              (not comint-p)
                              lsp-ltex-plus-check-fileless-buffers)))
        (if (and programming-p
                 (not lsp-ltex-plus-check-programming-languages)
                 (not (called-interactively-p 'any)))
            ;; Hook-driven activation for a programming-language mode with
            ;; checking disabled: silently bail out.  Explicit interactive
            ;; calls always proceed so the user can run an on-demand check.
            (setq lsp-ltex-plus-mode nil)
          ;; Register the current major mode if it is not yet known to the client.
          ;; Two tables must be updated:
          ;;   1. `lsp-ltex-plus-major-modes' — our own registry, read by the
          ;;      :activation-fn and :language-id lambda in lsp-register-client.
          ;;      This controls which buffers the client accepts and what language
          ;;      ID is sent in textDocument/didOpen.
          ;;   2. `lsp-language-id-configuration' — lsp-mode's own lookup table,
          ;;      used solely by `lsp-buffer-language' for bookkeeping and to
          ;;      suppress an "Unable to calculate the languageId" warning.  It
          ;;      does NOT affect the language ID sent over the wire (our
          ;;      :language-id lambda handles that).  Modes already in lsp-mode's
          ;;      built-in defaults (markdown, org, latex, …) need no entry here;
          ;;      any mode absent from those defaults must be added to silence the
          ;;      warning.
          (unless entry
            (let ((lang-id (if (called-interactively-p 'any)
                               (read-string
                                (format "Language ID for %s (RET for \"plaintext\"): "
                                        major-mode)
                                nil nil "plaintext")
                             "plaintext")))
              ;; New entries added interactively are treated as markup (nil),
              ;; since unknown modes are typically plain-text writing contexts.
              (push (list major-mode lang-id nil) lsp-ltex-plus-major-modes)
              ;; lsp-language-id-configuration uses plain cons pairs.
              (push (cons major-mode lang-id) lsp-language-id-configuration)))
          (if (not (executable-find lsp-ltex-plus-ls-plus-executable))
              (progn
                (message
                 (concat "[lsp-ltex-plus] Aborting: %s not found on PATH.  "
                         "See installation instructions at "
                         "https://github.com/ltex-plus/emacs-ltex-plus/#server-installation "
                         "or set `lsp-ltex-plus-ls-plus-executable' to the absolute path of the binary.")
                 lsp-ltex-plus-ls-plus-executable)
                (setq lsp-ltex-plus-mode nil))
            (lsp-ltex-plus--log "Enabling LTEX+ in %s" (buffer-name))
            (cond
             ;; lsp-mode not yet loaded — defensive, deferred startup.
             ((not (fboundp 'lsp))
              (if (not (or fileless-p comint-p))
                  ;; If dealing with a real file, we invoke lsp-deferred
                  ;; that defers server startup until the buffer is visible
                  (progn
                    (lsp-ltex-plus--log "Activation path: lsp-deferred (lsp-mode not loaded)")
                    (lsp-deferred))
                ;; If dealing with a file-less buffer, invoking `lsp-deferred'
                ;; has no effect.  A file-less buffer can't be deferred because
                ;; `lsp-deferred' just schedules `(lsp)' for when the buffer is
                ;; visible, and `(lsp)' does nothing without a
                ;; `buffer-file-name'.  So, we just log and bail.
                (lsp-ltex-plus--log
                 "lsp-mode not loaded; cannot start file-less buffer yet")))
             ;; A comint buffer attaches like a file-less buffer (shared
             ;; scratch workspace, synthetic URI), but its virtual buffer
             ;; restricts the checked document to the active input region.
             ;; Handled before `fileless-p' (a comint buffer is also
             ;; file-less) and before the `lsp-mode'-active clause.
             (comint-p
              (lsp-ltex-plus--log "Activation path: comint input-region startup")
              (lsp-ltex-plus--setup-comint-buffer)
              ;; Same `buffer-file-name' binding rationale as the file-less
              ;; branch: `lsp--start-workspace' calls `file-remote-p' on it.
              (let ((buffer-file-name (lsp--uri-to-path lsp-ltex-plus--fileless-uri)))
                (lsp-ltex-plus--rejoin-workspace
                 (lsp-f-canonical temporary-file-directory)))
              (when lsp--buffer-workspaces
                (setq-local lsp--virtual-buffer
                            (plist-put lsp--virtual-buffer
                                       :workspaces lsp--buffer-workspaces))
                ;; Register the region as a virtual-buffer connection so
                ;; `lsp-virtual-buffer-on-change' can find it by `:in-range'
                ;; and route input-region edits (and only those) to didChange.
                (cl-pushnew lsp--virtual-buffer lsp--virtual-buffer-connections)
                (lsp-mode 1)
                ;; Cover the already-initialized-workspace reuse path, where
                ;; didOpen (and thus the `lsp-after-open-hook' patch) already
                ;; ran synchronously during rejoin; harmless if it runs again.
                (lsp-patch-on-change-event)
                (setq lsp-ltex-plus--comint-active t)
                (add-hook 'comint-input-filter-functions
                          #'lsp-ltex-plus--comint-on-submit nil t)
                (add-hook 'kill-buffer-hook
                          #'lsp-ltex-plus--comint-teardown nil t)))
             ;; A file-less buffer gets a synthetic identity and attaches to
             ;; the shared scratch workspace.  Handled before the
             ;; `lsp-mode'-active clause so a file-less buffer always takes
             ;; this path and never falls through to the generic rejoin, which
             ;; derives its root from `buffer-file-name' (nil here).
             (fileless-p
              (lsp-ltex-plus--log "Activation path: file-less synthetic startup")
              (lsp-ltex-plus--setup-fileless-buffer)
              ;; `lsp--start-workspace' builds the server's `:processId' from
              ;; `(file-remote-p (buffer-file-name))', and `file-remote-p'
              ;; errors on nil — which is what `buffer-file-name' is here.  So
              ;; bind it to the synthetic path (a local, non-remote string)
              ;; just for the start.  The real `didOpen' happens later and
              ;; takes its URI from `lsp-buffer-uri', not from this binding, so
              ;; the buffer stays file-less.
              (let ((buffer-file-name (lsp--uri-to-path lsp-ltex-plus--fileless-uri)))
                (lsp-ltex-plus--rejoin-workspace
                 (lsp-f-canonical temporary-file-directory)))
              (when lsp--buffer-workspaces
                ;; The pass-through virtual buffer needs its `:workspaces' so
                ;; `lsp-with-current-buffer' binds them when lsp-mode addresses
                ;; the buffer by its plist identity (e.g. the post-init open
                ;; loop, diagnostics).
                (setq-local lsp--virtual-buffer
                            (plist-put lsp--virtual-buffer
                                       :workspaces lsp--buffer-workspaces))
                ;; Turn on the lsp-mode minor mode for the lighter/keymap; its
                ;; body no-ops now that `lsp--buffer-workspaces' is populated.
                (lsp-mode 1))
              ;; Switch to real-file mechanics if the buffer is later saved.
              (add-hook 'after-set-visited-file-name-hook
                        #'lsp-ltex-plus--fileless-on-save nil t))
             ;; lsp-mode already active in this buffer (another client,
             ;; e.g. pyright or texlab).  Attach only the ltex-ls-plus workspace
             ;; to avoid a redundant didOpen to the co-tenants.
             ((bound-and-true-p lsp-mode)
              (lsp-ltex-plus--log "Activation path: rejoin-workspace (lsp-mode already active)")
              (lsp-ltex-plus--rejoin-workspace))
             ;; Another caller (e.g., a `python-mode-hook' that calls
             ;; `lsp-deferred') already scheduled `(lsp)' to run when the
             ;; buffer becomes visible.  Skip our own call — piggyback on
             ;; theirs to avoid a second didOpen to the primary server.
             ;; `ltex-ls-plus' is a registered client with `:add-on? t',
             ;; so their `(lsp)' will pick it up automatically.
             ((bound-and-true-p lsp--buffer-deferred)
              (lsp-ltex-plus--log "Activation path: piggyback (lsp-deferred already scheduled)"))
             ;; lsp-mode loaded but not yet active in this buffer —
             ;; full startup.
             (t
              (lsp-ltex-plus--log "Activation path: (lsp) (first startup)")
              (lsp))))))
    ;; Deactivation.  First detach comint input-region wiring (submit hook,
    ;; virtual-buffer connection) if this buffer opted into it; the shared
    ;; server tear-down below still runs.
    (lsp-ltex-plus--comint-teardown)
    ;; Two paths depending on co-tenant state:
    ;;   • Sole client — `lsp-disconnect' cleanly tears down lsp-managed-mode,
    ;;     clears diagnostics, and stops the server.
    ;;   • Co-tenants (e.g., basedpyright, texlab) — `lsp-disconnect' would
    ;;     tear them down too, so we surgically remove only the ltex workspace:
    ;;     detach this buffer from it, send `textDocument/didClose' scoped to
    ;;     the ltex workspace, drop the workspace from `lsp--buffer-workspaces',
    ;;     and clean up diagnostics it published.
    (when (bound-and-true-p lsp--buffer-workspaces)
      (let ((ltex-ws (seq-find
                      (lambda (ws)
                        (eq 'ltex-ls-plus (lsp--workspace-server-id ws)))
                      lsp--buffer-workspaces)))
        (when ltex-ws
          (lsp-ltex-plus--log "Disabling LTEX+ in %s" (buffer-name))
          (if (= 1 (length lsp--buffer-workspaces))
              ;; Sole client.
              (lsp-disconnect)
            ;; Co-tenants remain — selective tear-down.
            (with-lsp-workspace ltex-ws
              (cl-callf2 delq (lsp-current-buffer)
                         (lsp--workspace-buffers ltex-ws))
              (with-demoted-errors
                  "[lsp-ltex-plus] Error in didClose: %S"
                (lsp-notify "textDocument/didClose"
                            `(:textDocument ,(lsp--text-document-identifier)))))
            (setq lsp--buffer-workspaces
                  (delete ltex-ws lsp--buffer-workspaces))
            ;; Clear diagnostics in lsp-mode's model, then force the UI to
            ;; refresh — flycheck/flymake cache overlays independently and
            ;; won't drop ltex squiggles until asked to re-check.
            (lsp-diagnostics--workspace-cleanup ltex-ws)
            (run-hooks 'lsp-diagnostics-updated-hook)
            (when (bound-and-true-p flycheck-mode)
              (flycheck-buffer))
            (when (bound-and-true-p flymake-mode)
              (flymake-start))))))))


;; Initialize the lsp client.  At default settings this registers language IDs,
;; loads persisted dictionaries/rules from disk, and calls
;; `lsp-register-custom-settings' + `lsp-register-client'.  Optional features
;; (protocol patches, progress-silencing advice, debug logging, latency
;; benchmarks) are each gated behind a `defcustom' that defaults to off and
;; execute only when the user opts in.
(lsp-ltex-plus--setup)

(provide 'lsp-ltex-plus)
;;; lsp-ltex-plus.el ends here
