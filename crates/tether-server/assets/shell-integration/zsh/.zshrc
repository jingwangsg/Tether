if [[ -z "${TETHER_ZSH_INTEGRATION_LOADED:-}" ]]; then
  export TETHER_ZSH_INTEGRATION_LOADED=1

  if [[ -n "${TETHER_REAL_ZDOTDIR:-}" && -f "${TETHER_REAL_ZDOTDIR}/.zshrc" ]]; then
    source "${TETHER_REAL_ZDOTDIR}/.zshrc"
  elif [[ -f "${HOME}/.zshrc" ]]; then
    source "${HOME}/.zshrc"
  fi

  export TETHER_AGENT_RUNTIME_DIR="${ZDOTDIR%/shell-integration/zsh}/agent"
  export TETHER_AGENT_NOTIFY_BIN="${TETHER_AGENT_RUNTIME_DIR}/bin/tether-agent-notify"
  export CODEX_HOME="${TETHER_AGENT_RUNTIME_DIR}/codex-home"
  export PATH="${TETHER_AGENT_RUNTIME_DIR}/bin:${PATH}"

  if [[ -f "${ZDOTDIR}/tether-integration.zsh" ]]; then
    source "${ZDOTDIR}/tether-integration.zsh"
  fi
fi
