#!/usr/bin/env bash
# Neko test runner: bash tests/run.sh [suite...]
# Suites: core proxy_export apply dns install recommend
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# Keep every temporary file inside the project (.test-tmp/) unless the caller
# chose another TMPDIR.
export TMPDIR=${NEKO_TEST_TMPDIR:-$PWD/.test-tmp}
mkdir -p "$TMPDIR" || exit 1
export T_RESULTS
T_RESULTS=$(mktemp)
# shellcheck source=tests/lib.sh
source tests/lib.sh
suites=("$@")
((${#suites[@]})) || suites=(core proxy_export apply dns install recommend)
for s in "${suites[@]}"; do
  # shellcheck source=/dev/null
  source "tests/t_${s}.sh"
done
t_summary
rc=$?
rm -f "$T_RESULTS"
exit $rc
