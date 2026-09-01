---
"cb": minor
---

`cb mk` gains `--standalone`/`--no-standalone`. By default a worktree is still a linked `git worktree`, sharing the project's object database — fast to create, but its `.git` is a pointer back into the project checkout and it can never be moved or mounted anywhere alone. `--standalone` instead creates a fully independent `git clone --local` (hardlinked objects: near-instant, near-zero extra disk on the same filesystem), with `origin` pointed at the project's real remote — self-contained enough to be mounted alone, e.g. into a container volume, with nothing else present. The trade-off: a branch created in a standalone worktree isn't visible from the project checkout (no `git worktree list` entry, no `git log <branch>`) until it's pushed, or fetched from the worktree directly.

A new `worktrees.standalone` config key (respecting the existing per-project `projects.overrides` mechanism) sets the default; an explicit `--standalone`/`--no-standalone` flag always overrides it in either direction. `cb rm` and `cb doctor` both know the difference — a standalone worktree is torn down with a plain directory delete instead of `git worktree remove`, and is never compared against `git worktree list`.
