# Maintainer Scripts

This directory contains scripts used during the development and maintenance of `lsp-ltex-plus`. They are **not** intended for end users; you do not need to run anything here to use the package.

The automated tests live in `../test/` — run them with `make test`. What stays here are the probes that cannot run offline: they need a live `ltex-ls-plus` server, a checkout of its source, or the MELPA archive.

## Scripts

- **`probe_rules.bash`** — interrogates a running `ltex-ls-plus` server to enumerate the rule IDs it currently advertises. Used to keep `is_proposed_unknown_word_rule` in `lsp-ltex-plus.el` aligned with upstream when ltex-ls-plus renames or adds rules.

- **`check_language_ids.py`** — cross-checks the language IDs declared in `lsp-ltex-plus-major-modes` (in `lsp-ltex-plus-bootstrap.el`) against those that the server source actually understands. Parses three canonical Kotlin files (`FileIo.kt`, `ProgramCommentRegexs.kt`, `CodeFragmentizer.kt`) from a local checkout of the `ltex-ls-plus` repo and reports IDs missing from our alist or present in our alist but unknown to the server. Run from the repo root: `python3 dev/check_language_ids.py /path/to/ltex-ls-plus`.

- **`probe_completion.py`** — drives a `ltex-ls-plus` binary directly over LSP stdio to inspect what `textDocument/completion` returns for a given document and cursor position, without going through Emacs. Useful for debugging completion-side bugs (missing `kind`, empty results at boundary positions, prefix-matching surprises) and for regression-testing server changes. Performs the LSP handshake, answers `workspace/configuration` pull requests, waits for the first `publishDiagnostics` (so the document is parsed before completion fires), then prints either a labelled summary or the raw JSON response. The cursor is placed at the end of the supplied text. Examples: `dev/probe_completion.py "I really wonder"` (summary), `dev/probe_completion.py --raw "wonder"` (full JSON), `dev/probe_completion.py --trace "W" 2>log` (full JSON-RPC traffic to stderr), `dev/probe_completion.py --server /path/to/ltex-ls-plus "..."` (point at a non-PATH binary, e.g. a local maven build under `target/appassembler/bin/`).
