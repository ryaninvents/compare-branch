---
"cb": minor
---

Add `-i` to `cb cd` for interactive project/worktree selection: `cb cd -i` picks a project then a worktree; `cb cd <key> -i` picks a worktree within that project (freshest first).

Uses `fzf` when it's on `PATH`, falling back to a numbered prompt on stderr/stdin otherwise. Refuses outright (never guesses) when the terminal isn't interactive. `cb` remains dependency-free without `fzf` installed.
