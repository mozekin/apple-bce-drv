# Installing apple-bce on Ubuntu 26.04 LTS (T2 Macs, e.g. MacBook 2018–2019)

This driver provides the **internal keyboard, trackpad and audio** on T2 Macs.

> **Note on Wi-Fi:** Wi-Fi is NOT provided by this driver. Wi-Fi/Bluetooth on T2
> Macs uses the in-kernel `brcmfmac` driver plus firmware files that must be
> copied from macOS. See the "Wi-Fi" section at the end.

Verified: this source tree compiles cleanly against Ubuntu 26.04's kernel
`7.0.0-27-generic` (it already contains all upstream t2linux compatibility
fixes through kernel 6.18+/7.0).

## Fully offline install (recommended — everything is on this USB)

This folder is a self-contained offline bundle. It includes:

- `install-offline.sh` — one-shot installer, run this and you're done
- `offline-deps/` — the exact `.deb` build dependencies (dkms, gcc, make, …)
  matching a fresh, un-updated Ubuntu 26.04 GA desktop install
- `firmware/firmware-renamed.tar` — Wi-Fi + Bluetooth firmware for **all**
  T2 Macs, extracted from an Apple macOS Sonoma recovery image and renamed by
  the official t2linux firmware script (`firmware/firmware.sh`, included for
  reference)
- the apple-bce driver source (this directory)

On the Ubuntu machine:

```sh
# copy the folder off the USB first (the installer writes into it via dkms)
cp -r /media/$USER/<usb-label>/apple-bce-drv-aur ~/t2
cd ~/t2
sudo bash install-offline.sh
```

That's it. The script installs the build tools, builds and installs the
apple-bce module with DKMS (auto-rebuilds on kernel updates), installs the
Wi-Fi/Bluetooth firmware, configures the module to load at boot (including
the initramfs, so the internal keyboard works at a LUKS prompt), and reloads
the drivers. Reboot afterwards for good measure.

Notes:
- The bundled debs match Ubuntu 26.04 GA (kernel `7.0.0-14-generic`). If you
  have already updated the system online, just use apt instead:
  `sudo apt install build-essential dkms` and rerun the script — it skips
  the deb step gracefully if you delete `offline-deps/`.
- This whole flow was verified end-to-end on Ubuntu 26.04 with kernel
  7.0.0-14-generic (GA) and 7.0.0-27-generic (updates).

## Audio

The module exposes the T2 audio device (playback). For proper speaker/mic
profiles you may also want the T2 ALSA/UCM config from the t2linux project:
https://wiki.t2linux.org/guides/audio-config/

## Wi-Fi and Bluetooth details

The bundled `firmware/firmware-renamed.tar` was produced with the official
t2linux tooling (https://wiki.t2linux.org/guides/wifi-bluetooth/) from Apple's
macOS Sonoma recovery image and contains firmware for every T2 board — the
`brcmfmac` driver picks the right files for your model automatically. If you
ever need to redo this (e.g. a future board needs newer firmware), run
`bash firmware/firmware.sh` on Linux with internet, or on macOS.

## Known limitations

- Suspend/resume support on this branch is limited (see README.md).
- If `dkms install` warns about Secure Boot / module signing: on T2 Macs you
  already disabled Secure Boot in the Startup Security Utility to boot Linux,
  so unsigned modules load fine. If `mokutil --sb-state` reports enabled,
  enroll the MOK key DKMS offers, then reboot.

## Troubleshooting

- `modprobe apple-bce` → "Operation not permitted / key rejected": Secure Boot
  signing issue, see above.
- No device found: check `lspci -nn | grep 106b:1801` — the BCE PCI device
  must be visible.
- Build failure on a future kernel: check for updated compatibility fixes at
  https://github.com/t2linux/apple-bce-drv (branch `aur`).
