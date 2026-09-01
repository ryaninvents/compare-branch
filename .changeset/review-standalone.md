---
"cb": minor
---

`cb review` gains `--standalone`/`--no-standalone`, matching `cb mk`. By default a review checkout is a linked `git worktree` and the review repo depends on the project's object database via `objects/info/alternates` — fast to set up, but neither half can be moved or mounted anywhere alone. `--standalone` instead checks the target out as an independent `git clone --local` with `origin` pointed at the project's real remote, and repacks the review repo's borrowed objects in before dropping its `objects/info/alternates`. The result: both the working tree and the review repo are self-contained, so the whole review directory — worktree, review repo, and review shell included — can be mounted alone into e.g. a container volume with nothing else present.

`--standalone`/`--no-standalone` override the same `worktrees.standalone` config key `cb mk` uses, with the same precedence: an explicit flag always wins over config in either direction.
