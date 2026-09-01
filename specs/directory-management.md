This tool has the ability to manage worktrees in a unified manner for the user. The philosophy: worktrees are cheap and disposable.

Every remote repo is associated with one **project**. A project is simply the main checkout of a given repo. A project has a "key" which is the short name used in the command line.

# Config format

Config is under `~/.config/cb/config.json`. Comments are shown below, but are not acceptable in the actual config.

We use a JSON-based template syntax for string interpolation. It's a little clunky to type, but very clear and deliberately simple. Elements are simply concatenated.

```jsonc
{
  "workDir": [{"var": "HOME"}, "/work"], // "root" directory where all work is presumed to be
  "projects": {
    "baseDir": [{"var": "workDir"}, "/.base"], // parent directory for project checkouts
    "overrides": {
      // per-project overrides, keyed by project-key. Currently only `worktrees`
      // is recognized here, and it *replaces* (does not merge with) the
      // top-level `worktrees` for that project.
      "<project-key>": { "worktrees": { "copy": [], "onCreate": [], "standalone": false } }
    }
  },
  "branches": {
    "name": [{"var": "USER"}, "/", {"date": "YYYYMMDD.HHmmss"}, "/", {"join": {"delimiter": "--", "elements": [{"var": "ticket"},{"var": "worktree-key"}]}}] // this is the default format
  },
  "worktrees": {
    "copy": [], // relative paths copied from the project checkout into a new worktree
    "onCreate": [], // shell commands run in a new worktree after copy
    "standalone": false // default for `cb mk`'s --standalone/--no-standalone; see below
  }
}
```

`copy` and `onCreate` entries are template-DSL values, evaluated with `projectDir`
and `worktreeDir` added to the per-invocation context (alongside `ticket` and
`worktree-key`).

# Filenames

Files are pretty flat. Whenever we create a directory based on a branch name, we *always* convert `/` to `--`. (Other non-filename-friendly characters are also converted to `-`).

# Creating a new project

```
cb mkproject <project-key> [<dir>] [--category <cat>] [--worktrees <path>]
```

Create a project with the given key. Optionally, set the given directory for the main checkout, and use the given `--worktrees` directory as a container for worktrees.

By default, worktrees are created directly in `workDir`. If `--category` is provided, it is used to nest the worktree under `workDir`: for example, if `workDir` is `~/Work` and you pass `--category Experiments`, then the worktree will be created in `~/Work/Experiments`. There is no central registry of "categories". If you need further customization you may fully override the worktrees location with `--worktrees`.

# Creating a new worktree
```bash
cb mk <project-key> <worktree-key> [-t|--ticket <ticket_id>] [--base <branch>] [--branch-name <branch_name>] [-n|--note <note>] [--no-hooks] [--standalone|--no-standalone]
```

Create a new worktree for the given project. The worktree will be identified by the given key.

`-t|--ticket` can be used to track a ticket associated with the worktree.

By default, a new branch is created from the project's default branch, using the format specified in the config. If `--branch-name` is specified, it is used instead. `-n|--note` can be used to attach an optional note to the worktree.

We always keep a timestamp of when each worktree was created.

By default the worktree is a linked `git worktree`: fast to create, but it shares the
project's object database and can never be moved or mounted anywhere alone — its `.git`
is a pointer back into the project checkout. `--standalone` instead creates a fully
independent `git clone --local` (hardlinked objects: near-instant, near-zero extra disk
on the same filesystem), with `origin` pointed at the project's real remote — self-contained
enough to be mounted alone (e.g. into a container volume) with nothing else present. The
trade-off: a branch created in a standalone worktree isn't visible from the project
checkout (no `git worktree list` entry, no `git log <branch>`) until it's pushed, or
fetched from the worktree directly. `--standalone`/`--no-standalone` override
`worktrees.standalone` in either direction; an explicit flag always wins over config,
`--no-standalone` wins if both are somehow given, and with neither flag the project's
`worktrees.standalone` config value decides (default `false`).

`cb rm` tears a standalone worktree down with a plain directory delete instead of
`git worktree remove`, since it was never registered with the project repo to begin
with. `cb doctor` only checks a standalone worktree for on-disk existence, never
against `git worktree list`.

After the worktree is created, we run **post-create hooks** from the
`worktrees` config (see Config format): each `copy` entry is copied from the
project checkout into the new worktree (a missing source warns, doesn't
fail; entries resolving outside the worktree are rejected), then each
`onCreate` command runs via `$SHELL -c` in the new worktree with
`CB_PROJECT_DIR`/`CB_PROJECT_KEY`/`CB_WORKTREE_DIR`/`CB_WORKTREE_KEY`/
`CB_BRANCH`/`CB_BASE`/`CB_TICKET` set. A failing `onCreate` command stops the
remaining hooks but leaves the worktree in place. `--no-hooks` skips both.

# Navigating worktrees

```bash
cb cd <project-key> # navigate to a project's main checkout
cb cd <project-key> <worktree-key> # navigate to a given worktree
cb cd # navigate to the project checkout for the worktree containing $PWD
cb cd <project-key> -i # interactively pick a worktree (fzf, or a numbered prompt)
cb cd -i # interactively pick a project, then a worktree
```

# Listing projects and worktrees

```bash
cb ls # list all projects, with each project's worktree count
cb ls <project-key> # list worktrees for the given project: branch, age, and status
cb ls [<project-key>] --json # emit the full records as JSON
cb ls <project-key> --no-status # skip the status column's extra git calls
```

The status column (per worktree) shows `*` when dirty and `+N`/`-N` for
commits ahead/behind the upstream tracking branch.

# Destroying worktrees

```bash
cb rm <project-key> <worktree-key> [--force]
cb rm # remove the worktree containing $PWD (both args must be given together, or omitted together)
cb rm -i # interactively pick a worktree to remove (project key optional, same as cd -i)
```

Before removing, `cb rm` refuses (printing an itemized summary) if the
worktree has uncommitted/untracked changes or commits not yet pushed
upstream; `--force` bypasses this. Review worktrees are exempt, since
they're throwaway by construction.

# Identifying the current worktree

```bash
cb whereami
```

Reports the project, worktree, kind, branch, path, base, and any ticket/note
for the directory containing `$PWD`, using the same longest-prefix match
that powers the omitted-argument forms above. Outside any registered
project/worktree it errors; if `$PWD` somehow matches two registered
directories at the same depth, it refuses to guess and errors instead.

# Reconciling state with reality

```bash
cb doctor [<project-key>] [--fix]
```

The state log is the only source of truth for what `cb` believes exists, and
it can drift from reality — a worktree removed with plain `git worktree
remove`, a directory deleted by hand, a worktree created outside `cb`.
`doctor` cross-references the state log against `git worktree list` and the
filesystem and reports:

- **ghost** worktrees — recorded in state, but gone from git/disk.
- **orphan** worktrees — a real git worktree under the project that state
  doesn't know about.

Read-only by default. `--fix` appends corrective events (a removal for each
ghost, an adoption for each orphan) — consistent with the append-only log,
this never rewrites existing lines. `cb review` worktrees are real linked
`git worktree`s of the project repo (see Reviews below) and are compared
against `git worktree list` like ordinary ones. `cb review-local` worktrees
point at the user's own directory and are only checked for existence on
disk.

# Reviews

```bash
cb review <project-key> <remote-branch-name | PR-number | PR-URL> [-t|--ticket <ticket_id>] [-n|--note <note>] [--base <branch>] [--shell] [--standalone|--no-standalone]
```

Creates a "review worktree": a real `git worktree` of the project repo, checked out at the target branch, so plain `git`/`gh` (log, status, remotes, `gh pr view --web`) work in it like any other worktree. Alongside it, `cb` creates a second, isolated git directory — the *review repo* — that shares the project's object database but keeps its own `HEAD`/index/refs. See <https://github.com/ryaninvents/rapid-review> for a Bash implementation of the review workflow. We're not copying rapid-review, but we're using the same `--git-dir` mechanism, layered on top of the real worktree, to allow the user to review code incrementally: `cb review-shell` points `GIT_DIR`/`GIT_WORK_TREE` at the review repo so `git status` there shows only what's left to review; a plain `cd` into the same directory sees the real branch history instead. See <cb-review(7)> for the mechanism in full.

We always use `git merge-base` when comparing, so that we don't end up having to review all of the commits that landed on the main branch since this one. We can use `--base` to specify a different base, but always use `git merge-base` to get the merge base when comparing (unless `--no-merge-base` is used).

We always store the metadata attached to the given review.

When `--shell` is passed, we immediately open the review shell (described below)

By default the checkout is a linked `git worktree` and the review repo depends on the
project's object database via `objects/info/alternates` — fast to set up, but neither
half can be moved or mounted anywhere alone. `--standalone` instead checks the target
out as an independent `git clone --local` (hardlinked objects, near-instant, near-zero
extra disk on the same filesystem) with `origin` pointed at the project's real remote,
and repacks the review repo's borrowed objects in before dropping its
`objects/info/alternates`. The result: both halves are self-contained, so the whole
review directory — worktree and review repo alike, review shell included — can be
mounted alone with nothing else present. `--standalone`/`--no-standalone` override
`worktrees.standalone` the same way they do for `cb mk` (see above): an explicit flag
always wins over config in either direction, `--no-standalone` wins if both are somehow
given, and with neither the project's `worktrees.standalone` config value decides.

## Reviewing a pull request

A bare number, or a URL containing `/pull/<n>`, is resolved as a pull
request via `gh pr view` (the GitHub CLI, must be installed and
authenticated) rather than treated as a branch name directly. No
`--repo`/`--hostname` override is passed — `gh` infers the target host from
the project's git remote, so this covers GitHub Enterprise the same way it
covers github.com, given a prior `gh auth login --hostname <host>`. The
resolved head branch is then reviewed exactly as if it had been passed
directly. The worktree key becomes `pr-<number>`, and the PR's title/author
are recorded and shown by `cb ls`/`cb whereami`. Missing `gh` errors clearly;
plain branch reviews are unaffected. A fork PR (no `origin/<branch>` to
compare against locally) errors with a pointer to fetching
`refs/pull/<n>/head` manually and reviewing that branch by name instead.

```bash
cb review-local <project-key> <dir>
```

Creates a "local review worktree", typically used to review AI output. Compares the given working directory against the given project's main branch.

```bash
cb refresh <project-key> <worktree-key>
cb refresh # inside a review shell: from CB_REVIEW; otherwise: the worktree containing $PWD
```

Loads new changes into the review batch (see "rapid-review" for more on this concept). For a remote review, fetches latest from the review branch. For a local/AI review, checks the target working directory for new changes.

```bash
cb review-shell <project-key> <worktree-key>
cb review-shell [<project-key>] -i
```

Opens a "review shell" in the given worktree. This functions the same as the "rapid-review" utility linked above. `-i` picks interactively among review/local-review worktrees only (project key optional, same lookup as `cb cd -i`).

## Special review-only commands

These are only valid inside a review shell:

```bash
cb refresh # Checks the remote for any new changes, and adds them to the review batch.
cb exit # Prompts for confirmation, then exits the review shell.
cb done # Prompts for confirmation, exits the review shell, and deletes the worktree.
```
