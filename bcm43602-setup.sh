#!/usr/bin/env bash
# bcm43602-setup.sh
# Setup Wi-Fi (BCM43602) on MacBookPro14,3 for Ubuntu 22.04 / kernel 5.15.x

set -Eeuo pipefail

# --- Tweakables / defaults ---
FW_URL_DEFAULT="https://raw.githubusercontent.com/HezhaKh/mbp14-3/refs/heads/main/brcmfmac43602-pcie.txt"
REGDOMAIN="${REGDOMAIN:-}"        # e.g. export REGDOMAIN=CA  (leave empty to skip)
FW_URL="${FW_URL:-$FW_URL_DEFAULT}"

FWDIR="/lib/firmware/brcm"
TARGET="$FWDIR/brcmfmac43602-pcie.txt"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET.bak.$STAMP"

# --- Helpers ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }

as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

info()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[ OK ]\e[0m $*"; }
fail()  { echo -e "\e[1;31m[FAIL]\e[0m $*"; exit 1; }

update_initramfs() {
  if command -v update-initramfs >/dev/null 2>&1; then
    info "Updating initramfs (all kernels)..."
    update-initramfs -u -k all
  elif command -v dracut >/dev/null 2>&1; then
    info "Dracut detected — rebuilding..."
    dracut -f
  else
    warn "No initramfs tool found (update-initramfs/dracut). Skipping."
  fi
}

set_persistent_regdomain() {
  local code="$1"
  [[ -z "$code" ]] && return 0

  info "Setting persistent regulatory domain to: $code"
  mkdir -p /etc/modprobe.d
  echo "options cfg80211 ieee80211_regdom=$code" > /etc/modprobe.d/cfg80211-regdom.conf

  # Also try to align the firmware ccode= for cleaner channel behavior
  if grep -q '^ccode=' "$TARGET" 2>/dev/null; then
    sed -i "s/^ccode=.*/ccode=$code/" "$TARGET"
  else
    echo "ccode=$code" >> "$TARGET"
  fi
}

reload_brcmfmac() {
  info "Reloading brcmfmac module..."
  # If NetworkManager is aggressively managing Wi-Fi, a quick kill isn't necessary here.
  modprobe -r brcmfmac 2>/dev/null || true
  sleep 1
  modprobe brcmfmac
}

# --- Main ---
as_root "$@"
need_cmd uname
need_cmd grep
need_cmd sed
need_cmd tee
need_cmd mkdir
need_cmd cp
need_cmd modprobe
need_cmd dmesg
need_cmd iw

info "Detected system:"
echo "  Product: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'unknown')"
echo "  Kernel : $(uname -r)"

if [[ "$(uname -r)" != 5.15.* ]]; then
  warn "Kernel is not 5.15.x. Script is tuned for 5.15.x but will proceed."
fi

if [[ -f /sys/class/dmi/id/product_name ]] && ! grep -q "MacBookPro14,3" /sys/class/dmi/id/product_name; then
  warn "This does not look like a MacBookPro14,3. Proceeding anyway."
fi

mkdir -p "$FWDIR"

if [[ -f "$TARGET" ]]; then
  info "Backing up existing firmware NVRAM to: $BACKUP"
  cp -a "$TARGET" "$BACKUP"
fi

TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# Try download; if it fails, fall back to local file next to the script (if present).
if command -v curl >/dev/null 2>&1; then
  info "Downloading NVRAM from: $FW_URL"
  if ! curl -fsSL "$FW_URL" -o "$TMP"; then
    warn "Download failed, checking for local ./brcmfmac43602-pcie.txt next to script."
  fi
elif command -v wget >/dev/null 2>&1; then
  info "Downloading NVRAM from: $FW_URL"
  if ! wget -qO "$TMP" "$FW_URL"; then
    warn "Download failed, checking for local ./brcmfmac43602-pcie.txt next to script."
  fi
else
  warn "No curl/wget found, checking for local ./brcmfmac43602-pcie.txt next to script."
fi

if [[ ! -s "$TMP" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [[ -s "$SCRIPT_DIR/brcmfmac43602-pcie.txt" ]]; then
    info "Using local NVRAM file from script directory."
    cp -f "$SCRIPT_DIR/brcmfmac43602-pcie.txt" "$TMP"
  else
    fail "Could not obtain NVRAM file (download failed and no local copy found)."
  fi
fi

info "Installing NVRAM to $TARGET"
cp -f "$TMP" "$TARGET"
chmod 0644 "$TARGET"
chown root:root "$TARGET"

# Optional: persistent reg domain
if [[ -n "$REGDOMAIN" ]]; then
  set_persistent_regdomain "$REGDOMAIN"
fi

update_initramfs
reload_brcmfmac

# Live (non-persistent) reg change if requested
if [[ -n "$REGDOMAIN" ]]; then
  info "Applying live reg domain: $REGDOMAIN"
  iw reg set "$REGDOMAIN" || warn "iw reg set failed (may require reboot)."
fi

# Quick sanity checks
ok "Done. Quick checks:"
echo "---- dmesg (brcmfmac) ----"
dmesg | grep -i brcmfmac | tail -n 25 || true
echo "---- iw dev ----"
iw dev || true
echo "---- iw phy (head) ----"
iw phy 2>/dev/null | sed -n '1,60p' || true

echo
ok "If Wi-Fi is up and channels look right, you're good. A reboot is safe but not required."
echo "Backups (if any): $BACKUP"
