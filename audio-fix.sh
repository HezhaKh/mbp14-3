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

log "D) Build & install the patched driver via DKMS (auto-rebuilds on kernel updates)…"
cd "$REPO_DIR"
# dkms.sh patches the in-tree cs8409 source (PRE_BUILD), builds, and installs into
# /lib/modules/$(uname -r)/updates/dkms, then depmods. Preferred over running
# install.cirrus.driver.sh directly because DKMS rebuilds automatically after kernel
# point updates and cleanly restores the stock module on removal.
sudo bash dkms.sh

log "E) Assert the PATCHED module is the one modprobe will load…"
# This is the check that matters: if the loader still resolves to the in-tree
# .../kernel/... module, the patch did NOT take and audio will stay on Dummy Output.
RESOLVED="$(modinfo -n snd_hda_codec_cs8409 2>/dev/null || true)"
log "   resolved module: ${RESOLVED:-<none>}"
case "$RESOLVED" in
  */updates/*)
    log "   OK: patched module is in place." ;;
  *)
    cat >&2 <<EOF

ERROR: snd_hda_codec_cs8409 still resolves to the STOCK in-tree module:
  ${RESOLVED:-<none>}
The DKMS install did not take. Check:
  - 'dkms status | grep snd_hda_macbookpro' should show 'installed'
  - build log under /var/lib/dkms/snd_hda_macbookpro/0.1/\$(uname -r)/\$ARCH/log/
Re-run this script after resolving the build error.
EOF
    exit 1 ;;
esac
dkms status | grep -i snd_hda_macbookpro || true

log "F) Try to load the patched module now (a reboot is the reliable activation path)…"
# Live swap usually fails with 'Module ... is in use' because card 0's codec is bound
# to the running sound stack. That is expected — the patched module loads on next boot.
sudo modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
sudo modprobe snd_hda_codec_cs8409 2>/dev/null || true

log "G) Quick sanity checks…"
cat /proc/asound/cards 2>/dev/null || true
lsmod | grep -E 'cs8409|hda_codec' || true
aplay -l || true
pactl list short sinks 2>/dev/null || true

cat <<'EOF'

Next steps:
  1) REBOOT — the patched codec cannot hot-swap while audio is in use, so the
     analog sink only enumerates after a fresh boot.
  2) After reboot, open Settings > Sound and choose "Analog Stereo Output".

Tip:
  DKMS rebuilds this automatically on 5.15.x kernel updates. If audio ever
  disappears after an update, re-run this script.
EOF
