# Change Log

## [Unreleased]

### Changed
- Persistence files now use a `.eld` extension by default (`stored-dictionary.eld`, `enabled-rules.eld`, `disabled-rules.eld`, `hidden-false-positives.eld`). `.eld` is the conventional Emacs extension for `prin1`-serialised Lisp data and is mapped to `lisp-data-mode` by `auto-mode-alist`, so opening the files by hand (or via Finder/Explorer/Nautilus) gets proper highlighting. Extensionless files left over from earlier versions are renamed automatically on first startup; users who have customised the file paths to non-`.eld` values are left alone.

## [0.3.3] - 2026-05-03

### Fixed
- **Expanded protocol patches for `lsp-mode`.** The `lsp-ltex-plus-apply-kind-first-patch` toggle now applies three surgical fixes to `lsp-mode` to improve protocol robustness:
    - **Kind-First Routing**: prioritizing the `method` field over `id` to prevent deadlocks from ID collisions.
    - **Resilient Message Dispatch**: ensures that when the server sends multiple updates bundled together, an interruption in one (like typing during completion) doesn't cause the rest of the bundle to be discarded.
    - **Stale Callback Protection**: prevents synchronous requests from throwing `lsp-done` after they have already timed out or been cancelled.

## [0.3.2] - 2026-05-03

### Added
- **`ltex/workspaceSpecificConfiguration` request handler.** The client now advertises `initializationOptions.customCapabilities.workspaceSpecificConfiguration: true` and registers a handler that responds with the four merged language-keyed maps (`dictionary`, `disabledRules`, `enabledRules`, `hiddenFalsePositives`). Without this capability advertisement, ltex-ls-plus skips both `workspace/configuration` and the LTEX-custom configuration pull on each check, leaving the server with stale per-language data — initial `textDocument/didOpen` produces diagnostics, but subsequent `textDocument/didChange` notifications produce none. Mirrors the pattern used by `vscode-ltex-plus`. Per-scope (per-URI) differentiation is not yet implemented; every `scopeUri` receives the same global merged values.

### Fixed
- **Empty maps and booleans no longer serialize as JSON `null`.** The `workspace/didChangeConfiguration` push and the responses to `workspace/configuration` and `ltex/workspaceSpecificConfiguration` were emitting `null` for any setting whose Elisp value was `nil` (the empty plist). The server tolerated this, but `null` violates the protocol's expected types — booleans should be `false`, language-keyed maps should be `{}`. Two new internal helpers (`lsp-ltex-plus--obj-or-empty`, `lsp-ltex-plus--bool`) normalize these at the protocol boundary, backed by a single shared empty hash-table.

### Documentation
- New troubleshooting subsection: "Keep `lsp-completion-enable` and `lsp-ltex-plus-completion-enabled` in sync." Documents an observed but not-yet-fully-understood instability that appears when these two flags are configured asymmetrically (client-side completion on, server-side off): missing diagnostics after edits, spurious code-action polling. Recommends a buffer-local sync via the mode hook.
- Removed a stray reference to "IntelliSense" in the completion defcustom docstring.

## [0.3.1] - 2026-04-28

### Changed
- `lsp-ltex-plus-reload-external-settings` renamed to `lsp-ltex-plus-reload-and-notify-server`. The previous name described only the disk-reload half; the function also pushes the result to every running ltex-ls-plus workspace via `workspace/didChangeConfiguration`, which is what actually makes the settings take effect. The old name remains available as an obsolete alias and will be removed in a future release.

## [0.3.0] - 2026-04-28

### Added
- `lsp-ltex-plus-dictionary`: user-seeded counterpart to the runtime dictionary file, accepted as a per-language plist (`'(:en-US ["WORD1" ...] :de-DE [...])`). The package never alters this defcustom. Its contents are entirely the user's responsibility. This plist is merged with the on-disk dictionary file, and the result is sent to the server.
- `lsp-ltex-plus-hidden-false-positives`: same model as above for hidden false positives. Per-language plist of `{"rule":...,"sentence":...}` JSON strings.
- `lsp-ltex-plus-reload-external-settings` (interactive command): Re-reads the four external plist files from disk, rebuilds the merged views, and notifies every running ltex-ls-plus workspace via `workspace/didChangeConfiguration`. Useful when you edit one of the files by hand and want the change picked up without restarting Emacs.
- Support for more tree-sitter major-mode variants (`markdown-ts-mode`, `latex-ts-mode`, …). They are enabled by default; opt out via `lsp-ltex-plus-enable-for-modes` (`:exclude` / `:restrict-to`) if you don't want ltex-plus attaching to them.

### Changed
- External-settings architecture refactored. Defcustoms (`lsp-ltex-plus-dictionary`, `-enabled-rules`, `-disabled-rules`, `-hidden-false-positives`) are now strictly pristine — they are never mutated by code-action handlers. Each one has a private `-stored` variable holding the on-disk state and a `-merged` variable that the server reads. The merge is recomputed whenever either source changes. This lets users keep their hand-curated word lists in `:custom`/`init.el` without those values being clobbered or written to disk by the code actions.
- `lsp-ltex-plus-list-dictionary` now reports the merged dictionary actually in effect, not just the on-disk slice.

### Bugs fixed
- **Co-tenant LSP completion silently disabled.** `lsp-ltex-plus-buffer-setup-default` was used to set six buffer-wide `lsp-mode` variables buffer-locally on every activation, most damagingly `lsp-completion-enable nil`, which closes the gate that `lsp-configure-hook` reads to enable `lsp-completion-mode`. In any buffer where ltex-plus attached alongside another server (texlab, pyright, marksman, …), `lsp-completion-at-point` was never registered and **all** LSP completion was lost, without any diagnostic. The same shape of bug affected `lsp-enable-file-watchers`, `lsp-idle-delay`, `lsp-auto-guess-root`, `lsp-ui-sideline-enable`, and `lsp-modeline-code-actions-enable`: each is a buffer-wide setting that fans out to every co-tenant server, not a per-server flag. The function and its `lsp-ltex-plus-buffer-setup-function` defcustom have been removed. For any per-buffer tweaks, we recommend the user to follow the Emacs-idiomatic pattern by adding them directly to `lsp-ltex-plus-mode-hook`. Server-side `ltex.completionEnabled` continues to control whether ltex generates completion items.

### Documentation
- New README section dedicated to external settings (file layout, semantics, hand-editing workflow).
- Added a "pro tip" on disabling rules on a per-file basis.
- New troubleshooting entry on unrecognized language codes.
- Clarified role of `lsp-ltex-plus-major-modes` and described when each parameter is applied.
- Specifications and defaults for parameters tightened.

## [0.2.1] - 2026-04-19

### Fixed
- Code action handlers (`_ltex.addToDictionary`, `_ltex.disableRules`, `_ltex.hideFalsePositives`) errored with `Wrong type argument: hash-table-p` when `lsp-use-plists` was enabled (e.g. on Doom Emacs). Replaced direct `gethash`/`maphash` calls with abstract `lsp-get` / `lsp-map` from `lsp-protocol.el`, which pick the right accessor for whichever representation `lsp-mode` was compiled against. Reported on Reddit by TremulousTones.

## [0.2.0] - 2026-04-18

### Added
- `lsp-ltex-plus-show-latency` — echo-area benchmark of server round-trip latency (cold-start `didOpen` and warm-path `didChange` reported separately). Debug mode implicitly enables it via sticky defaults. Documented in the new `Performance` and `Measuring Server Latency` README sections.
- `lsp-ltex-plus-show-progress` — toggle to silence ltex-ls-plus progress updates in the mode line without affecting other LSP clients.
- `lsp-ltex-plus-multi-root` — on by default; a single JVM handles every folder in the session. Can be disabled for per-project isolation.
- `lsp-ltex-plus-check-programming-languages` — opt-in to grammar/spell checking in comments of 30+ programming languages (Python, C, Rust, …). Matches LTeX+'s own default (off).
- `lsp-ltex-plus-enable-for-modes` keyword arguments `:restrict-to`, `:exclude`, and `:extend-to` for filtering or extending the default mode set without mutating `lsp-ltex-plus-major-modes`.
- Add-on registration (`:add-on? t`, `:priority -1`) so the client runs concurrently with primary language servers (`texlab`, `basedpyright`, …) instead of competing for priority.
- Helpful message when the `ltex-ls-plus` binary is not on `PATH`, pointing to installation instructions.

### Changed
- Activation uses a single dispatcher on `after-change-major-mode-hook` (exact-match against the enabled-modes set) instead of per-mode hooks, eliminating parent-mode hook leakage (e.g. `text-mode` → `org-mode`).
- `lsp-ltex-plus-major-modes` entries are now 3-tuples `(major-mode language-id programming-p)`.
- Activation paths handle lsp-mode being already active for a co-tenant server (new `lsp-ltex-plus--rejoin-workspace`), piggybacking on an already-scheduled `lsp-deferred`, and the sole-client case.
- Deactivation is re-entrant and correctly scopes `textDocument/didClose`, diagnostic cleanup, and flycheck/flymake refresh to the ltex-ls-plus workspace when co-tenants are present.
- Benchmark and progress advices are installed at setup time only when their corresponding flags are on, so the package leaves no advice on `lsp-mode` internals during normal use.

### Fixed
- Explicit interactive `M-x lsp-ltex-plus-mode` calls now always proceed, regardless of `lsp-ltex-plus-check-programming-languages`, so on-demand checks work in any supported buffer.
- Dispatcher skips buffers without a file name (scratch, temporary buffers) instead of erroring.
- Removed the capability check on `workspace/didChangeWorkspaceFolders` that was forcing single-root fallback on older server builds.

### Documentation
- New README sections: `Performance` (with measured numbers and a reproducible benchmark), `Under the Hood`, and several `Troubleshooting` entries (communication stalls, cold-start delay, high memory, orphan buffers).
- Added `docs/comparison-lsp-ltex.md` (technical side-by-side) and `docs/what-is-new-with-ltex-plus.md` (upstream feature notes).
- Acknowledged the naming collision with `emacs-languagetool/lsp-ltex-plus` (independent projects that converged on the same label; the renamed variant shares `lsp-ltex`'s architecture).

## [0.1.1] - 2026-04-14

### Added
- Implemented protocol-level deadlock fix of `lsp-mode` using `advice-add` with `:override`.
- Added `lsp-core--json-get` helper to ensure the package is standalone and functional.

### Fixed
- Fixed unescaped single quotes in docstrings to resolve byte-compiler warnings.
- Fixed typos in variable names (`lsp-ltex-plus-enabledRules` -> `lsp-ltex-plus-enabled-rules`).
- Resolved "free variable" warnings in `lsp-ltex-plus--setup`.

## [0.1.0] - 2026-04-14

This is the first release of `lsp-ltex-plus` for Emacs!

### Why this package exists

Previously, the only available option was [lsp-ltex](https://github.com/emacs-languagetool/lsp-ltex). However, that package had not been updated to support the newer **plus** version of the server (`ltex-ls-plus`), and it suffered from persistent instability—at least on my setup using Emacs 31.0.50.

More importantly, I simply could not get the original package to run reliably; in fact, it rarely managed more than a few corrections before the communication with the server crashed. I spent numerous hours trying to diagnose the issue, but I couldn't find a fix. While it might work fine for others on different versions of Emacs, I found it impossible to maintain a stable workflow where the spell checker could survive more than a few edits.

To solve this, I decided to rewrite the client from scratch, specifically modernized for LTeX+. By rebuilding the entire communication chain—starting with direct command-line interrogation of the server—I was able to understand exactly how the server and client interact. This deep dive allowed me to identify and fix the underlying protocol issues described in the README. The result is a lightweight, reliable client that handles the full JSON-RPC communication without the deadlocks or crashes I encountered before.
