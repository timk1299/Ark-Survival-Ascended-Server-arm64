#!/bin/sh
# Installed as /usr/bin/FEX. Runs the FEX build that fits this CPU.
#
# The image ships the armv8.0, armv8.2 and armv8.4 builds of FEX in
# /opt/fex/<variant>/ (each next to its own FEXServer). The variant is picked
# when the container runs, not when the image is built, because the build
# machine's CPU says nothing about the CPU the image will run on.
# The feature lists are the ones FEX's own Scripts/InstallFEX.py uses.
#
# FEX_VARIANT=armv8.0|armv8.2|armv8.4 forces a variant.
# On a non-arm64 machine the program is started directly, without FEX.

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) exec "$@" ;;
esac

variant="${FEX_VARIANT:-}"
if [ -z "$variant" ]; then
  features=" $(grep -m1 '^Features' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "

  has_all() {
    for feature in "$@"; do
      case "$features" in
        *" $feature "*) ;;
        *) return 1 ;;
      esac
    done
  }

  variant=armv8.0
  if has_all atomics asimdrdm crc32 dcpop; then
    variant=armv8.2
    if has_all fcma jscvt lrcpc paca pacg asimddp flagm ilrcpc uscat; then
      variant=armv8.4
    fi
  fi
fi

if [ ! -x "/opt/fex/$variant/FEX" ]; then
  echo "FEX: no build for variant '$variant' in /opt/fex" >&2
  exit 1
fi

exec "/opt/fex/$variant/FEX" "$@"
