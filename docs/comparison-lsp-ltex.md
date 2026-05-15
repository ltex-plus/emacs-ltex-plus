# Comparative Analysis: `lsp-ltex-plus` vs. `lsp-ltex`

This document compares `lsp-ltex-plus` (this package) with the original [`emacs-languagetool/lsp-ltex`](https://github.com/emacs-languagetool/lsp-ltex) package. While both act as LSP clients for LTeX, `lsp-ltex-plus` is a modernized, protocol-corrected implementation.

## A note on naming

Separately from the original `lsp-ltex`, a second project also carries the `-plus` suffix: [`emacs-languagetool/lsp-ltex-plus`](https://github.com/emacs-languagetool/lsp-ltex-plus). From a reading of its source, that project appears to be the original `lsp-ltex` codebase with its function and variable prefixes renamed from `lsp-ltex-` to `lsp-ltex-plus-`, retargeted at the newer `ltex-ls-plus` server binary. It may therefore benefit from new features exposed by `ltex-ls-plus` that `lsp-ltex` itself cannot reach. The comparison below is written against the original `lsp-ltex`, but most of the technical differences apply to the renamed project as well, since the renamed project inherits `lsp-ltex`'s architecture.

---

## 1. Core Stability: The LSP-Protocol Patches
The most significant technical difference is the inclusion of several **Protocol Patches** in `lsp-ltex-plus` that improve `lsp-mode`'s robustness.

*   **The Problem:** The LTeX server frequently initiates its own requests (like `workspace/configuration`) to fetch your settings. Standard `lsp-mode` can misidentify these as responses to previous client requests if IDs collide (common with remote servers or high-latency environments). This leads to a permanent protocol deadlock where both Emacs and the server wait for each other indefinitely. Additionally, standard `lsp-mode` is vulnerable to framing errors in batch dispatches and stale callbacks from cancelled synchronous requests.
*   **`lsp-ltex-plus` Solution:** Includes three surgical fixes (Kind-First Routing, Resilient Message Dispatch, and Stale Callback Protection) that redefine core `lsp-mode` functions to handle these edge cases correctly. For example, the Resilient Message Dispatch fix ensures that when the server sends multiple updates bundled together, an interruption in one (like typing during completion) doesn't cause the rest of the bundle to be discarded.
    ```elisp
    ;; Kind-First routing: if a method exists, it's a server-initiated
    ;; message (request/notification) regardless of ID collisions.
    (message-type (cond
                   (has-method (if has-id 'request 'notification))
                   (has-id (if has-error 'response-error 'response))
                   (t 'notification)))
    ```
*   **`lsp-ltex` Status:** Relies on default `lsp-mode` behavior, making it vulnerable to these specific protocol deadlocks and message-loss scenarios.

---

## 2. Modern Major Mode Support
`lsp-ltex-plus` includes built-in support for contemporary formats that the original package lacks or requires manual configuration for.

*   **`lsp-ltex-plus` Unique Support:** `typst-mode`, `quarto-mode`, `norg-mode` (Neorg), and `asciidoc-mode`.
*   **Target:** Specifically tuned for `ltex-ls-plus`, whereas `lsp-ltex` is hardcoded for the older, unmaintained `ltex-ls`.

---

## 2. Configuration Sync Strategy
`lsp-ltex-plus` ensures the server is always in sync with your Emacs settings by proactively pushing updates.

*   **`lsp-ltex-plus` (Proactive Push):** After every code action (like adding a word to the dictionary), it explicitly notifies the server to re-fetch settings.
    ```elisp
    (defun lsp-ltex-plus--action-add-to-dictionary (action)
      ...
      (lsp-notify "workspace/didChangeConfiguration" '(:settings nil)))
    ```
    *Source: `lsp-ltex-plus.el`, lines [394-408](https://github.com/ltex-plus/emacs-ltex-plus/blob/db37bf3af620fbd21377999b22ad426fe7db2293/lsp-ltex-plus.el#L394-L408)*
*   **`lsp-ltex` (Passive):** The original client updates local variables but does not send the `didChangeConfiguration` notification, relying instead on the server's next polling interval or a manual restart.
    ```elisp
    (lsp-defun lsp-ltex--code-action-add-to-dictionary ((&Command :arguments?))
      ...
      (setq lsp-ltex--combined-dictionary
            (lsp-ltex-combine-plists lsp-ltex-dictionary lsp-ltex--stored-dictionary))
      (lsp-message "[INFO] Word added to dictionary."))
    ```
    *Source: `lsp-ltex.el`, [lines 557-568](https://github.com/emacs-languagetool/lsp-ltex/blob/6adc2b4d32a907943a6ce06e2267090241e7af6a/lsp-ltex.el#L557-L568)*

---

## 3. Server Management vs. Core Bridge
The two projects have diverging philosophies regarding server binaries.

*   **`lsp-ltex` (Heavyweight):** Devotes roughly 100 lines of code to downloading, unzipping, and upgrading the `ltex-ls` binary from GitHub. This adds complexity and potential failure points during installation.
*   **`lsp-ltex-plus` (Lightweight/Surgical):** Focuses entirely on the LSP communication bridge. It expects the `ltex-ls-plus` binary to be managed by the system or the user (e.g., via `PATH`), resulting in a more predictable and self-contained package.

---

## 4. Debugging Infrastructure
`lsp-ltex-plus` provides superior visibility into the LSP "wire" protocol.

*   **`lsp-ltex-plus`:** Uses a `tee`-based pipeline to log raw JSON-RPC traffic to `/tmp/ltex-server-input.log` and `/tmp/ltex-server-output.log` when debugging is enabled.
*   **`lsp-ltex`:** Relies solely on `lsp-mode`'s standard logging, which may not capture raw timing or corruption issues at the process level.

---

## 5. Workspace Reuse and Memory Footprint
The server runs on the JVM and typically reserves several hundred megabytes of heap per process, so how the client asks `lsp-mode` to manage server instances has a direct effect on RAM usage when the user works across multiple unrelated directories.

*   **`lsp-ltex-plus`:** Registers the client with `:multi-root t`. `lsp-mode` then reuses a single server workspace across all project roots for this client, so **one JVM** handles every supported buffer in the session — whether those buffers belong to the same git repository or to ten unrelated directories.
*   **`lsp-ltex`:** Registers without `:multi-root`. `lsp-mode` defaults to one workspace per detected project root, so opening files from multiple unrelated directories spawns one JVM per root.

The difference is a single keyword at the registration call site. Mentioned here for the users of the other project, because it can be fixed with a single line.
