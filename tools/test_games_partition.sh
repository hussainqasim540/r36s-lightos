#!/bin/sh
# Tests tools/games_partition.sh on two made-up 3 GiB cards, one with an MBR
# and one with GPT: a boot loader at sector 64, ROCKNIX (FAT, 256 MiB) and
# STORAGE (ext4, the rest) with files spread over it, some of them past the
# 1 GiB that STORAGE gets. After the script: the boot loader and ROCKNIX
# byte for byte the same, STORAGE checks clean with every file intact, and
# GAMES is a clean FAT32 partition that takes the rest. Needs Docker
# (colima) and --privileged. The images go in out/games-test/ (sparse).
#
# Usage: tools/test_games_partition.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
w=$here/out/games-test
mkdir -p "$w"
rm -f "$w"/*.img "$w"/*.txt

make() {  # make LABEL: the card and the sums of its files
  docker run --rm --privileged -v "$w:/w" -e LABEL=$1 debian:trixie bash -euc '
apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools util-linux >/dev/null 2>&1
img=/w/card-$LABEL.img
truncate -s 3G $img
printf "label: $LABEL\nstart=32768, size=524288, type=%s\nstart=557056, type=%s\n" \
  $([ $LABEL = gpt ] && echo "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 0FC63DAF-8483-4772-8E79-3D69D8477DE4" || echo "c 83") |
  sfdisk -q $img
head -c 4M /dev/urandom | dd of=$img bs=512 seek=64 conv=notrunc status=none
p1=$(losetup -f --show -o $((32768 * 512)) --sizelimit $((524288 * 512)) $img)
mkfs.vfat -n ROCKNIX $p1 >/dev/null
mkdir -p /m1; mount $p1 /m1; head -c 1M /dev/urandom > /m1/KERNEL; umount /m1; losetup -d $p1
p2n=$(sfdisk -d $img | sed -n "s/.*img2 *: *//p" | tr "," "\n" | sed -n "s/^ *size= *//p")
p2=$(losetup -f --show -o $((557056 * 512)) --sizelimit $((p2n * 512)) $img)
mkfs.ext4 -q -L STORAGE $p2
mkdir -p /m2; mount $p2 /m2
for i in $(seq 1 40); do head -c 50M /dev/urandom > /m2/f$i; done
mkdir -p /m2/.config; echo kept > /m2/.config/note
for i in $(seq 1 40); do [ $((i % 8)) = 0 ] || rm /m2/f$i; done
(cd /m2 && find . -type f | sort | xargs sha256sum) > /w/sums-$LABEL.txt
umount /m2; losetup -d $p2
dd if=$img bs=512 skip=34 count=$((557056 - 34)) status=none | sha256sum > /w/boot-$LABEL.txt
'
}

verify() {  # verify LABEL
  docker run --rm --privileged -v "$w:/w" -e LABEL=$1 debian:trixie bash -euc '
apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools util-linux >/dev/null 2>&1
img=/w/card-$LABEL.img
fails=0
ok() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
sfdisk -d $img > /tmp/t.txt
n=$(grep -c "^/w/" /tmp/t.txt)
get() { sed -n "s/.*img$1 *: *//p" /tmp/t.txt | tr "," "\n" | sed -n "s/^ *$2= *//p"; }
ok "three partitions" "[ $n = 3 ]"
ok "STORAGE is 1 GiB" "[ $(get 2 size) = 2097152 ]"
p3s=$(get 3 start) p3n=$(get 3 size)
last=$(( $(stat -c %s $img) / 512 - $([ $LABEL = gpt ] && echo 34 || echo 0) ))
ok "GAMES takes the rest of the card" "[ $((p3s + p3n)) -ge $((last - 2048)) ]"
ok "boot loader and ROCKNIX unchanged" "[ \"$(dd if=$img bs=512 skip=34 count=$((557056 - 34)) status=none | sha256sum)\" = \"$(cat /w/boot-$LABEL.txt)\" ]"
p2=$(losetup -f --show -r -o $((557056 * 512)) --sizelimit $((2097152 * 512)) $img)
ok "STORAGE checks clean" "e2fsck -f -n $p2 >/dev/null 2>&1"
mkdir -p /m2; mount -o ro $p2 /m2
ok "every STORAGE file intact" "(cd /m2 && sha256sum -c --quiet /w/sums-$LABEL.txt)"
umount /m2; losetup -d $p2
p3=$(losetup -f --show -o $((p3s * 512)) --sizelimit $((p3n * 512)) $img)
ok "GAMES is FAT32 labelled GAMES" "[ \"$(blkid -o value -s LABEL $p3)\" = GAMES ] && [ \"$(blkid -o value -s TYPE $p3)\" = vfat ]"
ok "GAMES checks clean" "fsck.vfat -n $p3 >/dev/null"
mkdir -p /m3; mount $p3 /m3; head -c 100M /dev/zero > /m3/big.nds; sync
ok "GAMES takes a 100 MB file" "[ $(stat -c %s /m3/big.nds) = 104857600 ]"
umount /m3; losetup -d $p3
[ $fails = 0 ]
'
}

fails=0
for label in dos gpt; do
  echo "== $label"
  make $label
  sh "$here/tools/games_partition.sh" "$w/card-$label.img" 1 | sed "s/^/    /"
  # Once more: it has to refuse a card that already has three partitions.
  if sh "$here/tools/games_partition.sh" "$w/card-$label.img" 1 > "$w/again-$label.txt" 2>&1; then
    echo "  FAIL  a second run changed the card again"; fails=$((fails + 1))
  else
    echo "  ok    a second run refuses: $(tail -n 1 "$w/again-$label.txt")"
  fi
  verify $label || fails=$((fails + 1))
done
rm -f "$w"/*.img
[ $fails = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
