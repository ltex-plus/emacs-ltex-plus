# Test suite

ERT tests for `lsp-ltex-plus`. Nothing here is needed to use the package.

```sh
make test                      # everything
test/run-tests.sh project      # files whose name contains "project"
test/run-tests.sh -s "\"cache\""   # an ERT selector
```

Each file runs in its own Emacs batch process. That is not tidiness:
`ltex-plus-setup-test.el` switches on every optional feature and installs
global advice on `lsp-mode`, and `ltex-plus-additions-test.el` overrides
`lsp-notify`. Sharing one process would make results depend on load order.

No `ltex-ls-plus` binary is involved and no server is started. Everything
under test is on the client side of the protocol, and the two request
handlers are ordinary functions of `(WORKSPACE PARAMS)`.

## Finding `lsp-mode`

The package has no Cask or Eldev file, so the suite finds `lsp-mode` by
convention: the first straight.el build tree or package.el archive under
`$XDG_CONFIG_HOME/emacs`, `~/.config/emacs` or `~/.emacs.d`. Two escape
hatches, both read by `ltex-plus-test-helper.el`:

| Variable | Meaning |
|---|---|
| `LTEX_PLUS_LOAD_PATH` | Colon-separated directories, added to `load-path` verbatim |
| `LTEX_PLUS_STRAIGHT_BUILD` | One directory holding a package per subdirectory |
| `EMACS` | Which Emacs to run (default `emacs`) |

## Two things the fixtures exist for

**`user-emacs-directory` is redirected before anything is loaded.** Both
`lsp-mode` and this package compute paths from it at load time — the four
`lsp-ltex-plus-*-file` variables among them. Without the sandbox a test run
reads the developer's own dictionary and mixes it into the results, which
looks like the code working. `ltex-plus-test-reset` goes further and
repoints the four files at a fresh directory per test, so a test can only
see what it wrote itself.

**JSON objects are built through `ltex-plus-test-obj`.** `lsp-mode`
represents them as hash tables, or as plists when it was byte-compiled with
`lsp-use-plists` (the default in Doom). The package reads them with
`lsp-get`, which copes with either; a fixture that hard-codes one
representation passes on one machine and fails on the other for reasons
that have nothing to do with the code under test.

## What each file covers

| File | Covers |
|---|---|
| `ltex-plus-bootstrap-test.el` | The mode table, the three `enable-for-modes` keywords, and the single dispatcher — including the exact-match rule that keeps `text-mode` from activating in `org-mode` buffers |
| `ltex-plus-settings-test.el` | Merging, reading and writing the four language-keyed lists; the invariant that a code action never writes to a defcustom; the JSON boundary helpers; the `.eld` migration |
| `ltex-plus-scope-test.el` | Resolving a document URI to its buffer, and two documents in one session being answered from their own buffers rather than from whichever came first |
| `ltex-plus-project-test.el` | Project word lists merging with the global ones, relative paths resolving against the `.dir-locals.el` directory, and the modification-time cache |
| `ltex-plus-additions-test.el` | Where an accepted suggestion is written, all three values of `lsp-ltex-plus-save-additions-to`, the two-suggestion split, and the pass-through for other servers' code actions |
| `ltex-plus-safety-test.el` | The `:safe` declarations — the endpoint allowlist, the project-path rule, and the policy that everything else is vouched for on a type check |
| `ltex-plus-synthetic-test.el` | File-less and comint buffers: the virtual-buffer plists, the comint input region and its busy gate, and routing a `WorkspaceEdit` back to a buffer that visits no file |
| `ltex-plus-setup-test.el` | The client registration, the settings surface (the push and the pull describing the same settings), the gated advice bodies, and that re-running setup never installs an advice twice |
| `ltex-plus-mode-test.el` | What the minor mode decides before it reaches for a server: the programming-language guard, registering an unseen major mode, and giving up when the binary is missing |
| `ltex-plus-patch-test.el` | Kind-First routing: a server request with a colliding id stays a request |

## What is deliberately not covered

Roughly a sixth of the package never executes during a run, and almost
all of it is code that only runs with a live workspace: the minor mode's
five-way startup `cond` and its deactivation path, `--rejoin-workspace`,
the comint submit re-sync, `--fileless-on-save`, and the broadcast half
of `lsp-ltex-plus-reload-settings`. Mocking `lsp-mode` far enough to
reach them would produce a fixture that drifts from the real thing and
tests itself; the manual checklist in the developer guide covers them
instead.

Two smaller gaps are simply not worth the code: the latency-benchmark
advice bodies, and the two deprecated protocol backports
(`--create-filter-function-patch`, `--request-while-no-input-patch`),
which are only installed on an `lsp-mode` predating the upstream fixes.

There is no integration test against a real `ltex-ls-plus`. The protocol
facts the client is built on were established by driving the server from
a raw Python client (see `dev/`), and they are recorded in the developer
guide; nothing here re-checks them against a running server.

## Adding a test

Put it in the file that owns the area, `(require 'ltex-plus-test-helper)`
first, and call `ltex-plus-test-reset` at the top of anything that asserts
on list contents. A new file is picked up by the runner as soon as it is
named `*-test.el`.

Say in the docstring what breaks if the test fails, not what the code does.
Most of what is tested here has no visible symptom when it regresses — a
document checked against the wrong project's dictionary, an advice
installed twice, a config pull answered from an arbitrary buffer — and the
docstring is where that ends up recorded.
