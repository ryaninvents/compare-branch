---
"cb": minor
---

Auto-cd after `cb mk`, git fetch/pull on `cb cd`, divergence reporting for worktrees, and escape cwd on `cb rm`.

- `cb mk <proj> <key>` now automatically changes directory into the new worktree. Pass `--no-cd` to suppress.
- `cb mk` runs `git fetch` before creating the branch. Pass `--no-fetch` to suppress.
- `cb cd <proj>` (base checkout) runs `git fetch` then `git pull` (non-fatal). Pass `--no-fetch` to suppress both, or `--no-pull` to skip only the pull.
- `cb cd <proj> <key>` (worktree) runs `git fetch` and prints a note if the worktree branch has diverged from its upstream (ahead, behind, or both). No pull is attempted on worktrees.
- `cb rm` now detects when the removed worktree contains the current working directory and cd's up to the nearest surviving ancestor.
