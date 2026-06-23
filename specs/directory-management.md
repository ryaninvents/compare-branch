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
  },
  "branches": {
    "name": [{"var": "USER"}, "/", {"date": "YYYYMMDD.HHmmss"}, "/", {"join": {"delimiter": "--", "elements": [{"var": "ticket"},{"var": "worktree-key"}]}}] // this is the default format
  }
}
```

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
cb mk <project-key> <worktree-key> [-t|--ticket <ticket_id>] [--base <branch>] [--branch-name <branch_name>] [-n|--note <note>]
```

Create a new worktree for the given project. The worktree will be identified by the given key.

`-t|--ticket` can be used to track a ticket associated with the worktree.

By default, a new branch is created from the project's default branch, using the format specified in the config. If `--branch-name` is specified, it is used instead. `-n|--note` can be used to attach an optional note to the worktree.

We always keep a timestamp of when each worktree was created.

# Navigating worktrees

```bash
cb cd <project-key> # navigate to a project's main checkout
cb cd <project-key> <worktree-key> # navigate to a given worktree
```

# Listing projects and worktrees

```bash
cb ls # list all projects
cb ls <project-key> # list worktrees for the given project
```

# Destroying worktrees

```bash
cb rm <project-key> <worktree-key>
```

# Reviews

```bash
cb review <project-key> <remote-branch-name> [-t|--ticket <ticket_id>] [-n|--note <note>] [--base <branch>] [--shell]
```

Creates a "review worktree". This is the same as a regular worktree, except with a couple of additional features pertaining to reviews. See <https://github.com/ryaninvents/rapid-review> for a Bash implementation of the review workflow. We're not copying rapid-review, but we're using the same `--git-dir` mechanism to allow the user to review code incrementally.

We always use `git merge-base` when comparing, so that we don't end up having to review all of the commits that landed on the main branch since this one. We can use `--base` to specify a different base, but always use `git merge-base` to get the merge base when comparing (unless `--no-merge-base` is used).

We always store the metadata attached to the given review.

When `--shell` is passed, we immediately open the review shell (described below)

```bash
cb review-local <project-key> <dir>
```

Creates a "local review worktree", typically used to review AI output. Compares the given working directory against the given project's main branch.

```bash
cb refresh <project-key> <worktree-key>
```

Loads new changes into the review batch (see "rapid-review" for more on this concept). For a remote review, fetches latest from the review branch. For a local/AI review, checks the target working directory for new changes.

```bash
cb review-shell <project-key> <worktree-key>
```

Opens a "review shell" in the given worktree. This functions the same as the "rapid-review" utility linked above.

## Special review-only commands

These are only valid inside a review shell:

```bash
cb refresh # Checks the remote for any new changes, and adds them to the review batch.
cb exit # Prompts for confirmation, then exits the review shell.
cb done # Prompts for confirmation, exits the review shell, and deletes the worktree.
```
