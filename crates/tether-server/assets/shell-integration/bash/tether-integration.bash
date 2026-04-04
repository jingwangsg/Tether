if [[ -z "${TETHER_GHOSTTY_BASH_INTEGRATION:-}" ]]; then
  export TETHER_GHOSTTY_BASH_INTEGRATION=1

  __tether_emit() {
    builtin printf '%b' "$1"
  }

  __tether_sanitize_title() {
    local value="$1"
    value="${value//$'\e'/}"
    value="${value//$'\a'/}"
    builtin printf '%s' "$value"
  }

  __tether_report_pwd() {
    local host_name="${HOSTNAME:-$(hostname 2>/dev/null)}"
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$host_name" "$PWD"
  }

  __tether_precmd() {
    local ret=$?
    _TETHER_IN_PRECMD=1

    if [[ -n "${_TETHER_EXECUTING:-}" ]]; then
      builtin printf '\e]133;D;%s\a' "$ret"
    fi

    __tether_emit '\e]133;A;redraw=last;cl=line\a'
    __tether_report_pwd

    if [[ "${GHOSTTY_SHELL_FEATURES:-}" == *"title"* ]]; then
      builtin printf '\e]2;%s\a' "${PWD}"
    fi

    unset _TETHER_EXECUTING
    unset _TETHER_PREEXEC_FIRED
    unset _TETHER_IN_PRECMD
    return "$ret"
  }

  __tether_preexec() {
    if [[ -n "${COMP_LINE:-}" ]]; then
      return
    fi
    if [[ -n "${_TETHER_IN_PRECMD:-}" ]]; then
      return
    fi
    if [[ -n "${_TETHER_PREEXEC_FIRED:-}" ]]; then
      return
    fi

    _TETHER_PREEXEC_FIRED=1
    local cmd="${BASH_COMMAND:-}"
    if [[ -n "$cmd" && "${GHOSTTY_SHELL_FEATURES:-}" == *"title"* ]]; then
      builtin printf '\e]2;%s\a' "$(__tether_sanitize_title "$cmd")"
    fi

    __tether_emit '\e]133;C\a'
    _TETHER_EXECUTING=1
  }

  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a "* ]]; then
    _tether_has_precmd=0
    for _tether_prompt_command in "${PROMPT_COMMAND[@]}"; do
      if [[ "$_tether_prompt_command" == "__tether_precmd" ]]; then
        _tether_has_precmd=1
        break
      fi
    done
    if [[ $_tether_has_precmd -eq 0 ]]; then
      _tether_joined_prompt_command=""
      for _tether_prompt_command in "${PROMPT_COMMAND[@]}"; do
        if [[ -n "$_tether_joined_prompt_command" ]]; then
          _tether_joined_prompt_command+="; "
        fi
        _tether_joined_prompt_command+="${_tether_prompt_command}"
      done
      if [[ -n "$_tether_joined_prompt_command" ]]; then
        _tether_joined_prompt_command+="; "
      fi
      PROMPT_COMMAND="${_tether_joined_prompt_command}__tether_precmd"
      unset _tether_joined_prompt_command
    fi
    unset _tether_has_precmd
    unset _tether_prompt_command
  elif [[ -z "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="__tether_precmd"
  else
    case ";${PROMPT_COMMAND};" in
      *";__tether_precmd;"*) ;;
      *)
        [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
        PROMPT_COMMAND+=" __tether_precmd"
        ;;
    esac
  fi

  trap '__tether_preexec' DEBUG
fi
