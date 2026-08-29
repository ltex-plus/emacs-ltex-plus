#!/usr/bin/env bash
# Run the ERT suite for `lsp-ltex-plus'.
#
# Usage:
#   test/run-tests.sh                     # every test file
#   test/run-tests.sh project additions   # only the named files (substring match)
#   test/run-tests.sh -s SELECTOR         # an ERT selector, e.g. a test-name regexp
#
# Each file runs in its own Emacs batch process.  That is not just tidiness:
# `ltex-plus-setup-test.el' switches on every optional feature and installs
# global advice on `lsp-mode', and `ltex-plus-additions-test.el' overrides
# `lsp-notify'.  Sharing one process would make the result depend on load
# order, which is the sort of thing that shows up as a test failing only in
# CI.
#
# Finding lsp-mode: the suite looks for a straight.el build tree or a
# package.el archive under the usual XDG and classic Emacs directories.
# Override with either of
#
#   LTEX_PLUS_LOAD_PATH      colon-separated directories, added verbatim
#   LTEX_PLUS_STRAIGHT_BUILD one directory holding a package per subdirectory
#
# Also honours EMACS (default: emacs).
#
# Exit status: 0 when every file passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
EMACS="${EMACS:-emacs}"

selector=""
patterns=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--selector) selector="${2:?-s needs an ERT selector}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) patterns+=("$1"); shift ;;
  esac
done

if ! command -v "${EMACS}" >/dev/null 2>&1; then
  echo "Cannot find Emacs (tried '${EMACS}'); set EMACS to its path." >&2
  exit 2
fi

files=()
for file in "${SCRIPT_DIR}"/*-test.el; do
  [[ -e "${file}" ]] || continue
  if [[ ${#patterns[@]} -gt 0 ]]; then
    keep=0
    for pattern in "${patterns[@]}"; do
      [[ "$(basename "${file}")" == *"${pattern}"* ]] && keep=1
    done
    [[ ${keep} -eq 1 ]] || continue
  fi
  files+=("${file}")
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No test files matched." >&2
  exit 2
fi

if [[ -n "${selector}" ]]; then
  run=(--eval "(ert-run-tests-batch-and-exit (quote ${selector}))")
else
  run=(-f ert-run-tests-batch-and-exit)
fi

failed=()
for file in "${files[@]}"; do
  name="$(basename "${file}" .el)"
  echo "=== ${name} ==============================================="
  if ! "${EMACS}" --batch -Q \
        -L "${REPO_ROOT}" -L "${SCRIPT_DIR}" \
        -l "${file}" "${run[@]}"; then
    failed+=("${name}")
  fi
  echo
done

echo "==========================================================="
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "All ${#files[@]} test file(s) passed."
  exit 0
fi
echo "Failed: ${failed[*]}"
exit 1
