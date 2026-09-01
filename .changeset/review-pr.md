---
"cb": minor
---

`cb review <key> <target>` now accepts a bare PR number or a PR URL in place of a branch name, resolving it via `gh pr view` (requires the GitHub CLI, authenticated with `gh auth login`).

- The worktree key becomes `pr-<number>`; the PR's title and author are recorded and shown by `cb ls`/`cb whereami`.
- No `--repo`/`--hostname` is passed to `gh`, so it infers the target host from the project's git remote — this works against GitHub Enterprise the same way it works against github.com, given a prior `gh auth login --hostname <host>` for that host.
- A fork PR (no `origin/<branch>` to compare against locally) errors with a pointer to fetching `refs/pull/<n>/head` manually and reviewing that branch by name instead.
- Missing `gh` gives a clear error; plain branch-name reviews are unaffected.

Also fixes a bug where `cb review` and `cb review-local` worktree directories weren't canonicalized at creation time (unlike `cb mk`'s), so `cb whereami` and `$PWD`-inference (`cb rm`/`cb refresh`/`cb cd`) could fail to recognize a review worktree on platforms where the work directory sits behind a symlink (e.g. macOS's `/tmp` → `/private/tmp`).
