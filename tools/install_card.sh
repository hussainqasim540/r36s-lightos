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
cp -X "$here/lightos/"* "$card/lightos/"
initrd=$here/../out/initrd.img
if [ -f "$initrd" ]; then
  cp -X "$initrd" "$card/lightos/initrd.img"
else
  echo "No out/initrd.img (tools/build_initramfs.sh): LightOS can't boot from this card yet" >&2
fi
# Our kernel (tools/build_kernel.sh). Without it LightOS boots ROCKNIX's KERNEL.
# The LightOS kernel and the device tree built with it (boot.ini uses that
# one only together with lightos/Image).
if [ -f "$here/../out/kernel/Image" ]; then
  cp -X "$here/../out/kernel/Image" "$card/lightos/Image"
  cp -X "$here/../out/kernel/rk3326-gameconsole-r36s.dtb" "$card/lightos/rk3326-gameconsole-r36s.dtb"
fi
# The root file system (tools/build_rootfs.sh): stage 1 copies it to RAM and
# hands over to it. Without it LightOS stays in the initramfs.
if [ -f "$here/../out/rootfs/rootfs.sqfs" ]; then
  cp -X "$here/../out/rootfs/rootfs.sqfs" "$card/lightos/rootfs.sqfs"
fi
# LightOS's panel overlay, only if it was made from the overlay this card
# has now (tools/build_panel_overlay.sh): a card with another panel boots
# LightOS with its own overlays/mipi-panel.dtbo.
panel=$here/../out/panel
if [ -f "$panel/mipi-panel.dtbo" ] && cmp -s "$panel/rocknix.dtbo" "$card/overlays/mipi-panel.dtbo"; then
  cp -X "$panel/mipi-panel.dtbo" "$card/lightos/mipi-panel.dtbo"
elif [ -f "$card/lightos/mipi-panel.dtbo" ]; then
  rm -f "$card/lightos/mipi-panel.dtbo"
  echo "Removed lightos/mipi-panel.dtbo: out/panel is not from this card's overlay (tools/build_panel_overlay.sh)" >&2
fi

# macOS leaves ._ files on FAT; U-Boot and ROCKNIX don't need them.
dot_clean -m "$card" 2>/dev/null || true
sync

echo "Installed on $card:"
ls -l "$card/boot.ini" "$card/mount-storage.sh" "$card/lightos"
[ -f "$card/overlays/mipi-panel.dtbo" ] && echo "Panel overlay: overlays/mipi-panel.dtbo" || echo "No panel overlay on the card"
[ -f "$card/lightos/mipi-panel.dtbo" ] && echo "LightOS panel overlay: lightos/mipi-panel.dtbo"
