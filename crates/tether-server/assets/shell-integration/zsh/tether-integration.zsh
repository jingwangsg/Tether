if [[ -z "${TETHER_GHOSTTY_ZSH_INTEGRATION:-}" ]]; then
  export TETHER_GHOSTTY_ZSH_INTEGRATION=1

  _tether_emit() {
    builtin print -rn -- "$1"
  }

  _tether_sanitize_title() {
    builtin print -rn -- "${1//[[:cntrl:]]/}"
  }

  _tether_report_pwd() {
    local host_name="${HOST:-${HOSTNAME:-$(hostname 2>/dev/null)}}"
    _tether_emit $'\e]7;kitty-shell-cwd://'"${host_name}${PWD}"$'\a'
  }

  _tether_precmd() {
    local ret=$?
    if [[ -n "${_tether_executing:-}" ]]; then
      _tether_emit $'\e]133;D;'"${ret}"$'\a'
    fi

    _tether_emit $'\e]133;A;redraw=last;cl=line\a'
    _tether_report_pwd

    if [[ "${GHOSTTY_SHELL_FEATURES:-}" == *"title"* ]]; then
      _tether_emit $'\e]2;'"${(%):-%(4~|…/%3~|%~)}"$'\a'
    fi

    unset _tether_executing
    return $ret
  }

  _tether_preexec() {
    local cmd="$1"
    if [[ -n "$cmd" && "${GHOSTTY_SHELL_FEATURES:-}" == *"title"* ]]; then
      _tether_emit $'\e]2;'"$(_tether_sanitize_title "$cmd")"$'\a'
    fi

    _tether_emit $'\e]133;C\a'
    _tether_executing=1
  }

  autoload -Uz add-zsh-hook 2>/dev/null || true
  if (( $+functions[add-zsh-hook] )); then
    add-zsh-hook precmd _tether_precmd
    add-zsh-hook preexec _tether_preexec
    add-zsh-hook chpwd _tether_report_pwd
  else
    precmd_functions+=(_tether_precmd)
    preexec_functions+=(_tether_preexec)
    chpwd_functions+=(_tether_report_pwd)
  fi
fi
