#!/usr/bin/env bash
# End-to-end tests for the review workflow. Everything is hermetic: config and
# state live in a temp dir via CB_CONFIG_FILE / CB_STATE_FILE, and a throwaway
# "origin" repo stands in for a remote. The interactive review-shell is exercised
# by running git against the same GIT_DIR/GIT_WORK_TREE the shell would inherit.
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

# git operations as the review shell would see them (isolated GIT_DIR).
rgit() { local gd="$1" wt="$2"; shift 2; ( cd "$wt" && GIT_DIR="$gd" GIT_WORK_TREE="$wt" git -c user.email=t@t.t -c user.name=t "$@" ); }

# --- fixture: origin repo with main + a feature branch ---
ORIGIN="$TMP/origin"; mkdir -p "$ORIGIN"
( cd "$ORIGIN"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  printf 'hello\n' > a.txt; printf 'keep\n' > b.txt; git add -A; git commit -qm base
  git checkout -q -b feature
  printf 'hello world\n' > a.txt; printf 'new\n' > c.txt; git add -A; git commit -qm feat
  git checkout -q main )

echo "[1] mkproject clones the remote"
out="$("$BIN" mkproject myproj "$TMP/proj" --remote "$ORIGIN")"
assert_contains "$out" "created project 'myproj'" "mkproject output"
[ -d "$TMP/proj/.git" ] || fail "project was not cloned"

echo "[2] review creates a worktree exposing the merge-base delta"
"$BIN" review myproj feature >/dev/null
GD="$TMP/reviews/myproj--feature.git"; WT="$TMP/work/feature"
[ -d "$GD" ] || fail "review git dir missing"
assert_eq "$(cat "$WT/a.txt")" "hello world" "worktree shows target content"
status="$(rgit "$GD" "$WT" status --porcelain)"
assert_contains "$status" "M a.txt" "a.txt modified vs base"
assert_contains "$status" "?? c.txt" "c.txt added vs base"

echo "[3] ls reports the review worktree"
assert_contains "$("$BIN" ls myproj)" "review" "ls shows review kind"

echo "[4] staging + committing a batch shrinks the remaining set"
rgit "$GD" "$WT" add a.txt
rgit "$GD" "$WT" commit -qm 'reviewed a'
status="$(rgit "$GD" "$WT" status --porcelain)"
[ -z "$(echo "$status" | grep 'a.txt' || true)" ] || fail "a.txt should be reviewed now"
assert_contains "$status" "c.txt" "c.txt still pending"

echo "[5] refresh pulls a new upstream commit into the worktree"
( cd "$ORIGIN" && git checkout -q feature && printf 'hello world!!\n' > a.txt && git commit -qam more && git checkout -q main )
"$BIN" refresh myproj feature >/dev/null
assert_eq "$(cat "$WT/a.txt")" "hello world!!" "refresh updated worktree to new target"
# The amended file resurfaces as unreviewed because the reviewed baseline held.
assert_contains "$(rgit "$GD" "$WT" status --porcelain)" "a.txt" "amended file re-exposed"

echo "[6] review-done removes the worktree but not the project"
"$BIN" review-done myproj feature --force >/dev/null
[ ! -d "$WT" ] || fail "worktree dir should be gone"
[ ! -d "$GD" ] || fail "review git dir should be gone"
assert_contains "$("$BIN" ls myproj)" "no worktrees" "worktree dropped from state"

echo "[7] review-local compares a live directory against the base"
D="$TMP/ai-output"; mkdir -p "$D"
printf 'hello LOCAL\n' > "$D/a.txt"; printf 'keep\n' > "$D/b.txt"
"$BIN" review-local myproj "$D" >/dev/null
LGD="$TMP/reviews/myproj--ai-output.git"
[ -d "$LGD" ] || fail "local review git dir missing"
lstatus="$(rgit "$LGD" "$D" status --porcelain)"
assert_contains "$lstatus" "M a.txt" "local edit detected vs base"
[ -z "$(echo "$lstatus" | grep 'b.txt' || true)" ] || fail "unchanged b.txt must not show"

echo "[8] review-done on a local review leaves the user's dir intact"
"$BIN" review-done myproj ai-output --force >/dev/null
[ -d "$D" ] || fail "local review must not delete the user's directory"
[ -f "$D/a.txt" ] || fail "local review files must survive"

echo "ALL E2E PASSED ($PASS assertions)"
