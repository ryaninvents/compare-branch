---
"cb": minor
---

Ship man pages (`cb(1)`, `cb-config(5)`, `cb-review(7)`) covering every command, the config template DSL and post-create hooks, and the isolated review model, and install them via Homebrew and the manual release archive. `zig build e2e` now cross-checks every dispatched command against `man/cb.1` and lints the pages with `mandoc` when it's available, so an undocumented command fails the build rather than just review.
