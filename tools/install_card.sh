#!/bin/sh
# Copies sdcard/ onto the FAT partition of a ROCKNIX 20250517 A card.
# Usage: tools/install_card.sh [/Volumes/ROCKNIX]
set -e

card=${1:-/Volumes/ROCKNIX}
here=$(cd "$(dirname "$0")/../sdcard" && pwd)

if [ ! -f "$card/KERNEL" ] || [ ! -f "$card/SYSTEM" ]; then
  echo "$card is not a ROCKNIX boot partition" >&2
  exit 1
fi
if ! head -n 1 "$card/boot.ini" | grep -q '^odroidgoa-uboot-config'; then
  echo "$card/boot.ini is not for the Hardkernel U-Boot; these files are for ROCKNIX 20250517 A" >&2
  exit 1
fi
if [ ! -f "$card/rk3326-gameconsole-r36s.dtb" ]; then
  echo "$card has no rk3326-gameconsole-r36s.dtb" >&2
  exit 1
fi

mkdir -p "$card/lightos"
# Keep the boot.ini found on the card the first time, to go back to it.
[ -f "$card/lightos/boot.ini.before" ] || cp -X "$card/boot.ini" "$card/lightos/boot.ini.before"

cp -X "$here/boot.ini" "$card/boot.ini"
cp -X "$here/mount-storage.sh" "$card/mount-storage.sh"
cp -X "$here/lightos/diag.sh" "$here/lightos/lightos-diag.service" "$card/lightos/"

# macOS leaves ._ files on FAT; U-Boot and ROCKNIX don't need them.
dot_clean -m "$card" 2>/dev/null || true
sync

echo "Installed on $card:"
ls -l "$card/boot.ini" "$card/mount-storage.sh" "$card/lightos"
[ -f "$card/overlays/mipi-panel.dtbo" ] && echo "Panel overlay: overlays/mipi-panel.dtbo" || echo "No panel overlay on the card"
