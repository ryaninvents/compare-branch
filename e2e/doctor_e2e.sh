#!/usr/bin/env bash
# End-to-end tests for `cb doctor`. Hermetic, same pattern as the other e2e
# scripts: config/state in a temp dir, a throwaway "origin" repo.
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
assert_contains() { echo "$1" | grep -qF "$2" || fail "expected to contain '$2': $1 ($3)"; PASS=$((PASS+1)); }
assert_not_contains() { echo "$1" | grep -qF "$2" && fail "expected NOT to contain '$2': $1 ($3)"; PASS=$((PASS+1)); }

ORIGIN="$TMP/origin"; mkdir -p "$ORIGIN"
( cd "$ORIGIN"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m base )

"$BIN" mkproject demo "$TMP/proj" --remote "$ORIGIN" > /dev/null
"$BIN" mk demo feature-x > /dev/null

echo "[1] a clean project reports no issues"
out="$("$BIN" doctor demo)"
assert_contains "$out" "no issues found" "clean doctor"

echo "[2] a worktree removed outside cb becomes a ghost"
wt_dir="$("$BIN" cd-path demo feature-x --no-fetch)"
( cd "$TMP/proj" && git worktree remove --force "$wt_dir" )
out="$("$BIN" doctor demo)"
assert_contains "$out" "ghost worktree 'feature-x'" "ghost detected"

echo "[3] a worktree added outside cb becomes an orphan"
( cd "$TMP/proj" && git worktree add -q -b orphan-branch "$TMP/work/orphan-wt" main )
out="$("$BIN" doctor demo)"
assert_contains "$out" "orphan worktree at" "orphan detected"

echo "[4] --fix reconciles both, and a follow-up run reports clean"
out="$("$BIN" doctor demo --fix)"
assert_contains "$out" "2 issue(s) fixed" "fix count"
out="$("$BIN" ls demo --no-status)"
assert_not_contains "$out" "feature-x" "ghost removed from state"
assert_contains "$out" "orphan-wt" "orphan adopted into state"
out="$("$BIN" doctor demo)"
assert_contains "$out" "no issues found" "clean after fix"

echo "ALL E2E PASSED ($PASS assertions)"
