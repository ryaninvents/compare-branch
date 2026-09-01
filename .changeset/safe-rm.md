---
"cb": minor
---

`cb rm` now refuses to remove a worktree that has uncommitted/untracked changes or unpushed commits, printing an itemized summary of what's at risk. `--force` bypasses the check entirely (as before).

- Unpushed commits are counted against the upstream tracking branch when one exists, falling back to the worktree's recorded base branch otherwise.
- Review worktrees (`cb review`) are exempt — they're throwaway by construction.
- Dropped the unconditional `--force` previously passed to `git worktree remove` for the non-`--force` path, so git's own safety net (refusing removal with uncommitted changes) is back in play as a backstop.
