#!/bin/sh
# Arms the LightOS one-shot on a card mounted on this computer (in a reader,
# or over the OTG port from ROCKNIX or LightOS): LIGHTOS.TXT in the root of
# the FAT partition, "L" and a new token. Eject the card and the next boot is
# LightOS; U-Boot keeps the token in sector 31 of the partition, so the boot
# after that is ROCKNIX again.
# Usage: tools/lightos_once.sh [/Volumes/ROCKNIX]
set -e
card=${1:-/Volumes/ROCKNIX}
here=$(cd "$(dirname "$0")/../sdcard" && pwd)
if [ ! -f "$card/KERNEL" ] || [ ! -f "$card/boot.ini" ]; then
  echo "$card is not a ROCKNIX boot partition" >&2
  exit 1
fi
if ! grep -q LIGHTOS.TXT "$card/boot.ini"; then
  echo "$card/boot.ini has no LightOS one-shot: run tools/install_card.sh first" >&2
  exit 1
fi
if [ ! -f "$card/lightos/initrd.img" ]; then
  echo "$card/lightos/initrd.img is missing: run tools/build_initramfs.sh and tools/install_card.sh" >&2
  exit 1
fi
{
  echo "L $(date +%Y%m%dT%H%M%S) $(uuidgen | tr A-Z a-z)"
  cat "$here/lightos/once.txt"
} > "$card/LIGHTOS.TXT"
dot_clean -m "$card" 2>/dev/null || true
sync
echo "LightOS armed for the next boot: eject $card."
