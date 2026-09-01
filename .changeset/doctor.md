---
"cb": minor
---

Add `cb doctor [<key>] [--fix]`, which cross-references the append-only state log against `git worktree list` and the filesystem, since the log can drift out of sync (a manual `git worktree remove`, a deleted directory, a worktree created outside `cb`).

- Reports **ghost** worktrees (recorded in state but gone from git/disk) and **orphan** worktrees (a real git worktree state doesn't know about).
- Read-only by default; `--fix` appends corrective events — a removal for each ghost, an adoption for each orphan — never rewriting existing log lines.
- Review worktrees (`cb review`) aren't real git worktrees (isolated GIT_DIR), so they're only checked for existence on disk, never compared against `git worktree list`.
