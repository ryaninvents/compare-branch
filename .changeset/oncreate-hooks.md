---
"cb": minor
---

`cb mk` now runs `worktrees.onCreate` commands in the new worktree (after `worktrees.copy`), via `$SHELL -c` with output inherited.

- Sets `CB_PROJECT_DIR`, `CB_PROJECT_KEY`, `CB_WORKTREE_DIR`, `CB_WORKTREE_KEY`, `CB_BRANCH`, `CB_BASE`, and `CB_TICKET` in the command's environment.
- A failing command stops the remaining `onCreate` hooks but leaves the worktree in place, so it's recoverable rather than silently continuing past a broken setup step.
- Same project-override-replaces-global lookup and `--no-hooks` gate as `worktrees.copy` (added in the previous release).
