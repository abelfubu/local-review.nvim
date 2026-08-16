#!/usr/bin/env sh
# Verifies the layer rules from ARCHITECTURE.md:
#   domain         -> nothing above (no application/presentation/infrastructure imports)
#   infrastructure -> no application/presentation imports
#   application    -> no presentation imports
# Exits non-zero and prints offending lines on violation.

set -eu
cd "$(dirname "$0")/.."

fail=0

check() {
  # $1 = description, $2 = grep pattern, $3... = paths
  desc="$1"; pattern="$2"; shift 2
  if grep -rnE "$pattern" "$@" 2>/dev/null; then
    echo "VIOLATION: $desc"
    fail=1
  fi
}

import_re='require\(["'"'"']local_review\.'

check "domain must not import upper layers" \
  "${import_re}(application|presentation|infrastructure)\." \
  lua/local_review/domain/

check "infrastructure must not import application/presentation" \
  "${import_re}(application|presentation)\." \
  lua/local_review/infrastructure/

check "application must not import presentation" \
  "${import_re}presentation\." \
  lua/local_review/application/

if [ "$fail" -eq 0 ]; then
  echo "Layer check passed."
fi
exit "$fail"
