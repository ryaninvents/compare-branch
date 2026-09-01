# cb — Agent Guidelines

## Changesets

Every change that affects user-visible behavior, fixes a bug, or changes the public CLI interface **must** include a changeset. Run:

```bash
pnpm changeset
```

Choose the bump type:
- `patch` — bug fixes, documentation, internal refactors with no behavior change
- `minor` — new features, backwards-compatible additions
- `major` — breaking changes to the CLI interface

Commit the generated `.changeset/*.md` file in the same PR as the change. Do not merge without a changeset for any non-trivial change.

## A feature is not done until its man page is

`man/` (`cb.1`, `cb-config.5`, `cb-review.7`) is the reference a user who has *installed* `cb` — rather than cloned this repository — can actually reach with `man cb`. It is not optional polish alongside `--help`: a new user-visible command, flag, environment variable, or file is not complete until the relevant page is edited **in the same commit**. A changed or removed feature gets its man page entry changed or deleted in that same commit — a stale page is worse than no page, since it's the one an installed user actually trusts. `--help` (`src/cli/app.zig`'s `usage`) stays a terse synopsis; it points at the man pages rather than duplicating their content, so the two can't independently drift.

`e2e/man_check.sh` (run by `zig build e2e`) cross-checks every command dispatched in `src/cli/app.zig` against `man/cb.1`'s `COMMANDS` section, and lints all three pages with `mandoc` when it's available — a new command that isn't documented fails `zig build e2e`, not just review. This is a floor, not a substitute for judgment: it only catches a wholly undocumented command, not a documented-but-stale flag list, so still re-read the affected page whenever you touch its command's behavior.

Man pages are handwritten [mdoc](https://man.openbsd.org/mdoc.7), installed by `build.zig`'s `man_pages` table into `share/man/man<N>` (so a local `zig build` reproduces the installed layout), and packaged into release tarballs and the Homebrew formula by `scripts/release.sh`.
