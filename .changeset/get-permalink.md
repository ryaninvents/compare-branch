---
"cb": minor
---

Add `cb get-permalink <path>[:<line>[-<line>]]`, which prints a GitHub permalink for a file — and optionally a line or range — pinned to the current `HEAD` so the linked lines can't shift under the reader.

- Accepts the same `<path>:<line>` / `<path>:<start>-<end>` argument form as `gh browse`, so the two are copy-pasteable between each other. A colon that isn't a line spec (`notes:draft.md`) stays part of the path.
- Paths are resolved against the repository root rather than the current directory, so `cb get-permalink main.zig:10` from `src/` and `cb get-permalink src/main.zig:10` from the root produce the same link. (`gh browse` resolves against the cwd, where the second spelling silently yields `src/src/main.zig` with a zero exit status.)
- Only the URL is written to stdout, so the command composes: `cb get-permalink src/main.zig:10-20 | pbcopy`. Every diagnostic goes to stderr.
- Warns when `HEAD` isn't pushed to any remote, since that link 404s until it is. Exits non-zero when the path doesn't exist at `HEAD` — but prints the URL anyway, because knowing what it would have been is what makes the message actionable.
- `?plain=1` is kept for Markdown, where GitHub needs it for line anchors to resolve, and dropped everywhere else.
- `--json` emits `url`, `commit`, `path`, `startLine`, `endLine`, `pushed` and `existsAtCommit`.
- Needs no registered project — it works in any GitHub checkout. `gh` resolves the host and owner/repo from the git remote, so GitHub Enterprise works on the same terms as `cb review`.

Also extracts the inline `gh` subprocess spawn in `cb review` into a small `github/gh.zig` wrapper alongside `git/git.zig`, now that there are two call sites.
