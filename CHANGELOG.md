# cb

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
