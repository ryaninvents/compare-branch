# cb

## 0.6.0

### Minor Changes

- eab7916: `cb refresh` now re-derives a review's base the same way it was first computed and, if it moved, folds the base branch's own changes into the reviewed baseline — so a base-branch merge or rebase into the reviewed branch, or the base branch simply advancing, reads as already-reviewed instead of muddying the diff with someone else's already-landed code. A path where the base's change genuinely conflicts with already-reviewed content is left pending for re-review rather than silently resolved either way. This now also makes `review-local` refreshes do something: they previously were a no-op.

  Pass `--no-advance-base` to keep the previous behavior, where the working tree updates but the reviewed baseline never moves.

## 0.5.1

### Patch Changes

- e412434: `cb review-shell` now infers the target review worktree from the current directory when run with no arguments, matching `cb refresh`'s existing cwd-detection.

## 0.5.0

### Minor Changes

- 16b9cc2: Add `cb --version` (`-v`), which prints the version cb was built from (`build.zig.zon`'s `.version`, the same value the release pipeline stamps into the tag).
- 3a163ad: Add `cb get-permalink <path>[:<line>[-<line>]]`, which prints a GitHub permalink for a file — and optionally a line or range — pinned to the current `HEAD` so the linked lines can't shift under the reader.

  - Accepts the same `<path>:<line>` / `<path>:<start>-<end>` argument form as `gh browse`, so the two are copy-pasteable between each other. A colon that isn't a line spec (`notes:draft.md`) stays part of the path.
  - Paths are resolved against the repository root rather than the current directory, so `cb get-permalink main.zig:10` from `src/` and `cb get-permalink src/main.zig:10` from the root produce the same link. (`gh browse` resolves against the cwd, where the second spelling silently yields `src/src/main.zig` with a zero exit status.)
  - Only the URL is written to stdout, so the command composes: `cb get-permalink src/main.zig:10-20 | pbcopy`. Every diagnostic goes to stderr.
  - Warns when `HEAD` isn't pushed to any remote, since that link 404s until it is. Exits non-zero when the path doesn't exist at `HEAD` — but prints the URL anyway, because knowing what it would have been is what makes the message actionable.
  - `?plain=1` is kept for Markdown, where GitHub needs it for line anchors to resolve, and dropped everywhere else.
  - `--json` emits `url`, `commit`, `path`, `startLine`, `endLine`, `pushed` and `existsAtCommit`.
  - Needs no registered project — it works in any GitHub checkout. `gh` resolves the host and owner/repo from the git remote, so GitHub Enterprise works on the same terms as `cb review`.

  Also extracts the inline `gh` subprocess spawn in `cb review` into a small `github/gh.zig` wrapper alongside `git/git.zig`, now that there are two call sites.

- 6096c36: Ship man pages (`cb(1)`, `cb-config(5)`, `cb-review(7)`) covering every command, the config template DSL and post-create hooks, and the isolated review model, and install them via Homebrew and the manual release archive. `zig build e2e` now cross-checks every dispatched command against `man/cb.1` and lints the pages with `mandoc` when it's available, so an undocumented command fails the build rather than just review.

## 0.4.0

### Minor Changes

- aba7078: Auto-cd after `cb mk`, git fetch/pull on `cb cd`, divergence reporting for worktrees, and escape cwd on `cb rm`.

  - `cb mk <proj> <key>` now automatically changes directory into the new worktree. Pass `--no-cd` to suppress.
  - `cb mk` runs `git fetch` before creating the branch. Pass `--no-fetch` to suppress.
  - `cb cd <proj>` (base checkout) runs `git fetch` then `git pull` (non-fatal). Pass `--no-fetch` to suppress both, or `--no-pull` to skip only the pull.
  - `cb cd <proj> <key>` (worktree) runs `git fetch` and prints a note if the worktree branch has diverged from its upstream (ahead, behind, or both). No pull is attempted on worktrees.
  - `cb rm` now detects when the removed worktree contains the current working directory and cd's up to the nearest surviving ancestor.

- 90ee54b: `cb rm`, `cb refresh`, and `cb cd` now infer their target from the current directory when positional arguments are omitted, using the same longest-prefix matching as `cb whereami`.

  - `cb rm` with no args removes the worktree containing `$PWD` (still requires confirmation or `--force`); the shell wrapper escapes `$PWD` to a surviving ancestor as before.
  - `cb refresh` with no args falls back to `$PWD` inference outside a review shell (the `CB_REVIEW` env var still takes priority when set).
  - `cb cd` with no args goes to the project checkout for the worktree containing `$PWD`.
  - All three still fail loudly — never guessing — when `$PWD` is outside any registered tree or matches more than one.

- 0ce5310: Add `cb doctor [<key>] [--fix]`, which cross-references the append-only state log against `git worktree list` and the filesystem, since the log can drift out of sync (a manual `git worktree remove`, a deleted directory, a worktree created outside `cb`).

  - Reports **ghost** worktrees (recorded in state but gone from git/disk) and **orphan** worktrees (a real git worktree state doesn't know about).
  - Read-only by default; `--fix` appends corrective events — a removal for each ghost, an adoption for each orphan — never rewriting existing log lines.
  - Review worktrees (`cb review`) aren't real git worktrees (isolated GIT_DIR), so they're only checked for existence on disk, never compared against `git worktree list`.

- cb400d3: Add `-i` to `cb cd` for interactive project/worktree selection: `cb cd -i` picks a project then a worktree; `cb cd <key> -i` picks a worktree within that project (freshest first).

  Uses `fzf` when it's on `PATH`, falling back to a numbered prompt on stderr/stdin otherwise. Refuses outright (never guesses) when the terminal isn't interactive. `cb` remains dependency-free without `fzf` installed.

- bbfec18: Extend `-i` interactive selection to `cb rm` and `cb review-shell` (review/review-local worktrees only), matching `cb cd -i`.

  - `cb rm -i` / `cb rm <key> -i` pick the worktree to remove.
  - `cb review-shell -i` / `cb review-shell <key> -i` pick among review worktrees only.
  - Simplified the shell wrapper's `cb rm` cwd-escape logic: it now checks whether `$PWD` still exists after removal rather than trying to predict the target beforehand, which also makes the escape work correctly for `-i`'s interactive pick.
  - README gains an "Interactive & context-aware" section documenting `$PWD` inference and `-i` together.

- f169c63: `cb mk` now runs `worktrees.onCreate` commands in the new worktree (after `worktrees.copy`), via `$SHELL -c` with output inherited.

  - Sets `CB_PROJECT_DIR`, `CB_PROJECT_KEY`, `CB_WORKTREE_DIR`, `CB_WORKTREE_KEY`, `CB_BRANCH`, `CB_BASE`, and `CB_TICKET` in the command's environment.
  - A failing command stops the remaining `onCreate` hooks but leaves the worktree in place, so it's recoverable rather than silently continuing past a broken setup step.
  - Same project-override-replaces-global lookup and `--no-hooks` gate as `worktrees.copy` (added in the previous release).

- 1a54035: `cb review <key> <target>` now accepts a bare PR number or a PR URL in place of a branch name, resolving it via `gh pr view` (requires the GitHub CLI, authenticated with `gh auth login`).

  - The worktree key becomes `pr-<number>`; the PR's title and author are recorded and shown by `cb ls`/`cb whereami`.
  - No `--repo`/`--hostname` is passed to `gh`, so it infers the target host from the project's git remote — this works against GitHub Enterprise the same way it works against github.com, given a prior `gh auth login --hostname <host>` for that host.
  - A fork PR (no `origin/<branch>` to compare against locally) errors with a pointer to fetching `refs/pull/<n>/head` manually and reviewing that branch by name instead.
  - Missing `gh` gives a clear error; plain branch-name reviews are unaffected.

  Also fixes a bug where `cb review` and `cb review-local` worktree directories weren't canonicalized at creation time (unlike `cb mk`'s), so `cb whereami` and `$PWD`-inference (`cb rm`/`cb refresh`/`cb cd`) could fail to recognize a review worktree on platforms where the work directory sits behind a symlink (e.g. macOS's `/tmp` → `/private/tmp`).

- 5ae7f44: `cb ls <key>` now shows branch, relative age, and a status column (`*` for dirty, `+N`/`-N` for ahead/behind upstream) per worktree; pass `--no-status` to skip the status column's extra `git` calls on a large listing. Bare `cb ls` now shows each project's worktree count.

  Adds `--json` to both forms, emitting the full folded records for scripting.

  Extracted the ahead/behind computation (previously only in `cb cd`'s divergence note) into `Git.aheadBehind`, and added `Git.isDirty`, both shared between `cb rm`'s safety check and `cb ls`'s status column.

- 41e3c5a: `cb rm` now refuses to remove a worktree that has uncommitted/untracked changes or unpushed commits, printing an itemized summary of what's at risk. `--force` bypasses the check entirely (as before).

  - Unpushed commits are counted against the upstream tracking branch when one exists, falling back to the worktree's recorded base branch otherwise.
  - Review worktrees (`cb review`) are exempt — they're throwaway by construction.
  - Dropped the unconditional `--force` previously passed to `git worktree remove` for the non-`--force` path, so git's own safety net (refusing removal with uncommitted changes) is back in play as a backstop.

- c02fbfb: Add `cb whereami`, which identifies the registered project and worktree containing the current directory by matching `$PWD` against every stored project/worktree path.

  - Reports project key, worktree key, kind, branch, path, base, and any ticket/note.
  - Errors outside any registered tree, and refuses to guess (rather than silently picking one) if the current directory matches more than one registered path.
  - Project and worktree directories are now canonicalized (symlinks resolved) at creation time so this matching is reliable across platforms (e.g. macOS's `/tmp` → `/private/tmp`).

- 0ec717e: Add `worktrees.copy` config, so `cb mk` can copy files from the project checkout into the new worktree (e.g. an untracked `.env`) right after creating it.

  - Configured globally under `worktrees.copy`, or per-project under `projects.overrides.<key>.worktrees.copy` (which replaces, not merges with, the global list).
  - Entries are template-DSL values with `projectDir`/`worktreeDir` available alongside the usual `ticket`/`worktree-key` context.
  - A missing source file is a warning, not a failure; entries resolving outside the worktree (`..`, absolute paths) are rejected.
  - `--no-hooks` on `cb mk` skips this.

  This also lays the config plumbing (`worktrees.onCreate`, project overrides) for running post-create setup commands in a follow-up release.

## 0.3.0

### Minor Changes

- 2b0d166: Ship shell integration as real `source`-able files instead of relying on `eval "$(cb-bin init zsh)"`, and add zsh/bash tab-completion. The `cb()` wrapper now lives in `shell/cb.{zsh,bash}` (the single source of truth, embedded into `cb-bin` so `cb init` stays identical), and Homebrew installs the wrappers plus `completions/_cb` and `completions/cb.bash`. Completion includes dynamic project/worktree keys via a new hidden `cb-bin __complete` helper. The `eval` path still works as a no-Homebrew fallback.

## 0.2.0

### Minor Changes

- 2d6182e: Add `rmproject` command to remove a project from tracking. Accepts `--delete-dir` to also delete the checkout directory. Refuses if active worktrees exist.

### Patch Changes

- 0852418: Quote 'done' case label to fix zsh parse error
- 257ef1e: Quote 'exit' case label in shell wrapper to fix zsh parse error (matches the existing 'done' fix).
- 24de3ac: Resolve relative paths passed as `<dir>` to mkproject before storing, so the path remains valid regardless of working directory.
