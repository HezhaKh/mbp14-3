#!/usr/bin/env bash
# install-all.sh
# One-shot enablement for MacBookPro14,3 on Ubuntu 22.04 / kernel 5.15.x.
# Runs each per-device script in a sensible order and prints a pass/fail summary.
# Every step is idempotent, so this is safe to re-run (e.g. after a kernel update).
#
# Usage:
#   sudo ./install-all.sh                 # run everything
#   sudo ./install-all.sh --skip-wifi     # skip one or more steps
#   sudo ./install-all.sh --only-audio    # run a single step
#
# Steps (in order): wifi, bluetooth, audio, touchbar, power
#
# Prerequisite: Secure Boot must be OFF (the audio + Touch Bar modules are out-of-tree).

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Order matters: wifi first (network for the others), then the cheap BT fix, then the
# heavier driver builds.
ALL_STEPS=(wifi bluetooth audio touchbar power)
declare -A SCRIPT=(
  [wifi]="bcm43602-setup.sh"
  [bluetooth]="bluetooth-fix.sh"
  [audio]="audio-fix.sh"
  [touchbar]="touchbar-fix.sh"
  [power]="power-cooling-fix.sh"
)

# --- arg parsing: --skip-X (repeatable) or --only-X (repeatable) ---
declare -A SKIP=() ONLY=()
have_only=0
for arg in "$@"; do
  case "$arg" in
    --skip-*) SKIP["${arg#--skip-}"]=1 ;;
    --only-*) ONLY["${arg#--only-}"]=1; have_only=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $arg (use --skip-<step> or --only-<step>)"; exit 2 ;;
  esac
done

declare -A RESULT=()
for step in "${ALL_STEPS[@]}"; do
  if (( have_only )) && [[ -z "${ONLY[$step]:-}" ]]; then RESULT[$step]="skipped"; continue; fi
  if [[ -n "${SKIP[$step]:-}" ]]; then RESULT[$step]="skipped"; continue; fi

  sh="$SCRIPT_DIR/${SCRIPT[$step]}"
  if [[ ! -f "$sh" ]]; then RESULT[$step]="missing ($sh)"; continue; fi

  echo
  echo "==================== $step :: ${SCRIPT[$step]} ===================="
  if bash "$sh"; then RESULT[$step]="OK"; else RESULT[$step]="FAILED (rc=$?)"; fi
done

echo
echo "==================== SUMMARY ===================="
for step in "${ALL_STEPS[@]}"; do
  printf "  %-10s %s\n" "$step" "${RESULT[$step]:-skipped}"
done
echo
echo "Reboot once when finished — internal audio (and a dark Touch Bar) only come up"
echo "cleanly after a fresh boot."
