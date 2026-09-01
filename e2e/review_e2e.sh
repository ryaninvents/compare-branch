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

echo "[0] --version / -v report the build.zig.zon version"
zon_version="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$ROOT/build.zig.zon" | head -1)"
assert_eq "$("$BIN" --version)" "cb $zon_version" "--version"
assert_eq "$("$BIN" -v)" "cb $zon_version" "-v"

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

echo "[5b] base moved but the PR didn't: refresh is silent (merge-base unchanged)"
( cd "$ORIGIN" && git checkout -q main && printf 'unrelated\n' > z.txt && git add z.txt && git commit -qm 'main moves' && git checkout -q feature )
out="$("$BIN" refresh myproj feature)"
assert_eq "$out" "refreshed 'feature'" "no base-advance summary when merge-base is unchanged"
status="$(rgit "$GD" "$WT" status --porcelain)"
[ -z "$(echo "$status" | grep 'z.txt' || true)" ] || fail "z.txt from main must not appear: main never merged into feature"
( cd "$ORIGIN" && git checkout -q main && git rm -q z.txt && git commit -qm 'undo main moves' && git checkout -q feature )

echo "[5c] author merges main in: main's new file is absorbed as already-reviewed"
( cd "$ORIGIN" && git checkout -q main && printf 'from main\n' > d.txt && git add d.txt && git commit -qm 'main adds d.txt' )
( cd "$ORIGIN" && git checkout -q feature && git merge -q --no-edit main && git checkout -q main )
out="$("$BIN" refresh myproj feature)"
assert_contains "$out" "base advanced" "refresh reports the base advanced"
assert_contains "$out" "(1 file absorbed from main)" "d.txt is the only absorbed file"
status="$(rgit "$GD" "$WT" status --porcelain)"
[ -z "$(echo "$status" | grep 'd.txt' || true)" ] || fail "d.txt absorbed into the baseline must not show as pending"
assert_contains "$status" "c.txt" "c.txt (the author's own unreviewed file) still pending"

echo "[5d] a real conflict between main and the reviewed baseline keeps the reviewed version, re-exposing the file"
( cd "$ORIGIN" && git checkout -q main && printf 'hello MAIN CHANGE\n' > a.txt && git commit -qam 'main changes a.txt' )
( cd "$ORIGIN" && git checkout -q feature
  git merge --no-edit main >/dev/null 2>&1 || true
  printf 'hello MERGED\n' > a.txt && git add a.txt && git commit -qm 'merge main, resolve conflict'
  git checkout -q main )
out="$("$BIN" refresh myproj feature)"
assert_contains "$out" "base advanced" "refresh reports the base advanced"
assert_contains "$out" "need re-review" "conflicted path is called out"
assert_contains "$out" "a.txt" "a.txt is the conflicted path"
status="$(rgit "$GD" "$WT" status --porcelain)"
assert_contains "$status" "a.txt" "a.txt resurfaces: main's change conflicted with the already-reviewed content"

echo "[5e] --no-advance-base keeps the frozen-baseline behavior"
( cd "$ORIGIN" && git checkout -q main && printf 'from main2\n' > e.txt && git add e.txt && git commit -qm 'main adds e.txt' )
( cd "$ORIGIN" && git checkout -q feature && git merge -q --no-edit main && git checkout -q main )
out="$("$BIN" refresh myproj feature --no-advance-base)"
assert_eq "$out" "refreshed 'feature'" "no base-advance summary with --no-advance-base"
status="$(rgit "$GD" "$WT" status --porcelain)"
assert_contains "$status" "e.txt" "e.txt not absorbed: base advance was skipped"

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

echo "[7b] refresh advances a review-local baseline too, without touching the live dir"
( cd "$ORIGIN" && git checkout -q main && printf 'from main3\n' > f.txt && git add f.txt && git commit -qm 'main adds f.txt' && git checkout -q feature )
out="$("$BIN" refresh myproj ai-output)"
assert_contains "$out" "base advanced" "review-local refresh reports the base advanced"
assert_eq "$(cat "$D/a.txt")" "hello LOCAL" "live dir content untouched by refresh"
assert_eq "$(cat "$D/b.txt")" "keep" "live dir content untouched by refresh"
[ ! -e "$D/f.txt" ] || fail "refresh must never write into the live review-local directory"
lstatus="$(rgit "$LGD" "$D" status --porcelain)"
assert_contains "$lstatus" "f.txt" "baseline picked up main's new file, which the live dir doesn't have"
assert_contains "$lstatus" "a.txt" "a.txt still shows: live dir's edit vs baseline"

echo "[8] review-done on a local review leaves the user's dir intact"
"$BIN" review-done myproj ai-output --force >/dev/null
[ -d "$D" ] || fail "local review must not delete the user's directory"
[ -f "$D/a.txt" ] || fail "local review files must survive"

echo "ALL E2E PASSED ($PASS assertions)"
