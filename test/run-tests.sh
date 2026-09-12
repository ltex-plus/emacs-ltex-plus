#!/usr/bin/env bash
# Run the ERT suite for `lsp-ltex-plus'.
#
# Usage:
#   test/run-tests.sh                     # every test file
#   test/run-tests.sh project additions   # only the named files (substring match)
#   test/run-tests.sh -s SELECTOR         # an ERT selector, e.g. a test-name regexp
#
# The selected files run in one Emacs batch process.  They used to run
# one per process because two of them installed global advice on
# lsp-mode; with that gone, nothing a file loads or leaves behind reaches
# another: the fake server is started and stopped per test, and every
# test that asserts on list contents resets them first.  One process
# saves the suite about ten Emacs start-ups.
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

load=()
for file in "${files[@]}"; do
  load+=(-l "${file}")
done

echo "=== $(printf '%s ' "${files[@]##*/}")"
"${EMACS}" --batch -Q -L "${REPO_ROOT}" -L "${SCRIPT_DIR}" "${load[@]}" "${run[@]}"
status=$?
echo
echo "==========================================================="
if [[ ${status} -eq 0 ]]; then
  echo "All ${#files[@]} test file(s) passed."
  exit 0
fi
echo "Failed (exit ${status}); see above."
exit 1
