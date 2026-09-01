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
    mk)
      local __cb_no_cd=0
      local __cb_mk_proj='' __cb_mk_wt='' __cb_pos=0
      local -a __cb_fwd
      __cb_fwd=()
      local __cb_arg
      for __cb_arg in "${@:2}"; do
        case "$__cb_arg" in
          --no-cd) __cb_no_cd=1 ;;
          *)
            __cb_fwd+=("$__cb_arg")
            case "$__cb_arg" in
              -*) ;;
              *)
                __cb_pos=$((__cb_pos + 1))
                [ $__cb_pos -eq 1 ] && __cb_mk_proj="$__cb_arg"
                [ $__cb_pos -eq 2 ] && __cb_mk_wt="$__cb_arg"
                ;;
            esac
            ;;
        esac
      done
      command cb-bin mk "${__cb_fwd[@]}" || return $?
      if [ "$__cb_no_cd" = "0" ]; then
        local __cb_dir
        __cb_dir="$(command cb-bin cd-path --no-fetch "$__cb_mk_proj" "$__cb_mk_wt")" || return $?
        builtin cd "$__cb_dir"
      fi
      ;;
    rm)
      command cb-bin rm "${@:2}" || return $?
      # $PWD may no longer exist: cb-bin infers the target from $PWD when no
      # args are given, and even with an explicit key (or -i's interactive
      # pick, which the wrapper can't predict) that target might be where we
      # are standing. Checking existence after the fact covers every case
      # uniformly instead of trying to predict the target beforehand.
      if [ ! -d "$PWD" ]; then
        local __cb_up="$PWD"
        while [ -n "$__cb_up" ] && [ ! -d "$__cb_up" ]; do
          __cb_up="${__cb_up%/*}"
        done
        [ -n "$__cb_up" ] && builtin cd "$__cb_up"
      fi
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
