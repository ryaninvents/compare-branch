---
"cb": minor
---

Extend `-i` interactive selection to `cb rm` and `cb review-shell` (review/review-local worktrees only), matching `cb cd -i`.

- `cb rm -i` / `cb rm <key> -i` pick the worktree to remove.
- `cb review-shell -i` / `cb review-shell <key> -i` pick among review worktrees only.
- Simplified the shell wrapper's `cb rm` cwd-escape logic: it now checks whether `$PWD` still exists after removal rather than trying to predict the target beforehand, which also makes the escape work correctly for `-i`'s interactive pick.
- README gains an "Interactive & context-aware" section documenting `$PWD` inference and `-i` together.
