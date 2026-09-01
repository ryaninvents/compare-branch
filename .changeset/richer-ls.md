---
"cb": minor
---

`cb ls <key>` now shows branch, relative age, and a status column (`*` for dirty, `+N`/`-N` for ahead/behind upstream) per worktree; pass `--no-status` to skip the status column's extra `git` calls on a large listing. Bare `cb ls` now shows each project's worktree count.

Adds `--json` to both forms, emitting the full folded records for scripting.

Extracted the ahead/behind computation (previously only in `cb cd`'s divergence note) into `Git.aheadBehind`, and added `Git.isDirty`, both shared between `cb rm`'s safety check and `cb ls`'s status column.
