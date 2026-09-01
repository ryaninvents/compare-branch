---
"cb": minor
---

Add `worktrees.copy` config, so `cb mk` can copy files from the project checkout into the new worktree (e.g. an untracked `.env`) right after creating it.

- Configured globally under `worktrees.copy`, or per-project under `projects.overrides.<key>.worktrees.copy` (which replaces, not merges with, the global list).
- Entries are template-DSL values with `projectDir`/`worktreeDir` available alongside the usual `ticket`/`worktree-key` context.
- A missing source file is a warning, not a failure; entries resolving outside the worktree (`..`, absolute paths) are rejected.
- `--no-hooks` on `cb mk` skips this.

This also lays the config plumbing (`worktrees.onCreate`, project overrides) for running post-create setup commands in a follow-up release.
