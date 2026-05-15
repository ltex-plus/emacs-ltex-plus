# Emacs LTeX+

<!-- ltex: language=en-GB -->
<!-- ltex: dictionary+=plist -->
<!-- ltex: dictionary+=defcustom -->
<!-- ltex: dictionary+=LTeX+ -->

`lsp-ltex-plus` is a lightweight [lsp-mode](https://github.com/emacs-lsp/lsp-mode) client for **LTeX+**, a powerful grammar and spell checker powered by [LanguageTool](https://languagetool.org/).

*Developed and tested on Emacs 31.1. Requires Emacs 27.1 or later.*

This package allows you to have professional-grade grammar checking in Emacs while you write Markdown, LaTeX, Org-mode, Magit-commit messages, and more — and also checks grammar and spelling inside comments and string literals of 30+ programming languages. It is designed to be an "add-on" server, meaning it runs quietly in the background alongside your existing language servers without interfering with them. With the local backend, checks typically complete fast enough to feel instant while you type — see [Performance](#performance) for measured numbers and a reproducible benchmark.

![LTeX+ in action](screenshot.jpg)
*LTeX+ in action: `C-c l a a` activates the LSP actions, allowing you to choose the suitable correction (e.g., fixing "your" to "you're" in the example above). The key binding can be customized by configuring the `lsp-mode` package.*

For detailed information about the underlying LTeX+ server and its capabilities, please refer to the [official LTeX+ documentation](https://ltex-plus.github.io/ltex-plus/index.html).

## New to Emacs or LSP?

If you use Emacs for writing—perhaps in the humanities, social sciences, or law—rather than for programming, the term "LSP" might be new to you. Here is a simple way to understand how this works:

*   **The LSP Server (LTeX+):** This is a separate program that runs in the background on your computer. It "reads" your document as you type and identifies errors, much like the grammar checkers in Microsoft Word or Google Docs.
*   **The Bridge (lsp-mode):** This is a popular Emacs package that manages the connection between Emacs and these background programs.
*   **The Client (lsp-ltex-plus):** This is the package you are looking at right now. It acts as the specific "translator" that tells Emacs exactly how to interact with the LTeX+ grammar server.

While this technology was originally built for programmers to find "bugs" in their code, we use it here to provide a powerful, professional-grade assistant for your writing.

## Offline Privacy vs. Online Power

LTeX+ can operate in two distinct ways, depending on your needs:

1.  **Fully Offline (Default):** By default (or by setting `lsp-ltex-plus-lt-server-uri` to `nil`), the grammar checker runs entirely on your local machine. No text ever leaves your computer, making it ideal for sensitive work or when you don't have internet access.
2.  **Remote API:** You can connect to a remote LanguageTool server (like `https://api.languagetoolplus.com`) by setting the `lsp-ltex-plus-lt-server-uri` variable. This can offload the processing from your computer.

**Note on Premium Subscriptions:** If you have a paid LanguageTool Premium account, you can provide your credentials via `lsp-ltex-plus-lt-username` and `lsp-ltex-plus-lt-api-key`. While this provides access to some additional rules, many users find that the local/standard experience is already excellent and hard to distinguish from the premium service.

## Features

- **Concurrent Execution:** Works simultaneously with other LSP servers (like `texlab` for LaTeX or `pyright` for Python).
- **Smart Persistence:** Words you "add to dictionary" or rules you disable are automatically saved to your Emacs directory and remembered across sessions.
- **Bi-directional Support:** Handles advanced server requests (like dynamic configuration fetching) safely.
- **Highly Configurable:** Easily switch languages, enable "picky" grammar rules, or connect to a premium LanguageTool account.
- **Wide Language Support:** Pre-configured for Markdown, LaTeX, Org, RestructuredText, HTML, BibTeX, and many others.
- **Programming Language Support:** Optionally checks grammar and spelling in comments of 30+ programming languages (Python, C, C++, Rust, Java, …), running transparently alongside the primary language server thanks to its add-on design. Disabled by default (matching LTeX+), opt-in via `lsp-ltex-plus-check-programming-languages`.
- **Lightweight & Lazy-loading:** Split into a tiny bootstrap file loaded at Emacs startup and a full client loaded on first use of a supported buffer, so startup time is essentially unaffected.
- **Intuitive API:** A deliberately small surface area — one entry point (`lsp-ltex-plus-enable-for-modes`) plus customisation variables under a consistent `lsp-ltex-plus-` prefix, so configuration is discoverable through `customize-group` or tab-completion.

## Performance

`lsp-ltex-plus` is fast. On an Apple M2, grammar checking a full-page Markdown or Org buffer completes in about **70 ms**, and a longer LaTeX document (around 15 KB) in about **150 ms** — both comfortably inside the threshold that feels instantaneous while typing. The package ships with a small built-in benchmark (`lsp-ltex-plus-show-latency`) that echoes the round-trip time to the minibuffer after every check, so you can reproduce these numbers on your own hardware; see [Measuring Server Latency](#measuring-server-latency) for how to enable it.

Two caveats worth stating honestly:

- **What you *see* on screen is slower than what the server reports.** The figures above measure the round-trip from `textDocument/didChange` to `textDocument/publishDiagnostics`. Between `publishDiagnostics` arriving and the squiggly underline appearing in the buffer, Emacs still has to pass the diagnostic through `lsp-mode`'s idle cadence (`lsp-idle-delay`, default 0.5 s), the full-sync debounce, and the Flycheck / Flymake overlay refresh. With stock settings the visible delay can add several hundred milliseconds on top of the server round-trip. The grammar checker is not the bottleneck in an Emacs session — the display pipeline typically is. Normal users, however, would likely find Emacs' default settings quite acceptable when typing or editing texts. 

  For a snappier response, consider lowering `lsp-idle-delay` (default 0.5 s), `flycheck-idle-change-delay` (default 0.5 s), and `lsp-debounce-full-sync-notifications-interval` (default 1.0 s). The last of these races against a secondary flush path in lsp-mode that fires whenever Emacs is about to send any outgoing LSP message — a completion request, a hover, a periodic `textDocument/documentHighlight` fired by `lsp-on-idle-hook` after `lsp-idle-delay` seconds of inactivity, or even traffic from a co-tenant server on the same buffer. Whichever of the two paths fires first drains the queue, so reducing the interval only starts to bite once it drops below typical inter-message times (~`lsp-idle-delay`). If you want the interval to be the sole flush trigger — useful mainly when benchmarking or reasoning about timing — additionally set `(setq lsp-flush-delayed-changes-before-next-message nil)` to temporarily disable the secondary flush path.

  For more advanced performance tuning (such as increasing the garbage collection threshold or switching to plists), see [Slow Server Response / High CPU Usage](#slow-server-response--high-cpu-usage) in the Troubleshooting section.
- **A remote LanguageTool server is noticeably slower.** If you point `lsp-ltex-plus-lt-server-uri` at the hosted service, the round-trip stretches to roughly **1–4 seconds** depending on network conditions and how busy the service is. That is the trade-off for Premium-only rules, but the local backend is likely what the majority of users may want for an interactive writing experience.

## Prerequisites

Before using this package, you need:

1.  **Emacs:** Version **27.1** or later. Tree-sitter major modes (`bash-ts-mode`, `python-ts-mode`, …) are picked up automatically when running on Emacs 29.1+/30.1+; on older Emacs they are silently skipped.
2.  **Emacs lsp-mode:** This package is an extension for `lsp-mode` (version 6.0 or higher). Therefore, `lsp-mode` must be installed and available before `lsp-ltex-plus` can function. We strongly recommend a recent build — see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision) below.
3.  **LTeX+ Language Server:** This is the core engine that performs the grammar checks. See [Server Installation](#server-installation) below.
4.  **Java:** LTeX+ requires **Java 21** or higher. Most platform-specific releases of LTeX+ include a bundled Java runtime, so you don't necessarily need to install it separately. See [Java Runtime Configuration](#3-java-runtime-configuration) for details.

### Recommended `lsp-mode` Revision

Five LSP-protocol bugs that this package historically worked around have since been fixed upstream:

| PR | Fix |
|---|---|
| [#5052](https://github.com/emacs-lsp/lsp-mode/pull/5052) | Treat bare-array `CompletionItem[]` responses as complete completion lists. |
| [#5055](https://github.com/emacs-lsp/lsp-mode/pull/5055) | Classify JSON-RPC messages by `method` before `id` (Kind-First routing) — fixes deadlocks on ID collisions between server and client. |
| [#5056](https://github.com/emacs-lsp/lsp-mode/pull/5056) | Ignore stale callbacks that arrive after a synchronous request has already unwound. |
| [#5057](https://github.com/emacs-lsp/lsp-mode/pull/5057) | Keep dispatching messages in a batch when an earlier one throws or fails framing. |
| [#5059](https://github.com/emacs-lsp/lsp-mode/pull/5059) | Preserve empty-object capabilities (e.g. `completionProvider: {}`) under `lsp-use-plists`. |

All five are present on `lsp-mode` master from commit [`0951bf38`](https://github.com/emacs-lsp/lsp-mode/commit/0951bf38) (2026-05-15) onward. Installing a recent `lsp-mode` and **leaving `lsp-ltex-plus-apply-kind-first-patch` out of your config** (it defaults to `nil`) is the recommended setup. As of today the option `lsp-ltex-plus-apply-kind-first-patch` is therefore **deprecated**: setting it to `t` against a recent `lsp-mode` only duplicates upstream fixes (harmless, just redundant), and the option will be removed once the package's `Package-Requires` minimum is bumped past commit `0951bf38`.

## Server Installation

The LTeX+ language server is a standalone program. You can install it anywhere on your computer that suits your workflow.

### 1. Download the Server

Download the latest release for your architecture from the [official GitHub releases page](https://github.com/ltex-plus/ltex-ls-plus/releases/latest). 

Choose the file that matches your operating system and CPU architecture:

- **Linux:** `ltex-ls-plus-X.Y.Z-linux-x64.tar.gz` or `ltex-ls-plus-X.Y.Z-linux-aarch64.tar.gz`
- **macOS:** `ltex-ls-plus-X.Y.Z-mac-x64.tar.gz` or `ltex-ls-plus-X.Y.Z-mac-aarch64.tar.gz` (Apple Silicon)
- **Windows:** `ltex-ls-plus-X.Y.Z-windows-x64.zip` or `ltex-ls-plus-X.Y.Z-windows-aarch64.zip`

### 2. Choose an Installation Directory

A common, Emacs-idiomatic place to store such tools is within your `.emacs.d` directory (e.g., `~/.emacs.d/ltex-ls-plus/`). However, you can place it anywhere—for instance, in `/usr/local/bin/` or a dedicated software folder.

Once extracted, the package contains:
- `bin/ltex-ls-plus`: The main executable used by this package.
- `bin/ltex-cli-plus`: A command-line interface for LTeX+.
- `jdk-21.x.y/`: A bundled Java runtime.

### 3. Java Runtime Configuration

LTeX+ is a Java application. By default, the server uses the Java runtime bundled within its own directory. 

- **Recommendation:** Start with the bundled Java runtime. It is guaranteed to be compatible.
- **Using System Java:** If you already have Java 21+ installed and prefer to use it, you can delete the bundled `jdk-21.x.y/` folder. In this case, ensure your `JAVA_HOME` environment variable points to your system Java or explicitly set the path in Emacs:
  ```elisp
  (use-package lsp-ltex-plus
    :custom
    (lsp-ltex-plus-java-path "/path/to/your/java/home"))
  ```

### 4. Make it Discoverable

For `lsp-ltex-plus` to work, Emacs must be able to find the `ltex-ls-plus` binary. You have several options:

- **Symlink or Shim (Recommended):** To avoid cluttering your `PATH` with many individual directories, you can create a symlink or a small shim script in a directory that is already in your `PATH` (such as `~/.local/bin/` or `/usr/local/bin/`).
  
  Example (Linux/macOS symlink):
  ```bash
  ln -s /path/to/ltex-ls-plus/bin/ltex-ls-plus ~/.local/bin/ltex-ls-plus
  ```

  Example (Bash shim script):
  A shim is useful if you need to set environment variables like `JAVA_HOME` specifically for the server:
  ```bash
  #!/bin/bash
  # Save this as ~/.local/bin/ltex-ls-plus and make it executable
  export JAVA_HOME="/path/to/ltex-ls-plus/jdk-21.x.y"
  exec "/path/to/ltex-ls-plus/bin/ltex-ls-plus" "$@"
  ```

- **Direct Configuration:** If you prefer not to modify your system environment, you can point to the executable directly in your Emacs configuration:
  ```elisp
  (use-package lsp-ltex-plus
    :custom
    (lsp-ltex-plus-ls-plus-executable "/path/to/ltex-ls-plus/bin/ltex-ls-plus"))
  ```

- **Update PATH:** Alternatively, add the `bin/` directory of the extracted server to your system `PATH` (via your shell profile) or your Emacs `exec-path`.

## Installation (Emacs Package)

### Using straight.el

```elisp
(straight-use-package
 '(lsp-ltex-plus :type git :host github :repo "ltex-plus/emacs-ltex-plus"))
```

### Manual Installation

Download `lsp-ltex-plus.el`, place it in your load path, and require it:

```elisp
(require 'lsp-ltex-plus)
```

## Basic Configuration

The most idiomatic way to use this package is to call `lsp-ltex-plus-enable-for-modes` in your `:init` block. It reads the default list of ~80 supported major modes, records them as the effective enabled set, and installs a single dispatcher on `after-change-major-mode-hook`. The dispatcher activates the client only when `major-mode` exactly matches an enabled mode — no parent-mode leakage. The full package is loaded lazily — only when you first open a file whose major mode is on the list.

```elisp
(use-package lsp-ltex-plus
  :defer t
  :init
  (lsp-ltex-plus-enable-for-modes))
```

### Customizing Supported Modes

`lsp-ltex-plus-major-modes` is the **client's registry of supported modes**. Each entry is a three-element list `(major-mode language-id programming-p)`:

- `major-mode` — the Emacs major mode symbol.
- `language-id` — a **VS Code language identifier**, the string LTeX+ uses to select the correct grammar rules and that the LSP protocol sends in `textDocument/didOpen`. The canonical list is at the [VS Code language identifiers page](https://code.visualstudio.com/docs/languages/identifiers).
- `programming-p` — `nil` for markup and writing modes (LaTeX, Markdown, Org, …), `t` for programming languages (Python, C, Rust, …). This flag controls whether the mode is checked by default or only when `lsp-ltex-plus-check-programming-languages` is enabled.

The registry serves two purposes: it tells the client which buffers to accept, and it provides the language ID to send over the wire. Both are looked up dynamically at activation time, so changes take effect immediately without restarting the server.

`lsp-ltex-plus-enable-for-modes` reads `lsp-ltex-plus-major-modes` to compute the effective set of modes the dispatcher activates on, but its keyword arguments (`:restrict-to`, `:exclude`, `:extend-to`) only control that set — they never modify `lsp-ltex-plus-major-modes` itself. The full registry always stays intact.

This matters in practice: even if you auto-start the server only in Markdown, you can still call `M-x lsp-ltex-plus-mode` in an Org or Python buffer and the client activates without any prompt — because those modes are already in the registry.

**Activate only a specific subset** with `:restrict-to` (whitelist):

```elisp
(use-package lsp-ltex-plus
  :defer t
  :init
  (lsp-ltex-plus-enable-for-modes
    :restrict-to '(org-mode markdown-mode latex-mode LaTeX-mode)))
```

**Drop a few unwanted modes** from the large default list with `:exclude` (blacklist):

```elisp
(use-package lsp-ltex-plus
  :defer t
  :init
  (lsp-ltex-plus-enable-for-modes
    :exclude '(python-mode c-mode c++-mode)))
```

**Add a mode that is not in the built-in list** with `:extend-to`:

```elisp
(use-package lsp-ltex-plus
  :defer t
  :init
  (lsp-ltex-plus-enable-for-modes
    :extend-to '((my-custom-mode "plaintext" nil))))
```

All three keywords can be combined. `:extend-to` entries are always added after `:restrict-to` and `:exclude` are applied, so they are never accidentally dropped:

```elisp
(lsp-ltex-plus-enable-for-modes
  :restrict-to '(org-mode markdown-mode)
  :exclude     '(markdown-mode)
  :extend-to   '((my-custom-mode "plaintext" nil)))
```

### Ready-to-go Configuration Example

For a more robust setup using `use-package` and `straight.el`, you can use the following pattern. This example shows how to automatically pull credentials from your system environment variables if you choose to use an online service:

```elisp
(use-package lsp-ltex-plus
  :straight (lsp-ltex-plus
             :type git
             :host github
             :repo "ltex-plus/emacs-ltex-plus")

  :defer t

  :custom
  ;; Uncomment to use the online LanguageTool service.
  ;; If left commented, the local-only server is used (default).
  ;; (lsp-ltex-plus-lt-server-uri "https://api.languagetoolplus.com")

  ;; Opt in to grammar checking inside programming language comments.
  ;; By default only markup languages (LaTeX, Markdown, Org, …) are checked.
  ;; Set to t to also check comments in Python, C, Rust, and all other
  ;; programming languages in lsp-ltex-plus-major-modes.
  (lsp-ltex-plus-check-programming-languages t)

  ;; lsp-ltex-plus-apply-kind-first-patch is deprecated and no longer set
  ;; in the recommended config — the five upstream lsp-mode fixes it once
  ;; worked around have been merged. See "Recommended `lsp-mode` Revision"
  ;; near the top of the README.

  :init
  ;; Enable lsp-ltex-plus for all supported major modes. The full package
  ;; loads lazily — only when you first open a relevant file.
  (lsp-ltex-plus-enable-for-modes)

  :config
  ;; Optional: Automatically use credentials from environment variables.
  ;; This is safer than hardcoding your API key in your configuration.
  (let ((user (getenv "LANGUAGETOOL_USERNAME"))
        (key  (getenv "LANGUAGETOOL_API_KEY")))
    (when (and user (or (null lsp-ltex-plus-lt-username) (string-empty-p lsp-ltex-plus-lt-username)))
      (setq lsp-ltex-plus-lt-username user))
    (when (and key (or (null lsp-ltex-plus-lt-api-key) (string-empty-p lsp-ltex-plus-lt-api-key)))
      (setq lsp-ltex-plus-lt-api-key key))))
```

### Key Settings
- `lsp-ltex-plus-language`: The language variant to check (e.g., `"en-US"`, `"de-DE"`).
- `lsp-ltex-plus-additional-rules-enable-picky-rules`: Set to `t` if you want stricter grammar checks (e.g., passive voice detection).
- `lsp-ltex-plus-apply-kind-first-patch`: **Deprecated.** Defaults to `nil`. The five `lsp-mode` bugs this option once worked around are now fixed upstream — see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision). Leave it unset; it will be removed in a future release once the package's `lsp-mode` minimum is bumped.

For the full list of available settings, see [Customization](#customization).

## Usage

Once active, LTeX+ works just like any other LSP server:

- **Diagnostics:** Errors and warnings will be highlighted in your buffer.
- **Code Actions:** Use your standard `lsp-execute-code-action` (usually `s-l a` or `C-c l a`) to:
    - Add a word to your personal dictionary.
    - Disable a specific rule you don't like.
    - Ignore a false positive.

### Toggling grammar checking in a buffer

`lsp-ltex-plus-mode` is a standard Emacs minor mode: `M-x lsp-ltex-plus-mode` toggles it on and off in the current buffer. In practice this means:

- **Disable** in a buffer where it auto-activated — for example, while you write a throwaway draft that you don't want flagged. Diagnostics disappear, the `LTeX+` mode-line lighter is removed, and running `M-x lsp-ltex-plus-mode` again re-enables it.
- **Enable** in a buffer where automatic activation did not fire — because the major mode was filtered out by `:restrict-to` / `:exclude`, or because it is a programming language and `lsp-ltex-plus-check-programming-languages` is nil. The client starts immediately; you do not need to flip any global variable first.

If the current major mode is not yet in `lsp-ltex-plus-major-modes`, you will be prompted for a [VS Code language identifier](https://code.visualstudio.com/docs/languages/identifiers) (press `RET` to accept the default `"plaintext"`). The mode is then registered and the grammar checker starts immediately. When called from a hook rather than interactively, `"plaintext"` is used silently without prompting.

Deactivation is properly scoped: when the mode is turned off in a buffer where other LSP servers are also active (e.g. `texlab` for LaTeX, `basedpyright` for Python), only the LTeX+ workspace is detached and its diagnostics are cleared; the co-tenant servers keep running untouched. The mode is also re-entrant — toggling it off and on repeatedly in the same buffer works cleanly.

> **Why two tables?**  lsp-mode uses `lsp-language-id-configuration` to decide the language ID string sent over the wire (in `textDocument/didOpen` and similar messages). Most common modes — Markdown, Org, LaTeX, plain text — already have entries there from lsp-mode's built-in defaults, so they work without any extra step. Modes outside that list (e.g. `fundamental-mode`) have no default entry, which is why `lsp-ltex-plus-mode` adds the mode to both `lsp-ltex-plus-major-modes` and `lsp-language-id-configuration` simultaneously.


## Customization

`lsp-ltex-plus` supports the full range of customizable parameters provided by the LTeX+ server, alongside unique settings specific to this Emacs client (such as debugging tools). For detailed documentation on the official LTeX+ server settings, visit the [official settings page](https://ltex-plus.github.io/ltex-plus/settings.html). LTeX+ itself is a thin LSP wrapper around the [LanguageTool Java library](https://github.com/languagetool-org/languagetool) (`languagetool-core` + per-language modules), adding document parsers (LaTeX, Markdown, BibTeX, …) and per-language client-scoped settings on top of LT's rule engine.

You can configure the parameters using `:custom` in `use-package`:

```elisp
(use-package lsp-ltex-plus
  :custom
  ;; Client-specific: Enable detailed logging for troubleshooting
  (lsp-ltex-plus-debug t)
  ;; Server-specific: Provide a custom path to the LTeX+ root directory
  (lsp-ltex-plus-ltex-ls-path "~/path/to/ltex-ls-plus-18.6.1")
  ;; Server-specific: Set the language
  (lsp-ltex-plus-language "en-GB"))
```

### Full list of supported parameters

The table below lists every parameter this Emacs client exposes. The **When applied** column (col. 2) shows when a change to the variable takes effect — see the legend below the table. Crosses denote parameters for which a counterpart exists in LTeX+ (col. 4) and in the underlying LanguageTool itself (col. 5) — either the [`/check` HTTP parameter](https://languagetoolplus.com/http-api/) or the equivalent concept in the [Java library](https://github.com/languagetool-org/languagetool).

An empty space means the parameter has no direct counterpart at that layer: typically an Emacs-only concern (e.g., UI behaviour, mode registration) or an LTeX+-only feature (e.g., user custom dictionaries for individual languages).

| Parameter | When applied | Description | Official LTeX+ Setting | Counterpart in LT Java Library |
| :--- | :---: | :--- | :---: | :---: |
| `lsp-ltex-plus-ls-plus-executable` | R | The name or path of the ltex-ls-plus executable. *Type:* string; *default:* `"ltex-ls-plus"`. | | |
| `lsp-ltex-plus-debug` | R | When non-nil, enable verbose logging and JSON-RPC tracing. *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-major-modes` | S† | List of `(major-mode language-id programming-p)` triples driving client activation. *Type:* list; *default:* ~80 entries covering markup and programming modes (defined in `lsp-ltex-plus-bootstrap.el`). | | |
| `lsp-ltex-plus-check-programming-languages` | L† | When non-nil, enable grammar checking in comments of programming languages (disabled by default, matching LTeX+). *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-language` | L | The language LanguageTool should check against (e.g. `"en-US"`, `"de-DE"`). Valid codes are listed on the [LTeX+ supported-languages page](https://ltex-plus.github.io/ltex-plus/supported-languages.html); `"auto"` attempts language detection (not recommended — no spelling). *Type:* string; *default:* `"en-US"`. | X | X |
| `lsp-ltex-plus-dictionary` | L | Additional words accepted as correctly spelled (language-specific). *Type:* plist; *default:* `nil`. See [External settings](#external-settings) for format and behaviour. | X | |
| `lsp-ltex-plus-enabled-rules` | L | Language-specific list of rules to enable. *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | X |
| `lsp-ltex-plus-disabled-rules` | L | Language-specific list of rules to disable. *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | X |
| `lsp-ltex-plus-hidden-false-positives` | L | Regex-based suppression of false-positive diagnostics (language-specific). *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | |
| `lsp-ltex-plus-bibtex-fields` | L | BibTeX fields whose values are to be checked. *Type:* alist of `(field-name . boolean)`; *default:* `nil`. | X | |
| `lsp-ltex-plus-latex-commands` | L | LaTeX commands to be handled by the LaTeX parser (listed with empty arguments, e.g. `"\ref{}"`). *Type:* alist of `(command . action)`, where action is `"default"`, `"ignore"`, `"dummy"`, `"pluralDummy"`, or `"vowelDummy"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-latex-environments` | L | LaTeX environments to be handled by the LaTeX parser. *Type:* alist of `(env-name . action)`, where action is `"default"` or `"ignore"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-markdown-nodes` | L | Markdown node types to be handled by the Markdown parser. *Type:* alist of `(node-type . action)`, where action is `"default"`, `"ignore"`, `"dummy"`, `"pluralDummy"`, or `"vowelDummy"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-additional-rules-enable-picky-rules` | L | Enable LanguageTool rules marked as picky (e.g. passive voice, sentence length) at the cost of more false positives. *Type:* boolean; *default:* `nil`. | X | X |
| `lsp-ltex-plus-additional-rules-mother-tongue` | L | Optional mother tongue of the user (e.g. `"de-DE"`). When set, enables false-friend detection (picky rules may additionally need to be enabled). *Type:* string; *default:* `""` (disabled). | X | X |
| `lsp-ltex-plus-additional-rules-language-model` | L | Optional path to a directory with n-gram language models (parent directory containing per-language subfolders). *Type:* string; *default:* `""` (disabled). | X | X |
| `lsp-ltex-plus-lt-server-uri` | L | Base URI for the LanguageTool HTTP server. Must be a bare host — the server appends `/v2/check`. *Type:* `nil` for local built-in (default) or a string URI such as `"https://api.languagetoolplus.com"`. | X | |
| `lsp-ltex-plus-lt-username` | L | Username/email for LanguageTool Premium API access. Only relevant when `lsp-ltex-plus-lt-server-uri` is set. *Type:* string; *default:* `""`. | X | X |
| `lsp-ltex-plus-lt-api-key` | L | API key for LanguageTool Premium API access. Only relevant when `lsp-ltex-plus-lt-server-uri` is set. *Type:* string; *default:* `""`. | X | X |
| `lsp-ltex-plus-ltex-ls-path` | R | Path to the root directory of ltex-ls-plus (contains `bin` and `lib` subdirectories). *Type:* string; *default:* `""` (use the executable found on `PATH`). | X | |
| `lsp-ltex-plus-ltex-ls-log-level` | R | Logging level (verbosity) of the ltex-ls-plus server log. *Choices* (descending verbosity): `"severe"`, `"warning"`, `"info"`, `"config"`, `"fine"` (default), `"finer"`, `"finest"`. | X | |
| `lsp-ltex-plus-java-path` | R | Path to an existing Java installation (same value you would use for `JAVA_HOME`). *Type:* string; *default:* `""` (use the bundled JRE). | X | |
| `lsp-ltex-plus-java-initial-heap` | R | Initial size of the Java heap in megabytes (`-Xms`). *Type:* integer; *default:* `64`. | X | |
| `lsp-ltex-plus-java-max-heap` | R | Maximum size of the Java heap in megabytes (`-Xmx`). *Type:* integer; *default:* `512`. | X | |
| `lsp-ltex-plus-sentence-cache-size` | R | Size of the LanguageTool `ResultCache` in sentences. Lower values reduce RAM usage but may significantly slow down checking. *Type:* integer; *default:* `2000`. | X | X |
| `lsp-ltex-plus-completion-enabled` | L | Controls whether word completion is enabled. Requires an `lsp-mode` build containing [PR #5052](https://github.com/emacs-lsp/lsp-mode/pull/5052) (merged 2026-05-03); see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision). *Type:* boolean; *default:* `nil`. | X | |
| `lsp-ltex-plus-diagnostic-severity` | L | Severity of the diagnostics. *Choices:* `"error"`, `"warning"` (default), `"information"`, `"hint"`. | X | |
| `lsp-ltex-plus-check-frequency` | L | Controls when documents should be checked. *Choices:* `"edit"` (default, on every keystroke), `"save"` (on open and save), `"manual"` (explicit commands only). | X | |
| `lsp-ltex-plus-clear-diagnostics-when-closing-file` | L | Whether to clear diagnostics when a file is closed. *Type:* boolean; *default:* `t`. | X | |
| `lsp-ltex-plus-show-progress` | S | Show `ltex-ls-plus` progress updates in the mode line (the `⌛` prefix and optional spinner). Set to nil to silence the flicker on every keystroke without affecting progress rendering for other LSP clients. *Type:* boolean; *default:* `t`. | | |
| `lsp-ltex-plus-apply-kind-first-patch` | S | **Deprecated** — see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision). Whether to apply the 'Kind-First' routing patch (and four related workarounds) to lsp-mode; all five are now fixed upstream. *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-show-latency` | S | When non-nil, echo the server round-trip time after every check. Reports both the cold start (`"Completed initial spell check in N ms."` after `textDocument/didOpen`) and the warm path (`"Completed spell check in N ms."` after each `textDocument/didChange`); see [Measuring Server Latency](#measuring-server-latency). *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-multi-root` | S | Register the client as multi-root so a single `ltex-ls-plus` JVM handles all folders in the session. Leave enabled unless you have a specific need to isolate projects — disabling it spawns one JVM per project root, which can balloon memory usage. *Type:* boolean; *default:* `t`. | | |

> **"When applied" legend:**
>
> - **L** — *Live*: read by the client on every `workspace/configuration` pull, which the server issues before each diagnostic publish. A plain `setq` is honoured on the next edit — no manual notification, no restart.
> - **R** — *Requires server restart*: the server reads the value at JVM init only. Change the variable, then run `M-x lsp-workspace-restart` for it to take effect.
> - **S** — *Setup-only*: wired during `lsp-ltex-plus--setup` (the first time a supported buffer is opened in the Emacs session). Typically installed via `advice-add` or baked into the `lsp-register-client` call. Changing the variable later with `setq` or `customize-set-variable` does not re-apply the change. To force a mid-session update, restart Emacs or evaluate `M-: (lsp-ltex-plus--setup)`.
>
> **†** on `lsp-ltex-plus-major-modes` — this is a registry, not a customization knob. It is listed here for reference because the client reads from it, but users should not mutate it directly. To adjust which modes the dispatcher activates on, call `lsp-ltex-plus-enable-for-modes` with its `:restrict-to`, `:exclude`, and `:extend-to` keyword arguments (see [Customizing Supported Modes](#customizing-supported-modes)).
>
> **†** on `lsp-ltex-plus-check-programming-languages` — re-read at every buffer (re-)activation rather than on every check. Already-active buffers are unaffected by a mid-session flip; newly opened or toggled buffers see the new value.

</details>

### External settings

Alongside the in-Emacs parameters above, `lsp-ltex-plus` relies on four pieces of **persistent configuration** on disk, which survive across Emacs sessions. Each of them has a defcustom counterpart so you can seed it declaratively from `:custom`. Three of the four (all except `enabled-rules`) also grow at runtime when you invoke a code action on a flagged diagnostic (`lsp-execute-code-action`, usually `s-l a` or `C-c l a`) — *Add to dictionary*, *Disable rule …*, or *Hide false positive …*.

Each file is a per-language plist under `~/.emacs.d/lsp-ltex-plus/`, with language keys (`:en-US`, `:de-DE`, …) mapped to vectors of strings. Settings provided via `:custom` and via the file are kept separate: the defcustom settings are never mutated, and they are never written to disk. The server sees their merge.

Code actions update the relevant file and notify the server, so the change takes effect on the next check without a restart.

| File (under `~/.emacs.d/lsp-ltex-plus/`) | `:custom` variable (defcustom) | Written by code action? | Provenance |
| :--- | :--- | :---: | :---: |
| `stored-dictionary.eld` | `lsp-ltex-plus-dictionary` | yes | **LTeX+ only** |
| `enabled-rules.eld` | `lsp-ltex-plus-enabled-rules` | no | LanguageTool |
| `disabled-rules.eld` | `lsp-ltex-plus-disabled-rules` | yes | LanguageTool |
| `hidden-false-positives.eld` | `lsp-ltex-plus-hidden-false-positives` | yes | **LTeX+ only** |

The `.eld` extension is the Emacs convention for `prin1`-serialised Lisp data; opening one of these files (from Emacs or your OS file manager) gets `lisp-data-mode` automatically. Earlier versions of `lsp-ltex-plus` wrote the external files by default without an extension; if you upgraded from such an older version, these files will be renamed automatically the first time `lsp-ltex-plus` is loaded — no action required. If you customized the filenames, it is recommended moving the files to use the `.eld` extension.  

#### Format

All four settings use the same structure: an Emacs **plist** (property list) whose keys are language-code keywords (`:en-US`, `:de-DE`, `:fr`, `:it`, …) and whose values are vectors of strings. Languages you never touch don't need to be present; unknown keys are ignored by the server.

A minimal example seeding a couple of disabled rules for two languages via `:custom`:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-disabled-rules
   '(:en-US ["UPPERCASE_SENTENCE_START" "EN_QUOTES"]
     :de-DE ["TYPOGRAFISCHE_ANFUEHRUNGSZEICHEN"])))
```

The meaning of each string is setting-specific:

| Setting | Each string is… |
| :--- | :--- |
| `dictionary` | a single word, e.g. `"alberti"` |
| `enabled-rules` / `disabled-rules` | a LanguageTool rule ID, e.g. `"EN_QUOTES"` |
| `hidden-false-positives` | a JSON object of the form `{"rule":"RULE_ID","sentence":"REGEX"}`, e.g. `"{\"rule\":\"MORFOLOGIK_RULE_EN_US\",\"sentence\":\"^My LaTeX\\\\TeX command\\\\.$\"}"` |

The on-disk files use the same Lisp representation — open `~/.emacs.d/lsp-ltex-plus/stored-dictionary.eld` (or any of the others) in Emacs and you'll see a plain plist like:

```elisp
(:en-US ["Alberti" "elisp" "plist"] :it ["Caravaggio"])
```

Hand-editing the file is supported; afterwards run `M-x lsp-ltex-plus-reload-and-notify-server` (see [Inspecting and editing](#inspecting-and-editing)) or restart Emacs to pick up the change.

#### What each one is for

**Dictionary** — a per-language list of additional words that should be accepted as correctly spelled. Grown at runtime by the *Add to dictionary* code action, and "seedable" from `:custom`. For large hand-curated word lists, prefer editing the on-disk file directly (see [Inspecting and editing](#inspecting-and-editing) below) rather than stuffing everything into `:custom`.

The dictionary is an **LTeX+ feature**, not a LanguageTool one. The `/check` HTTP endpoint exposed by LanguageTool has no `dictionary` parameter, and the personal-dictionary APIs offered to LanguageTool Premium subscribers live on a separate set of endpoints that `ltex-ls-plus` does not use. Instead, LTeX+ applies the dictionary locally. This means the following: For LanguageTool's rules pertaining to orthography errors (`MORFOLOGIK_RULE_*`, `HUNSPELL_*` and, for LT premium users, `*ORTHOGRAPHY*`), LTeX+ checks whether the listed words occur in the user's dictionary, and if so, it prevents the resulting diagnostics from being sent on to Emacs. This works identically for both the embedded local LanguageTool and the remote `lsp-ltex-plus-lt-server-uri`, since the dictionary filter runs in the LTeX+ server `ltex-ls-plus` either way.

**Enabled / disabled rules** — the **coarsest-grained** control you have over what LanguageTool checks. A rule (e.g. `OXFORD_SPELLING_NOUNS`, `UPPERCASE_SENTENCE_START`, `EN_QUOTES`) either fires for every match in every document of that language, or it doesn't. Disabling a rule turns it off globally for its language; enabling a rule re-activates one that would otherwise be off (e.g. a *picky* rule, or a rule a user-level config previously disabled). These are **LanguageTool-level** settings — both the locally-embedded LanguageTool inside `ltex-ls-plus` and the hosted [LanguageTool HTTP API](https://languagetoolplus.com/http-api/) honour them (via the `enabledRules` / `disabledRules` query parameters). LTeX+ just exposes them per-language.

`disabled-rules` also grows at runtime via the *Disable rule* code action; `enabled-rules` has no such writer (there is no "Enable rule" action for a flagged diagnostic) and is populated strictly from your `:custom` value and/or hand-edits to the file.

**Hidden false positives** — the **finest-grained** control, and a feature unique to LTeX+ ([documented here](https://ltex-plus.github.io/ltex-plus/advanced-usage.html#hiding-false-positives-with-regular-expressions)). Each entry pairs a rule ID with a regular expression matched against the diagnostic's surrounding text. Matches are directly suppressed inside `ltex-ls-plus`, before diagnostics reach Emacs. This fine-grained control allows the user to specifically hide false positives, without entirely turning the specific rule off. So, only the specific phrasing you marked as correct stops being flagged, and the same rule keeps catching real problems elsewhere in your prose. This lives entirely outside LanguageTool's own API and has no counterpart in hosted LanguageTool. The plist `hidden-false-positives` grows at runtime via the *Hide false positive* code action; it can also be populated from `:custom` with false-positive patterns you always want suppressed.

#### Rules vs. hidden false positives — which should I use?

- If a rule produces *only* noise for your writing style, **disable the rule** — it's faster, cheaper, and covers everything.
- If a rule is usually right but wrong on one recurring phrase or idiom, **hide the false positive** — the rule keeps working everywhere else, and only that specific text stops being flagged.

#### Inspecting and editing

- `M-x lsp-ltex-plus-list-dictionary` — prints the merged dictionary currently in effect (the union of `:custom` and file contents) to the echo area.
- `M-x lsp-ltex-plus-reload-and-notify-server` — re-reads all four files, rebuilds the merged views combining them with your `:custom` values, and notifies every running `ltex-ls-plus` workspace so the change takes effect on the next check. Convenient for bulk edits: open any of the four files under `~/.emacs.d/lsp-ltex-plus/` in a buffer, edit entries across one or more languages, save, then run this command. Also the right command to run after changing an `lsp-ltex-plus-*` defcustom in a live session — it pushes the new value to the server without an Emacs restart.
- The four files are plain Emacs plists. After hand-editing, either run the reload command above or restart Emacs to pick up the change.

#### Pro tip: per-file overrides with magic comments

For tweaks that only make sense in a single document, LTeX+ supports **magic comments** — file-local directives that override settings for the rest of the file. Two of them map directly onto the external settings above:

- **Rules:** `rules+=RULE_ID` enables a rule for this file, `rules-=RULE_ID` disables it, and `rules#=RULE_ID` reverts the rule to the global setting.
- **Dictionary:** `dictionary+=Word` accepts a word for this file, `dictionary-=Word` removes one that the global dictionary would accept.

The comment syntax depends on the file's language — e.g. `% LTeX: rules-=EN_QUOTES` in LaTeX, `<!-- LTeX: rules-=EN_QUOTES -->` in Markdown, `# LTeX: rules-=EN_QUOTES` in Org-mode. See the [LTeX+ magic-comments documentation](https://ltex-plus.github.io/ltex-plus/advanced-usage.html#magic-comments) for the full syntax table and the other settings they can change (language, picky rules, LaTeX/Markdown parser tweaks, …).

**No per-file support for hidden false positives.** Magic comments cover rules and the dictionary, but not `hiddenFalsePositives` — if you need file-local false-positive suppression, there is no upstream mechanism for it. Use `:custom` or the `hidden-false-positives.eld` file for a global suppression, or disable the offending rule for the file instead.

## Troubleshooting

All variables mentioned below are standard Emacs customization options. If you use `use-package`, it is recommended to set them within the `:custom` block of your configuration.

### Server Not Found

If Emacs cannot find the `ltex-ls-plus` binary, ensure it is in your system `PATH`. You can verify this within Emacs by evaluating:

```elisp
(executable-find "ltex-ls-plus")
```

If it returns `nil`, you must either add the binary's directory to your `PATH` or provide the absolute path to the executable via `lsp-ltex-plus-ls-plus-executable`. See [Server Installation](#4-make-it-discoverable) for details.

### Language Not Recognized

**Symptom:** No diagnostics ever appear for a buffer that should be checked. The server's stderr buffer (`*ltex-ls-plus::stderr*`) contains a line of the form:

```
'fr-FR' is not a recognized language. Leaving LanguageTool uninitialized, checking disabled.
```

The server process stays up, but grammar checking is disabled for that language until the setting is fixed and the server is restarted.

**Cause:** The local server accepts only the exact codes listed on the [LTeX+ supported languages page](https://ltex-plus.github.io/ltex-plus/supported-languages.html), and several languages have no regional variants there. For example:

- French is only `"fr"` — `"fr-FR"` is **not** accepted.
- Italian is only `"it"`, Spanish only `"es"` (plus `"es-AR"`), Dutch only `"nl"` (plus `"nl-BE"`).
- German has `"de"`, `"de-AT"`, `"de-CH"`, `"de-DE"`.
- English has `"en"`, `"en-AU"`, `"en-CA"`, `"en-GB"`, `"en-NZ"`, `"en-US"`, `"en-ZA"`.
- Portuguese has `"pt"`, `"pt-AO"`, `"pt-BR"`, `"pt-MZ"`, `"pt-PT"`.

The **remote LanguageTool server** (when `lsp-ltex-plus-lt-server-uri` points at `https://api.languagetoolplus.com`) is more permissive and accepts codes such as `"fr-FR"` that the local server rejects. A configuration that works against the remote service can therefore stop working after a switch to the local backend — with only the stderr line above to signal what happened.

**A second subtlety — bare code vs. regional variant.** Where a language is listed **both** with a bare code and one or more regional variants (English, German, Portuguese, Dutch, Catalan), the bare code (`en`, `de`, `pt`, `nl`, `ca-ES`) enables LanguageTool's grammar rules but **no spell-check dictionary** — dictionaries are variant-specific. Pick the variant matching your text (`en-US`, `de-DE`, `pt-BR`, …) to get both grammar *and* spelling. For languages listed only as a bare code (French `"fr"`, Italian `"it"`, Swedish `"sv"`, …), that code already includes the single dictionary LanguageTool ships for that language — there is nothing more specific to choose.

**Fix:** Check `lsp-ltex-plus-language` against the official list and pick a code that appears there verbatim:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-language "fr"))  ; NOT "fr-FR" — French has no regional variants
```

### Communication Stalls — No More Diagnostics

**Symptom:** After a few edits, grammar diagnostics stop updating entirely. The `*lsp-log*` buffer shows no new activity, and the server appears alive but silent.

**Cause:** This is a JSON-RPC ID collision deadlock. LTeX+ sends its own requests to Emacs (e.g., to fetch your configuration) while Emacs is still waiting for a response from the server. When the IDs of these two concurrent messages happen to collide, `lsp-mode`'s default parser misroutes the server's request as a response to a pending client request — causing both sides to wait for each other indefinitely.

This is most likely with a **remote/online server**, where both network latency and the server's own processing time (it is a shared service handling many requests) mean that responses take long enough for message overlaps to become virtually inevitable. It can also occur, though rarely, with the local server.

**Fix:** Update `lsp-mode` to a build that contains the upstream Kind-First routing fix ([PR #5055](https://github.com/emacs-lsp/lsp-mode/pull/5055), merged 2026-05-11). Any commit on or after [`0951bf38`](https://github.com/emacs-lsp/lsp-mode/commit/0951bf38) (2026-05-15) suffices — see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision) for the full list of related fixes.

On older `lsp-mode` builds, the legacy fallback is to set `lsp-ltex-plus-apply-kind-first-patch` to `t`, which installs the same routing logic as `:override` advice. This option is now deprecated; prefer upgrading `lsp-mode`.

### Server Crashes or Memory Issues

The LTeX+ server runs on the Java Virtual Machine (JVM) and can be memory-intensive. If the server crashes unexpectedly or becomes unresponsive, you may need to adjust its memory allocation.

You can control the Java heap size using these variables (values are in megabytes):

- `lsp-ltex-plus-java-initial-heap` (default: `64`): Corresponds to the `-Xms` Java option.
- `lsp-ltex-plus-java-max-heap` (default: `512`): Corresponds to the `-Xmx` Java option.

If you encounter crashes, try increasing the maximum heap size:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-java-max-heap 1024))
```

While you can experiment with lower values to save system resources, be aware that setting the memory too low may result in an unstable server and frequent crashes. See [Java Runtime Configuration](#3-java-runtime-configuration) for more context.

### Slow Server Response / High CPU Usage

If diagnostics take a long time to appear or if Emacs feels sluggish when `lsp-ltex-plus` is active, it is often due to general LSP performance overhead rather than the grammar checker itself.

1. **Run `M-x lsp-doctor`**: This command performs an automated health check of your LSP setup and provides environment-specific recommendations.
2. **Consult the Performance Guide**: The official [lsp-mode performance page](https://emacs-lsp.github.io/lsp-mode/page/performance/) contains exhaustive advice on tuning Emacs for LSP. Two high-impact settings frequently recommended for LSP performance are:
  - **Increase Garbage Collection Threshold**: Emacs' default is very low. Increasing it reduces the frequency of GC pauses during heavy JSON-RPC traffic:
    ```elisp
    (setq gc-cons-threshold 100000000) ; 100 MB
    ```
  - **Use Plists for JSON**: Switching `lsp-mode` from hash tables to property lists can yield significant speedups on modern Emacs versions:
    ```elisp
    (setq lsp-use-plists t)
    ```
    However, this setting also requires `LSP_USE_PLISTS=true` when `lsp-mode` is byte-compiled; see the official instructions.

### Startup Delay After Closing Buffers

**Symptom:** Opening a supported buffer is noticeably slow — grammar checking only kicks in after several seconds, and this happens repeatedly, not just on the first buffer opened after starting Emacs.

**Possible explanation:** `ltex-ls-plus` runs on the JVM and reloads the LanguageTool model at startup, so a cold start takes non-trivial time. This happens when `lsp-keep-workspace-alive` is set to `nil`: `lsp-mode` will shut down the server process when the last buffer attached to it is killed; the next supported buffer you open will have to wait through another cold start.

**Fix:** Ensure `lsp-keep-workspace-alive` is left at its default value of `t`:

```elisp
(setq lsp-keep-workspace-alive t)
```

This keeps the workspace (and the server process) alive even when no buffers are currently attached, so later buffers reuse the warm server and diagnostics appear nearly instantaneously.

Note that this setting only matters when the **last** buffer using `ltex-ls-plus` is killed. As long as at least one supported buffer remains open, the server is still in active use and will not be shut down regardless of this setting.

### High Memory Use with Many Loose Files

**Symptom:** After opening several supported files from unrelated directories, you notice multiple `java` / `ltex-ls-plus` processes running, each claiming several hundred megabytes of RAM. Memory use scales roughly linearly with the number of distinct directories you have touched in the session. You can check from a terminal:

```bash
pgrep -afl 'ltex-ls-plus|ltex.ls.plus'
```

**Possible explanation:** `lsp-ltex-plus-multi-root` may have been set to `nil` somewhere in your configuration. When this variable is `nil`, each distinct project root (the git repo for files inside one, or the file's own directory for loose files) gets its own dedicated server process. With the default (`t`), a single server handles every supported buffer in the session regardless of where the files live.

**Fix:** confirm that `lsp-ltex-plus-multi-root` is at its default value of `t`:

```elisp
(setq lsp-ltex-plus-multi-root t)
```

Unless you have a specific need to isolate projects (e.g., you are experimenting with per-project dictionaries or rule sets and want to keep them from bleeding across projects), leave this enabled. With it set to `t`, a single `ltex-ls-plus` process handles every supported buffer in the session regardless of how many unrelated directories those buffers come from.

### No Grammar Checking in Scratch or Anonymous Buffers

**Symptom:** You write prose in `*scratch*` (or any buffer not visiting a file), enable `lsp-ltex-plus-mode` manually, and nothing happens — no lighter, no diagnostics.

**Explanation:** `lsp-mode` identifies every document by a `file://` URI derived from the buffer's file name. A buffer without a file name cannot form such a URI, so the `textDocument/didOpen` handshake that would carry the buffer contents to the server never happens. The grammar-check engine itself has no problem with orphan buffers — it operates purely on the text content passed over the wire — but the LSP plumbing around it does.

**Workaround:** save the buffer to a file first. Even a throwaway path under `/tmp` is enough to satisfy the URI requirement, after which `lsp-ltex-plus-mode` activates normally.

Supporting orphan buffers without requiring a save is tracked as a future enhancement (synthetic `untitled:` URIs or transparent temp-file mirroring).

### Word Completion Not Working with `lsp-ltex-plus-completion-enabled`

**Symptom:** You set `lsp-ltex-plus-completion-enabled t` (or invoke completion explicitly with `M-x completion-at-point` / your usual completion key) in a buffer where `lsp-ltex-plus-mode` is active, but no LTeX+ word suggestions appear.

**Cause:** Word completion depends on `lsp-mode`'s **buffer-wide** `lsp-completion-enable` variable, which is shared across every LSP client active in the buffer. Setting `lsp-ltex-plus-completion-enabled t` only tells LTeX+ to advertise completion to the server; the actual `textDocument/completion` requests are sent only when `lsp-completion-enable` is also non-nil. If you have set `lsp-completion-enable nil` globally — for example because you find LSP-driven completion noisy in code buffers — LTeX+ completion will be silently suppressed alongside everything else.

**Fix (option 1, recommended for most users):** leave `lsp-completion-enable` at its default of `t`. This is the natural setting for LSP-driven autocompletion in code buffers, and LTeX+ will work alongside other servers without further intervention.

**Fix (option 2, for users who prefer global completion off):** enable `lsp-completion-enable` only in buffers where `lsp-ltex-plus-mode` is active. The cleanest way is a small mode hook:

```elisp
(defun my/lsp-ltex-plus-buffer-defaults ()
  "Buffer-local LSP settings for LTeX+."
  (setq-local lsp-completion-enable lsp-ltex-plus-completion-enabled))

(add-hook 'lsp-ltex-plus-mode-hook #'my/lsp-ltex-plus-buffer-defaults)
```

This pattern lets `lsp-ltex-plus-completion-enabled` act as a per-buffer override of your global preference: turn it on, and the buffer gets LSP completion (which, in a buffer where LTeX+ is the only client, means LTeX+ word completion).

**Caveat for option 2.** Because the hook copies `lsp-ltex-plus-completion-enabled` into the buffer-wide `lsp-completion-enable`, it has side effects on **every** LSP client in the same buffer. If you later set `lsp-ltex-plus-completion-enabled nil`, the hook will *also* disable completion for any co-tenant servers (e.g. `basedpyright` or `texlab` running in the same buffer because LTeX+ is enabled for code comments). If you flip the variable off, remove or amend the hook accordingly to avoid surprising other clients.

## Under the Hood

This section is for users who want to understand how `lsp-ltex-plus` works internally — useful context if you hit an unexpected issue or simply want to know what is happening behind the scenes.

### Measuring Server Latency

If you want to evaluate how fast `ltex-ls-plus` responds on your machine — for example, to compare the local backend against a remote LanguageTool service — enable `lsp-ltex-plus-show-latency`:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-show-latency t))
```

Two distinct events are reported with different wording so the two regimes can be distinguished at a glance:

| Event | Triggered by | Message |
| :--- | :--- | :--- |
| **Cold start** | `textDocument/didOpen` (first time the buffer is shown to the server) | `Completed initial spell check in N ms.` |
| **Warm path** | `textDocument/didChange` (every edit, debounced) | `Completed spell check in N ms.` |

The cold-start figure reflects a full first-pass check of the entire document. The warm-path figure reflects incremental re-checks served partly from the server's sentence cache. Reporting both lets you quote numbers such as *"first open: X ms, incremental edit: Y ms."*

On a modern laptop with the local backend, incremental edits typically land in around **~60 ms** for short Org / Markdown buffers and **~120 ms** for long LaTeX documents. The cold-start figure is always noticeably higher — the server has to parse the full document from scratch and prime its caches before the first diagnostics come back.

A remote LanguageTool server typically adds 100–300 ms on top of both numbers, depending on network latency and how busy the service is.

> **Important — what the numbers do _not_ include.** Each measurement stops the instant diagnostics *arrive*. It does **not** cover the subsequent rendering step inside Emacs: `lsp-mode`'s diagnostic dispatch, `flycheck` / `flymake` overlay refresh, and any `lsp-ui-sideline` redraw. On typical configurations that rendering path adds several hundred milliseconds on top and is the **dominant contributor to perceived responsiveness** — not the grammar checker itself.
>
> So if the experience feels laggy even though `ltex-ls-plus` reports a small number, the bottleneck is in the UI layer above LSP, not in the grammar checker below it. Tuning `lsp-idle-delay`, `flycheck-idle-change-delay`, and `lsp-ui-sideline-delay` usually helps more than replacing the checker with a faster one.

Because the warm-path message fires after every check (i.e. on essentially every keystroke when `lsp-ltex-plus-check-frequency` is `"edit"` and the debounce interval is small), it is intended for investigation only. Turn the flag off again when you are done measuring. For richer diagnostic output — including entries in the `*lsp-ltex-plus::client*` log buffer and raw JSON-RPC dumps under `/tmp` — see `lsp-ltex-plus-debug` instead; the two flags are independent and can be combined.

### Lsp-mode Protocol Patches

> **Deprecated as of 2026-05-15.** All three patches described below have been merged into `lsp-mode` upstream (alongside two related fixes); see [Recommended `lsp-mode` Revision](#recommended-lsp-mode-revision). The `lsp-ltex-plus-apply-kind-first-patch` toggle is now a no-op against any sufficiently recent `lsp-mode` and will be removed once the package's `lsp-mode` minimum is bumped. This section is preserved as a technical reference for users on older `lsp-mode` builds and for the historical record.

This package includes several surgical fixes for `lsp-mode` to improve protocol robustness. They are applied globally when `lsp-ltex-plus-apply-kind-first-patch` is non-nil.

1.  **Kind-First Routing (Fix for Communication Stalls)**: Standard `lsp-mode` routes messages by checking the `id` field first. LTeX+ frequently initiates its own requests (e.g., to fetch your configuration), which can overlap with Emacs's own requests (like checking a document). In such cases, an "id collision" can occur where `lsp-mode` misinterprets the server's new request as a response to its own pending check, causing both sides to hang indefinitely. This patch analyzes the message format (presence of a `method` field) to distinguish with certainty between requests and responses. **Highly recommended if you use a remote server and necessary for `lsp-ltex-plus` to  correctly function.**

2.  **Resilient Message Dispatch (Fix for Lost Updates)**: Often, the server sends several updates bundled together (for example, a progress update followed immediately by diagnostics). In standard `lsp-mode`, if processing one update is interrupted—such as when you start typing while a completion list is being shown—all other updates in that same bundle are accidentally discarded. This patch ensures that every message in a bundle is processed, even if one of them is interrupted. This patch is highly recommended for the functioning of this package.

3.  **Stale Callback Protection**: Prevents synchronous requests from throwing `lsp-done` after they have already timed out or been cancelled. Without this, a late response to a cancelled request could escape its local scope and throw a mysterious error to the top level.

To enable these patches, add this to your `:custom` block:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-apply-kind-first-patch t))
```

*Note: As these are protocol-level improvements, enabling them generally improves the stability and reliability of **all** your other LSP clients as well.*

### How does `lsp-ltex-plus-mode` get set up and activated?

The package is split into two files with different load-time profiles:

- **`lsp-ltex-plus-bootstrap.el`** — tiny, no dependencies. Loaded at `:init` time. Defines the major-mode alist and exposes two autoloaded entry points.
- **`lsp-ltex-plus.el`** — the full client. Loaded lazily, only when a relevant buffer is first opened.

#### Setup: what happens at startup

When the package manager builds `lsp-ltex-plus`, it scans both files for `;;;###autoload` cookies and writes a single autoloads file. This registers lightweight stubs for two symbols — `lsp-ltex-plus-enable-for-modes` and `lsp-ltex-plus-mode` — very early at startup, before any `use-package` form is evaluated. Neither file is loaded yet.

When `use-package` evaluates the `:init` block and calls `(lsp-ltex-plus-enable-for-modes)`, it hits that stub, which loads `lsp-ltex-plus-bootstrap.el` (the tiny file only). The full package is **not** loaded. The function stores the effective set of enabled modes in `lsp-ltex-plus--enabled-modes` and adds a single dispatcher, `lsp-ltex-plus--maybe-activate`, to `after-change-major-mode-hook`.

#### Activation: user opens a file

```
User opens foo.md
  → markdown-mode activates → after-change-major-mode-hook fires
      → lsp-ltex-plus--maybe-activate runs
          → (memq 'markdown-mode lsp-ltex-plus--enabled-modes) → non-nil
          → lsp-ltex-plus-mode called ← hits its autoload stub
              → lsp-ltex-plus.el loads for the first time
                  → (require 'lsp-ltex-plus-bootstrap) → already loaded, no-op
                  → (with-eval-after-load 'lsp-mode ...) registered
              → lsp-ltex-plus-mode body runs → (lsp) called
                  → lsp-mode.el loads → (provide 'lsp-mode) fires
                      → lsp-ltex-plus--setup runs ← client registered
                  → lsp-mode finds ltex-ls-plus, activates it
```

The crucial detail is that `with-eval-after-load` fires **synchronously inside the `require` call**, at the exact moment `lsp-mode.el` evaluates `(provide 'lsp-mode)`. By the time `(lsp)` returns, the client is already registered. There is no race condition.

Thus, with `with-eval-after-load`, we ensure the correct load orders, while no special configuration is required from the user.

#### Why a single dispatcher?

An earlier design registered `lsp-ltex-plus-mode` on each selected mode's hook individually (`text-mode-hook`, `org-mode-hook`, `markdown-mode-hook`, …). It was abandoned for two reasons:

1. **Parent-mode leakage.** Emacs mode hooks inherit along the `define-derived-mode` chain. Opening an `org-mode` buffer also runs `text-mode-hook` (org derives from text via outline), so `:exclude '(org-mode)` could not actually keep the client out of org buffers as long as `text-mode` remained in the enabled set.
2. **Redundant firings.** Every parent hook in the chain ran for each buffer open, calling the minor mode multiple times per buffer — harmless but wasteful.

A grammar and spell checker is a cross-cutting tool expected to run across many writing and programming modes (the default registry ships with 80+), so the realistic baseline is a large enabled set. At that scale a single dispatcher on `after-change-major-mode-hook` that checks `(memq major-mode lsp-ltex-plus--enabled-modes)` is both the correct and the efficient choice — it fires once per mode change and matches by exact identity, so inheritance never leaks.

For users who go the other way and pick only a handful of modes with `:restrict-to`, per-mode hooks would have been roughly as efficient; the remaining advantage of the dispatcher there is purely about `:exclude` correctness when an excluded descendant mode shares a parent with an enabled one. The common situation takes precedence, hence the decision for a single dispatcher. The design stays simple: one hook, one list, exact match.

## Why this package?

Two Emacs LSP clients for LTeX already existed before this package:

- [`emacs-languagetool/lsp-ltex`](https://github.com/emacs-languagetool/lsp-ltex) — the original client, targeted at the older `ltex-ls` server.
- [`emacs-languagetool/lsp-ltex-plus`](https://github.com/emacs-languagetool/lsp-ltex-plus) — a more recent variant by the same author, with function and variable prefixes renamed and the client retargeted at `ltex-ls-plus`. From a reading of its source, the renaming is the only substantive change, so it shares the original's architecture. For that reason the [detailed comparison](docs/comparison-lsp-ltex.md) treats the two as one family and refers to them jointly as `lsp-ltex`.

> **Note on the name collision.** The overlap with `emacs-languagetool/lsp-ltex-plus` is unintentional — I was not aware of that project when I chose the name for this one. The two packages are independent; they simply converged on the same label.

The motivation for writing a new client was practical: on my setup the existing client reliably stalled after a handful of edits — the server stopped publishing diagnostics and a workspace restart was needed to recover. Tracing that symptom led to the JSON-RPC ID-collision issue documented in [Lsp-mode Protocol Patch](#lsp-mode-protocol-patch), and from there to a from-scratch implementation designed specifically for `ltex-ls-plus`. Rebuilding the communication chain — starting with direct command-line interrogation of the server — made it possible to understand exactly how the server and client interact. The result is a lightweight client built around `ltex-ls-plus`'s actual behaviour (bi-directional server-initiated requests, full document sync, server-pulled configuration) rather than inheriting a design tuned for the older `ltex-ls`.

If you want to dig deeper:

- [Detailed Technical Comparison between `lsp-ltex` and `lsp-ltex-plus`](docs/comparison-lsp-ltex.md)
- [What is New with LTeX+?](docs/what-is-new-with-ltex-plus.md)

## License

This project is licensed under the **Mozilla Public License 2.0 (MPL-2.0)**. See the `LICENSE` file for details.
