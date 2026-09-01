#!/usr/bin/env bash
# Drift guard for the man-page mandate in CLAUDE.md ("a feature is not done
# until its man page is"): every user-facing command dispatched in
# src/cli/app.zig must appear in man/cb.1, and every man page must lint clean
# at ERROR level under mandoc when it's available. This is what makes the
# mandate enforced by `zig build e2e` rather than aspirational.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/cli/app.zig"
PAGE="$ROOT/man/cb.1"

PASS=0
fail() { echo "  FAIL: $1"; exit 1; }

echo "[1] every user-facing dispatch command is documented in man/cb.1"
# Internal/wrapper-only commands are intentionally undocumented as top-level
# verbs: cd-path is cd's plain alias (documented alongside cd), review-done
# and review-confirm-exit back the in-shell `cb done`/`cb exit` (documented
# under review-shell / cb-review(7)), and __complete is a hidden shell-
# completion helper.
commands="$(grep -oE 'eq\(cmd, "[a-zA-Z0-9_-]+"\)' "$APP" | sed -E 's/eq\(cmd, "([^"]+)"\)/\1/' | sort -u)"
missing=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  case "$cmd" in
    cd-path|review-done|review-confirm-exit|__complete) continue ;;
  esac
  # Every dispatched command gets its own `.Ss <cmd> ...` subsection heading
  # under COMMANDS — a SYNOPSIS mention alone isn't enough documentation.
  if ! grep -qE "^\\.Ss ${cmd//-/\\-}([[:space:]]|\$)" "$PAGE"; then
    echo "  missing from man/cb.1: $cmd"
    missing=$((missing+1))
  fi
done <<< "$commands"
[ "$missing" -eq 0 ] || fail "$missing command(s) undocumented in man/cb.1 (see above)"
PASS=$((PASS+1))

echo "[2] man pages lint clean at ERROR level"
if command -v mandoc >/dev/null 2>&1; then
  out="$(mandoc -Tlint -Wall "$ROOT"/man/cb.1 "$ROOT"/man/cb-config.5 "$ROOT"/man/cb-review.7 2>&1 || true)"
  if echo "$out" | grep -q "ERROR:"; then
    echo "$out"
    fail "mandoc reported ERROR-level issues"
  fi
  PASS=$((PASS+1))
else
  echo "  (mandoc not installed — skipped)"
fi

echo "ALL MAN CHECKS PASSED ($PASS checks)"
