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

Man pages are installed too — see `man cb`, `man cb-config`, and `man cb-review`
for the full command, config, and review-model reference.

### Manual

Download the archive for your platform from the
[latest release](../../releases/latest) and put `cb-bin` on your `PATH`. The
archive bundles `shell/` (the wrapper functions), `completions/`, and `man/`
(point `MANPATH` at it, or `man /path/to/man/cb.1` directly). Source the
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
cb mk <key> <worktree-key> [-t <ticket>] [--base <branch>] [--branch-name <name>] [-n <note>] [--no-hooks]
cb cd [<key> [<worktree-key>]] [-i]
cb ls [<key>] [--json] [--no-status]
cb rm [<key> <worktree-key>] [-i]

# review flow
cb review <key> <remote-branch | PR number | PR URL> [-t <ticket>] [-n <note>] [--base <branch>] [--no-merge-base] [--shell]
cb review-local <key> <dir>
cb review-shell [<key> <worktree-key>] [-i]
cb refresh [<key> <worktree-key>]   # no args inside a review shell, or inferred from $PWD

cb whereami
cb get-permalink <path>[:<line>[-<line>]] [--json]
cb doctor [<key>] [--fix]
cb init <zsh|bash>
cb config [path]
cb --version | -v
```

- **`mkproject`** adopts an existing checkout at `<dir>`, or clones `--remote` into
  it (default `<baseDir>/<key>`).
- **`mk`** creates a branch + worktree. The branch name defaults to the
  `branches.name` template (overridable with `--branch-name`); the base defaults to
  the project's default branch.
- **`cd`** prints/changes to a project checkout or one of its worktrees. With no
  args, it goes to the project checkout for the worktree containing `$PWD`.
  `-i` picks interactively — `cb cd -i` picks a project then a worktree; `cb cd
  <key> -i` picks a worktree within that project. Uses `fzf` when it's on
  `PATH`, otherwise a numbered prompt; refuses (never guesses) outside a
  terminal.
- **`rm`** with no args infers the worktree containing `$PWD` (both `<key>` and
  `<worktree-key>` must be given together, or omitted together). `refresh` does
  the same outside a review shell. Before removing, it refuses (with an
  itemized summary) if the worktree has uncommitted/untracked changes or
  commits not yet pushed upstream — `--force` bypasses this and removes
  regardless. Review worktrees (`cb review`) are exempt, since they're
  throwaway by construction.
- **`whereami`** reports the project, worktree, branch, and base for the current
  directory — inferred by matching `$PWD` against every registered project and
  worktree dir. Outside any registered tree it errors; if two registered dirs
  somehow tie, it refuses to guess and errors instead.
- **`get-permalink`** prints a GitHub permalink for a file, pinned to the
  current `HEAD` so the lines can't shift: `cb get-permalink src/main.zig:10-20`.
  Paths are resolved against the repo root, so the same file gets the same link
  from any directory. Only the URL goes to stdout (`| pbcopy` works); an
  unpushed `HEAD` or a file missing at `HEAD` is reported on stderr, and the
  latter also exits non-zero — the link is printed either way. `--json` emits
  the URL plus commit, path, line range, and both of those checks. Needs `gh`,
  which resolves the host and owner/repo from the git remote, so GitHub
  Enterprise works on the same terms as `cb review`.
- **`ls <key>`** shows branch, age, and a status column (`*` dirty, `+N`/`-N`
  ahead/behind upstream) per worktree; the status column costs a couple of
  `git` calls per worktree, so pass `--no-status` to skip it on a large
  listing. Bare `cb ls` shows each project's worktree count. `--json` emits
  the full records (including `dir`, `kind`, `base`, and timestamps) for
  scripting.
- **`doctor`** cross-references the state log against `git worktree list` and
  the filesystem (the log is the only source of truth, so it can drift — a
  manual `git worktree remove`, a deleted directory, a worktree created
  outside `cb`) and reports **ghost** worktrees (recorded but gone) and
  **orphan** worktrees (real, but unrecorded). Read-only by default; `--fix`
  appends the corrective events — a removal for each ghost, an adoption for
  each orphan — never rewriting history.

## Interactive & context-aware

Most commands that take a `<key> <worktree-key>` pair work without them too:

- **Inferred from `$PWD`** — `cb rm`, `cb refresh`, and `cb cd` (project form)
  accept omitted positionals and resolve the project/worktree containing the
  current directory, the same lookup `cb whereami` reports. This never guesses:
  outside any registered tree, or if `$PWD` somehow matches more than one, the
  command errors instead of picking one.
- **`-i` for interactive selection** — `cb cd -i`, `cb rm -i`, and `cb
  review-shell -i` open a picker instead (`review-shell -i` only offers review
  worktrees). Give a project key to pick just the worktree (`cb cd demo -i`), or
  omit it to pick the project first. Worktrees are listed freshest-first. Uses
  `fzf` when it's on `PATH` (`brew install fzf`), otherwise a numbered
  stdin/stderr prompt — `cb` has no hard dependency on it. Refuses outright, no
  fallback guess, when stdin/stderr isn't a terminal.

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

### Reviewing a pull request

Pass a bare PR number or a PR URL instead of a branch name — `cb review <key>
123` or `cb review <key> https://github.com/o/r/pull/123` — and `cb` resolves
it via `gh pr view` (requires the [GitHub CLI](https://cli.github.com/),
authenticated with `gh auth login`) to its head branch, then reviews that
branch as usual. The worktree key becomes `pr-<number>`, and the PR's title
and author are recorded and shown by `cb ls`/`cb whereami`. `gh` infers the
target host from the project's git remote (no `--repo`/`--hostname` is
passed), so this works against **GitHub Enterprise** the same way it works
against github.com, as long as you've run `gh auth login --hostname
<your-ghe-host>` once. A PR from a fork has no `origin/<branch>` to compare
against locally, so `cb` errors with a pointer to fetching
`refs/pull/<n>/head` manually and reviewing that branch by name instead.

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

### Post-create hooks

`cb mk` can copy files from the project checkout into the new worktree
(e.g. an untracked `.env`) and run setup commands, right after creating it:

```jsonc
{
  "worktrees": {
    "copy": [".env", ".env.local"],
    "onCreate": ["pnpm install"]
  },
  "projects": {
    "overrides": {
      "myproj": { "worktrees": { "onCreate": ["make dev-setup"] } }
    }
  }
}
```

A project override in `projects.overrides.<key>.worktrees` **replaces** the
global `worktrees.copy`/`worktrees.onCreate` for that project entirely — it
doesn't merge with it. Both lists are template-DSL values, with `projectDir`
and `worktreeDir` available alongside the usual `ticket`/`worktree-key`
context.

- `copy` entries must be relative paths inside the worktree (`..` and
  absolute paths are rejected); a missing source is a warning, not a
  failure.
- `onCreate` commands run via `$SHELL -c` in the new worktree, with
  `CB_PROJECT_DIR`, `CB_PROJECT_KEY`, `CB_WORKTREE_DIR`, `CB_WORKTREE_KEY`,
  `CB_BRANCH`, `CB_BASE`, and `CB_TICKET` set, output inherited. A failing
  command stops the remaining hooks but leaves the worktree in place.

`--no-hooks` on `cb mk` skips both.

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
man/                  man pages (cb.1, cb-config.5, cb-review.7), installed
e2e/                  end-to-end review tests
```
