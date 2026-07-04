#!/bin/bash
# Offline installer for T2 Mac support on Ubuntu 26.04 LTS (GA install).
# Installs: build deps (bundled .debs) -> apple-bce driver via DKMS
#           -> Wi-Fi/Bluetooth firmware -> boot configuration.
#
# Usage:  sudo bash install-offline.sh
# (Run from this directory, e.g. the mounted USB stick or a copy of it.)

set -e

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root:  sudo bash install-offline.sh"
    exit 1
fi

cd "$(dirname "$0")"
KVER="${KVER:-$(uname -r)}"
MODVER=0.2

echo "==> Target kernel: ${KVER}"
if [ ! -e "/lib/modules/${KVER}/build" ] && ! ls offline-deps/linux-headers-* >/dev/null 2>&1; then
    echo "Note: kernel headers for ${KVER} not found yet; they should be"
    echo "preinstalled on Ubuntu 26.04 desktop. Continuing anyway."
fi

if ls offline-deps/*.deb >/dev/null 2>&1; then
    echo "==> Installing bundled build dependencies (dpkg)"
    # dpkg unpacks all debs first, then configures them in dependency order
    dpkg -i offline-deps/*.deb
else
    echo "==> No offline-deps/*.deb found, assuming build tools are installed"
fi

echo "==> Installing apple-bce ${MODVER} via DKMS"
rm -rf "/usr/src/apple-bce-${MODVER}"
mkdir -p "/usr/src/apple-bce-${MODVER}"
cp -r Makefile dkms.conf ./*.c ./*.h audio vhci "/usr/src/apple-bce-${MODVER}/"
dkms add -m apple-bce -v "${MODVER}" 2>/dev/null || true  # ok if already added
dkms install -m apple-bce -v "${MODVER}" -k "${KVER}"

echo "==> Configuring apple-bce to load at boot"
echo apple-bce > /etc/modules-load.d/apple-bce.conf
if [ -f /etc/initramfs-tools/modules ] && ! grep -q '^apple-bce$' /etc/initramfs-tools/modules; then
    echo apple-bce >> /etc/initramfs-tools/modules
fi

echo "==> Installing Wi-Fi/Bluetooth firmware to /lib/firmware/brcm"
mkdir -p /lib/firmware/brcm
tar -xC /lib/firmware/brcm -f firmware/firmware-renamed.tar

if command -v update-initramfs >/dev/null 2>&1; then
    echo "==> Rebuilding initramfs (so keyboard + firmware are available early)"
    update-initramfs -u
fi

echo "==> Loading drivers"
modprobe apple-bce 2>/dev/null && echo "    apple-bce loaded (keyboard/trackpad/audio)" \
    || echo "    apple-bce will load after a reboot"
modprobe -r brcmfmac_wcc 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true
modprobe brcmfmac 2>/dev/null || true
modprobe -r hci_bcm4377 2>/dev/null || true
modprobe hci_bcm4377 2>/dev/null || true

echo
echo "Done. If Wi-Fi does not appear within ~30 seconds, reboot."
echo "Check status with:  dkms status ; nmcli device ; dmesg | grep -iE 'brcmfmac|bce'"
