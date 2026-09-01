#!/usr/bin/env bash
# End-to-end tests for `cb mk --standalone`/`--no-standalone`: standalone
# worktrees are independent `git clone --local` checkouts rather than linked
# `git worktree`s, so they survive being mounted alone (e.g. into a container
# volume) with nothing else present. Hermetic, same pattern as review_e2e.sh.
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
  printf 'hello\n' > a.txt; git add -A; git commit -qm base )

"$BIN" mkproject demo "$TMP/proj" --remote "$ORIGIN" > /dev/null

echo "[1] --standalone creates an independent clone, not a linked worktree"
"$BIN" mk demo sa --standalone > /dev/null
WT="$("$BIN" cd-path demo sa --no-fetch)"
[ -d "$WT/.git" ] || fail "standalone worktree should have its own .git directory"
plain_status="$(cd "$WT" && git status --porcelain)"
assert_eq "$plain_status" "" "standalone clone is clean"
plain_remote="$(cd "$WT" && git remote get-url origin)"
assert_eq "$plain_remote" "$ORIGIN" "standalone clone's origin points at the project's real remote"
proj_worktrees="$(cd "$TMP/proj" && git worktree list --porcelain)"
if echo "$proj_worktrees" | grep -qF "$WT"; then fail "a standalone worktree must not appear in the project's git worktree list"; fi
PASS=$((PASS+1))

echo "[2] the standalone clone survives with nothing else present (no alternates, no project object dependency)"
rm -rf "$TMP/proj"
( cd "$WT" && git log --oneline -1 --format=%s ) > /tmp/standalone_log.$$
assert_eq "$(cat /tmp/standalone_log.$$)" "base" "history still resolves after the project checkout is gone"
rm -f /tmp/standalone_log.$$
"$BIN" mkproject demo2 "$TMP/proj2" --remote "$ORIGIN" > /dev/null

echo "[3] --no-standalone always overrides worktrees.standalone: true in config"
printf '{"workDir":["%s/work"], "worktrees": {"standalone": true}}' "$TMP" > "$CB_CONFIG_FILE"
"$BIN" mk demo2 linked --no-standalone > /dev/null
WT2="$("$BIN" cd-path demo2 linked --no-fetch)"
[ -f "$WT2/.git" ] || fail "--no-standalone should produce a linked worktree (.git file, not directory)"
PASS=$((PASS+1))

echo "[4] with no flag, worktrees.standalone: true in config is the default"
"$BIN" mk demo2 fromcfg > /dev/null
WT3="$("$BIN" cd-path demo2 fromcfg --no-fetch)"
[ -d "$WT3/.git" ] || fail "config default should have produced a standalone clone"
PASS=$((PASS+1))

echo "[5] rm --force on a standalone worktree deletes the directory without touching the project's worktree list"
"$BIN" mk demo2 sa2 --standalone > /dev/null
WT4="$("$BIN" cd-path demo2 sa2 --no-fetch)"
echo dirty > "$WT4/x.txt"
if "$BIN" rm demo2 sa2 2>/tmp/rm_err.$$; then fail "rm should refuse a dirty standalone worktree"; fi
assert_contains "$(cat /tmp/rm_err.$$)" "uncommitted or unpushed work" "standalone dirty refusal message"
rm -f /tmp/rm_err.$$
"$BIN" rm demo2 sa2 --force > /dev/null
[ -d "$WT4" ] && fail "--force should have removed the standalone worktree dir"
PASS=$((PASS+1))

echo "[6] doctor checks a standalone worktree for on-disk existence only"
out="$("$BIN" doctor demo2)"
assert_contains "$out" "no issues found" "doctor reports clean after standalone teardown"

echo "ALL E2E PASSED ($PASS assertions)"
