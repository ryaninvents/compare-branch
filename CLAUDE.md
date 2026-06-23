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
