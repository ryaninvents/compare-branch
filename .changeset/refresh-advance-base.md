---
"cb": minor
---

`cb refresh` now re-derives a review's base the same way it was first computed and, if it moved, folds the base branch's own changes into the reviewed baseline — so a base-branch merge or rebase into the reviewed branch, or the base branch simply advancing, reads as already-reviewed instead of muddying the diff with someone else's already-landed code. A path where the base's change genuinely conflicts with already-reviewed content is left pending for re-review rather than silently resolved either way. This now also makes `review-local` refreshes do something: they previously were a no-op.

Pass `--no-advance-base` to keep the previous behavior, where the working tree updates but the reviewed baseline never moves.
