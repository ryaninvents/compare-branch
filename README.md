# cb — disposable git worktree manager

A single, dependency-free binary (written in Zig) that manages git worktrees in a
unified way. Worktrees are cheap and disposable; `cb` makes creating, navigating,
and reviewing them a one-liner. See [`specs/directory-management.md`](specs/directory-management.md)
for the full specification this implements.

## Install

### Homebrew

```sh
brew install ryaninvents/tap/cb
```

Then `source` the shell integration from your rc file:

```sh
# ~/.zshrc
source "$(brew --prefix)/share/cb/cb.zsh"
# ~/.bashrc
source "$(brew --prefix)/share/cb/cb.bash"
```

Tab-completion (zsh and bash) is installed automatically — for zsh it loads once
Homebrew's `site-functions` directory is on your `fpath` (the standard Homebrew
setup), and the `source` line additionally loads the `cb` shell function.

### Manual

Download the archive for your platform from the
[latest release](../../releases/latest) and put `cb-bin` on your `PATH`. The
archive bundles `shell/` (the wrapper functions) and `completions/`. Source the
wrapper for your shell:

```sh
# ~/.zshrc
source /path/to/shell/cb.zsh
fpath=(/path/to/completions $fpath)   # for `cb` tab-completion
# ~/.bashrc
source /path/to/shell/cb.bash
source /path/to/completions/cb.bash   # for `cb` tab-completion
```

Without Homebrew you can also generate the wrapper on the fly with
`eval "$(cb-bin init zsh)"` (or `bash`) — it emits the same function. Either way,
the wrapper defines a shell function named `cb` that fronts the binary: this is
required because a binary cannot change its parent shell's working directory
(`cb cd`) or exit a review shell (`cb exit`/`cb done`). Every other subcommand
forwards straight to `cb-bin`.

## Usage

```sh
cb mkproject <key> [<dir>] [--remote <url>] [--category <cat>] [--worktrees <path>]
cb mk <key> <worktree-key> [-t <ticket>] [--base <branch>] [--branch-name <name>] [-n <note>]
cb cd <key> [<worktree-key>]
cb ls [<key>]
cb rm <key> <worktree-key>

# review flow
cb review <key> <remote-branch> [-t <ticket>] [-n <note>] [--base <branch>] [--no-merge-base] [--shell]
cb review-local <key> <dir>
cb review-shell <key> <worktree-key>
cb refresh [<key> <worktree-key>]   # no args inside a review shell

cb init <zsh|bash>
cb config [path]
```

- **`mkproject`** adopts an existing checkout at `<dir>`, or clones `--remote` into
  it (default `<baseDir>/<key>`).
- **`mk`** creates a branch + worktree. The branch name defaults to the
  `branches.name` template (overridable with `--branch-name`); the base defaults to
  the project's default branch.
- **`cd`** prints/changes to a project checkout or one of its worktrees.

## Reviews

`cb review` checks out a remote branch into a throwaway worktree and wires up an
**isolated review repo** modeled on
[rapid-review](https://github.com/ryaninvents/rapid-review): your real `.git` is
never touched. The review repo shares the project's object database via
`objects/info/alternates` and keeps its own `HEAD`/index, where:

- **`HEAD`** is the reviewed baseline — it starts at `git merge-base <branch> <base>`
  (use `--base` to change the base, `--no-merge-base` to compare against the tip).
- the **working tree** always shows the full target content, and
- **`git status`** is therefore exactly what's left to review.

Inside a review shell you review incrementally: `git add` a file to mark it
reviewed, `git commit` to checkpoint a batch (advancing `HEAD`). `cb refresh`
fetches new upstream commits and updates only the working tree, so amended code you
already reviewed resurfaces without discarding your progress.

`cb review-local <key> <dir>` does the same against a live directory (e.g. AI
output) compared to the project's base branch — and `cb done`/`review-done` never
deletes that directory.

Inside a review shell (`--shell` or `cb review-shell`):

```sh
cb refresh   # pull new changes into the batch
cb exit      # confirm, then leave the shell
cb done      # confirm, leave the shell, and delete the worktree
```

## Configuration

User config lives at `~/.config/cb/config.json` (override with `CB_CONFIG_FILE`).
It is never rewritten by `cb`. Strings use a small JSON template DSL — elements are
concatenated, with `{"var": name}`, `{"date": format}`, and
`{"join": {"delimiter": d, "elements": [...]}}` (empty join elements are dropped).
`var` resolves config-defined names (e.g. `workDir`), per-command values (`ticket`,
`worktree-key`), then environment variables. Built-in defaults:

```jsonc
{
  "workDir": [{"var": "HOME"}, "/work"],
  "projects": { "baseDir": [{"var": "workDir"}, "/.base"] },
  "branches": {
    "name": [{"var": "USER"}, "/", {"date": "YYYYMMDD.HHmmss"}, "/",
             {"join": {"delimiter": "--", "elements": [{"var": "ticket"}, {"var": "worktree-key"}]}}]
  }
}
```

Branch names become directory names by mapping `/` → `--` and other awkward
characters → `-`. Dates are formatted in UTC (tokens: `YYYY MM DD HH mm ss`).

## State

Mutable state (projects, worktrees, timestamps, notes, tickets, review metadata)
is an **append-only ndjson event log** at `~/.local/cb/state.json` (override with
`CB_STATE_FILE`). Current state is derived by folding the log; `cb` never rewrites
earlier lines.

## Build & test

Requires Zig 0.14.1 and git.

```sh
zig build            # build cb-bin into zig-out/bin
zig build test       # unit tests
zig build e2e        # hermetic end-to-end review tests (temp config + state)
zig build release    # cross-compile all four release targets
```

### Releases

`zig` cross-compiles every target from one host, so releases build inside a single
pinned-Zig Docker image (no per-arch runners, no QEMU):

```sh
docker build --target artifacts --output type=local,dest=dist .
```

`scripts/release.sh <tag>` builds that image, packages one `.tar.gz` per target
(macOS arm64/x86_64, Linux arm64/x86_64) with `SHA256SUMS`, and cuts a GitHub
release. It runs locally or via the manually-triggered **release** GitHub Actions
workflow (Actions → release → Run workflow → enter a tag).

## Layout

```
src/
  main.zig            composition root
  cli/                arg parsing, dispatch, command handlers
  config/             config loading + template DSL
  state/              ndjson event log + folded model
  review/             isolated-GIT_DIR review engine
  git/                git subprocess wrapper
  util/               path sanitization, XDG paths
shell/                cb() wrapper functions (cb.zsh/cb.bash), embedded + installed
completions/          zsh (_cb) and bash (cb.bash) tab-completion
e2e/                  end-to-end review tests
```
