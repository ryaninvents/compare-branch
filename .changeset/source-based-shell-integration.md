---
"cb": minor
---

Ship shell integration as real `source`-able files instead of relying on `eval "$(cb-bin init zsh)"`, and add zsh/bash tab-completion. The `cb()` wrapper now lives in `shell/cb.{zsh,bash}` (the single source of truth, embedded into `cb-bin` so `cb init` stays identical), and Homebrew installs the wrappers plus `completions/_cb` and `completions/cb.bash`. Completion includes dynamic project/worktree keys via a new hidden `cb-bin __complete` helper. The `eval` path still works as a no-Homebrew fallback.
