#!/usr/bin/env bash
# power-cooling-fix.sh
# Reduce heat + battery drain on MacBookPro14,3 (Ubuntu 22.04 / kernel 5.15.x).
#
# Root cause on this machine: the discrete AMD GPU (Polaris/Baffin) drives the internal
# panel and CANNOT be powered off, and its "auto" DPM pins the core clock at maximum
# (855 MHz) even at 0% load — ~10 W idle, which is most of the heat and battery drain.
# Forcing the GPU to "low" on battery cuts ~5 W (~21%) off idle draw and runs much cooler.
#
# This script (idempotent):
#   1) Installs an AMD GPU power policy: force "low" clocks on battery, "auto" (full) on AC.
#      Applied at boot (systemd) and on every AC plug/unplug (udev).
#   2) Installs + configures TLP for deeper savings (PCIe ASPM, runtime PM, USB autosuspend,
#      CPU energy bias), masking power-profiles-daemon. The Touch Bar iBridge (05ac:8600) is
#      excluded from USB autosuspend so it doesn't go flaky.
#   3) Tunes mbpfan to ramp the fans earlier/harder (this machine was running too hot).
#
# Override defaults via env vars, e.g.:
#   GPU_BAT_LEVEL=low GPU_AC_LEVEL=auto FAN_LOW=55 FAN_HIGH=63 FAN_MAX=84 INSTALL_TLP=1 sudo -E ./power-cooling-fix.sh

set -Eeuo pipefail

# --- Tunables ---
GPU_BAT_LEVEL="${GPU_BAT_LEVEL:-low}"     # force_performance_level when on battery
GPU_AC_LEVEL="${GPU_AC_LEVEL:-auto}"      # force_performance_level when on AC (auto == full clocks on this GPU)
FAN_LOW="${FAN_LOW:-55}"                   # mbpfan: temp where fans start ramping (was 63)
FAN_HIGH="${FAN_HIGH:-63}"                 # mbpfan: temp for the high ramp point (was 66)
FAN_MAX="${FAN_MAX:-84}"                   # mbpfan: temp where fans hit max RPM (was 86)
INSTALL_TLP="${INSTALL_TLP:-1}"            # 1 = install/enable TLP, 0 = skip
IBRIDGE_USB_ID="05ac:8600"                 # Touch Bar / iBridge — keep out of USB autosuspend

# --- Helpers (same style as the other scripts) ---
as_root() { if [[ $EUID -ne 0 ]]; then echo "Re-running with sudo..."; exec sudo -E bash "$0" "$@"; fi; }
info()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[ OK ]\e[0m $*"; }
fail()  { echo -e "\e[1;31m[FAIL]\e[0m $*"; exit 1; }

as_root "$@"
info "MacBookPro14,3 power + cooling fix (kernel $(uname -r))"

# ============================================================================
# 1) AMD GPU power policy
# ============================================================================
info "Installing AMD GPU power policy (battery=$GPU_BAT_LEVEL, AC=$GPU_AC_LEVEL)…"
cat > /usr/local/sbin/amdgpu-power-policy.sh <<EOF
#!/bin/sh
# Set amdgpu force_performance_level based on AC/battery. Installed by power-cooling-fix.sh.
AC_ONLINE="\$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo 1)"
if [ "\$AC_ONLINE" = "1" ]; then LEVEL="$GPU_AC_LEVEL"; else LEVEL="$GPU_BAT_LEVEL"; fi
for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
  [ -w "\$f" ] && echo "\$LEVEL" > "\$f" 2>/dev/null || true
done
logger -t amdgpu-power-policy "set force_performance_level=\$LEVEL (AC=\$AC_ONLINE)" 2>/dev/null || true
EOF
chmod +x /usr/local/sbin/amdgpu-power-policy.sh

# udev: re-apply on every AC adapter state change
cat > /etc/udev/rules.d/81-mbp14-3-gpu-power.rules <<'EOF'
# Re-apply AMD GPU power policy when AC adapter is plugged/unplugged
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="/usr/local/sbin/amdgpu-power-policy.sh"
EOF
udevadm control --reload-rules || true

# systemd: apply once at boot (covers initial state)
cat > /etc/systemd/system/amdgpu-power-policy.service <<'EOF'
[Unit]
Description=Apply AMD GPU power policy (low on battery / full on AC) for MacBookPro14,3
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amdgpu-power-policy.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable amdgpu-power-policy.service >/dev/null 2>&1 || true
/usr/local/sbin/amdgpu-power-policy.sh
ok "GPU policy applied now: $(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null) (level), sclk=$(grep '\*' /sys/class/drm/card0/device/pp_dpm_sclk 2>/dev/null | tr -s ' ')"

# ============================================================================
# 2) TLP
# ============================================================================
if [[ "$INSTALL_TLP" == "1" ]]; then
  info "Installing/configuring TLP…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y tlp tlp-rdw

  # GNOME's power-profiles-daemon conflicts with TLP — disable it.
  systemctl disable --now power-profiles-daemon >/dev/null 2>&1 || true
  systemctl mask power-profiles-daemon >/dev/null 2>&1 || true

  # Keep the Touch Bar iBridge out of USB autosuspend so it stays responsive.
  # Also let TLP own the AMD GPU clock so it doesn't fight our policy: TLP applies
  # RADEON_DPM_* to amdgpu cards too, and its default (auto on battery) would re-pin
  # the core clock high. Match our intent here instead.
  cat > /etc/tlp.d/01-mbp14-3.conf <<EOF
# MacBookPro14,3 overrides
USB_AUTOSUSPEND=1
USB_DENYLIST="$IBRIDGE_USB_ID"
# Slightly more aggressive on battery; defaults are sane on AC.
CPU_ENERGY_PERF_POLICY_ON_BAT=power
# AMD GPU: 'auto' pins the core clock at max on this Polaris GPU, so force '$GPU_BAT_LEVEL'
# on battery (real heat/power win) and '$GPU_AC_LEVEL' on AC (full clocks).
RADEON_DPM_PERF_LEVEL_ON_BAT=$GPU_BAT_LEVEL
RADEON_DPM_PERF_LEVEL_ON_AC=$GPU_AC_LEVEL
RADEON_DPM_STATE_ON_BAT=battery
RADEON_DPM_STATE_ON_AC=performance
EOF

  systemctl enable tlp >/dev/null 2>&1 || true
  systemctl restart tlp || warn "tlp restart returned non-zero."
  tlp start >/dev/null 2>&1 || true
  ok "TLP active: $(systemctl is-active tlp 2>/dev/null), power-profiles-daemon: $(systemctl is-enabled power-profiles-daemon 2>/dev/null || echo masked)"
else
  info "Skipping TLP (INSTALL_TLP=0)."
fi

# ============================================================================
# 3) mbpfan thresholds (ramp earlier / harder)
# ============================================================================
MBPCONF="/etc/mbpfan.conf"
if command -v mbpfan >/dev/null 2>&1 && [[ -f "$MBPCONF" ]]; then
  info "Tuning mbpfan (low=$FAN_LOW high=$FAN_HIGH max=$FAN_MAX)…"
  cp -a "$MBPCONF" "$MBPCONF.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i -E "s/^[[:space:]]*low_temp[[:space:]]*=.*/low_temp = $FAN_LOW/"   "$MBPCONF"
  sed -i -E "s/^[[:space:]]*high_temp[[:space:]]*=.*/high_temp = $FAN_HIGH/" "$MBPCONF"
  sed -i -E "s/^[[:space:]]*max_temp[[:space:]]*=.*/max_temp = $FAN_MAX/"    "$MBPCONF"
  systemctl restart mbpfan || warn "mbpfan restart returned non-zero."
  ok "mbpfan restarted: $(systemctl is-active mbpfan 2>/dev/null). Fans: $(cat /sys/devices/platform/applesmc.768/fan1_input 2>/dev/null) / $(cat /sys/devices/platform/applesmc.768/fan2_input 2>/dev/null) RPM"
else
  warn "mbpfan not installed or $MBPCONF missing — install with: sudo apt install mbpfan"
fi

echo
ok "Done. Summary:"
B=/sys/class/power_supply/BAT0
CN=$(cat $B/current_now 2>/dev/null || echo 0); VN=$(cat $B/voltage_now 2>/dev/null || echo 0)
awk "BEGIN{printf \"  Battery draw now: ~%.2f W\n\", ($CN/1000000)*($VN/1000000)}" 2>/dev/null || true
echo "  GPU level: $(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null) | sclk: $(grep '\*' /sys/class/drm/card0/device/pp_dpm_sclk 2>/dev/null | tr -s ' ')"
echo "  TLP: $(systemctl is-active tlp 2>/dev/null || echo n/a) | mbpfan: $(systemctl is-active mbpfan 2>/dev/null || echo n/a)"
echo
echo "Tip: on battery the GPU drops to low clocks (coolest); plug in AC for full GPU performance."
