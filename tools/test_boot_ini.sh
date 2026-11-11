#!/bin/sh
# Runs sdcard/boot.ini in a U-Boot sandbox (mainline v2024.10, in Docker)
# against a FAT32 image laid out like the ROCKNIX card, and checks the
# LIGHTOS.TXT one-shot: which kernel arguments and initrd booti would get,
# and that U-Boot rewrote the flag without breaking the file system.
#
# The sandbox's hush, load, itest, mw and fatwrite are newer than the
# console's 2017 U-Boot, so this checks the script's logic, not that U-Boot's
# FAT writer.
#
# Usage: tools/test_boot_ini.sh [/Volumes/ROCKNIX]
# With the card, its R36S tree and panel overlay go into the image, so
# "fdt apply" runs on the real files. The first run builds the sandbox into
# the Docker volume lightos-ubsandbox (a few minutes).
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
card=${1:-/Volumes/ROCKNIX}
work=$here/out/test-boot-ini
rm -rf "$work"
mkdir -p "$work"
cp "$here/sdcard/boot.ini" "$work/boot.ini"
if [ -f "$card/rk3326-gameconsole-r36s.dtb" ]; then
  cp "$card/rk3326-gameconsole-r36s.dtb" "$work/"
  cp "$card/overlays/mipi-panel.dtbo" "$work/" 2>/dev/null || true
  ls "$card" > "$work/root-names.txt"
fi

docker run --rm -v lightos-ubsandbox:/w -v "$work:/t" debian:bookworm bash -c '
set -e
apt-get update -qq
apt-get install -y -qq build-essential bison flex libssl-dev python3 python3-dev \
  python3-setuptools swig libgnutls28-dev uuid-dev bc efitools git \
  dosfstools mtools fdisk u-boot-tools >/dev/null 2>&1
if [ ! -x /w/u-boot/u-boot ]; then
  cd /w
  [ -d u-boot ] || git clone -q --depth 1 -b v2024.10 https://github.com/u-boot/u-boot.git
  cd u-boot
  make -s sandbox_defconfig
  make -s NO_SDL=1 -j8 u-boot dtbs >/dev/null 2>&1
fi
UB=/w/u-boot/u-boot
DTB=/w/u-boot/arch/sandbox/dts/test.dtb

cd /t
# The script as cfgload runs it: without the first line, and with booti
# replaced by a line the test can read.
tail -n +2 boot.ini | sed "s/^booti /echo RESULT /" > boot.cmd
echo "echo ARGS \${bootargs}" >> boot.cmd
mkimage -A sandbox -T script -C none -d boot.cmd boot.scr >/dev/null

# 300 MB image, one FAT32 partition with 4 KiB clusters, like the card.
OFF=$((2048 * 512))
make_image() {
  rm -f mmc1.img
  truncate -s 300M mmc1.img
  echo "2048,,c" | sfdisk -q mmc1.img
  mkfs.vfat -F 32 -s 8 -n ROCKNIX --offset 2048 mmc1.img >/dev/null
  export MTOOLS_SKIP_CHECK=1
  I="mmc1.img@@$OFF"
  if [ -f root-names.txt ]; then
    while read -r n; do
      case "$n" in .*|overlays|lightos|SYSTEM|KERNEL) continue;; esac
      echo "$n" > dummy; mcopy -o -i "$I" dummy "::$n"
    done < root-names.txt
  fi
  head -c 1000000 /dev/urandom > KERNEL; mcopy -i "$I" KERNEL ::KERNEL
  mmd -i "$I" ::overlays ::lightos
  if [ -f rk3326-gameconsole-r36s.dtb ]; then
    mcopy -o -i "$I" rk3326-gameconsole-r36s.dtb ::rk3326-gameconsole-r36s.dtb
    [ -f mipi-panel.dtbo ] && mcopy -i "$I" mipi-panel.dtbo ::overlays/mipi-panel.dtbo
  fi
  printf "LightOS test initrd" > initrd.img
  [ "$1" = no-initrd ] || mcopy -i "$I" initrd.img ::lightos/initrd.img
  mcopy -i "$I" boot.scr ::boot.scr
}
flag() { printf "%s\nrest of the file\n" "$1" > LIGHTOS.TXT; mcopy -o -i "mmc1.img@@$OFF" LIGHTOS.TXT ::LIGHTOS.TXT; }
first() { mtype -i "mmc1.img@@$OFF" ::LIGHTOS.TXT 2>/dev/null | head -c 1; }
run() {
  $UB -d $DTB -c "setenv hwrev none; load mmc 1:1 0x800800 boot.scr && source 0x800800" 2>&1 | tr -d "\r" > out.txt || true
  RESULT=$(grep "^RESULT" out.txt | tail -1)
  ARGS=$(grep "^ARGS" out.txt | tail -1)
}
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok    $1: $2"
  else echo "  FAIL  $1: got \"$2\", want \"$3\""; fails=$((fails + 1)); sed "s/^/        /" out.txt; fi
}
fsck_ok() {
  dd if=mmc1.img of=part.img bs=512 skip=2048 2>/dev/null
  fsck.vfat -n part.img > fsck.txt 2>&1 && echo clean || { echo damaged; sed "s/^/        /" fsck.txt >&2; }
}
rocknix="RESULT 0x02000000 - 0x01f00000"
lightos="RESULT 0x02000000 0x04000000 0x01f00000"

echo "no LIGHTOS.TXT"
make_image; run
check booti "$RESULT" "$rocknix"
echo "$ARGS" | grep -q "boot=LABEL=ROCKNIX" && echo "  ok    ROCKNIX arguments" || { echo "  FAIL  arguments: $ARGS"; fails=$((fails+1)); }
grep -q "overlay\|FDT_ERR" out.txt && grep -i "fdt\|overlay" out.txt | sed "s/^/  note  /"

echo "LIGHTOS.TXT = L"
make_image; flag L; run
check booti "$RESULT" "$lightos"
check args "$ARGS" "ARGS rdinit=/lightos/init quiet panic=10 console=ttyS2,115200 console=tty0"
check "flag after" "$(first)" R
check "file system" "$(fsck_ok)" clean
size=$(mtype -i "mmc1.img@@$OFF" ::LIGHTOS.TXT | wc -c)
check "flag size" "$size" "$(wc -c < LIGHTOS.TXT)"
check "flag rest" "$(mtype -i "mmc1.img@@$OFF" ::LIGHTOS.TXT | tail -n +2)" "rest of the file"

echo "second power-on (flag now R)"
run
check booti "$RESULT" "$rocknix"
check "flag after" "$(first)" R

echo "LIGHTOS.TXT = L, no lightos/initrd.img"
make_image no-initrd; flag L; run
check booti "$RESULT" "$rocknix"
echo "$ARGS" | grep -q "boot=LABEL=ROCKNIX" && echo "  ok    ROCKNIX arguments" || { echo "  FAIL  arguments: $ARGS"; fails=$((fails+1)); }
check "flag after" "$(first)" R

echo "LIGHTOS.TXT = x (any other letter)"
make_image; flag x; run
check booti "$RESULT" "$rocknix"
check "flag after" "$(first)" x

rm -f mmc1.img part.img dummy
[ $fails = 0 ] && echo "all checks passed" || { echo "$fails checks failed"; exit 1; }
'
