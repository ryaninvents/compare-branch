---
"cb": minor
---

`cb review` now checks the target out as a real, linked `git worktree` of the project repo instead of a bare directory populated by `checkout-index`. Outside the review shell, plain `git`/`gh` now work in a review worktree exactly as in any other worktree (`git log`, `git status`, `git remote`, `gh pr view --web`) — previously they either failed or silently resolved against whatever repo happened to enclose the worktrees directory. `cb review-shell`'s isolated `GIT_DIR`/`GIT_WORK_TREE` review view is unchanged: `git status` there still shows exactly what's left to review. `cb refresh` now also keeps the plain `cd` view's branch history current as it pulls in new upstream commits.

`cb rm` and `cb review-done` on a review worktree also now correctly remove both the checkout and its review repo — previously `cb rm` (as opposed to `cb review-done`) silently failed to remove either and leaked both. Removing a review worktree now goes through the same uncommitted/unpushed-work safety check as any other worktree, since it's a real worktree that can hold real commits.
