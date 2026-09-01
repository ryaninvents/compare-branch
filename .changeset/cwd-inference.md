---
"cb": minor
---

`cb rm`, `cb refresh`, and `cb cd` now infer their target from the current directory when positional arguments are omitted, using the same longest-prefix matching as `cb whereami`.

- `cb rm` with no args removes the worktree containing `$PWD` (still requires confirmation or `--force`); the shell wrapper escapes `$PWD` to a surviving ancestor as before.
- `cb refresh` with no args falls back to `$PWD` inference outside a review shell (the `CB_REVIEW` env var still takes priority when set).
- `cb cd` with no args goes to the project checkout for the worktree containing `$PWD`.
- All three still fail loudly — never guessing — when `$PWD` is outside any registered tree or matches more than one.
