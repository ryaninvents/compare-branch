---
"cb": minor
---

Auto-cd after `cb mk`, git fetch on branch creation and base checkout, and escape cwd on `cb rm`.

- `cb mk <proj> <key>` now automatically changes directory into the new worktree. Pass `--no-cd` to suppress.
- `cb mk` and `cb cd <proj>` (no worktree key) now run `git fetch` before acting. Pass `--no-fetch` to either command to suppress.
- `cb rm` now detects when the removed worktree contains the current working directory and cd's up to the nearest surviving ancestor.
