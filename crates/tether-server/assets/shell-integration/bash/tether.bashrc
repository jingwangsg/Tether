if [[ -z "${TETHER_BASH_INTEGRATION_LOADED:-}" ]]; then
  export TETHER_BASH_INTEGRATION_LOADED=1

  if [[ -f "${HOME}/.bashrc" ]]; then
    . "${HOME}/.bashrc"
  fi

  _tether_bash_rc_dir="${BASH_SOURCE[0]%/*}"
  if [[ -f "${_tether_bash_rc_dir}/tether-integration.bash" ]]; then
    . "${_tether_bash_rc_dir}/tether-integration.bash"
  fi
fi
