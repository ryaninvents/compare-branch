#!/usr/bin/env bash
# End-to-end tests for `cb mk`/`cb rm` worktree safety. Hermetic, same pattern
# as review_e2e.sh: config/state in a temp dir, a throwaway "origin" repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CB_BIN:-$ROOT/zig-out/bin/cb-bin}"
[ -x "$BIN" ] || { echo "binary not found at $BIN — run 'zig build' first"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CB_CONFIG_FILE="$TMP/config.json"
export CB_STATE_FILE="$TMP/state.json"
printf '{"workDir":["%s/work"]}' "$TMP" > "$CB_CONFIG_FILE"

PASS=0
fail() { echo "  FAIL: $1"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; PASS=$((PASS+1)); }
assert_contains() { echo "$1" | grep -qF "$2" || fail "expected to contain '$2': $1 ($3)"; PASS=$((PASS+1)); }

ORIGIN="$TMP/origin"; mkdir -p "$ORIGIN"
( cd "$ORIGIN"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m base )

"$BIN" mkproject demo "$TMP/proj" --remote "$ORIGIN" > /dev/null

echo "[1] rm refuses a worktree with uncommitted changes"
"$BIN" mk demo dirty > /dev/null
wt_dir="$("$BIN" cd-path demo dirty --no-fetch)"
echo scratch > "$wt_dir/scratch.txt"
if "$BIN" rm demo dirty 2>/tmp/rm_err.$$; then fail "rm should have refused a dirty worktree"; fi
assert_contains "$(cat /tmp/rm_err.$$)" "uncommitted or unpushed work" "dirty refusal message"
rm -f /tmp/rm_err.$$
[ -d "$wt_dir" ] || fail "dirty worktree should not have been removed"

echo "[2] --force removes it anyway"
"$BIN" rm demo dirty --force > /dev/null
[ -d "$wt_dir" ] && fail "--force should have removed the worktree"

echo "[3] rm refuses a worktree with unpushed commits"
"$BIN" mk demo unpushed > /dev/null
wt_dir2="$("$BIN" cd-path demo unpushed --no-fetch)"
( cd "$wt_dir2" && git -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m wip )
if "$BIN" rm demo unpushed 2>/tmp/rm_err2.$$; then fail "rm should have refused unpushed commits"; fi
assert_contains "$(cat /tmp/rm_err2.$$)" "uncommitted or unpushed work" "unpushed refusal message"
rm -f /tmp/rm_err2.$$
"$BIN" rm demo unpushed --force > /dev/null

echo "[4] a clean worktree removes via the normal y/N confirm"
"$BIN" mk demo clean > /dev/null
wt_dir3="$("$BIN" cd-path demo clean --no-fetch)"
out="$(echo y | "$BIN" rm demo clean)"
assert_contains "$out" "removed worktree 'clean'" "clean rm output"
[ -d "$wt_dir3" ] && fail "clean worktree should have been removed"

echo "[5] a review worktree is exempt from the dirty check"
( cd "$ORIGIN" && git checkout -q -b feature && git commit -q --allow-empty -m feat && git checkout -q main )
"$BIN" review demo feature > /dev/null
out="$(echo y | "$BIN" rm demo feature)"
assert_contains "$out" "removed worktree 'feature'" "review rm output"

echo "ALL E2E PASSED ($PASS assertions)"
