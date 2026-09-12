# Test suite

ERT tests for `lsp-ltex-plus`. Nothing here is needed to use the package.

```sh
make test                      # everything; the live tests report as skipped
make test-live                 # the same, with a real ltex-ls-plus
make live-repl                 # a daemon with the live fixture, for debugging
test/run-tests.sh project      # files whose name contains "project"
test/run-tests.sh -s "\"cache\""   # an ERT selector
```

The selected files run in one Emacs batch process. Nothing a file loads
or leaves behind reaches another: the fake server is started and stopped
per test, and every test that asserts on list contents resets them
first.

No `ltex-ls-plus` binary is involved and no server is started, except in
`ltex-plus-live-test.el` — see **Live tests** below. The shared helper
makes sure of that by pointing the executable setting at a name that does
not exist; on a machine with `ltex-ls-plus` on `PATH`, a test that
reached for a connection without the fake in place once started a JVM,
and every later test reused it in place of the fake and timed out for no
visible reason.

## The fake server

`ltex-plus-fake-server.el` is an `ltex-ls-plus` that lives inside the
test's own Emacs, on the pattern of `jsonrpc`'s own tests: a loopback
socket accepts one connection and wraps it in a server-side
`jsonrpc-process-connection`. The client under test is pointed at it by
overriding the one function that creates the server process; everything
above that function — the handshake, the dispatchers, document sync,
diagnostics, code actions — runs unchanged.

The fake behaves the way the real server was observed to. It answers
`initialize` with the capabilities `ltex-ls-plus` advertises, and on
every `didOpen` and `didChange` it pulls configuration through both of
the server's requests before publishing one diagnostic per match of
`ltex-plus-fake-flag-regexp` (by default the word `teh`), with positions
in UTF-16 code units. It is as strict as the real server about a refused
pull: `ltex-ls-plus` abandons the check when either configuration request
is answered with an error, and so does the fake. Every message it
receives is recorded in `ltex-plus-fake-received`, so a test can assert on
exactly what went over the wire; `ltex-plus-fake-code-actions` is what it
answers a code action request with.

What it cannot stand in for is the real server's judgement of a text.

## Live tests

`make test-live` runs `ltex-plus-live-test.el` against a real server.
Without the opt-in — or on a machine with no `ltex-ls-plus`, or one older
than `ltex-plus-live-server-floor` — every test in it reports as
*skipped* with the reason, rather than being invisible.

The whole file costs about twenty seconds, nearly all of it one JVM
start: one connection serves every buffer in the session and stays up
between tests, so each document after the first is tens of milliseconds.
Every test works from any server state — the first buffer to need a
server starts one — so a test that stops the server costs the next one a
start and nothing more.

A batch Emacs needs one thing set, by `ltex-plus-live-configure`: a short
change delay. The client asks no questions and needs no autoloads.

Two rules for the tests themselves. Wait on a predicate with a deadline
(`ltex-plus-live-until`), never on a duration. And never read "no
diagnostics" as an answer: it is indistinguishable from "not checked
yet", so anything asserting an absence goes through
`ltex-plus-live-after-publish`, which waits for the server to speak about
*that buffer* — counting publishes globally is not enough.

## What the fixtures exist for

**`user-emacs-directory` is redirected before anything is loaded.** The
package computes paths from it at load time — the four
`lsp-ltex-plus-*-file` variables among them. Without the sandbox a test
run reads the developer's own dictionary and mixes it into the results,
which looks like the code working. `ltex-plus-test-reset` goes further
and repoints the four files at a fresh directory per test, so a test can
only see what it wrote itself.

**JSON is what `jsonrpc` hands out.** Objects are plists with keyword
keys, arrays are vectors, `null` is `nil` and `false` is `:json-false`.
Fixtures are written as plain plists; `ltex-plus-test-suggestion` builds
a code action shaped like the ones the real server sends.

## What each file covers

| File | Covers |
|---|---|
| `ltex-plus-bootstrap-test.el` | The mode table, the three `enable-for-modes` keywords, and the single dispatcher — including the exact-match rule that keeps `text-mode` from activating in `org-mode` buffers |
| `ltex-plus-settings-test.el` | Merging, reading and writing the four language-keyed lists; the invariant that a code action never writes to a defcustom; the JSON boundary helpers; the `.eld` migration; the reload command; the server version guard; the settings object and its key set |
| `ltex-plus-conn-test.el` | URIs, the `initialize` request, finding the executable, and against the fake: the handshake, work queued behind it, shutdown, document open and close, debounced edits, receiving diagnostics, and position conversion in UTF-16 with and without a document region |
| `ltex-plus-diag-test.el` | The flymake backend: conversion, the kept report function, and through flymake itself, underlines that appear, change and clear from the server's publishes alone |
| `ltex-plus-scope-test.el` | Both configuration replies answered per document from the buffer the URI names, a dead document answered globally, sections, and the pulls seen over the wire |
| `ltex-plus-project-test.el` | Project word lists merging with the global ones, relative paths resolving against the `.dir-locals.el` directory, and the modification-time cache |
| `ltex-plus-actions-test.el` | Which diagnostics go out as context, the code action request, applying workspace edits, the menu and the dictionary shortcut, and the keymap |
| `ltex-plus-additions-test.el` | Where an accepted suggestion is written, all three values of `lsp-ltex-plus-save-additions-to`, the three commands, and the two-suggestion split |
| `ltex-plus-safety-test.el` | The `:safe` declarations — the endpoint allowlist, the project-path rule, and the policy that everything else is vouched for on a type check |
| `ltex-plus-synthetic-test.el` | File-less buffers: the invented identity, its reuse, edits and pulls reaching the buffer, and the handover when the buffer is saved to a file |
| `ltex-plus-comint-test.el` | The comint input region: what is sent, positions past the prompt, output above the region sending nothing, the busy gate, submitting |
| `ltex-plus-mode-test.el` | What the minor mode decides before it reaches for a server, and against the fake, what it does once it has one, including the shutdown and restart commands |
| `ltex-plus-live-test.el` | Opt-in, against a real server: the whole pipeline, both configuration pulls, code actions, per-project language and dictionaries, the reload broadcast, file-less and comint buffers, teardown, and shutdown |

## Adding a test

Put it in the file that owns the area, `(require 'ltex-plus-test-helper)`
first — and `(require 'ltex-plus-fake-server)` if it needs a server — and
call `ltex-plus-test-reset` at the top of anything that asserts on list
contents. A new file is picked up by the runner as soon as it is named
`*-test.el`.

Say in the docstring what breaks if the test fails, not what the code does.
Most of what is tested here has no visible symptom when it regresses — a
document checked against the wrong project's dictionary, a stale
underline nothing clears, a config pull answered from the wrong buffer —
and the docstring is where that ends up recorded.
