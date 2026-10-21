#!/usr/bin/env bash
#
# Regenerate the Fillline product status dashboard.
#
#   ./Scripts/status.sh              # write docs/status/index.html
#   ./Scripts/status.sh --open       # ...and open it
#   ./Scripts/status.sh --out /tmp/x.html
#
# Every number and state word lives in docs/status/data.json; nothing here
# is hand-edited. Requires python3 only (standard library).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found." >&2
  exit 1
fi

exec python3 "$REPO_ROOT/Scripts/status.py" "$@"
