---
"cb": minor
---

Add `cb whereami`, which identifies the registered project and worktree containing the current directory by matching `$PWD` against every stored project/worktree path.

- Reports project key, worktree key, kind, branch, path, base, and any ticket/note.
- Errors outside any registered tree, and refuses to guess (rather than silently picking one) if the current directory matches more than one registered path.
- Project and worktree directories are now canonicalized (symlinks resolved) at creation time so this matching is reliable across platforms (e.g. macOS's `/tmp` → `/private/tmp`).
