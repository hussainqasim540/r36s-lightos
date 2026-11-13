#!/bin/sh
# Arms ROCKNIX for the next power-on of a Lume card mounted on this computer
# (in a reader, or over the OTG port from Lume or ROCKNIX): ROCKNIX.TXT in
# the root of the FAT partition, "R" and a new token. Eject the card and the
# next boot is ROCKNIX; U-Boot keeps the token in sector 31 of the
# partition, so the boot after that is Lume again. Holding VOL- at power-on
# does the same without this file.
# Usage: tools/rocknix_once.sh [/Volumes/ROCKNIX]
set -e
card=${1:-/Volumes/ROCKNIX}
here=$(cd "$(dirname "$0")/../sdcard" && pwd)
if [ ! -f "$card/KERNEL" ] || [ ! -f "$card/boot.ini" ]; then
  echo "$card is not a ROCKNIX boot partition" >&2
  exit 1
fi
if ! grep -q ROCKNIX.TXT "$card/boot.ini"; then
  echo "$card/boot.ini has no ROCKNIX one-shot: run tools/install_card.sh first" >&2
  exit 1
fi
{
  echo "R $(date +%Y%m%dT%H%M%S) $(uuidgen | tr A-Z a-z)"
  cat "$here/lightos/rocknix.txt"
} > "$card/ROCKNIX.TXT"
dot_clean -m "$card" 2>/dev/null || true
sync
echo "ROCKNIX armed for the next boot: eject $card."
