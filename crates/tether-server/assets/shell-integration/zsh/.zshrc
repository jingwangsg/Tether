if [[ -z "${TETHER_ZSH_INTEGRATION_LOADED:-}" ]]; then
  export TETHER_ZSH_INTEGRATION_LOADED=1

  if [[ -n "${TETHER_REAL_ZDOTDIR:-}" && -f "${TETHER_REAL_ZDOTDIR}/.zshrc" ]]; then
    source "${TETHER_REAL_ZDOTDIR}/.zshrc"
  elif [[ -f "${HOME}/.zshrc" ]]; then
    source "${HOME}/.zshrc"
  fi

  if [[ -f "${ZDOTDIR}/tether-integration.zsh" ]]; then
    source "${ZDOTDIR}/tether-integration.zsh"
  fi
fi
