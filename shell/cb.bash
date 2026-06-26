# cb — bash integration. Source this from ~/.bashrc:
#   source "$(brew --prefix)/share/cb/cb.bash"
#
# Defines the `cb` shell function that fronts cb-bin. A binary can't change its
# parent shell's cwd (`cb cd`) or exit a review shell (`cb exit`/`cb done`), so
# those are handled here; everything else forwards to cb-bin. The body is
# POSIX-ish and shared verbatim with cb.zsh.
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

# Completion is delivered separately: Homebrew installs completions/cb.bash into
# bash_completion.d (auto-loaded by bash-completion). For a manual install,
# `source` that file too — see the README.
