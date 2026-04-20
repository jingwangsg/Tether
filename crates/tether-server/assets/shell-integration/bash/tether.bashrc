if [[ -z "${TETHER_BASH_INTEGRATION_LOADED:-}" ]]; then
  export TETHER_BASH_INTEGRATION_LOADED=1

  if [[ -f "${HOME}/.bashrc" ]]; then
    . "${HOME}/.bashrc"
  fi

  _tether_bash_rc_dir="${BASH_SOURCE[0]%/*}"
  export TETHER_AGENT_RUNTIME_DIR="${_tether_bash_rc_dir%/shell-integration/bash}/agent"
  export TETHER_AGENT_NOTIFY_BIN="${TETHER_AGENT_RUNTIME_DIR}/bin/tether-agent-notify"
  export CODEX_HOME="${TETHER_AGENT_RUNTIME_DIR}/codex-home"
  export PATH="${TETHER_AGENT_RUNTIME_DIR}/bin:${PATH}"
  if [[ -f "${_tether_bash_rc_dir}/tether-integration.bash" ]]; then
    . "${_tether_bash_rc_dir}/tether-integration.bash"
  fi
fi
