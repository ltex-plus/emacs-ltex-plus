#!/usr/bin/env bash
# Run `package-lint' against the package sources.
#
# This is a development-time check; it is not part of the user-facing
# package. Run it before tagging a release or opening a MELPA-bound PR.
#
# Usage: dev/package-lint.sh
#
# Requirements:
#   - emacs on PATH
#   - network access on first run (to fetch package-lint and the MELPA
#     archive index; both are cached afterwards)
#
# What it does:
#   1. Clones purcell/package-lint into /tmp/package-lint if not present
#      (no system-wide install required).
#   2. Initialises the MELPA package archive so package-lint can verify
#      that declared `Package-Requires' dependencies actually exist.
#      Without this, package-lint emits a spurious "Package <name> is
#      not installable" error for any MELPA-only dependency.
#   3. Runs `package-lint-batch-and-exit' against the package files.
#
# Exit status: package-lint's own — non-zero if any error is reported.

set -euo pipefail

# Resolve the repository root from this script's location so it works
# regardless of the caller's current directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PACKAGE_LINT_DIR="/tmp/package-lint"

if [[ ! -d "${PACKAGE_LINT_DIR}" ]]; then
  echo "Cloning package-lint into ${PACKAGE_LINT_DIR}..."
  git clone --depth 1 https://github.com/purcell/package-lint "${PACKAGE_LINT_DIR}"
fi

cd "${REPO_ROOT}"

exec emacs --batch -Q \
  -L . \
  -L "${PACKAGE_LINT_DIR}" \
  --eval "(progn
            (require 'package)
            (add-to-list 'package-archives
                         '(\"melpa\" . \"https://melpa.org/packages/\"))
            (package-initialize)
            (package-refresh-contents))" \
  --eval "(require 'package-lint)" \
  -f package-lint-batch-and-exit \
  lsp-ltex-plus-bootstrap.el lsp-ltex-plus-settings.el lsp-ltex-plus-conn.el \
  lsp-ltex-plus-diag.el lsp-ltex-plus.el
