# cb

## 0.2.0

### Minor Changes

- 2d6182e: Add `rmproject` command to remove a project from tracking. Accepts `--delete-dir` to also delete the checkout directory. Refuses if active worktrees exist.

### Patch Changes

- 0852418: Quote 'done' case label to fix zsh parse error
- 257ef1e: Quote 'exit' case label in shell wrapper to fix zsh parse error (matches the existing 'done' fix).
- 24de3ac: Resolve relative paths passed as `<dir>` to mkproject before storing, so the path remains valid regardless of working directory.
