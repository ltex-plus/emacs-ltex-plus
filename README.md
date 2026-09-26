# Emacs LTeX+

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/lsp-ltex-plus-badge.svg)](https://melpa.org/#/lsp-ltex-plus)
[![MELPA Stable](https://stable.melpa.org/packages/lsp-ltex-plus-badge.svg)](https://stable.melpa.org/#/lsp-ltex-plus)
[![melpazoid](https://github.com/ltex-plus/emacs-ltex-plus/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/ltex-plus/emacs-ltex-plus/actions/workflows/melpazoid.yml)
[![CI](https://github.com/ltex-plus/emacs-ltex-plus/actions/workflows/ci.yml/badge.svg)](https://github.com/ltex-plus/emacs-ltex-plus/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/github/license/ltex-plus/emacs-ltex-plus)](LICENSE)

<!-- ltex: language=en-GB -->
<!-- ltex: dictionary+=plist -->
<!-- ltex: dictionary+=defcustom -->
<!-- ltex: dictionary+=LTeX+ -->
<!-- ltex: dictionary+=jsonrpc -->
<!-- ltex: dictionary+=flymake -->

`lsp-ltex-plus` is an Emacs client for **LTeX+**, a powerful grammar and spell checker powered by LanguageTool's [local](https://github.com/languagetool-org/languagetool) or [remote](https://languagetool.org/) servers. Under the hood, it communicates with the [LTeX+ server](https://github.com/ltex-plus/ltex-ls-plus) over `jsonrpc`, which is part of Emacs, and shows the server's findings through flymake, also part of Emacs — or through [flycheck](https://github.com/flycheck/flycheck), if you prefer.

*Requires Emacs 29.1 or later and **needs no external Emacs package**. Works on Linux, macOS, and Windows.*

This package gives you professional-grade grammar checking in Emacs while you write Markdown, LaTeX, Org-mode, Magit commit messages, and more — and also checks grammar and spelling inside comments and string literals of 30+ programming languages. It runs quietly beside your existing language servers, whatever client drives them, without interfering with them. With the local backend a check takes tens of milliseconds; you get it shortly after you pause typing — see [Performance](#performance).

![LTeX+ in action](screenshot.png)
*LTeX+ in action: `C-c "` offers the server's suggestions, allowing you to choose a suitable correction (e.g., fixing "your" to "you're" in the example above). The key is `lsp-ltex-plus-actions-key`.*

**Start with `M-x lsp-ltex-plus-doctor`.** It opens one page that says which server you are running, which LanguageTool is behind it, and what every setting is set to — and then checks itself, in three languages, on paragraphs that are wrong on purpose. If grammar checking works, you see it working; if it does not, the page says what is missing. See [Start here](#start-here-m-x-lsp-ltex-plus-doctor).

For detailed information about the underlying LTeX+ server and its capabilities, please refer to the [official LTeX+ documentation](https://ltex-plus.github.io/ltex-plus/index.html).

## New to Emacs or LSP?

If you use Emacs for writing—perhaps in the humanities, social sciences, or law—rather than for programming, the term "LSP" might be new to you. Here is a simple way to understand how this works:

*   **The LSP Server (LTeX+):** This is a separate program that runs in the background on your computer. It "reads" your document as you type and identifies errors, much like the grammar checkers in Microsoft Word or Google Docs.
*   **The Client (lsp-ltex-plus):** This is the package you are looking at now. It starts the server, sends it what you write, and shows what it finds. The conversation between the two follows the Language Server Protocol, carried by a small library that is part of Emacs; nothing else needs installing on the Emacs side (see [No `lsp-mode` required](#no-lsp-mode-required)).

While this technology was originally built for programmers to find "bugs" in their code, we use it here to provide a powerful, professional-grade assistant for your writing.

## No `lsp-mode` required

Despite the name, this package does not depend on `lsp-mode`, or on any other external Emacs package. The `lsp-` prefix has two reasons, one historical and one technical:

- **Historical:** until version 0.6.0 the client was built on `lsp-mode`, and was named after it, as `lsp-mode` clients are. Since version 1.0.0 it is not: it talks to the server itself, over the `jsonrpc` library that has been part of Emacs since 27.1, and shows what it finds through flymake, also part of Emacs. The name stayed so that existing configurations and the package's MELPA identity kept working. The migration cost was surprisingly little: we added the connection, document sync and diagnostics display, which `lsp-mode` used to provide, and removed the code that patched and worked around `lsp-mode` limitations, and the package came out fewer than a hundred lines longer than 0.6.0, some three percent, now split into separate files based on their concern area. The optional flycheck checker, added on top, brings the total growth to about eleven percent.
- **Technical:** the conversation with `ltex-ls-plus` still follows the Language Server Protocol, because that is what the server speaks. LSP is the protocol; `lsp-mode` is one of several Emacs frameworks that implement it, and this client no longer needs one.

In practice: `package-install` or `straight` pulls in no external dependencies, Emacs starts as fast as before, and the client sits beside whatever else is checking your buffers, whether that is `eglot`, `lsp-mode` with another server, or nothing at all. No advice is needed: the client only uses public functions of `jsonrpc` and regular functions of stock Emacs. The previous version 0.6.0, based on `lsp-mode`, carried thirteen pieces of advice to work around `lsp-mode`. If you avoided this package because of the `lsp-mode` dependency, that reason is gone. If you used it under `lsp-mode`, [Migrating from 0.6.0](#migrating-from-060) lists what to change, and the [README of the 0.6.0 client](https://github.com/ltex-plus/emacs-ltex-plus/blob/lsp-mode/README.md) is preserved on the frozen `lsp-mode` branch for anyone who still needs it.

## Offline Privacy vs. Online Power

LTeX+ can operate in two distinct ways, depending on your needs:

1.  **Fully Offline (Default):** By default (or by setting `lsp-ltex-plus-lt-server-uri` to `nil`), the grammar checker runs entirely on your local machine. No text ever leaves your computer, making it ideal for sensitive work or when you don't have internet access.
2.  **Remote API:** You can connect to a remote LanguageTool server (like `https://api.languagetoolplus.com`) by setting the `lsp-ltex-plus-lt-server-uri` variable. This can offload the processing from your computer.

**Note on Premium Subscriptions:** If you have a paid LanguageTool Premium account, you can provide your credentials via `lsp-ltex-plus-lt-username` and `lsp-ltex-plus-lt-api-key`. While this provides access to some additional rules, many users find that the local/standard experience is already excellent and hard to distinguish from the premium service.

## Features

- **Says What It Is Doing:** `M-x lsp-ltex-plus-doctor` reports the server, the LanguageTool behind it, the connection, every setting in force and where each log goes — a bug report you can copy whole — and checks itself on deliberate mistakes in three languages, so you can see for yourself whether it works.
- **Runs Beside Anything:** Diagnostics go through flymake, whose list of backends is buffer-local and takes many. LTeX+ sits beside `texlab`, `pyright` or whatever other server you have installed — under `eglot` or `lsp-mode` alike — with no priority to arrange. Flycheck users can have the diagnostics there instead, with one setting.
- **Smart Persistence:** Words you "add to dictionary" or rules you disable are automatically saved to your Emacs directory and remembered across sessions.
- **Per-project Lists:** A project can keep its own dictionary and rule lists in its `.dir-locals.el`, merged with your global ones.
- **Highly Configurable:** Easily switch languages, enable "picky" grammar rules, or connect to a premium LanguageTool account.
- **Wide Language Support:** Pre-configured for Markdown, LaTeX, Org, RestructuredText, HTML, BibTeX, and many others.
- **Checks More Than Files:** Grammar-checks buffers with no file on disk (`*scratch*`, capture buffers) and the active input region of comint shells, REPLs, and AI agent shells — handy for composing prose into a prompt or command.
- **Programming Language Support:** Optionally checks grammar and spelling in comments of 30+ programming languages (Python, C, C++, Rust, Java, …). Disabled by default (matching LTeX+), opt-in via `lsp-ltex-plus-check-programming-languages`.
- **Lazy-loading:** Split into a tiny bootstrap file loaded at Emacs startup and the full client loaded on first use of a supported buffer, so startup time is essentially unaffected.
- **Intuitive API:** A deliberately small surface — one entry point (`lsp-ltex-plus-enable-for-modes`), a handful of commands under one prefix, and customisation variables under a consistent `lsp-ltex-plus-` prefix, so configuration is discoverable through `customize-group` or tab-completion.

## Performance

Two things happen between your keystroke and the underline: the client waits until you stop typing, then the server checks the document.

| Apple M2, `ltex-ls-plus` 19.0 | Local backend | Hosted service, Premium |
| :--- | :--- | :--- |
| The pause you leave before anything is sent | 0.5 s (`lsp-ltex-plus-idle-delay`) | the same |
| One paragraph changed, page of Org prose (3 KB) | **35 ms** | **0.2 s** |
| One paragraph changed, LaTeX document (15 KB) | **70–85 ms** | **0.2 s** |
| First check of a document, nothing cached yet | 0.5 s | 1 s |
| First checked buffer of a session | about 6 s, once: the server starts | the same |

The two middle rows measure what typing does: one paragraph edited, the rest of the document unchanged. The server keeps a paragraph cache, so only what changed is analysed again — and, with the hosted service, only what changed is sent over the network, which is why the 15 KB document costs barely more than the page. If you change nothing, nothing is sent: the buffer is sent only when an edit is waiting. Most of what the 15 KB document costs is not the changed paragraph either. Re-sending it unchanged still takes 60 ms, which is the time to send the whole document and parse it again. That cost grows with the size of the document, and raising the delay makes you pay it less often.

**The wait is the part you choose.** `lsp-ltex-plus-idle-delay` is how long after your *last* keystroke the buffer is sent, and every edit restarts it: while you type steadily nothing goes out, and a burst of typing is sent once, when it stops. That is deliberate — every send carries the whole document, because the server synchronises in full — but it means the underlines follow your pauses, not your keystrokes. Lower it for quicker feedback; raise it on a slow machine or for very large documents. There is no second delay to tune: flymake, or flycheck, draws the underlines as soon as the answer arrives.

**The check is the small part.** Locally, with the default delay, a correction appears about half a second after you stop typing, and the delay is almost all of that. The hosted service adds a network round trip for whatever changed: about 0.2 s, five times the local check. It is also far less predictable — of twenty re-checks, one took several seconds and one took nearly a minute. Network conditions and the load on the service decide, so treat that column as rough. The six seconds in the last row is the JVM starting and LanguageTool loading its language model; it happens once per session, whichever backend you use (see [Startup Delay When Opening the First Buffer](#startup-delay-when-opening-the-first-buffer)).

You can measure this yourself: `make bench` for the local figures, or `M-x lsp-ltex-plus-benchmark` in your own Emacs for the hosted ones, which need the account credentials that only your configuration has. See [`dev/benchmark.el`](dev/benchmark.el).

Nothing about the exchange is recorded by default. If you want to see it yourself, with timestamps, switch on the logging described under [Logging](#logging).

## Prerequisites

Before using this package, you need:

1.  **Emacs:** Version **29.1** or later. Tree-sitter major modes (`bash-ts-mode`, `python-ts-mode`, …) are picked up automatically when the running Emacs has them; the 30.1 ones are skipped on 29.x.
2.  **LTeX+ Language Server:** This is the core engine that performs the grammar checks. The recommended version is 18.7+. See [Server Installation](#server-installation) below on how to install it.
3.  **Java:** LTeX+ requires **Java 21** or higher. Most platform-specific releases of LTeX+ include a bundled Java runtime, so you don't necessarily need to install it separately. See [Java Runtime Configuration](#3-java-runtime-configuration) for details.
4.  **Operating system:** Linux, macOS, and Windows are fully supported.

No other Emacs package is required. `jsonrpc` and `flymake`, which the client is built on, are part of Emacs. Flycheck is optional: install it only if you want the diagnostics shown through it (see [Using flycheck instead of flymake](#using-flycheck-instead-of-flymake)).

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
- **Using System Java:** If you already have Java 21+ installed and prefer to use it, you can delete the bundled `jdk-21.x.y/` folder. In this case, ensure your `JAVA_HOME` environment variable points to your system Java or set the path in Emacs; the client passes it to the server's launcher as `JAVA_HOME`:
  ```elisp
  (use-package lsp-ltex-plus
    :custom
    (lsp-ltex-plus-java-home "/path/to/your/java/home"))
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
  Or name the directory you unpacked the release into, and the client looks in its `bin/`:
  ```elisp
  (use-package lsp-ltex-plus
    :custom
    (lsp-ltex-plus-ltex-ls-path "/path/to/ltex-ls-plus"))
  ```

- **Update PATH:** Alternatively, add the `bin/` directory of the extracted server to your system `PATH` (via your shell profile) or your Emacs `exec-path`.

## Installation (Emacs Package)

### Using MELPA

`lsp-ltex-plus` is published on [MELPA](https://melpa.org/#/lsp-ltex-plus). Once MELPA is in your `package-archives` (see [MELPA's Getting Started](https://melpa.org/#/getting-started) if it isn't), install with `M-x package-install RET lsp-ltex-plus RET`, or with `use-package`:

```elisp
(use-package lsp-ltex-plus
  :ensure t)
```

### Using straight.el

```elisp
(straight-use-package
 '(lsp-ltex-plus :type git :host github :repo "ltex-plus/emacs-ltex-plus"))
```

### Using `use-package` + `:vc` (Emacs 30+)

The built-in way to install directly from the Git repository — no `straight`, no manual `package-vc-install`:

```elisp
(use-package lsp-ltex-plus
  :vc (:url "https://github.com/ltex-plus/emacs-ltex-plus" :rev :newest))
```

### Using `package-vc-install` (Emacs 29+)

For Emacs 29, where `use-package` has no `:vc` keyword:

```elisp
(package-vc-install "https://github.com/ltex-plus/emacs-ltex-plus")
(require 'lsp-ltex-plus)
```

### Manual Installation

Download the nine `lsp-ltex-plus*.el` files — `lsp-ltex-plus-bootstrap.el`, `lsp-ltex-plus-settings.el`, `lsp-ltex-plus-conn.el`, `lsp-ltex-plus-diag.el`, `lsp-ltex-plus-flycheck.el`, `lsp-ltex-plus-actions.el`, `lsp-ltex-plus-comint.el`, `lsp-ltex-plus-doctor.el` and `lsp-ltex-plus.el` — place them in your load path, and require the main file:

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

> **Note on `:ensure t`:** The `use-package` snippets above omit `:ensure t` because the package is assumed to be already installed via one of the paths above. If you use vanilla `package.el` and have not set `use-package-always-ensure` (or an equivalent like `straight-use-package-by-default`), add `:ensure t` to make `use-package` fetch the package from your configured archives on first run.

### Customizing Supported Modes

`lsp-ltex-plus-major-modes` is the **client's registry of supported modes**. Each entry is a three-element list `(major-mode language-id programming-p)`:

- `major-mode` — the Emacs major mode symbol.
- `language-id` — a **VS Code language identifier**, the string LTeX+ uses to select the correct grammar rules and that the LSP protocol sends in `textDocument/didOpen`. The canonical list is at the [VS Code language identifiers page](https://code.visualstudio.com/docs/languages/identifiers).
- `programming-p` — `nil` for markup and writing modes (LaTeX, Markdown, Org, …), `t` for programming languages (Python, C, Rust, …). This flag controls whether the mode is checked by default or only when `lsp-ltex-plus-check-programming-languages` is enabled.

The registry serves two purposes: it tells the client which buffers to accept, and it provides the language ID to send to the server. Both are looked up when a buffer is opened on the server, so changes take effect for the next buffer without restarting the server.

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

  ;; Send the buffer to the server a little sooner after you stop typing.
  (lsp-ltex-plus-idle-delay 0.3)

  ;; Show the diagnostics through flycheck instead of flymake.  Flycheck
  ;; must be installed; without it flymake is used and a warning says so.
  ;; (lsp-ltex-plus-diagnostics-provider 'flycheck)

  ;; If you run flyspell globally, uncomment the next line to have it
  ;; switched off in the buffers LTeX+ checks: it flags macro names,
  ;; identifiers and proper nouns there, against a dictionary that is not
  ;; the one you maintain with LTeX+.  With flyspell out of the way its
  ;; own key, C-c $, is free, and it needs no Shift: a natural home for
  ;; the LTeX+ menu.  Any other key works just as well.
  ;; (lsp-ltex-plus-disable-flyspell t)
  ;; (lsp-ltex-plus-actions-key "C-c $")

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
- `lsp-ltex-plus-idle-delay`: Seconds of quiet after an edit before the buffer is sent for checking (default `0.5`).
- `lsp-ltex-plus-actions-key`: The key that opens the menu of suggestions (default `C-c "`); `nil` binds nothing.
- `lsp-ltex-plus-diagnostics-provider`: Which front-end shows the diagnostics, `flymake` (default) or `flycheck`.

For the full list of available settings, see [Customization](#customization).

## Usage

Once active, the server's findings appear as flymake diagnostics: underlines in the buffer, the message in the echo area when point is on one, and the usual `M-x flymake-show-buffer-diagnostics` list. Each message ends with the rule's id in brackets, which is what you need when deciding to disable a rule. (Under flycheck they are flycheck errors, listed by `M-x flycheck-list-errors`; see [Using flycheck instead of flymake](#using-flycheck-instead-of-flymake).)

One key does the work: `C-c "` runs `lsp-ltex-plus-actions`, which offers what the server suggests for the region, or for the diagnostic at point, and applies the one you pick. The entries run from the narrowest remedy to the broadest: the replacements first, then *Add … to dictionary*, then *Hide false positive*, which silences this one finding, then *Disable rule*, which silences every finding of its kind. (The protocol calls these code actions; here they are simply actions, since they act on the server's suggestions and have nothing to do with code.) The key is `lsp-ltex-plus-actions-key`; `C-c $` is a natural choice if you let the package switch flyspell off, and `nil` binds nothing.

Point just after a flagged word still counts as being on it, so you can type a word, notice the underline, and press `C-c "` without moving.

Everything else is called by name, since it is needed rarely:

| Command | What it does |
| :--- | :--- |
| `lsp-ltex-plus-add-to-dictionary` | Accepts the word at point into the dictionary without the menu. When both a project and the global dictionary are on offer, it still asks which. Bind it yourself if you want it on a key. |
| `lsp-ltex-plus-reload-settings` | Applies a changed setting or a hand-edited word list without restarting anything. |
| `lsp-ltex-plus-list-dictionary` | Shows the words accepted in this buffer, naming the project file where one applies. |
| `lsp-ltex-plus-restart-server` | Restarts the server, for a setting it reads only when it starts. |
| `lsp-ltex-plus-shutdown-server` | Stops the server and switches the mode off wherever it was on. |

### Toggling grammar checking in a buffer

`lsp-ltex-plus-mode` is a standard Emacs minor mode: `M-x lsp-ltex-plus-mode` toggles it on and off in the current buffer. In practice this means:

- **Disable** in a buffer where it auto-activated — for example, while you write a throwaway draft that you don't want flagged. Diagnostics disappear, the `LTeX+` mode-line lighter is removed, and running `M-x lsp-ltex-plus-mode` again re-enables it. The server keeps running for your other buffers.
- **Enable** in a buffer where automatic activation did not fire — because the major mode was filtered out by `:restrict-to` / `:exclude`, or because it is a programming language and `lsp-ltex-plus-check-programming-languages` is nil. The client starts immediately; you do not need to flip any global variable first.

If the current major mode is not yet in `lsp-ltex-plus-major-modes`, you will be prompted for a [VS Code language identifier](https://code.visualstudio.com/docs/languages/identifiers) (press `RET` to accept the default `"plaintext"`). The mode is then registered and the grammar checker starts immediately. When called from a hook rather than interactively, `"plaintext"` is used silently without prompting.

Turning the mode off affects only this client: the flymake backend is removed, or the flycheck checker deselected, and its underlines are cleared. Whatever other language server is checking the buffer keeps doing so. The mode is re-entrant — toggling it off and on repeatedly in the same buffer works cleanly.

### Using flycheck instead of flymake

Flymake is the default because it is part of Emacs and takes any number of backends per buffer. If you run [flycheck](https://www.flycheck.org/) and would rather see LTeX+ there — one error list, one set of faces, `M-x flycheck-list-errors` — choose it as the front-end:

```elisp
(setq lsp-ltex-plus-diagnostics-provider 'flycheck)
```

Flycheck 32 or later must be installed; this package does not depend on it. When flycheck is chosen but cannot be loaded, flymake is used and a warning says so, once per session. The setting is read when the mode turns on in a buffer, so a buffer already being checked keeps its front-end until you toggle the mode off and on.

With flycheck chosen, turning the mode on selects the `lsp-ltex-plus` checker as the buffer's `flycheck-checker` and turns `flycheck-mode` on if it is off; turning the mode off puts back whatever checker was selected before. Flycheck runs one checker per buffer, so a checker you also want in the same buffer — `tex-chktex` in a LaTeX file, `proselint` in Markdown — is chained after this one:

```elisp
(with-eval-after-load 'flycheck
  (flycheck-add-next-checker 'lsp-ltex-plus 'tex-chktex))
```

The checker reports what the server has already sent and asks flycheck to check again each time the server publishes, so the errors follow your edits the way the flymake underlines do, at the pace of `lsp-ltex-plus-idle-delay`. Each error's id is the rule's id, shown after the message and in the error list's ID column, which is what disabling a rule needs. The LTeX+ menu is the same under either front-end: `C-c "` opens it. `M-x flycheck-verify-setup` shows whether the checker is checking the buffer and whether the server is running.

### Checking file-less buffers

`lsp-ltex-plus-check-fileless-buffers` (enabled by default) lets temporary buffers with no associated file — `*scratch*`, capture buffers, quick drafts, and the like — be checked too. Set it to `nil` to restrict spell and grammar checking to buffers visiting a real file:

```elisp
;; Opt out: only check buffers visiting a real file.
(setq lsp-ltex-plus-check-fileless-buffers nil)
```

While enabled, a file-less buffer whose major mode is in the enabled set is checked just like a file buffer. The client gives it an identity of its own to be known by on the server; nothing is ever written to disk, and checking, suggestions, and diagnostics behave exactly as they do for real files.

A few details worth knowing:

- **Activation rules are the same as for files.** The buffer's major mode must be in the enabled set, and the programming-language gate still applies. Because `*scratch*` uses `lisp-interaction-mode` (a programming mode), it is auto-checked only when `lsp-ltex-plus-check-programming-languages` is *also* enabled — but an explicit `M-x lsp-ltex-plus-mode` in `*scratch*` always works regardless.
- **Saving to a file is seamless.** If you later save a checked file-less buffer to a real path (e.g. `C-x C-w`), it is closed under its temporary identity and re-checked as a normal file, whether or not the new name changes its major mode.

### Checking comint input (shells, REPLs, agent shells)

A `comint-mode` buffer — an inferior shell, a language REPL, or an AI agent shell such as [`agent-shell`](https://github.com/xenodium/agent-shell) — is mostly read-only output, with a single editable input region at the bottom where you type. `lsp-ltex-plus-check-comint-input` (enabled by default) grammar-checks **only that active input region**: never the command/agent output above it, and never input you have already submitted. Set it to `nil` to leave comint buffers unchecked:

```elisp
;; Opt out: don't check comint input regions.
(setq lsp-ltex-plus-check-comint-input nil)
```

This is useful when you compose prose into a shell — a prompt to an AI agent, a commit message piped to a command, a long query — and want the same spelling and grammar feedback you get in a document.

A few details worth knowing:

- **The major mode must be in the enabled set.** comint-derived modes are not enabled out of the box, so add the one you use — for example `(lsp-ltex-plus-enable-for-modes :extend-to '((agent-shell-mode "plaintext" nil)))` — or run `M-x lsp-ltex-plus-mode` in the buffer. The programming-language gate still applies to dispatcher-driven activation, but an explicit `M-x lsp-ltex-plus-mode` always works.
- **The prompt is not part of the document.** The input usually shares its line with a prompt (e.g. `OpenCode> `) that you did not type; diagnostics and corrections are positioned past it.
- **Output is never checked.** While the program is producing output — an agent streaming its reply — nothing is sent at all, so the reply is never checked as if you had typed it.
- **Multi-line input works.** Errors are flagged and corrections apply across every line of a multi-line entry.
- **Submitting clears the slate.** Once you send the input, its diagnostics are cleared and checking follows the fresh prompt.

## Customization

`lsp-ltex-plus` supports the full range of customizable parameters provided by the LTeX+ server, alongside settings specific to this Emacs client. For detailed documentation on the official LTeX+ server settings, visit the [official settings page](https://ltex-plus.github.io/ltex-plus/settings.html). LTeX+ itself is a thin LSP wrapper around the [LanguageTool Java library](https://github.com/languagetool-org/languagetool) (`languagetool-core` + per-language modules), adding document parsers (LaTeX, Markdown, BibTeX, …) and per-language client-scoped settings on top of LT's rule engine.

You can configure the parameters using `:custom` in `use-package`:

```elisp
(use-package lsp-ltex-plus
  :custom
  ;; Client-specific: keep the whole exchange with the server for inspection
  (lsp-ltex-plus-debug t)
  ;; Server-specific: Provide a custom path to the LTeX+ root directory
  (lsp-ltex-plus-ltex-ls-path "~/path/to/ltex-ls-plus-18.6.1")
  ;; Server-specific: Set the language
  (lsp-ltex-plus-language "en-GB"))
```

### Full list of supported parameters

The table below lists every parameter this Emacs client exposes. **When applied** shows when a change to the variable takes effect, and **Per project** whether it can be given its own value in a single project — both explained in the legend below the table. A cross under **Official LTeX+ Setting** or **Counterpart in LT Java Library** marks a parameter that has an equivalent at that layer: either the [`/check` HTTP parameter](https://languagetoolplus.com/http-api/) or the equivalent concept in the [Java library](https://github.com/languagetool-org/languagetool).

An empty space means the parameter has no direct counterpart at that layer: typically an Emacs-only concern (e.g., UI behaviour, mode registration) or an LTeX+-only feature (e.g., user custom dictionaries for individual languages).

| Parameter | When applied | Per project | Description | Official LTeX+ Setting | Counterpart in LT Java Library |
| :--- | :---: | :---: | :--- | :---: | :---: |
| `lsp-ltex-plus-ls-plus-executable` | R |  | The name or path of the ltex-ls-plus executable. A bare name is looked for under the `bin` of `lsp-ltex-plus-ltex-ls-path`, then on `exec-path`. *Type:* string; *default:* `"ltex-ls-plus"`. | | |
| `lsp-ltex-plus-require-minimum-server-version` | R |  | When non-nil (the default), stop the server if it reports a version older than 18.7.0, or none at all, and say why. Set to nil to keep using it; the warning still appears. Allowed, but not encouraged — some features will not work. *Type:* boolean; *default:* `t`. | | |
| `lsp-ltex-plus-debug` | L |  | When non-nil, log the client's steps — which buffers it checked, which it skipped and why, the documents it opened, the diagnostics it kept or dropped — to `*lsp-ltex-plus log*`. That is all it does; the three records below have their own settings. *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-events-buffer-size` | R |  | Characters of the exchange with the server kept in the `*ltex-ls-plus events*` buffer, handed straight to `jsonrpc` (which measures with `buffer-size`). `0` records nothing, a positive number is useful to watch the conversation and its latency, `nil` is jsonrpc's own default of no limit. *Type:* integer or `nil`; *default:* `0`. | | |
| `lsp-ltex-plus-events-buffer-format` | R |  | How much of each message that buffer gets: `short` is one line per message, `full` adds its JSON. Ignored on Emacs 29, whose `jsonrpc` takes no format. *Type:* `short` or `full`; *default:* `short`. | | |
| `lsp-ltex-plus-server-log-file` | R |  | A file for the server to tee the whole exchange and its own log into, through its `--log-file` option. `${PID}` is replaced by the server's process id. A maintainer's instrument — see [Logging](#logging). *Type:* file name or `nil`; *default:* `nil`. | | |
| `lsp-ltex-plus-major-modes` | A† |  | List of `(major-mode language-id programming-p)` triples driving client activation. *Type:* list; *default:* ~80 entries covering markup and programming modes (defined in `lsp-ltex-plus-bootstrap.el`). | | |
| `lsp-ltex-plus-actions-key` | L |  | Key that opens the menu of suggestions, `lsp-ltex-plus-actions`. Changing it through Customize rebinds at once. *Type:* key description or `nil` for no binding; *default:* `"C-c \""`. | | |
| `lsp-ltex-plus-idle-delay` | L | X | Seconds of quiet after an edit before the buffer is sent to the server. Every edit restarts the wait. *Type:* number; *default:* `0.5`. | | |
| `lsp-ltex-plus-check-programming-languages` | A | X | When non-nil, enable grammar checking in comments of programming languages (disabled by default, matching LTeX+). *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-check-fileless-buffers` | A | X | When non-nil, also check buffers with no backing file (e.g. `*scratch*`, capture buffers). See [Checking file-less buffers](#checking-file-less-buffers). *Type:* boolean; *default:* `t`. | | |
| `lsp-ltex-plus-disable-flyspell` | A | X | When non-nil, turning the mode on in a buffer where `flyspell-mode` is active switches flyspell off, and turning the mode off brings it back — only where this package stopped it. A reminder for anyone running flyspell globally: in a document LTeX+ checks, flyspell flags macro names, identifiers and every proper noun the system dictionary lacks, and its dictionary is not the one you maintain here. *Type:* boolean; *default:* `nil`. | | |
| `lsp-ltex-plus-diagnostics-provider` | A | X | Which front-end shows the server's diagnostics: `flymake` (default, part of Emacs) or `flycheck`, which must be installed; if it is chosen but cannot be loaded, flymake is used and a warning says so once. See [Using flycheck instead of flymake](#using-flycheck-instead-of-flymake). *Choices:* `flymake`, `flycheck`. | | |
| `lsp-ltex-plus-check-comint-input` | A | X | When non-nil, check the active input region of `comint-mode` buffers (shells, REPLs, agent shells) — only what you are currently typing, never the output or earlier input. See [Checking comint input](#checking-comint-input-shells-repls-agent-shells). *Type:* boolean; *default:* `t`. | | |
| `lsp-ltex-plus-language` | L | X | The language LanguageTool should check against (e.g. `"en-US"`, `"de-DE"`). Valid codes are listed on the [LTeX+ supported-languages page](https://ltex-plus.github.io/ltex-plus/supported-languages.html); `"auto"` attempts language detection (not recommended — no spelling). *Type:* string; *default:* `"en-US"`. | X | X |
| `lsp-ltex-plus-dictionary` | L | X | Additional words accepted as correctly spelled (language-specific). *Type:* plist; *default:* `nil`. See [External settings](#external-settings) for format and behaviour. | X | |
| `lsp-ltex-plus-enabled-rules` | L | X | Language-specific list of rules to enable. *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | X |
| `lsp-ltex-plus-disabled-rules` | L | X | Language-specific list of rules to disable. *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | X |
| `lsp-ltex-plus-hidden-false-positives` | L | X | Regex-based suppression of false-positive diagnostics (language-specific). *Type:* plist; *default:* `nil`. See [External settings](#external-settings). | X | |
| `lsp-ltex-plus-project-dictionary-file` | L | X | File holding *this project's* additional accepted words, merged with (never replacing) `lsp-ltex-plus-dictionary` and the global dictionary file. Normally set from the project's `.dir-locals.el`; a relative name resolves against the directory holding that file. *Type:* `nil` or file; *default:* `nil`. See [Project-local settings](#project-local-settings). | | |
| `lsp-ltex-plus-project-enabled-rules-file` | L | X | As above, for rules this project enables. *Type:* `nil` or file; *default:* `nil`. | | |
| `lsp-ltex-plus-project-disabled-rules-file` | L | X | As above, for rules this project disables. *Type:* `nil` or file; *default:* `nil`. | | |
| `lsp-ltex-plus-project-hidden-false-positives-file` | L | X | As above, for false positives this project hides. *Type:* `nil` or file; *default:* `nil`. | | |
| `lsp-ltex-plus-save-additions-to` | L | X | Where an accepted suggestion (*Add to dictionary*, *Disable rule …*, *Hide false positive …*) is written. Never affects what is *read* — a document is always checked against both lists. *Choices:* `either-allowing-user-choice` (default), `per-project-when-specified`, `globally-defined`. See [Project-local settings](#project-local-settings). | | |
| `lsp-ltex-plus-bibtex-fields` | L | X | BibTeX fields whose values are to be checked. *Type:* alist of `(field-name . boolean)`, where field-name is a symbol; *default:* `nil`. | X | |
| `lsp-ltex-plus-latex-commands` | L | X | LaTeX commands to be handled by the LaTeX parser, listed with empty arguments. *Type:* alist of `(command . action)`, where command is a symbol (not a string) with the initial backslash doubled, e.g. `\\ref{}`, `\\documentclass[]{}`; action is `"default"`, `"ignore"`, `"dummy"`, `"pluralDummy"`, or `"vowelDummy"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-latex-environments` | L | X | LaTeX environments to be handled by the LaTeX parser. *Type:* alist of `(env-name . action)`, where env-name is a symbol and action is `"default"` or `"ignore"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-markdown-nodes` | L | X | Markdown node types to be handled by the Markdown parser. *Type:* alist of `(node-type . action)`, where node-type is a symbol and action is `"default"`, `"ignore"`, `"dummy"`, `"pluralDummy"`, or `"vowelDummy"`; *default:* `nil`. | X | |
| `lsp-ltex-plus-additional-rules-enable-picky-rules` | L | X | Enable LanguageTool rules marked as picky (e.g. passive voice, sentence length) at the cost of more false positives. *Type:* boolean; *default:* `nil`. | X | X |
| `lsp-ltex-plus-additional-rules-mother-tongue` | L | X | Optional mother tongue of the user (e.g. `"de-DE"`). When set, enables false-friend detection (picky rules may additionally need to be enabled). *Type:* `nil` or string; *default:* `nil` (disabled). | X | X |
| `lsp-ltex-plus-additional-rules-language-model` | L | X | Optional path to a directory with n-gram language models (parent directory containing per-language subfolders). *Type:* `nil` or string; *default:* `nil` (disabled). | X | X |
| `lsp-ltex-plus-lt-server-uri` | L | X | Base URI for the LanguageTool HTTP server. Must be a bare host — the server appends `/v2/check`. *Type:* `nil` for local built-in (default) or a string URI such as `"https://api.languagetoolplus.com"`. | X | |
| `lsp-ltex-plus-lt-username` | L | X | Username/email for LanguageTool Premium API access. Only relevant when `lsp-ltex-plus-lt-server-uri` is set. *Type:* `nil` or string; *default:* `nil`. | X | X |
| `lsp-ltex-plus-lt-api-key` | L | X | API key for LanguageTool Premium API access. Only relevant when `lsp-ltex-plus-lt-server-uri` is set. *Type:* `nil` or string; *default:* `nil`. | X | X |
| `lsp-ltex-plus-ltex-ls-path` | R |  | Path to the root directory of ltex-ls-plus (contains `bin` and `lib` subdirectories); its `bin` is searched for the executable. *Type:* `nil` or string; *default:* `nil` (use the executable found on `PATH`). | X | |
| `lsp-ltex-plus-ltex-ls-log-level` | R |  | Logging level (verbosity) of the ltex-ls-plus server log. *Choices* (descending verbosity): `"severe"`, `"warning"`, `"info"`, `"config"`, `"fine"` (default), `"finer"`, `"finest"`. | X | |
| `lsp-ltex-plus-java-home` | R |  | The Java installation to start the server with — exactly what you would put in `JAVA_HOME`, and what the launcher is given. Unset, the server inherits the `JAVA_HOME` Emacs itself has, and failing that uses the `java` on the path, often the runtime bundled with the server. Renamed from `lsp-ltex-plus-java-path` in 1.1.0; the old name still works. *Type:* `nil` or string; *default:* `nil`. | X | |
| `lsp-ltex-plus-java-initial-heap` | R |  | Initial size of the Java heap in megabytes, passed to the launcher as `-Xms` when set. *Type:* `nil` or integer; *default:* `nil` (the JVM decides). | | |
| `lsp-ltex-plus-java-max-heap` | R |  | Maximum size of the Java heap in megabytes, passed to the launcher as `-Xmx` when set. Left unset, the JVM takes a quarter of the machine's memory, which is ample; a fixed cap is for machines where that is too much, and 512 is too little for two languages at once. *Type:* `nil` or integer; *default:* `nil` (the JVM decides). | | |
| `lsp-ltex-plus-sentence-cache-size` | R |  | Size of the LanguageTool `ResultCache` in sentences. The default and recommended value `0` disables the local LanguageTool server's own cache entirely: ltex-ls-plus keeps its own per-paragraph cache (see `lsp-ltex-plus-paragraph-cache-enabled`), which supersedes LanguageTool's caching. Use a positive value to turn it back on, but be aware that for the edit loop this is redundant and only adds CPU and memory overhead with no additional benefit. To restore LanguageTool's caching instead, set this positive and also set `lsp-ltex-plus-paragraph-cache-enabled` to nil. *Type:* integer; *default:* `0`. | X | X |
| `lsp-ltex-plus-max-request-size` | L | X | Largest amount of text, in characters, sent to LanguageTool in a single request when a run of changed paragraphs is batched together (typically the first, whole-document check). Text exceeding this is split across several requests; an individual paragraph is never split. The default fits within the [per-request character limit](https://languagetool.org/http-api/) of the free remote service; if you use a local server (`lsp-ltex-plus-lt-server-uri` is nil) or have a Premium account, consider raising it to 60000. *Type:* integer; *default:* `20000`. | X | |
| `lsp-ltex-plus-paragraph-cache-ttl-minutes` | L | X | How long, in minutes, a document's cached results are kept after they stop being used, before a background sweep drops them. The actively edited file always stays warm, and a document's cache is cleared immediately when the file is closed. *Type:* integer; *default:* `30`. | X | |
| `lsp-ltex-plus-paragraph-cache-enabled` | L | X | Whether ltex-ls-plus reuses cached results for unchanged paragraphs so an edit only re-checks the paragraphs that changed. Set to nil to disable result reuse (not recommended) — every paragraph is re-checked on each pass. Paragraphs are still sliced and batched into requests, just never stored or served from the cache. *Type:* boolean; *default:* `t`. | X | |
| `lsp-ltex-plus-completion-enabled` | L | X | Whether the server offers word completion. Not available in 1.0.0, planned for a future release; the setting has no visible effect until then. *Type:* boolean; *default:* `nil`. | X | |
| `lsp-ltex-plus-diagnostic-severity` | L | X | Severity of the diagnostics; it decides the flymake type, or flycheck level, the underline gets. *Choices:* `"error"`, `"warning"` (default), `"information"`, `"hint"`. | X | |
| `lsp-ltex-plus-check-frequency` | L | X | Controls when documents should be checked. *Choices:* `"edit"` (default, after every pause in typing), `"save"` (on open and save), `"manual"` (explicit commands only). | X | |
| `lsp-ltex-plus-clear-diagnostics-when-closing-file` | L | X | Whether to clear diagnostics when a file is closed. *Type:* boolean; *default:* `t`. | X | |

> **"Per project" legend:** **X** means the setting can be given its own value in one project through a `.dir-locals.el`, which this client honours because it answers the server's configuration requests from the buffer holding the document being checked (see [Project-local settings](#project-local-settings)). A blank means the value is read once — at server start or when the mode is turned on — so a project-local value would have nothing to act on.
>
> **"When applied" legend:**
>
> - **L** — *Live*: read by the client at the moment it is needed — on every `workspace/configuration` pull, which the server issues before each check, or (for `lsp-ltex-plus-save-additions-to`) at the moment you accept a suggestion, or (for `lsp-ltex-plus-idle-delay`) at each edit. A plain `setq` is honoured straight away — no manual notification, no restart.
> - **R** — *Requires server restart*: the server reads the value when it starts. Change the variable, then run `M-x lsp-ltex-plus-restart-server` for it to take effect.
> - **A** — *Activation-time*: read when `lsp-ltex-plus-mode` turns on in a buffer — neither on every check nor once at setup. A buffer already being checked keeps the value it started with; newly opened buffers, and ones where you toggle the mode off and on again, see the new one. No reload or restart is involved. If you changed the value in a `.dir-locals.el`, revert the buffer instead (`M-x revert-buffer`; Emacs 28 and later also bind `C-x x g` to `revert-buffer-quick`): toggling the mode re-reads the variable but not the file it came from.
>
> **†** on `lsp-ltex-plus-major-modes` — this is a registry, not a customization knob. It is listed here for reference because the client reads from it, but users should not mutate it directly. To adjust which modes the dispatcher activates on, call `lsp-ltex-plus-enable-for-modes` with its `:restrict-to`, `:exclude`, and `:extend-to` keyword arguments (see [Customizing Supported Modes](#customizing-supported-modes)).

Six settings from earlier releases only meant something while the client ran on `lsp-mode` and no longer exist; [Migrating from 0.6.0](#migrating-from-060) lists them with where their function went.

### External settings

Alongside the in-Emacs parameters above, `lsp-ltex-plus` relies on four pieces of **persistent configuration** on disk, which survive across Emacs sessions. Each of them has a defcustom counterpart so you can seed it declaratively from `:custom`. Three of the four (all except `enabled-rules`) also grow at runtime when you accept a suggestion on a flagged diagnostic (`C-c "`, `lsp-ltex-plus-actions`) — *Add to dictionary*, *Disable rule …*, or *Hide false positive …*.

Each file is a per-language plist under `~/.emacs.d/lsp-ltex-plus/`, with language keys (`:en-US`, `:de-DE`, …) mapped to vectors of strings. Settings provided via `:custom` and via the file are kept separate: the defcustom settings are never mutated, and they are never written to disk. The server sees their merge.

Accepting a suggestion updates the relevant file and notifies the server, so the change takes effect on the next check without a restart. Which file they update depends on `lsp-ltex-plus-save-additions-to` once a project keeps lists of its own — see [Project-local settings](#project-local-settings) below.

| File (under `~/.emacs.d/lsp-ltex-plus/`) | `:custom` variable (defcustom) | Written by a suggestion? | Provenance |
| :--- | :--- | :---: | :---: |
| `stored-dictionary.eld` | `lsp-ltex-plus-dictionary` | yes | **LTeX+ only** |
| `enabled-rules.eld` | `lsp-ltex-plus-enabled-rules` | no | LanguageTool |
| `disabled-rules.eld` | `lsp-ltex-plus-disabled-rules` | yes | LanguageTool |
| `hidden-false-positives.eld` | `lsp-ltex-plus-hidden-false-positives` | yes | **LTeX+ only** |

The `.eld` extension is the Emacs convention for `prin1`-serialised Lisp data; opening one of these files (from Emacs or your OS file manager) gets `lisp-data-mode` automatically. Earlier versions of `lsp-ltex-plus` wrote the external files by default without an extension; if you upgraded from such an older version, these files will be renamed automatically the first time `lsp-ltex-plus` is loaded — no action required. If you customized the filenames, rename them to use the `.eld` extension.

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

Hand-editing the file is supported; afterwards run `M-x lsp-ltex-plus-reload-settings` (see [Inspecting and editing](#inspecting-and-editing)) or restart Emacs to pick up the change.

#### What each one is for

**Dictionary** — a per-language list of additional words that should be accepted as correctly spelled. Grown at runtime by the *Add to dictionary* suggestion, and "seedable" from `:custom`. For large hand-curated word lists, prefer editing the on-disk file directly (see [Inspecting and editing](#inspecting-and-editing) below) rather than stuffing everything into `:custom`.

The dictionary is an **LTeX+ feature**, not a LanguageTool one. The `/check` HTTP endpoint exposed by LanguageTool has no `dictionary` parameter, and the personal-dictionary APIs offered to LanguageTool Premium subscribers live on a separate set of endpoints that `ltex-ls-plus` does not use. Instead, LTeX+ applies the dictionary locally. This means the following: for LanguageTool's rules pertaining to orthography errors (`MORFOLOGIK_RULE_*`, `HUNSPELL_*` and, for LT premium users, `*ORTHOGRAPHY*`), LTeX+ checks whether the listed words occur in the user's dictionary, and if so, it prevents the resulting diagnostics from being sent on to Emacs. This works identically for both the embedded local LanguageTool and the remote `lsp-ltex-plus-lt-server-uri`, since the dictionary filter runs in the LTeX+ server `ltex-ls-plus` either way.

**Enabled / disabled rules** — the **coarsest-grained** control you have over what LanguageTool checks. A rule (e.g. `OXFORD_SPELLING_NOUNS`, `UPPERCASE_SENTENCE_START`, `EN_QUOTES`) either fires for every match in every document of that language, or it doesn't. Disabling a rule turns it off globally for its language; enabling a rule re-activates one that would otherwise be off (e.g. a *picky* rule, or a rule a user-level config previously disabled). These are **LanguageTool-level** settings — both the locally-embedded LanguageTool inside `ltex-ls-plus` and the hosted [LanguageTool HTTP API](https://languagetoolplus.com/http-api/) honour them (via the `enabledRules` / `disabledRules` query parameters). LTeX+ just exposes them per-language.

`disabled-rules` also grows at runtime via the *Disable rule* suggestion; `enabled-rules` has no such writer (there is no "Enable rule" suggestion for a flagged diagnostic) and is populated strictly from your `:custom` value and/or hand-edits to the file.

**Hidden false positives** — the **finest-grained** control, and a feature unique to LTeX+ ([documented here](https://ltex-plus.github.io/ltex-plus/advanced-usage.html#hiding-false-positives-with-regular-expressions)). Each entry pairs a rule ID with a regular expression matched against the diagnostic's surrounding text. Matches are directly suppressed inside `ltex-ls-plus`, before diagnostics reach Emacs. This lets you hide one false positive without turning the rule off: only the phrasing you marked as correct stops being flagged, and the rule keeps catching real problems elsewhere in your prose. This lives entirely outside LanguageTool's own API and has no counterpart in hosted LanguageTool. The plist `hidden-false-positives` grows at runtime via the *Hide false positive* suggestion; it can also be populated from `:custom` with false-positive patterns you always want suppressed.

#### Rules vs. hidden false positives — which should I use?

- If a rule produces *only* noise for your writing style, **disable the rule** — it's faster, cheaper, and covers everything.
- If a rule is usually right but wrong on one recurring phrase or idiom, **hide the false positive** — the rule keeps working everywhere else, and only that specific text stops being flagged.

#### Project-local settings

Everything above describes lists that follow you everywhere. A project can also keep its **own** lists — the jargon of one book, the rule you only silence in one repository — beside your global ones, without either shadowing the other.

Point one or more of the four project settings at a file from the project's `.dir-locals.el`:

```elisp
;; .dir-locals.el at the root of your project
((nil . ((lsp-ltex-plus-project-dictionary-file . ".ltex/dictionary.eld")
         (lsp-ltex-plus-project-disabled-rules-file . ".ltex/disabled-rules.eld"))))
```

The files use the same plist format as the global ones, and each is optional: configure only a dictionary and the project collects words while your global rule choices stay global.

**Both lists are read; neither wins.** A word you accepted everywhere stays accepted inside the project, and the project's own words are added on top. The project settings decide what a project *adds*, never what it takes away.

**A relative name resolves against the directory holding the `.dir-locals.el` that set it** — not against the file being checked. Every document in the project therefore agrees on one location however deep it sits, and moving or renaming the project moves the setting with it. There is no separate notion of a "project root": `.dir-locals.el` already decides which files a setting governs, so Emacs' own rules apply, nested projects included. Buffers with no file at all — `*scratch*`, comint input — have no directory-local variables and so use your global lists alone.

**A `.dir-locals.el` edit does not reach buffers you already have open.** Emacs reads that file when it visits a file, so an open buffer keeps whatever was in force when you opened it — however you changed the setting afterwards, and whatever the **When applied** column says. Revert the buffer (`M-x revert-buffer`; Emacs 28 and later also bind `C-x x g` to `revert-buffer-quick`) or simply reopen the file; either re-reads the directory-local values and re-activates the mode. `M-x lsp-ltex-plus-reload-settings` will not do it, since it reloads this package's own state rather than Emacs' view of your project.

**Where new entries go** is `lsp-ltex-plus-save-additions-to`. By default (`either-allowing-user-choice`) each such suggestion appears twice in the menu — *Add 'foo' to project dictionary* beside *Add 'foo' to global dictionary*, and likewise *Disable rule for this project* beside *Disable rule globally*. You pick as you accept, and the entry goes to exactly one of them, never both. If you always want the same one, set `per-project-when-specified` to use the project's file whenever it keeps one for that kind of entry, or `globally-defined` to keep writing to your own files, leaving the project's list to be edited by hand.

None of this applies to a project that keeps no lists of its own: there is nowhere else to write, so every value saves to your own files and no extra suggestion appears.

Because this is an ordinary setting, a single project can depart from your usual habit by setting it in its own `.dir-locals.el`.

**On confirmation prompts.** Emacs asks before applying a directory-local variable unless the package has vouched for the value, and this package vouches for everything marked **X** in the parameter table, so a project's `.dir-locals.el` normally just works.

Two are qualified, for safety. `lsp-ltex-plus-lt-server-uri` names the host every document is sent to, so only leaving it unset (the built-in checker) or selecting LanguageTool Premium applies silently; any other host asks. And the four project *file* settings, which this package writes to, apply silently only for a relative path free of `..` — one that cannot lead outside the project. Absolute paths still work in both cases; Emacs just asks first.

#### Inspecting and editing

- `M-x lsp-ltex-plus-list-dictionary` — prints the words in force for the current buffer: the global list (the union of `:custom` and the file contents) with this project's dictionary folded in where it keeps one, naming the project file so an unexpected word can be traced to its source.
- `M-x lsp-ltex-plus-reload-settings` — the one command for making a configuration change take effect. It re-reads all four files and tells the running server the configuration changed, so it fetches its settings again on the next check; your `:custom` values are merged in when the server asks, so they need no reload of their own. Convenient for bulk edits: open any of the four files under `~/.emacs.d/lsp-ltex-plus/` in a buffer, edit entries across one or more languages, save, then run this command. Also the right command to run after changing an `lsp-ltex-plus-*` defcustom in a live session — it pushes the new value to the server without an Emacs restart. Settings the server reads only when it starts (marked **R** above) need `M-x lsp-ltex-plus-restart-server` instead.
- The four files are plain Emacs plists. After hand-editing, either run the reload command above or restart Emacs to pick up the change.

#### Pro tip: per-file overrides with magic comments

For tweaks that only make sense in a single document, LTeX+ supports **magic comments** — file-local directives that override settings for the rest of the file. Two of them map directly onto the external settings above:

- **Rules:** `rules+=RULE_ID` enables a rule for this file, `rules-=RULE_ID` disables it, and `rules#=RULE_ID` reverts the rule to the global setting.
- **Dictionary:** `dictionary+=Word` accepts a word for this file, `dictionary-=Word` removes one that the global dictionary would accept.

The comment syntax depends on the file's language — e.g. `% LTeX: rules-=EN_QUOTES` in LaTeX, `<!-- LTeX: rules-=EN_QUOTES -->` in Markdown, `# LTeX: rules-=EN_QUOTES` in Org-mode. See the [LTeX+ magic-comments documentation](https://ltex-plus.github.io/ltex-plus/advanced-usage.html#magic-comments) for the full syntax table and the other settings they can change (language, picky rules, LaTeX/Markdown parser tweaks, …).

**No per-file support for hidden false positives.** Magic comments cover rules and the dictionary, but not `hiddenFalsePositives` — if you need file-local false-positive suppression, there is no upstream mechanism for it. Use `:custom` or the `hidden-false-positives.eld` file for a global suppression, or disable the offending rule for the file instead.

## Migrating from 0.6.0

Version 1.0.0 replaced `lsp-mode` with the `jsonrpc` library bundled with Emacs (see [No `lsp-mode` required](#no-lsp-mode-required)). The settings that describe *what* to check are unchanged, and so are the word-list files; what changed is what surrounds the client. Go through your configuration once with this list. The old client itself, with its README, is preserved unchanged on the [`lsp-mode` branch](https://github.com/ltex-plus/emacs-ltex-plus/blob/lsp-mode/README.md).

- **`lsp-mode` is no longer needed.** If you installed it only for LTeX+, you can remove it. Anything you set in `lsp-mode` for this client's sake — an entry in `lsp-disabled-clients`, a language-id tweak in `lsp-language-id-configuration`, an `lsp-diagnostics-provider` choice — can go as well; none of it is read.
- **One key binding.** `lsp-mode` bound the code actions under its own prefix, `C-c l a a`. The menu is now `lsp-ltex-plus-actions` on `C-c "`, set with `lsp-ltex-plus-actions-key`; everything else is called by name (see [Usage](#usage)).
- **Diagnostics come through flymake.** Under `lsp-mode` they went through flycheck when it was installed. Anything you tuned in flycheck for LTeX+ no longer applies; flymake needs nothing configured.
- **One knob for responsiveness.** `lsp-idle-delay`, `flycheck-idle-change-delay` and `lsp-debounce-full-sync-notifications-interval` used to decide, between them, how soon after typing the buffer was checked. `lsp-ltex-plus-idle-delay` (default 0.5 s) replaces all three.
- **Six settings are gone.** Setting one does nothing any more; delete each line:
  - `lsp-ltex-plus-apply-kind-first-patch` patched `lsp-mode`'s message router; the `jsonrpc` library routes correctly and there is nothing to patch.
  - `lsp-ltex-plus-multi-root` asked `lsp-mode` to reuse one server across projects; that is now simply how the connection works — one `ltex-ls-plus` per Emacs session.
  - `lsp-ltex-plus-show-progress` silenced an `lsp-mode` spinner the client no longer has.
  - `lsp-ltex-plus-show-latency` measured round trips through advice on `lsp-mode` internals. The `*ltex-ls-plus events*` buffer timestamps every message instead, and `make bench` measures the round trip directly (see [Performance](#performance)).
  - `lsp-ltex-plus-server-input-log` and `lsp-ltex-plus-server-output-log` named two `tee` log files under `/tmp`, one per direction. `lsp-ltex-plus-server-log-file` replaces both with one file, written by the server itself and holding both directions plus the server's own log (see [Logging](#logging)).
- **Server commands.** `M-x lsp-workspace-restart` becomes `M-x lsp-ltex-plus-restart-server`, and `M-x lsp-ltex-plus-shutdown-server` stops the server outright. `lsp-ltex-plus-reload-settings` works as before and tells the running server the configuration changed.
- **Debugging.** `lsp-ltex-plus-debug` puts the client's own steps in `*lsp-ltex-plus log*`; the server's Java log is in `*ltex-ls-plus stderr*`; the messages exchanged with the server are recorded only if you ask for them, with `lsp-ltex-plus-events-buffer-size`. See [Logging](#logging). `lsp-log-io` and the `*lsp-log*` buffer play no part.
- **Word lists need no migration.** The four plist files under `~/.emacs.d/lsp-ltex-plus/` are read as before, and your `:custom` lists and project `.dir-locals.el` entries mean what they meant.
- **Three old command names are gone.** `lsp-ltex-plus-install-hooks` (renamed in 0.2.0) is `lsp-ltex-plus-enable-for-modes`; `lsp-ltex-plus-reload-external-settings` (0.3.1) and `lsp-ltex-plus-reload-and-notify-server` (0.5.0) are both `lsp-ltex-plus-reload-settings`. The aliases that kept them working are removed; a configuration still calling one gets an error naming the missing function.
- **Word completion is not available in 1.0.0.** It is planned for a future release; see [Word Completion](#word-completion).

## Troubleshooting

All variables mentioned below are standard Emacs customization options. If you use `use-package`, it is recommended to set them within the `:custom` block of your configuration.

### Start here: `M-x lsp-ltex-plus-doctor`

One buffer that answers *is LTeX+ working, and with what?* The report names the server binary Emacs found, the version that server reports and the version number compared against the minimum, which LanguageTool is behind it — the bundled one or a server over the network, with whether an account is configured (said, never shown) — whether the connection is up and which buffers it is checking, the settings every check is made with, which logs are switched on, and the Emacs, `jsonrpc` and `lsp-ltex-plus` versions. Copy the whole buffer with `C-x h M-w` and you have a bug report.

Below the report the doctor checks itself, under an `* Examples` heading. Three paragraphs follow, each one wrong on purpose and each checked in its own language; the line above each paragraph is a [magic comment](https://ltex-plus.github.io/ltex-plus/advanced-usage.html#magic-comments) that sets the language for the text below it and adds the name `LTeX` to the dictionary of that language, so the package's own name is not underlined in its own examples:

```org
# LTeX: enabled=true language=en-US dictionary+=LTeX
** English (en-US, your language)
  Are you tired of silly spellling mistakes in you're notes? Find them
  here, not in the commit message that outlives the code, or the email
  you just sent to fourty people.

  Success: spelling mistakes were detected in this paragraph.

# LTeX: language=fr-FR dictionary+=LTeX
** French
  Fatigué des fautes d'ortographe dans vos notes ? Autant les trouver
  ici que dans le courriel que vous venez d'envoyer a quarante personnes.

  Success: spelling mistakes were detected in this paragraph.

# LTeX: language=de-DE dictionary+=LTeX
** German
  Müde von dummen Rechtschreibfelern in Ihren Notizen? Besser hier
  gefunden als in der Commit-Nachricht, die unwiederruflich in der
  Historie bleibt.

  Success: spelling mistakes were detected in this paragraph.
```

Those two magic-comment settings are worth copying into your own documents — a language for one file, a word for one language's dictionary — and the doctor is a working example of both.

The line under each paragraph is the verdict for that paragraph, coloured like a traffic light: green (`success`) once mistakes have come back, amber (`warning`) while the check is still out — the normal state of a cold server for a few seconds — and red (`error`) for a check that failed or was never sent. Named faces, never colours, so your theme decides what each one looks like. No count is given — how many mistakes come back depends on the LanguageTool behind the server, since a Premium account or your own LanguageTool server finds mistakes the bundled one does not. The verdict is an overlay, not text, so nothing the doctor displays is part of the document being checked.

**A paragraph never goes quiet to mean "nothing wrong"**, because every sample is wrong on purpose: after thirty seconds with no answer the verdict becomes `No answer after 30 seconds: the server may have run out of memory while loading this language`, which names `lsp-ltex-plus-java-max-heap` as the setting to raise. LTeX+ checks the whole buffer in one go, so a language used for the first time keeps every heading waiting while the server loads a language model — a few seconds.

Keys in the doctor buffer: `g` writes the report again, `r` restarts the server, `v` shows or hides the setting behind each value, `q` buries the buffer. Each value names its setting — `Idle delay :: 0.5 s (lsp-ltex-plus-idle-delay)` — but the name is hidden until you press `v`, so the report reads as answers rather than as variables.

Run it inside a project and the report is that project's: the doctor applies the directory-local settings of the directory it was called from, so a `.dir-locals.el` naming another language is both what the report shows and what the samples are checked with.

**The report is read-only; the examples are not.** Those single letters are the report's keys, and in the examples they type themselves, so the samples stay editable: break them further, write your own sentence, and watch what comes back. `C-c "` opens the suggestions menu on the mistake at point and applies a replacement there — which makes this buffer the place to learn the menu before using it on your own writing. To check a fourth language, add an entry to `lsp-ltex-plus-doctor-samples`.

### Server Not Found

If Emacs cannot find the `ltex-ls-plus` binary, turning the mode on says so and names the setting to fix. Ensure the binary is in your system `PATH`; you can verify this within Emacs by evaluating:

```elisp
(executable-find "ltex-ls-plus")
```

If it returns `nil`, add the binary's directory to your `PATH`, provide the absolute path to the executable via `lsp-ltex-plus-ls-plus-executable`, or name the directory you unpacked the release into in `lsp-ltex-plus-ltex-ls-path`. See [Server Installation](#4-make-it-discoverable) for details.

### Server Too Old After a Package Update

Updating the Emacs package can leave you with an `ltex-ls-plus` that predates
it. When that happens, `lsp-ltex-plus` says so and stops the server rather
than running against one it was not written for:

```
[lsp-ltex-plus] This ltex-ls-plus gave no version, so it predates 18.7.0, the
first release that reports one; this package needs 18.7.0 or newer. Stopping
the server.  See … , or set `lsp-ltex-plus-require-minimum-server-version' to
nil to keep using it.
```

(A server that does report a version below a future floor is named with it
instead: "ltex-ls-plus 18.7.0 is older than …".)

Updating the server is the real answer, and [Server
Installation](#server-installation) covers it. But an old server is usually
not useless — most of what you rely on keeps working, and only the newer
features are missing — so if you are in the middle of something, you can
carry on with it and update later:

```elisp
M-: (setq lsp-ltex-plus-require-minimum-server-version nil)
M-x lsp-ltex-plus-mode
```

The second step matters: the version is checked when a server starts, so the
setting takes effect on the next connection rather than immediately. The mode
was switched off when the server was stopped, so turning it back on is what
starts a new one. There is nothing to revert, and no need to restart Emacs.

To keep the setting, put it in your configuration:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-require-minimum-server-version nil))
```

Leaving it at `nil` permanently is worth avoiding. The warning still appears
on every connection, which is deliberate: it is the reminder that the update
is still outstanding.

### Language Not Recognized

**Symptom:** No diagnostics ever appear for a buffer that should be checked. The server's stderr buffer (`*ltex-ls-plus stderr*`) contains a line of the form:

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

**Fix:** Check `lsp-ltex-plus-language` against the official list and pick a code that appears there verbatim, then `M-x lsp-ltex-plus-restart-server`:

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-language "fr"))  ; NOT "fr-FR" — French has no regional variants
```

### Server Crashes or Memory Issues

The LTeX+ server runs on the Java Virtual Machine (JVM) and can be memory-intensive. If the server crashes unexpectedly or becomes unresponsive, you may need to adjust its memory allocation.

By default the JVM decides its own heap size, a quarter of the machine's memory, which is ample. Two settings, both `nil` by default, put a fixed size in its place (values in megabytes):

- `lsp-ltex-plus-java-initial-heap`: the `-Xms` Java option.
- `lsp-ltex-plus-java-max-heap`: the `-Xmx` Java option.

When set, they reach the server's launcher script as `JAVA_OPTS` when the server starts. They are placed before any `JAVA_OPTS` already in your environment, so if you set `-Xmx` there yourself, yours comes later on the command line and the JVM takes it. A change takes effect at the next `M-x lsp-ltex-plus-restart-server`.

A cap is for a machine where a quarter of memory is too much to give a grammar checker. Do not set it below what your languages need: at 512 MB the server never finishes loading a second language.

```elisp
(use-package lsp-ltex-plus
  :custom
  (lsp-ltex-plus-java-max-heap 1024))
```

While you can experiment with lower values to save system resources, be aware that setting the memory too low may result in an unstable server and frequent crashes. See [Java Runtime Configuration](#3-java-runtime-configuration) for more context.

When the server dies, the mode is switched off in every buffer it was checking and a message says so; turning the mode on again in any buffer starts a new server.

### Slow Server Response / High CPU Usage

If diagnostics take a long time to appear, the first thing to look at is `lsp-ltex-plus-idle-delay`: nothing is sent until you have stopped typing for that long. The `*ltex-ls-plus events*` buffer carries a timestamp on every message, so the time between a `didChange` going out and the `publishDiagnostics` coming back is the server's own share.

If Emacs itself feels sluggish while the mode is active, increasing the garbage collection threshold reduces the frequency of GC pauses during JSON traffic:

```elisp
(setq gc-cons-threshold 100000000) ; 100 MB
```

### Startup Delay When Opening the First Buffer

**Symptom:** The first supported buffer you open in a session is noticeably slow to get its diagnostics — several seconds — and afterwards everything is instant.

**Explanation:** `ltex-ls-plus` runs on the JVM and loads the LanguageTool model at startup, so a cold start takes non-trivial time. One server serves every buffer in the session and stays up until you stop it with `M-x lsp-ltex-plus-shutdown-server` or Emacs exits, so the cold start happens once. If it happens repeatedly, something is stopping the server — look at `*ltex-ls-plus stderr*` and the `*Messages*` buffer for the reason it went away.

### No Grammar Checking in Scratch or Anonymous Buffers

File-less buffers are checked by default — see [Checking file-less buffers](#checking-file-less-buffers). If one isn't being checked, verify that `lsp-ltex-plus-check-fileless-buffers` is non-nil (the default) and that the buffer's major mode is in the enabled set. Note that `*scratch*` uses `lisp-interaction-mode` (a programming mode), so it is auto-checked only when `lsp-ltex-plus-check-programming-languages` is also enabled; an explicit `M-x lsp-ltex-plus-mode` always works.

### Word Completion

Word completion, which 0.6.0 offered, is not available in 1.0.0. It is planned for a future release. The technical reason: in 0.6.0 the completions came through `lsp-mode`, and this client does not yet send the `textDocument/completion` request itself. The setting `lsp-ltex-plus-completion-enabled` still exists and is still sent to the server, but has no visible effect until then.

## Under the Hood

This section is for users who want to understand how `lsp-ltex-plus` works internally — useful context if you hit an unexpected issue or simply want to know what is happening behind the scenes.

### Logging

Nothing is logged by default, and each record has one setting that turns it on. A grammar checker is why: it sends the *whole document* on every pause in your typing, so a record of the exchange grows by the size of your document every few seconds, and none of it is anything a writer needs to see.

| What you want to know | Where it goes | How to turn it on |
| :--- | :--- | :--- |
| What the client decided — which buffer it checked, which it skipped and why, where an added word was saved | `*lsp-ltex-plus log*` | `lsp-ltex-plus-debug` to `t`; takes effect at once |
| Which messages are crossing the wire, and how long the server takes to answer | `*ltex-ls-plus events*` | `lsp-ltex-plus-events-buffer-size` to a positive number of characters, e.g. `200000`; `lsp-ltex-plus-events-buffer-format` says whether each line carries its JSON too. Restart the server |
| What the server thinks it is doing | `*ltex-ls-plus stderr*` | `lsp-ltex-plus-ltex-ls-log-level`; restart the server |
| **Everything**, both directions, in one file | the file you name | `lsp-ltex-plus-server-log-file`; restart the server |

The last one is a **maintainer's instrument**. It is the server's own `--log-file` option: `ltex-ls-plus` tees both sides of the conversation and its own log into the file, in order, with no help from Emacs. Turn it on when the suspicion is a bug in the conversation with the server itself — a request the server refuses, a check that never comes back, a setting that seems not to arrive — and attach the file to the report. It is not useful for anything you would do while writing, and it grows for as long as the server runs, so name a file, reproduce the problem, then set it back to `nil` and restart the server:

```elisp
(setq lsp-ltex-plus-server-log-file "/tmp/ltex-${PID}.log")  ; ${PID} is the server's, filled in by the server
(lsp-ltex-plus-restart-server)
```

A check as it appears in the events buffer: a `textDocument/didChange` goes out with the whole text; the server sends back a `workspace/configuration` request and an `ltex/workspaceSpecificConfiguration` request, both tagged with the document's URI, and the client answers each from that document's buffer; then `textDocument/publishDiagnostics` arrives, and the front-end draws it.

### How does `lsp-ltex-plus-mode` get set up and activated?

The package is split into a tiny bootstrap file and the client proper:

- **`lsp-ltex-plus-bootstrap.el`** — tiny, no dependencies. Loaded at `:init` time. Defines the major-mode alist and exposes the autoloaded entry point.
- **`lsp-ltex-plus.el`** and the files it requires — the settings, the connection, the flymake backend and the flycheck checker, the code actions, the comint region. Loaded lazily, only when a relevant buffer is first opened.

#### Setup: what happens at startup

When the package manager builds `lsp-ltex-plus`, it scans the files for `;;;###autoload` cookies and writes a single autoloads file. This registers lightweight stubs for `lsp-ltex-plus-enable-for-modes`, `lsp-ltex-plus-mode` and the commands very early at startup, before any `use-package` form is evaluated. No file is loaded yet.

When `use-package` evaluates the `:init` block and calls `(lsp-ltex-plus-enable-for-modes)`, it hits that stub, which loads `lsp-ltex-plus-bootstrap.el` (the tiny file only). The full package is **not** loaded. The function stores the effective set of enabled modes in `lsp-ltex-plus--enabled-modes` and adds a single dispatcher, `lsp-ltex-plus--maybe-activate`, to `after-change-major-mode-hook`.

#### Activation: user opens a file

```
User opens foo.md
  → markdown-mode activates → after-change-major-mode-hook fires
      → lsp-ltex-plus--maybe-activate runs
          → (memq 'markdown-mode lsp-ltex-plus--enabled-modes) → non-nil
          → lsp-ltex-plus-mode called ← hits its autoload stub
              → lsp-ltex-plus.el and the files it requires load
                  → the four word lists are read from disk
              → lsp-ltex-plus-mode body runs
                  → the front-end is attached: the flymake backend added and
                    flymake-mode turned on (or, with flycheck chosen, the checker
                    selected and flycheck-mode turned on)
                  → the buffer asks for the session's server
                      → none yet: ltex-ls-plus is started, initialize sent
                  → once initialized: configuration pushed, didOpen sent
                  → the server checks, pulls the buffer's settings, publishes
                  → the front-end shows the diagnostics
```

Every later buffer, from any project, reuses the same server: it is simply opened on it.

#### Why a single dispatcher?

An earlier design registered `lsp-ltex-plus-mode` on each selected mode's hook individually (`text-mode-hook`, `org-mode-hook`, `markdown-mode-hook`, …). It was abandoned for two reasons:

1. **Parent-mode leakage.** Emacs mode hooks inherit along the `define-derived-mode` chain. Opening an `org-mode` buffer also runs `text-mode-hook` (org derives from text via outline), so `:exclude '(org-mode)` could not actually keep the client out of org buffers as long as `text-mode` remained in the enabled set.
2. **Redundant firings.** Every parent hook in the chain ran for each buffer open, calling the minor mode multiple times per buffer — harmless but wasteful.

A grammar and spell checker is a cross-cutting tool expected to run across many writing and programming modes (the default registry ships with 80+), so the realistic baseline is a large enabled set. At that scale a single dispatcher on `after-change-major-mode-hook` that checks `(memq major-mode lsp-ltex-plus--enabled-modes)` is both the correct and the efficient choice — it fires once per mode change and matches by exact identity, so inheritance never leaks.

For users who go the other way and pick only a handful of modes with `:restrict-to`, per-mode hooks would have been roughly as efficient; the remaining advantage of the dispatcher there is purely about `:exclude` correctness when an excluded descendant mode shares a parent with an enabled one. The common situation takes precedence, hence the decision for a single dispatcher. The design stays simple: one hook, one list, exact match.

## Why this package?

Two Emacs LSP clients for LTeX already existed before this package:

- [`emacs-languagetool/lsp-ltex`](https://github.com/emacs-languagetool/lsp-ltex) — the original client, targeted at the older `ltex-ls` server.
- [`emacs-languagetool/lsp-ltex-plus`](https://github.com/emacs-languagetool/lsp-ltex-plus) — a more recent variant by the same author, with function and variable prefixes renamed and the client retargeted at `ltex-ls-plus`. From a reading of its source, the renaming is the only substantive change, so it shares the original's architecture.

Both of those are built on `lsp-mode`, and both carry the architecture of a client written for the older `ltex-ls`. This package does not depend on `lsp-mode`, or on any other external Emacs package: since 1.0.0 it speaks the protocol itself over `jsonrpc`, which is part of Emacs (see [No `lsp-mode` required](#no-lsp-mode-required)). It was written from scratch around what `ltex-ls-plus` actually does — server-initiated configuration requests, full document sync, per-language settings pulled before every check. It also does not install the server for you: you download `ltex-ls-plus` yourself and tell the package where it is (see [Server Installation](#server-installation)). That keeps the package smaller and gives it fewer ways to fail.

**Why another one?** It did not begin as an alternative. The existing clients stalled on my machines — checking would stop and never come back — and debugging them never explained why. Writing a client of my own was how I found out: the stalls traced to `lsp-mode` rather than to those packages, and the fixes I submitted for them have since been merged. At my last attempt, though, neither client was usable for me, so the experiment kept going; feature by feature it became a package in its own right, and the irony is that it no longer depends on `lsp-mode` at all. Your experience may differ. If one of the other clients works for you, please [open an issue](https://github.com/ltex-plus/emacs-ltex-plus/issues) and tell me how: I would be glad to correct what this section says, and to learn what makes them work. Even so, this package does a good deal more than they do: `M-x lsp-ltex-plus-doctor`, project-local dictionaries and rule lists, flycheck as well as flymake, checking inside comint buffers, and 80+ major modes out of the box. Try it and then decide: stay where you are if you do not need any of that, or move.

> **Note on the name collision.** The overlap with `emacs-languagetool/lsp-ltex-plus` is unintentional — I was not aware of that project when I chose the name for this one. The two packages are independent; they simply converged on the same label.

If you want to dig deeper:

- [What is New with LTeX+?](docs/what-is-new-with-ltex-plus.md)

## License

This project is licensed under the **Mozilla Public License 2.0 (MPL-2.0)**. See the `LICENSE` file for details.
