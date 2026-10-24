#!/bin/bash

POK_SCRIPTS_DIR="${POK_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${POK_SCRIPTS_DIR}/common.sh"

main() {
  local target_url="${1:-https://ark-server-api.com/}"
  local probe="${POK_HTTPS_PROBE_EXE:-/home/pok/require_files/pok_https_probe.exe}"

  prepare_runtime_env
  initialize_proton_prefix || return 1
  if [ ! -f "$probe" ]; then
    echo "ERROR: Windows HTTPS probe is missing: $probe" >&2
    return 1
  fi

  echo "Testing Windows HTTPS through pinned Proton: $target_url"
  run_with_pinned_proton "$probe" "$target_url"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
