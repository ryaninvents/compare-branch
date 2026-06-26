# cb

## 0.3.0

### Minor Changes

- 2b0d166: Ship shell integration as real `source`-able files instead of relying on `eval "$(cb-bin init zsh)"`, and add zsh/bash tab-completion. The `cb()` wrapper now lives in `shell/cb.{zsh,bash}` (the single source of truth, embedded into `cb-bin` so `cb init` stays identical), and Homebrew installs the wrappers plus `completions/_cb` and `completions/cb.bash`. Completion includes dynamic project/worktree keys via a new hidden `cb-bin __complete` helper. The `eval` path still works as a no-Homebrew fallback.

## 0.2.0

### Minor Changes

- 2d6182e: Add `rmproject` command to remove a project from tracking. Accepts `--delete-dir` to also delete the checkout directory. Refuses if active worktrees exist.

### Patch Changes

- 0852418: Quote 'done' case label to fix zsh parse error
- 257ef1e: Quote 'exit' case label in shell wrapper to fix zsh parse error (matches the existing 'done' fix).
- 24de3ac: Resolve relative paths passed as `<dir>` to mkproject before storing, so the path remains valid regardless of working directory.
