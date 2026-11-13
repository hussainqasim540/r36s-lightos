#!/bin/sh
# Adds a games partition to an image of a ROCKNIX card, for Lume: shrinks
# STORAGE (partition 2, ROCKNIX's ext4 /storage) to STORAGE_GIB GiB and makes
# the rest of the card partition 3, FAT32 labelled GAMES, which Lume mounts on
# /games for the frontend and shares over its USB disk next to ROCKNIX.
#
# On a 32 GB card the computer otherwise sees only the 2 GB ROCKNIX
# partition (the FAT one); the other 30 GB are STORAGE, which macOS can't
# write. Partition 1, the boot loader before it and STORAGE's files stay as
# they are (resize2fs moves STORAGE's blocks below the new end first).
#
# It works on an image file, never on the card itself: dump the card with dd,
# make an APFS clone of the dump (cp -c, nearly free), run this on the clone,
# then write back what changed with tools/write_changes.py. The dump stays
# the backup. In Docker (colima), --privileged for the loop devices.
#
# Usage: tools/games_partition.sh --check IMAGE      the partitions, STORAGE's use
#        tools/games_partition.sh IMAGE [STORAGE_GIB]   (default 4)
set -eu
check=no
[ "${1:-}" = --check ] && { check=yes; shift; }
[ $# -ge 1 ] || { sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
img=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
gib=${2:-4}
[ -f "$img" ] || { echo "No image $img" >&2; exit 1; }
case $gib in ''|*[!0-9]*) echo "STORAGE_GIB must be a whole number of GiB" >&2; exit 2 ;; esac
dir=$(dirname "$img")
name=$(basename "$img")

docker run --rm --privileged -v "$dir:/img" -e IMG="/img/$name" -e GIB=$gib -e CHECK=$check debian:trixie bash -euc '
apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools util-linux >/dev/null 2>&1
fail() { echo "games_partition: $*" >&2; exit 1; }
size=$(stat -c %s "$IMG")
echo "Image: $IMG, $size bytes ($((size / 1000000000)) GB)"
sfdisk -d "$IMG" > /tmp/table.txt || fail "no partition table"
label=$(sed -n "s/^label: //p" /tmp/table.txt)
echo "Partition table: $label"
sfdisk -l -o Device,Start,End,Sectors,Size,Type "$IMG" | sed -n "/^Device/,\$p" | sed "s/^/  /"
part() {  # part N FIELD: start or size of partition N, in sectors
  sed -n "s/.*${IMG##*/}$1 *: *\(.*\)/\1/p" /tmp/table.txt | tr "," "\n" | sed -n "s/^ *$2= *//p"
}
n=$(grep -c "^/img/" /tmp/table.txt)
p1s=$(part 1 start) p1n=$(part 1 size) p2s=$(part 2 start) p2n=$(part 2 size)
[ -n "$p2s" ] || fail "no partition 2"

loop1=$(losetup -f --show -r -o $((p1s * 512)) --sizelimit $((p1n * 512)) "$IMG")
loop2=$(losetup -f --show $([ $CHECK = yes ] && echo -r) -o $((p2s * 512)) --sizelimit $((p2n * 512)) "$IMG")
trap "losetup -d $loop1 $loop2 2>/dev/null || true" EXIT
l1=$(blkid -o value -s LABEL $loop1 || true) t2=$(blkid -o value -s TYPE $loop2 || true) l2=$(blkid -o value -s LABEL $loop2 || true)
echo "Partition 1: ${l1:-no label}; partition 2: ${t2:-unknown} ${l2:-no label}"
[ "$l1" = ROCKNIX ] || fail "partition 1 is not ROCKNIX"
[ "$t2" = ext4 ] && [ "$l2" = STORAGE ] || fail "partition 2 is not ROCKNIX STORAGE (ext4)"

bs=$(dumpe2fs -h $loop2 2>/dev/null | sed -n "s/^Block size: *//p")
blocks=$(dumpe2fs -h $loop2 2>/dev/null | sed -n "s/^Block count: *//p")
free=$(dumpe2fs -h $loop2 2>/dev/null | sed -n "s/^Free blocks: *//p")
echo "STORAGE: $(( blocks * bs / 1048576 )) MiB, $(( (blocks - free) * bs / 1048576 )) MiB used"
if [ $CHECK = yes ]; then
  [ $n = 2 ] && echo "Two partitions: ready for a games partition." || echo "$n partitions: not the layout this script changes."
  exit 0
fi
[ $n = 2 ] || fail "$n partitions: this changes only a card with ROCKNIX and STORAGE"

e2fsck -f -y $loop2 > /tmp/fsck.txt 2>&1 || [ $? -le 1 ] || { cat /tmp/fsck.txt; fail "STORAGE has errors e2fsck could not fix"; }
min=$(resize2fs -P $loop2 2>/dev/null | sed -n "s/.*: *//p")
new=$((GIB * 1073741824))
need=$((min * bs + 536870912))
echo "STORAGE: at least $((min * bs / 1048576)) MiB after resize2fs, new size $((new / 1048576)) MiB"
[ $new -ge $need ] || fail "STORAGE_GIB=$GIB leaves under 512 MiB free in STORAGE: give it more"
[ $new -lt $((p2n * 512)) ] || fail "STORAGE is already $((p2n * 512 / 1048576)) MiB or less"

before=$(dd if="$IMG" bs=512 skip=34 count=$((p2s - 34)) status=none | sha256sum)
resize2fs $loop2 $((new / 1024))K
e2fsck -f -n $loop2 > /tmp/fsck2.txt 2>&1 || { cat /tmp/fsck2.txt; fail "STORAGE has errors after resize2fs"; }
losetup -d $loop2

# Partition 2 ends at the new size; 3 starts on the next MiB and takes the
# rest (GPT: up to its backup table at the end).
p2new=$((new / 512))
p3s=$(( (p2s + p2new + 2047) / 2048 * 2048 ))
case $label in
  dos) type=c ;;
  gpt) type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 ;;
  *) fail "partition table $label: only dos (MBR) or gpt" ;;
esac
echo "size=$p2new" | sfdisk -q --no-reread --no-tell-kernel --wipe never --wipe-partitions never -N 2 "$IMG"
echo "start=$p3s, type=$type" | sfdisk -q --no-reread --no-tell-kernel --wipe never --wipe-partitions never --append "$IMG"
sfdisk -d "$IMG" > /tmp/table.txt
p3n=$(part 3 size)
[ "$(part 2 size)" = $p2new ] && [ "$(part 3 start)" = $p3s ] && [ -n "$p3n" ] || fail "the new table is not what was asked"

loop3=$(losetup -f --show -o $((p3s * 512)) --sizelimit $((p3n * 512)) "$IMG")
trap "losetup -d $loop1 $loop3 2>/dev/null || true" EXIT
# No old ext4 bytes where blkid looks, at the start and the end.
dd if=/dev/zero of=$loop3 bs=1M count=1 conv=notrunc status=none
dd if=/dev/zero of=$loop3 bs=1M count=1 seek=$((p3n / 2048 - 1)) conv=notrunc status=none
mkfs.vfat -F 32 -n GAMES $loop3 > /dev/null
fsck.vfat -n $loop3 > /dev/null || fail "fsck.vfat: GAMES is not clean"
losetup -d $loop3

loop2=$(losetup -f --show -r -o $((p2s * 512)) --sizelimit $((p2new * 512)) "$IMG")
trap "losetup -d $loop1 $loop2 2>/dev/null || true" EXIT
e2fsck -f -n $loop2 > /dev/null 2>&1 || fail "STORAGE does not check clean in its new partition"
fsck.vfat -n $loop1 > /dev/null 2>&1 || echo "Note: fsck.vfat reports something on ROCKNIX (it did not change)"
after=$(dd if="$IMG" bs=512 skip=34 count=$((p2s - 34)) status=none | sha256sum)
[ "$before" = "$after" ] || fail "the boot loader or ROCKNIX changed"
echo
echo "Done. New table:"
sfdisk -l -o Device,Start,End,Sectors,Size,Type "$IMG" | sed -n "/^Device/,\$p" | sed "s/^/  /"
echo "Labels: $(blkid -o value -s LABEL $loop1) / $(blkid -o value -s LABEL $loop2) / GAMES"
echo "Boot loader and ROCKNIX: unchanged (sha256 of sectors 34 to $((p2s - 1)))."
'
