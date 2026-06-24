# Change Log

## [Unreleased]

### Added
- **Grammar checking in comint input regions via `lsp-ltex-plus-check-comint-input` (default `t`).** A `comint-mode` buffer — an inferior shell, a REPL, or an AI agent shell such as [`agent-shell`](https://github.com/xenodium/agent-shell) — is mostly read-only output with one editable input region at the bottom. Only that active input region is checked: never the output above it, and never input already submitted. This builds on the file-less synthetic-identity machinery (a comint buffer has no backing file) but uses a region-restricted `lsp--virtual-buffer` instead of the whole-buffer pass-through. `lsp-ltex-plus--setup-comint-buffer` anchors the region on the live process mark (`lsp-ltex-plus--comint-input-start`): its `:buffer-string` sends only the input text, and `lsp-patch-on-change-event` swaps in lsp-mode's range-aware change handlers so edits in the read-only output never produce a `didChange`. While the program is streaming output the region additionally reads as empty (keyed on `shell-maker--busy`, via `lsp-ltex-plus--comint-input-ready-p`): shell-maker inserts output at `point-max` but advances the process mark — created with insertion type nil — only afterwards, so without this gate the in-flight output would momentarily fall inside the input region and be checked. The input usually shares its line with a prompt (e.g. `OpenCode> `) that is not editable, so the first sent line is left-padded with spaces equal to the prompt width (`lsp-ltex-plus--comint-input-prompt-width`) — the checker ignores the spaces, but the columns it reports then line up with the real buffer under flycheck's line+column positioning. On submit, `lsp-ltex-plus--comint-on-submit` (on `comint-input-filter-functions`) re-syncs the now-empty region so diagnostics on the sent text clear. comint-derived modes are not enabled out of the box; add the one you use with `lsp-ltex-plus-enable-for-modes :extend-to`, or run `M-x lsp-ltex-plus-mode` in the buffer. Set the option to `nil` to leave comint buffers unchecked.

### Fixed
- **Code-action edits (e.g. "accept suggestion") now apply in file-less and comint buffers.** LTeX+ returns these fixes as a `WorkspaceEdit(documentChanges)` keyed by the document URI, and lsp-mode resolves the target buffer from that URI via `find-file-noselect`/`find-buffer-visiting`. Our synthetic `file://` URIs visit no buffer, so the edit was silently applied to a phantom temp-file buffer and never reached the real one — affecting `*scratch*` and other file-less buffers as well as comint input. A new `:around` advice on `lsp--apply-workspace-edit` (`lsp-ltex-plus--apply-workspace-edit-advice`, installed lazily the first time a synthetic buffer is set up) detects edits aimed at one of our synthetic buffers and applies them directly there with `lsp--virtual-buffer` bound, so ranges map through the buffer's own `:line/character->point`. Every non-matching edit falls straight through to the original, leaving ordinary file-backed edits untouched.

### Documentation
- **Clarified that the object-typed alist settings take symbol keys** ([#7](https://github.com/ltex-plus/emacs-ltex-plus/pull/7), thanks to [@LukeXuan](https://github.com/LukeXuan)). The docstrings and README for `lsp-ltex-plus-bibtex-fields`, `lsp-ltex-plus-latex-commands`, `lsp-ltex-plus-latex-environments`, and `lsp-ltex-plus-markdown-nodes` now state that keys are Lisp symbols, not strings — `lsp-mode` serialises these alists with `json-serialize`, which raises `wrong-type-argument symbolp` on string keys. For `lsp-ltex-plus-latex-commands` the note also explains that the leading backslash must be doubled (e.g. `\\ref{}`), because the Elisp reader treats a lone backslash as an escape, so a single-backslash symbol would read as `ref{}` and never match the command.

## [0.4.0] - 2026-06-14

### Added
- **Grammar checking in file-less buffers via `lsp-ltex-plus-check-fileless-buffers` (default `t`).** Buffers with no backing file — `*scratch*`, capture buffers, quick drafts — can now be checked, lifting the previous file-only restriction (lsp-mode's machinery is built around `file://` URIs). Each file-less buffer is given a unique synthetic `file://` URI under `temporary-file-directory` — a throwaway workspace anchor that is never read or written, only an identity — and all such buffers share a single `ltex-ls-plus` workspace so one JVM serves them all. Implementation: `lsp-ltex-plus--setup-fileless-buffer` sets buffer-local `lsp-buffer-uri` (the synthetic URI flows through `didOpen`/`didChange`), a whole-buffer pass-through `lsp--virtual-buffer` plist (lsp-mode addresses non-file buffers through this rather than `buffer-file-name`, so it must carry a complete buffer identity — `:buffer`, `:with-current-buffer`, `:buffer-live?`, `:workspaces`, … — for diagnostics to route back and document open/close to work), and `lsp-auto-touch-files nil` so the server never tries to write the synthetic path to disk; `lsp-ltex-plus--rejoin-workspace` gained an optional `EXPLICIT-ROOT` argument that file-less buffers use to attach to the shared scratch root. The existing programming-language gate still applies, so `*scratch*` (`lisp-interaction-mode`) is auto-checked only when `lsp-ltex-plus-check-programming-languages` is also non-nil; an explicit `M-x lsp-ltex-plus-mode` always works. If such a buffer is later saved to a real file, `lsp-ltex-plus--fileless-on-save` (a buffer-local `after-set-visited-file-name-hook`) drops the synthetic identity so lsp-mode transparently re-checks it under its real-file URI. Set the option to `nil` to restore the file-only behaviour.
- **Incremental-checking settings `lsp-ltex-plus-max-request-size`, `lsp-ltex-plus-paragraph-cache-ttl-minutes`, and `lsp-ltex-plus-paragraph-cache-enabled`.** These surface the three options added by `ltex-ls-plus` [PR #176](https://github.com/ltex-plus/ltex-ls-plus/pull/176), which makes the server re-check only the paragraphs you edited instead of the whole document. `lsp-ltex-plus-max-request-size` (default `20000`, the per-request character limit of the free remote LanguageTool service) is the largest amount of text in characters sent to LanguageTool in a single request when a run of changed paragraphs is batched together — larger text is split across several requests, but an individual paragraph is never split, and caching granularity stays per paragraph. `lsp-ltex-plus-paragraph-cache-ttl-minutes` (default `30`) is how long a document's cached results are kept after they stop being used before a background sweep drops them. `lsp-ltex-plus-paragraph-cache-enabled` (default `t`) toggles result reuse: set it to nil (not recommended) to re-check every paragraph on each pass (independent of `max-request-size`, which still slices and batches).
- **Emacs Lisp support.** `emacs-lisp-mode` is now registered in `lsp-ltex-plus-major-modes` with language ID `"elisp"`, matching the new Emacs Lisp parser merged into `ltex-ls-plus` upstream. Requires new LTeX+ v18.7+ (commits `590ed42` and `010af31f`). LTeX+ checks grammar inside Elisp comments and docstrings when `lsp-ltex-plus-check-programming-languages` is non-nil. The server also accepts `"emacs-lisp"` as an alias; this is recorded in `dev/check_language_ids.py` so the upstream sync check stays clean.
- **`lsp-ltex-plus--maybe-upstream-fixes-present-p` is now wired up.** The v0.3.4 stub returned `nil`; it now tests `(fboundp 'lsp--inlay-hint-tooltip-text)`, a function added to `lsp-mode.el` in commit [`8b04cf63`](https://github.com/emacs-lsp/lsp-mode/commit/8b04cf63) (2026-05-17) — the commit immediately after [`0951bf38`](https://github.com/emacs-lsp/lsp-mode/commit/0951bf38), where the last of the five protocol fixes landed. The probe is advisory only: when it returns non-nil and `lsp-ltex-plus-apply-kind-first-patch` is set, a one-shot log suggests removing the option, but the patches are still applied.

### Changed
- **String settings now default to `nil` ("unset") instead of `""`.** The seven string-typed defcustoms — `lsp-ltex-plus-additional-rules-mother-tongue`, `-additional-rules-language-model`, `-lt-username`, `-lt-api-key`, `-ltex-ls-path`, `-java-path`, and `-lt-server-uri` (already `nil`) — now use `nil` as the Emacs-idiomatic "unset" value, with a `:type` that offers an explicit "Unset" choice in Customize. A new internal helper `lsp-ltex-plus--str` (`(or val "")`) translates `nil` to the empty string the server expects, applied uniformly in both the `lsp-register-custom-settings` lambdas and the `:initialized-fn` configuration snapshot. This joins the existing `--obj-or-empty` and `--bool` boundary helpers so all three JSON types share one unset-handling story. Purely cosmetic/ergonomic: an explicit `""` left in an existing config passes through unchanged (string in, string out), so the change is fully backward compatible.
- **`lsp-ltex-plus-sentence-cache-size` now defaults to `0` (was `2000`),** tracking the same change to `ltex.sentenceCacheSize` in `ltex-ls-plus` [PR #176](https://github.com/ltex-plus/ltex-ls-plus/pull/176). The default and recommended value `0` disables the local LanguageTool server's own cache entirely: ltex-ls-plus keeps its own per-paragraph cache, which supersedes LanguageTool's caching. A value of `0` (or any non-positive value) takes LanguageTool's genuine no-cache code path rather than allocating a zero-capacity cache. Use a positive value to turn it back on, but be aware that for the edit loop this is redundant and only adds CPU and memory overhead with no additional benefit.

## [0.3.5] - 2026-05-15

### Changed
- **Repository moved to the `ltex-plus` GitHub organization.** New canonical URL: <https://github.com/ltex-plus/emacs-ltex-plus>. The `ltex-plus` org now hosts the LTeX+ ecosystem together — the `ltex-ls-plus` server, the VS Code client `vscode-ltex-plus`, and this Emacs client. GitHub continues to redirect the old `alberti42/emacs-ltex-plus` URL for clones and external links, so existing `git remote`s, stars, forks, issues, and PRs are preserved. In-repo `URL:` headers, README install snippets, and the deprecation-message body in `lsp-ltex-plus.el` have been updated to point at the new home.
- **Tree-sitter major modes are now gated by per-symbol `fboundp` guards** rather than listed unconditionally. The package's minimum-Emacs floor stays at 27.1, but entries for `bash-ts-mode`, `c-ts-mode`, `python-ts-mode`, and 14 others (built-ins added in Emacs 29.1 / 30.1, plus the third-party-or-builtin `csharp-mode`) are appended to `lsp-ltex-plus-major-modes` only when the corresponding mode symbol is actually `fboundp`. Users on Emacs 27/28 with a third-party tree-sitter mode installed still get their entry; users on Emacs 29.1+ or 30.1+ get the built-ins automatically; users on older Emacs without those modes simply see them skipped. This is also the gating pattern that `package-lint` requires for version-introduced symbols.
- **Prerequisites section in the README reorganised** to follow the dependency chain (Emacs → lsp-mode → server → Java) and to make the Emacs minimum (27.1) the first explicit prerequisite.

### Added
- **`dev/package-lint.sh`**: development-time helper that clones `purcell/package-lint` into `/tmp` on first run, initialises the MELPA package archive, and invokes `package-lint-batch-and-exit` against both `.el` files. Pre-flight check before tagging releases or opening MELPA-bound PRs.
- **`.dir-locals.el`**: sets `package-lint-main-file` to `lsp-ltex-plus.el` so `package-lint` correctly identifies `lsp-ltex-plus-bootstrap.el` as a secondary file of the same package (rather than complaining that its symbols don't start with the `lsp-ltex-plus-bootstrap-` prefix).

### Fixed (MELPA-readiness pass)
- Renamed three internal patch functions to comply with `package-lint`'s prefix discipline: `lsp-core--parser-on-message-patch` → `lsp-ltex-plus--parser-on-message-patch`, `lsp-core--create-filter-function-patch` → `lsp-ltex-plus--create-filter-function-patch`, and `lsp-core-request-while-no-input-patch` → `lsp-ltex-plus--request-while-no-input-patch` (also normalising the third one to the internal-symbol `--` double-dash convention). All advice-add call sites, docstring references, the CHANGELOG entry, and `CLAUDE.md` were updated to match.
- Replaced the literal `~/.emacs.d/lsp-ltex-plus/` path inside the docstring of `lsp-ltex-plus-reload-and-notify-server` with a reference to `user-emacs-directory`, satisfying `package-lint`'s "no hardcoded user-directory paths" check. The runtime code already used `user-emacs-directory`; only the docstring still mentioned the literal path.
- Documented the intentional `with-eval-after-load 'lsp-mode` at the bottom of `lsp-ltex-plus.el` with an inline comment explaining that this is the standard pattern for `:add-on?` `lsp-mode` clients (`lsp-pyright`, `lsp-haskell`, etc.). `package-lint` still emits a warning for the form, but the rationale is now in source.

### Documentation
- **Expanded `;;; Commentary:` section in `lsp-ltex-plus.el`** so it actually describes what the package does. It now covers: the markup and writing languages checked by default (LaTeX, Markdown, Org, RestructuredText, HTML, BibTeX, AsciiDoc, Typst, Quarto, Magit commit messages, plain text), the 30+ programming languages whose comments and string literals can be opted into, add-on integration with primary LSP servers, the offline-by-default mode (with optional remote LanguageTool server / Premium credentials), the multilingual per-language settings model, persistent external state, lazy loading via the two-file split, and a minimal `use-package` setup snippet. Replaces the previous design-memo-style commentary that was effectively user-invisible.

## [0.3.4] - 2026-05-15

### Deprecated
- **`lsp-ltex-plus-apply-kind-first-patch` is deprecated.** All five `lsp-mode` protocol bugs this package historically worked around (PRs [#5052](https://github.com/emacs-lsp/lsp-mode/pull/5052), [#5055](https://github.com/emacs-lsp/lsp-mode/pull/5055), [#5056](https://github.com/emacs-lsp/lsp-mode/pull/5056), [#5057](https://github.com/emacs-lsp/lsp-mode/pull/5057), [#5059](https://github.com/emacs-lsp/lsp-mode/pull/5059)) have been merged upstream; the last of them landed on 2026-05-15 (commit [`0951bf38`](https://github.com/emacs-lsp/lsp-mode/commit/0951bf38)). The toggle still works on older `lsp-mode` builds and is harmless against newer ones (the `:override` advices simply replace upstream code that already mirrors them), but it adds no value and will be removed once `Package-Requires` is bumped past `0951bf38`. New users should leave it unset; existing users should remove it from their config and update `lsp-mode`.

### Added
- `lsp-ltex-plus--maybe-upstream-fixes-present-p`: placeholder predicate that returns `nil`. Reserved for a future `fboundp`/`boundp` probe of a distinctive symbol postdating commit `0951bf38`. When it eventually returns non-nil, the package will skip applying the three `:override` advices in `lsp-ltex-plus--apply-lsp-mode-patch` (emitting a one-shot deprecation log if `lsp-ltex-plus-apply-kind-first-patch` is still set) and skip `lsp-ltex-plus--restore-completion-capability` on server init. The probe runs at most once per session and only when an opted-in code path actually fires it; default-config users pay zero cost.
- `lsp-ltex-plus--restore-completion-capability`: silent workaround for the pre-PR-#5059 `lsp-mode` bug where `completionProvider: {}` parsed as `nil` under `lsp-use-plists t`, leaving the server marked as "no completion support". Called from `:initialized-fn`, gated by the placeholder predicate so it becomes a no-op on a fixed `lsp-mode`. Unlike the three `:override` advices, this workaround was never gated by `lsp-ltex-plus-apply-kind-first-patch`, it always ran silently.

### Changed
- Persistence files now use a `.eld` extension by default (`stored-dictionary.eld`, `enabled-rules.eld`, `disabled-rules.eld`, `hidden-false-positives.eld`). `.eld` is the conventional Emacs extension for `prin1`-serialised Lisp data and is mapped to `lisp-data-mode` by `auto-mode-alist`, so opening the files by hand (or via Finder/Explorer/Nautilus) gets proper highlighting. Extensionless files left over from earlier versions are renamed automatically on first startup; users who have customized the file paths are invited (though it is not mandatory; rather a good-style policy) to update the filenames  to contain the `.eld` extension. 

### Documentation
- New "Recommended `lsp-mode` Revision" subsection in the README with a per-PR table (#5052, #5055, #5056, #5057, #5059) and the cutoff commit ([`0951bf38`](https://github.com/emacs-lsp/lsp-mode/commit/0951bf38), 2026-05-15) at which all five fixes are present.
- Every reference to `lsp-ltex-plus-apply-kind-first-patch` (use-package example, Key Settings bullet, parameter table, Troubleshooting "Communication Stalls", Under-the-Hood "Lsp-mode Protocol Patches") now carries a deprecation note and a link to the recommendation section. The protocol-patches reference subsection is preserved verbatim for users still on older `lsp-mode` builds.
- Deprecation status blocks added to the docstrings of the four affected functions: `lsp-ltex-plus--parser-on-message-patch` (PR #5055), `lsp-ltex-plus--create-filter-function-patch` (PR #5057), `lsp-ltex-plus--request-while-no-input-patch` (PR #5056), and `lsp-ltex-plus--restore-completion-capability` (PR #5059). Each names the upstream merge commit and the gating chain.
- The `lsp-ltex-plus-completion-enabled` parameter row now notes that word completion requires an `lsp-mode` build containing [PR #5052](https://github.com/emacs-lsp/lsp-mode/pull/5052).
- New section with performance tips for `lsp-mode` (garbage-collection tuning, switching to `lsp-use-plists`).
- Repository URL corrected throughout the README (thanks to @real-or-random for PR #1).
- Assorted docstring cleanups so the package passes `checkdoc`.

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
