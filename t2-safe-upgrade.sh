#!/usr/bin/env bash
# t2-safe-upgrade.sh (v2) — apt update + full-upgrade on a T2 Mac running Ubuntu
# with the t2linux kernel (linux-t2 / linux-t2-lts / xanmod variants from
# AdityaGarg8/t2-ubuntu-repo). Those kernels have apple-bce (keyboard, trackpad,
# audio), bcm5974 (trackpad) and the Touch Bar drivers BUILT IN, so no DKMS is used.
#
# Usage:  sudo bash t2-safe-upgrade.sh
# Does NOT reboot. Read the summary at the end before rebooting.

set -Eeuo pipefail

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root:  sudo bash $0"
    exit 1
fi

LOG="/var/log/t2-safe-upgrade-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
APT=(apt-get -y -o DPkg::Lock::Timeout=300
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ] %s\033[0m\n' "$*"; }
ask()  { local a; read -r -p "$1 [y/N] " a </dev/tty || true; [[ "$a" =~ ^[Yy]$ ]]; }
installed() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep '^ii' >/dev/null; }

# Needed for keyboard + trackpad to work at all (the BCE driver is checked
# separately: kernels <= 7.1.3 ship "apple-bce", 7.1.8+ split it into t2bce_*)
CRITICAL_MODS=(bcm5974 hid-apple)
BCE_NEW=(t2bce_core t2bce_dma t2bce_vhci)
# Touch Bar keys (Esc/F-keys) + keyboard backlight + SMC — nice to have
EXTRA_MODS=(hid-appletb-kbd hid-appletb-bl applesmc)
# These must NOT be installed alongside a t2 kernel (they duplicate built-in drivers)
CONFLICTS=(apple-bce apple-touchbar applesmc-t2 apfs-dkms bcm5974-t2)
T2_METAS=(linux-t2 linux-t2-lts linux-t2-xanmod linux-t2-xanmod-lts)

has_mod() { modinfo -k "$1" -F filename "$2" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
say "Pre-flight checks"
RUNNING=$(uname -r)
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
echo "Model: $MODEL   Running kernel: $RUNNING"
[[ "$RUNNING" == *t2* ]] && ok "Running a t2linux kernel" \
    || warn "Running kernel is not a t2 kernel — this script assumes linux-t2*"
lspci -nn | grep '106b:1801' >/dev/null && ok "T2 BCE PCI device present" \
    || warn "BCE PCI device 106b:1801 not visible"
lsmod | grep '^apple_bce' >/dev/null && ok "apple-bce loaded" || warn "apple-bce not loaded"

BCE_FILE=$(modinfo -F filename apple-bce 2>/dev/null || true)
echo "apple-bce in use from: ${BCE_FILE:-not found}"
if [[ "$BCE_FILE" == *updates/dkms* ]]; then
    warn "A DKMS apple-bce is overriding the kernel's built-in one."
fi

# t2 kernel metapackage (brings new t2 kernels with upgrades)
META=""
for p in "${T2_METAS[@]}"; do installed "$p" && META="$p"; done
if [ -n "$META" ]; then ok "t2 kernel metapackage installed: $META"
else warn "No linux-t2* metapackage installed — apt will NOT bring new t2 kernels."
     echo "       Fix later with: sudo apt install linux-t2   (or linux-t2-lts)"; fi

# t2 apt repo (common + release-specific)
CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
SRC=$(grep -rhs -v '^\s*#' /etc/apt/sources.list /etc/apt/sources.list.d/ || true)
echo "$SRC" | grep -i 'adityagarg8.github.io/t2-ubuntu-repo' >/dev/null \
    && ok "t2 common apt repo configured" || warn "t2 common apt repo not found"
echo "$SRC" | grep -i "t2-ubuntu-repo/releases/download/${CODENAME}" >/dev/null \
    && ok "t2 release repo for '$CODENAME' configured" \
    || warn "t2 release repo for '$CODENAME' missing — no t2 kernel/tiny-dfr updates"

# Conflicting DKMS driver packages
FOUND=()
for p in "${CONFLICTS[@]}"; do installed "$p" && FOUND+=("$p"); done
if [ ${#FOUND[@]} -gt 0 ]; then
    warn "These packages conflict with the t2 kernel's built-in drivers: ${FOUND[*]}"
    if ask "Purge them now (recommended by t2linux)?"; then
        "${APT[@]}" purge "${FOUND[@]}"
    fi
fi

# Leftover manual DKMS apple-bce from the original offline install
if [ -d /var/lib/dkms/apple-bce ]; then
    warn "A manual DKMS apple-bce is registered (/var/lib/dkms/apple-bce)."
    warn "On t2 kernels it can override the built-in driver or break kernel installs."
    if ask "Remove the DKMS registration (the kernel's built-in driver stays)?"; then
        dkms remove apple-bce/0.2 --all 2>/dev/null || true
        rm -rf /var/lib/dkms/apple-bce
        find /lib/modules -path '*/updates/dkms/apple-bce.ko*' -print -delete
        depmod -a
        ok "Removed DKMS apple-bce"
    fi
fi
[ -d /usr/src/apple-bce-0.2 ] && echo "Note: /usr/src/apple-bce-0.2 is a leftover from the old DKMS install and is unused (safe to delete)."

# Back up Apple Wi-Fi/BT firmware
FWBAK="/var/backups/t2-brcm-firmware-$(date +%F-%H%M%S).tar.gz"
FW_BEFORE=0
if [ -d /lib/firmware/brcm ]; then
    tar -czf "$FWBAK" -C /lib/firmware brcm && ok "Firmware backed up to $FWBAK"
    FW_BEFORE=$(find /lib/firmware/brcm -iname '*apple*' | wc -l)
fi

# --------------------------------------------------------------------------
say "apt update"
"${APT[@]}" update

# Touch Bar: without tiny-dfr the bar is blank (no Esc / F-keys)
HAS_TB=0
lsusb 2>/dev/null | grep -i '05ac:8302' >/dev/null && HAS_TB=1
[[ "$MODEL" =~ ^MacBookPro1[56], ]] && HAS_TB=1
if [ "$HAS_TB" = 1 ]; then
    if installed tiny-dfr; then ok "tiny-dfr (Touch Bar) installed"
    else say "Installing tiny-dfr for the Touch Bar (Esc / F-keys)"
         "${APT[@]}" install tiny-dfr || warn "Could not install tiny-dfr"; fi
fi

say "apt full-upgrade"
"${APT[@]}" full-upgrade
# Deliberately NOT running autoremove: older kernels stay as a fallback.

# --------------------------------------------------------------------------
set +e
say "Verifying keyboard/trackpad drivers for every installed kernel"

# Load at boot, both old and new driver names (a name missing on one kernel is skipped
# with a harmless "module not found" line from systemd-modules-load)
BOOTLIST="apple-bce t2bce_core t2bce_dma t2bce_vhci t2bce_audio"
printf '# T2 Mac BCE driver (keyboard/trackpad/audio). Old + new kernel module names.\n%s\n' \
    "$(tr ' ' '\n' <<<"$BOOTLIST")" > /etc/modules-load.d/apple-bce.conf
ok "Boot module list: $BOOTLIST"

# Early boot (initramfs) only matters for typing a disk-encryption password
LUKS=0
{ grep -Ev '^\s*(#|$)' /etc/crypttab 2>/dev/null | grep . >/dev/null || lsblk -rno TYPE | grep -x crypt >/dev/null; } && LUKS=1
INITRD_SYS=initramfs-tools; installed dracut && INITRD_SYS=dracut
echo "Disk encryption: $([ $LUKS = 1 ] && echo yes || echo no)   initramfs system: $INITRD_SYS"
if [ "$INITRD_SYS" = initramfs-tools ] && [ -f /etc/initramfs-tools/modules ]; then
    # initramfs-tools silently skips names a kernel doesn't have
    for m in $BOOTLIST; do grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules; done
fi

bce_kind() {  # prints: old | new | none
    if has_mod "$1" apple-bce; then echo old; return; fi
    local m; for m in "${BCE_NEW[@]}"; do has_mod "$1" "$m" || { echo none; return; }; done
    echo new
}

mapfile -t KERNELS < <(linux-version list 2>/dev/null | linux-version sort 2>/dev/null)
[ ${#KERNELS[@]} -eq 0 ] && mapfile -t KERNELS < <(ls /lib/modules | sort -V)
declare -A STATUS
for k in "${KERNELS[@]}"; do
    [ -e "/boot/vmlinuz-$k" ] || continue
    echo "--- $k"
    kind=$(bce_kind "$k")
    missing=()
    [ "$kind" = none ] && missing+=("apple-bce/t2bce")
    for m in "${CRITICAL_MODS[@]}"; do has_mod "$k" "$m" || missing+=("$m"); done
    if [ ${#missing[@]} -gt 0 ]; then
        bad "$k: missing ${missing[*]} — no internal keyboard/trackpad on this kernel"
        STATUS[$k]=FAIL; continue
    fi
    for m in "${EXTRA_MODS[@]}"; do has_mod "$k" "$m" || warn "$k: $m not available"; done
    if [ "$kind" = old ]; then
        f=$(modinfo -k "$k" -F filename apple-bce 2>/dev/null); pat='apple-bce\.ko'
        [[ "$f" == *updates/dkms* ]] && warn "$k: apple-bce comes from DKMS, not the kernel"
    else
        f=$(modinfo -k "$k" -F filename t2bce_vhci 2>/dev/null); pat='t2bce_vhci\.ko'
    fi
    echo "    BCE driver: $kind ($f)"
    if [ $LUKS = 1 ] && [ "$f" != "(builtin)" ] && [ -e "/boot/initrd.img-$k" ]; then
        if ! lsinitramfs "/boot/initrd.img-$k" 2>/dev/null | grep "$pat" >/dev/null; then
            echo "    Rebuilding initramfs for $k so the keyboard works at the unlock prompt ..."
            if [ "$INITRD_SYS" = dracut ]; then
                if [ "$kind" = new ]; then drv="${BCE_NEW[*]}"; else drv=apple-bce; fi
                dracut -f --kver "$k" --add-drivers "$drv"
            else
                update-initramfs -u -k "$k"
            fi
            lsinitramfs "/boot/initrd.img-$k" 2>/dev/null | grep "$pat" >/dev/null \
                || warn "$k: keyboard driver still not in initramfs — use a USB keyboard at the unlock prompt"
        fi
    fi
    ok "$k: keyboard + trackpad drivers present"; STATUS[$k]=OK
done

FW_AFTER=$(find /lib/firmware/brcm -iname '*apple*' 2>/dev/null | wc -l)
if [ "$FW_BEFORE" -gt 0 ] && [ "$FW_AFTER" -lt "$FW_BEFORE" ]; then
    warn "Apple Wi-Fi/BT firmware files dropped ($FW_BEFORE -> $FW_AFTER); restoring backup"
    tar -xzf "$FWBAK" -C /lib/firmware && update-initramfs -u -k all
fi

# --------------------------------------------------------------------------
say "Summary"
for k in "${!STATUS[@]}"; do echo "  $k : ${STATUS[$k]}"; done | sort -V
NEWEST=""
for k in "${KERNELS[@]}"; do [ -n "${STATUS[$k]:-}" ] && NEWEST="$k"; done
echo
echo "Kernel GRUB boots by default (newest): $NEWEST"
if [[ "$NEWEST" != *t2* ]]; then
    bad "The newest kernel is NOT a t2 kernel. It may boot without keyboard/trackpad."
    echo "   Pick the t2 kernel under GRUB > 'Advanced options', or remove the stock kernel."
elif [ "${STATUS[$NEWEST]:-FAIL}" = OK ]; then
    ok "Safe to reboot — keyboard/trackpad drivers are in $NEWEST."
else
    bad "Do NOT reboot blind — drivers missing in $NEWEST."
    echo "   Plug in a USB keyboard first, or pick the previous kernel in GRUB > 'Advanced options'."
fi
[ -f /var/run/reboot-required ] && echo "(Reboot required by updates: yes)"
echo "Full log: $LOG"
