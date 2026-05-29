#!/usr/bin/env bash
# bluetooth-fix.sh
# Enable Bluetooth (BCM, UART HCI) on MacBookPro14,3 for Ubuntu 22.04 / kernel 5.15.x
#
# On this machine the controller (hci0) is healthy and the BCM .hcd firmware is already
# shipped by linux-firmware — the only thing keeping Bluetooth off is an rfkill SOFT block.
# This script unblocks it, makes the controller auto-power on at boot, and installs a small
# boot-time service that re-applies the unblock as a belt-and-braces fallback.

set -Eeuo pipefail

# --- Helpers (same style as bcm43602-setup.sh) ---
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

as_root "$@"
command -v rfkill >/dev/null 2>&1 || { info "Installing rfkill…"; apt-get update -y && apt-get install -y rfkill; }

info "Detected system:"
echo "  Product: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'unknown')"
echo "  Kernel : $(uname -r)"

# --- 1) Clear the rfkill soft block ---
info "Clearing rfkill soft block on Bluetooth…"
rfkill unblock bluetooth || warn "rfkill unblock returned non-zero (may already be unblocked)."
rfkill list bluetooth || true

# --- 2) Make BlueZ auto-power the controller at boot ---
MAINCONF="/etc/bluetooth/main.conf"
if [[ -f "$MAINCONF" ]]; then
  if grep -qE '^\s*AutoEnable\s*=' "$MAINCONF"; then
    sed -i 's/^\s*#\?\s*AutoEnable\s*=.*/AutoEnable=true/' "$MAINCONF"
  elif grep -q '^\[Policy\]' "$MAINCONF"; then
    sed -i '/^\[Policy\]/a AutoEnable=true' "$MAINCONF"
  else
    printf '\n[Policy]\nAutoEnable=true\n' >> "$MAINCONF"
  fi
  info "Ensured AutoEnable=true in $MAINCONF"
else
  warn "$MAINCONF not found (is bluez installed?). Skipping AutoEnable."
fi

info "Enabling and starting bluetooth.service…"
systemctl enable --now bluetooth || warn "Could not enable/start bluetooth.service."

# --- 3) Fallback: re-apply unblock at every boot ---
# systemd-rfkill normally persists the unblock, but some GNOME/airplane-mode toggles can
# re-block. This oneshot guarantees BT is unblocked early in each boot.
SVC="/etc/systemd/system/bt-unblock.service"
cat > "$SVC" <<'EOF'
[Unit]
Description=Unblock Bluetooth rfkill at boot (MacBookPro14,3)
After=systemd-rfkill.service
Wants=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock bluetooth

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now bt-unblock.service || warn "Could not enable bt-unblock.service."

# --- 4) Power on now and report ---
if command -v bluetoothctl >/dev/null 2>&1; then
  bluetoothctl power on >/dev/null 2>&1 || true
  sleep 1
fi

ok "Done. Status:"
echo "---- rfkill ----"
rfkill list bluetooth || true
echo "---- controller ----"
if command -v bluetoothctl >/dev/null 2>&1; then
  bluetoothctl show 2>/dev/null | grep -E 'Controller|Name|Powered' || true
fi

echo
if rfkill list bluetooth | grep -q "Soft blocked: no"; then
  ok "Bluetooth is unblocked. If 'Powered: yes', pair from Settings > Bluetooth."
else
  fail "Bluetooth is still soft-blocked — check 'rfkill list' and airplane-mode toggle."
fi
