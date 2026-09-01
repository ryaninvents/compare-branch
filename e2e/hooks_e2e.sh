#!/usr/bin/env bash
# End-to-end tests for post-create hooks (worktrees.copy). Hermetic, same
# pattern as the other e2e scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CB_BIN:-$ROOT/zig-out/bin/cb-bin}"
[ -x "$BIN" ] || { echo "binary not found at $BIN — run 'zig build' first"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CB_CONFIG_FILE="$TMP/config.json"
export CB_STATE_FILE="$TMP/state.json"

PASS=0
fail() { echo "  FAIL: $1"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; PASS=$((PASS+1)); }

ORIGIN="$TMP/origin"; mkdir -p "$ORIGIN"
( cd "$ORIGIN"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m base )

"$BIN" mkproject demo "$TMP/proj" --remote "$ORIGIN" > /dev/null
# Untracked — proves the copy hook did it, not git's normal checkout.
echo "REAL=secret" > "$TMP/proj/.env"

echo "[1] worktrees.copy copies an untracked file into the new worktree"
printf '{"workDir":["%s/work"],"worktrees":{"copy":[".env"]}}' "$TMP" > "$CB_CONFIG_FILE"
"$BIN" mk demo feature-x > /dev/null
wt_dir="$("$BIN" cd-path demo feature-x --no-fetch)"
assert_eq "$(cat "$wt_dir/.env")" "REAL=secret" "copied .env content"

echo "[2] --no-hooks skips it"
"$BIN" mk demo feature-y --no-hooks > /dev/null
wt_dir2="$("$BIN" cd-path demo feature-y --no-fetch)"
[ -f "$wt_dir2/.env" ] && fail "--no-hooks should have skipped the copy"
PASS=$((PASS+1))

echo "[3] a project override replaces (not merges with) the global list"
printf '{"workDir":["%s/work"],"worktrees":{"copy":[".env"]},"projects":{"overrides":{"demo":{"worktrees":{"copy":["only-override.txt"]}}}}}' "$TMP" > "$CB_CONFIG_FILE"
echo "override" > "$TMP/proj/only-override.txt"
"$BIN" mk demo feature-z > /dev/null
wt_dir3="$("$BIN" cd-path demo feature-z --no-fetch)"
[ -f "$wt_dir3/.env" ] && fail "project override should have replaced the global copy list"
assert_eq "$(cat "$wt_dir3/only-override.txt")" "override" "override-only file copied"

echo "ALL E2E PASSED ($PASS assertions)"
