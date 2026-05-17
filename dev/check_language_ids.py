#!/usr/bin/env python3
"""
Verify that every language ID from the LTeX+ server source appears in the
second column of lsp-ltex-plus-major-modes in lsp-ltex-plus-bootstrap.el,
and report any IDs present in our list that are absent from the server source.

Server IDs are extracted from three canonical source files:
  - FileIo.kt              — getCodeLanguageIdFromPath() return values
  - ProgramCommentRegexs.kt — language ID keys in the comment-regex switch
  - CodeFragmentizer.kt    — language IDs handled by the parser dispatch

Aliases (shorthand IDs that map to the same parser as a canonical ID) are
excluded from the comparison; they need no Emacs mode entry.

Run from the root of emacs-ltex-plus with the path to the ltex-ls-plus repo:

  python3 check_language_ids.py /path/to/fork-ltex-ls-plus
"""

import re
import sys
from pathlib import Path

if len(sys.argv) < 2:
    print("Usage: check_language_ids.py <path-to-ltex-ls-plus-repo>")
    sys.exit(1)

repo = Path(sys.argv[1])
kotlin_src = repo / "src/main/kotlin/org/bsplines/ltexls"

# Aliases: shorthand IDs the server accepts on the wire but maps to the same
# parser as a canonical ID.  They need no Emacs mode entry of their own.
ALIASES = {
    # Shorthand aliases mapping to the same parser as a canonical ID
    "bash",       # → shellscript
    "coffee",     # → coffeescript
    "cs",         # → csharp
    "fortran",    # → fortran-modern
    "ps1",        # → powershell
    "sh",         # → shellscript
    "bib",        # → bibtex
    "git-commit", # → plaintext
    "gitcommit",  # → plaintext
    "xhtml",      # → html
    "plaintex",   # → latex
    "tex",        # → latex
    "emacs-lisp", # → elisp
    "nop",        # special no-op parser, not a real language ID
}

# --- FileIo.kt: return values of getCodeLanguageIdFromPath() ----------------
fileio_text = (kotlin_src / "tools/FileIo.kt").read_text()
m = re.search(r'fun getCodeLanguageIdFromPath.*?(?=\n  fun |\Z)', fileio_text, re.DOTALL)
func_body = m.group(0) if m else ""
fileio_ids = set(re.findall(r'^\s+"([^"]+)"\s*$', func_body, re.MULTILINE))

# --- ProgramCommentRegexs.kt: language ID keys in the regex switch ----------
commentregex_ids = set(re.findall(
    r'"([a-z][a-z0-9\-]*)"',
    (kotlin_src / "parsing/program/ProgramCommentRegexs.kt").read_text()))

# --- CodeFragmentizer.kt: language IDs in the parser dispatch ---------------
fragmentizer_ids = set(re.findall(
    r'"([a-z][a-z0-9.\-]*)"',
    (kotlin_src / "parsing/CodeFragmentizer.kt").read_text()))
# Remove dot-containing strings (package names, etc.)
fragmentizer_ids = {s for s in fragmentizer_ids if "." not in s}

server_ids = (fileio_ids | commentregex_ids | fragmentizer_ids) - ALIASES

# --- lsp-ltex-plus-bootstrap.el: extract second column ---------------------
bootstrap = Path("lsp-ltex-plus-bootstrap.el").read_text()
our_ids = set(re.findall(r'\(\S+\s+"([^"]+)"\s+(?:nil|t)\)', bootstrap))

missing_from_ours = server_ids - our_ids
extra_in_ours     = our_ids - server_ids

print("=== IDs in server source missing from our alist ===")
if missing_from_ours:
    for x in sorted(missing_from_ours):
        print(f"  MISSING: {x}")
else:
    print("  (none)")

print()
print("=== IDs in our alist not found in server source ===")
if extra_in_ours:
    for x in sorted(extra_in_ours):
        print(f"  EXTRA:   {x}")
else:
    print("  (none)")
