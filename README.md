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
| Heat & battery drain | ✅ reduced (~5 W idle) | `power-cooling-fix.sh` |
| Dual-boot (Ubuntu / macOS) | ✅ rEFInd picker + `jellyskull` theme | `refind-theme.sh` |
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
sudo ./install-all.sh        # runs wifi → bluetooth → audio → touchbar → power
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
- **`power-cooling-fix.sh`** — reduces heat and battery drain. The discrete AMD GPU drives the
  internal panel (so it can't be powered off) and its `auto` DPM pins the core clock at maximum
  (855 MHz) even at idle — ~10 W. This script forces the GPU to **low clocks on battery / full on
  AC**, installs and configures **TLP** (PCIe ASPM, runtime PM, USB autosuspend with the Touch Bar
  iBridge denylisted; replaces `power-profiles-daemon`), tunes **mbpfan** to ramp earlier, and
  **caps the CPU sustained power (RAPL PL1) to 30 W**. The firmware leaves PL1 at 100 W, so the
  i7-7700HQ runs flat-out into Tjmax (100 °C) under all-core load; the cap holds it at ~88 °C and
  ~12 W less while costing ~14% sustained multicore throughput (idle/interactive use is unchanged).
  Measured effect: idle draw ~24 W → **~18.5 W** on battery; load CPU 42 W → 30 W, 99 °C → 88 °C.
  Tunable via env vars (`GPU_BAT_LEVEL`, `FAN_LOW/HIGH/MAX`, `INSTALL_TLP`, `CPU_PL1_WATTS`;
  set `CPU_PL1_WATTS=0` to keep full CPU performance).

  > **Note:** CPU *undervolting* (the usual heat fix) is **locked** on this chip by the
  > Plundervolt microcode mitigation (rev `0xf8`) — writes to MSR 0x150 are silently ignored —
  > so the RAPL power cap is used instead.

- **`refind-theme.sh`** — sets up a clean **dual-boot picker** for Ubuntu + macOS using the
  **rEFInd** boot manager. GRUB can't show macOS on this Mac (neither GRUB nor `os-prober` can read
  the APFS volume), so rEFInd is used as the menu: it **chainloads Ubuntu's existing shim→GRUB** and
  boots **macOS** directly. Installs rEFInd, deploys the **`jellyskull`** theme (`refind/jellyskull/`:
  dark graphite `#2a2c30` background, monochrome **white solid** icons — a jellyfish for Ubuntu 22.04
  *"Jammy Jellyfish"*, the Apple logo for macOS — with an **Apple-style border-light glow** on the
  selected entry), writes a tidy `refind.conf` with **one explicit `macOS` entry** (volume-group GUID
  **auto-detected** from NVRAM; override via `MACOS_VG_GUID=`), and makes rEFInd the default EFI boot
  entry. Idempotent; backs up any existing config to `refind.conf.dist`. **Run it separately from
  `install-all.sh`** — it changes the boot manager. Fallback if macOS ever won't boot: hold **⌥**
  (Option) at the chime for Apple's Startup Manager. Tunables: `TIMEOUT`, `MACOS_VG_GUID`,
  `INSTALL_REFIND`.

## After a kernel update (within 5.15.x)

- **Audio** rebuilds automatically (DKMS).
- **Touch Bar** rebuilds automatically (the installed `postinst` hook).
- If anything is missing, just re-run `sudo ./install-all.sh` — every step is idempotent.
