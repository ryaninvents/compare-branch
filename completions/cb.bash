# bash completion for cb. Subcommands and flags are static (kept in sync with the
# usage block in src/cli/app.zig); project and worktree keys are resolved at
# completion time from `cb-bin __complete`, which folds the state log.
_cb() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  local cmd="${COMP_WORDS[1]}"

  local subcommands="mkproject mk cd ls rmproject rm review review-local refresh review-shell init config exit done"

  # Completing the subcommand itself.
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    return 0
  fi

  case "$cmd" in
    init)
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
    cd|ls|rm|rmproject|mk|review|review-local|refresh|review-shell)
      if [ "$COMP_CWORD" -eq 2 ]; then
        local projects
        projects="$(command cb-bin __complete projects 2>/dev/null)"
        COMPREPLY=( $(compgen -W "$projects" -- "$cur") )
      elif [ "$COMP_CWORD" -eq 3 ]; then
        case "$cmd" in
          cd|rm|review-shell|refresh)
            local worktrees
            worktrees="$(command cb-bin __complete worktrees "${COMP_WORDS[2]}" 2>/dev/null)"
            COMPREPLY=( $(compgen -W "$worktrees" -- "$cur") )
            ;;
        esac
      fi
      ;;
  esac
  return 0
}

complete -F _cb cb
complete -F _cb cb-bin
