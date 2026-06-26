# cb — zsh integration. Source this from ~/.zshrc:
#   source "$(brew --prefix)/share/cb/cb.zsh"
#
# Defines the `cb` shell function that fronts cb-bin. A binary can't change its
# parent shell's cwd (`cb cd`) or exit a review shell (`cb exit`/`cb done`), so
# those are handled here; everything else forwards to cb-bin. The body is
# POSIX-ish and shared verbatim with cb.bash.
cb() {
  case "$1" in
    cd)
      local __cb_dir
      __cb_dir="$(command cb-bin cd-path "${@:2}")" || return $?
      builtin cd "$__cb_dir"
      ;;
    'exit')
      if [ -n "$CB_REVIEW" ]; then
        command cb-bin review-confirm-exit && builtin exit
        return $?
      fi
      command cb-bin "$@"
      ;;
    'done')
      if [ -n "$CB_REVIEW" ]; then
        command cb-bin review-done $CB_REVIEW && builtin exit
        return $?
      fi
      command cb-bin "$@"
      ;;
    *)
      command cb-bin "$@"
      ;;
  esac
}

# Bind the bundled `_cb` completion to the function. Homebrew installs `_cb`
# onto $fpath (share/zsh/site-functions), so compinit autoloads it; this compdef
# is a no-op fallback for setups where the function is already known. Guarded so
# sourcing before compinit doesn't error.
if (( $+functions[compdef] )); then
  compdef _cb cb 2>/dev/null
fi
