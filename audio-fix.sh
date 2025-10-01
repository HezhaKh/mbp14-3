#!/usr/bin/env bash
# audio-fix.sh
# Enable internal audio on MacBookPro14,3 (2017 15") – Ubuntu 22.04, GA kernel 5.15.x
# Uses your fork of the CS8409 driver.
set -euo pipefail

REPO_URL="https://github.com/HezhaKh/snd_hda_macbookpro"
REPO_DIR="/usr/local/src/snd_hda_macbookpro"

log(){ printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

log "A) Install build deps, headers, and kernel *source* (needed by the installer)…"
sudo apt update
sudo apt install -y build-essential dkms linux-headers-"$(uname -r)"

# Try to install the exact GA source package first (e.g. linux-source-5.15.0), else fall back to linux-source.
KVER="$(uname -r)"                      # e.g. 5.15.0-157-generic
MAJOR="$(echo "$KVER" | awk -F. '{print $1"."$2}')"  # 5.15
SRC_PKG="linux-source-${MAJOR}.0"

if ! dpkg -s "$SRC_PKG" >/dev/null 2>&1; then
  sudo apt install -y "$SRC_PKG" || sudo apt install -y linux-source
fi

log "B) Ensure the linux-source tarball is present (and extract it for tools that expect it)…"
TARBALL="$(ls -1 /usr/src/linux-source-*.tar.* 2>/dev/null | head -n1 || true)"
if [ -n "${TARBALL}" ]; then
  SRC_DIR="/usr/src/$(basename "$TARBALL" | sed 's/\.tar\..*$//')"  # /usr/src/linux-source-5.15.0
  if [ ! -d "$SRC_DIR" ]; then
    sudo tar -C /usr/src -xf "$TARBALL"
  fi
  # Friendly symlink for scripts that look for /usr/src/linux
  sudo ln -sfn "$SRC_DIR" /usr/src/linux
else
  log "WARN: No linux-source tarball found in /usr/src. The driver installer may still succeed; continuing."
fi

log "C) Get/refresh the CS8409 driver repo (your fork)…"
sudo mkdir -p /usr/local/src
if [ -d "$REPO_DIR/.git" ]; then
  sudo git -C "$REPO_DIR" remote set-url origin "$REPO_URL" || true
  sudo git -C "$REPO_DIR" fetch --all --tags
  sudo git -C "$REPO_DIR" reset --hard origin/HEAD
else
  sudo git clone "$REPO_URL" "$REPO_DIR"
fi

log "D) Build & install the driver via the upstream installer…"
cd "$REPO_DIR"
# The script installs into /lib/modules/$(uname -r)/updates and runs depmod.
sudo ./install.cirrus.driver.sh

log "E) Load the module now (also happens automatically after a reboot)…"
# Reload in case an older attempt is in memory.
sudo modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
sudo modprobe snd_hda_codec_cs8409 || true

log "F) Quick sanity checks…"
grep -R "Codec:" /proc/asound/card*/codec* 2>/dev/null || true
lsmod | grep -E 'cs8409|hda_codec' || true
if ! aplay -l >/dev/null 2>&1; then
  log "ALSA reports no cards yet; nudging ALSA once…"
  sudo alsa force-reload || true
  sleep 2
fi
aplay -l || true
pactl list short sinks || true

cat <<'EOF'

Next steps (if needed):
  1) Open Settings > Sound and choose "Analog Stereo Output".
  2) If you still see "Dummy Output", reboot once and re-check.

Tip:
  After kernel updates within 5.15.x, re-run this script to rebuild if audio disappears.
EOF
