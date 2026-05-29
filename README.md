# mbp14-3 — Ubuntu on MacBook Pro 14,3

Scripts to bring up the hardware on a **MacBookPro14,3** (2017 15", AMD Radeon Pro 555)
running **Ubuntu 22.04 LTS** on the GA kernel (**5.15.x**).

## Status

| Subsystem | Status | Script |
|---|---|---|
| Wi-Fi (BCM43602) | ✅ working | `bcm43602-setup.sh` (+ `brcmfmac43602-pcie.txt`) |
| Bluetooth (BCM, UART) | ✅ working | `bluetooth-fix.sh` |
| Audio (Cirrus CS8409) | ✅ working *(after reboot)* | `audio-fix.sh` |
| Touch Bar (iBridge/T1) | ✅ working | `touchbar-fix.sh` |
| GPU (amdgpu) | ✅ works out of the box | — |
| Webcam (FaceTime HD) | ⚠️ not covered | — |

## Prerequisites

- **Secure Boot must be OFF.** The audio and Touch Bar modules are out-of-tree/unsigned;
  with Secure Boot enabled they will not load. (Check with `mokutil --sb-state`, or note that
  no `SecureBoot` EFI variable means it is disabled.)
- Kernel headers for the running kernel (`linux-headers-$(uname -r)`); the audio script also
  pulls `linux-source-5.15.0`. The scripts install these automatically.
- An internet connection (run `bcm43602-setup.sh` first if Wi-Fi isn't up yet).

## Quick start

```bash
git clone https://github.com/HezhaKh/mbp14-3.git
cd mbp14-3
sudo ./install-all.sh        # runs wifi → bluetooth → audio → touchbar
sudo reboot                  # required to activate the patched audio codec
```

Skip or isolate steps:

```bash
sudo ./install-all.sh --skip-wifi          # everything except Wi-Fi
sudo ./install-all.sh --only-audio         # just the audio driver
```

## What each script does

- **`bcm43602-setup.sh`** — installs the BCM43602 NVRAM (`brcmfmac43602-pcie.txt`) into
  `/lib/firmware/brcm`, updates initramfs, reloads `brcmfmac`. Optional `REGDOMAIN=CA` env var
  sets a persistent regulatory domain.
- **`bluetooth-fix.sh`** — clears the rfkill **soft block** (the only thing that disables BT on
  this machine), sets `AutoEnable=true` in `/etc/bluetooth/main.conf`, enables `bluetooth.service`,
  and installs a `bt-unblock.service` that re-applies the unblock at every boot as a fallback.
- **`audio-fix.sh`** — builds and installs the patched **CS8409** codec
  ([HezhaKh/snd_hda_macbookpro](https://github.com/HezhaKh/snd_hda_macbookpro)) via **DKMS** so it
  auto-rebuilds on kernel updates. It asserts the *patched* module (in `…/updates/dkms`) is what
  the loader resolves — not the stock in-tree one — and fails loudly otherwise.
  **Reboot afterwards:** the codec can't hot-swap while audio is in use, so the analog sink only
  appears on a fresh boot. Then pick *Analog Stereo Output* in Settings → Sound.
- **`touchbar-fix.sh`** — builds `apple_ibridge` + `apple_ib_tb` from
  [HezhaKh/macbook12-spi-driver](https://github.com/HezhaKh/macbook12-spi-driver) (`touchbar-driver-hid-driver`
  branch), sets the `applespi` load order, updates initramfs, installs a boot-time rebind service
  for the iBridge (`05ac:8600`), and adds a kernel `postinst` hook so the modules rebuild after
  5.15.x point updates.

## After a kernel update (within 5.15.x)

- **Audio** rebuilds automatically (DKMS).
- **Touch Bar** rebuilds automatically (the installed `postinst` hook).
- If anything is missing, just re-run `sudo ./install-all.sh` — every step is idempotent.
