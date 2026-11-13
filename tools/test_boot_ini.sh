#!/bin/sh
# Runs sdcard/boot.ini in a U-Boot sandbox (mainline v2024.10, in Docker)
# against a FAT32 image laid out like the ROCKNIX card, and checks that it
# boots Lume by default and ROCKNIX once for ROCKNIX.TXT or with VOL- held:
# which kernel arguments and initrd booti would get, what U-Boot leaves in
# sector 31 of the partition, and that it never changes the file system.
#
# The sandbox's commands are newer than the console's 2017 U-Boot. This
# checks the script's logic; the script only reads files and writes one raw
# sector, so it doesn't depend on the 2017 FAT writer (see boot.ini).
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
  cp "$here/out/panel/mipi-panel.dtbo" "$work/lightos-panel.dtbo" 2>/dev/null || true
  cp "$here/out/kernel/rk3326-gameconsole-r36s.dtb" "$work/lightos.dtb" 2>/dev/null || true
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
# replaced by a line the test can read. The sandbox crashes on "mmc read"
# and "mmc write" (v2024.10 passes the address as a host pointer, without
# map_sysmem), so they become "read/write mmc 1:0": the same raw blocks of
# the same device.
# VOL- ("gpio input c1") becomes false, or true for held.scr: the sandbox
# has no such pin.
script() {
  tail -n +2 boot.ini | sed -e "s/^booti /echo RESULT /" \
    -e "s/if mmc read /if read mmc 1:0 /" -e "s/if mmc write /if write mmc 1:0 /" \
    -e "s/^if gpio input c1; then/if $1; then/" > boot.cmd
  grep -q "read mmc 1:0" boot.cmd && grep -q "write mmc 1:0" boot.cmd && grep -q "^if $1; then" boot.cmd
  echo "echo ARGS \${bootargs}" >> boot.cmd
  echo "echo DTBO \${dtbo}" >> boot.cmd
  echo "echo DTB \${dtb_file}" >> boot.cmd
  echo "fdt print /dsi@ff450000/panel@0 panel_description" >> boot.cmd
  mkimage -A sandbox -T script -C none -d boot.cmd $2 >/dev/null
}
script false boot.scr
script true held.scr

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
  if [ "$1" = image ] || [ "$1" = image-dtb ]; then head -c 1234567 /dev/urandom > Image; mcopy -i "$I" Image ::lightos/Image; fi
  if [ "$1" = image-dtb ] || [ "$1" = dtb-only ]; then
    if [ -f lightos.dtb ]; then mcopy -i "$I" lightos.dtb ::lightos/rk3326-gameconsole-r36s.dtb
    else mcopy -i "$I" rk3326-gameconsole-r36s.dtb ::lightos/rk3326-gameconsole-r36s.dtb; fi
  fi
  if [ "$1" = panel ] || [ "$1" = image-dtb ]; then
    [ -f lightos-panel.dtbo ] && mcopy -i "$I" lightos-panel.dtbo ::lightos/mipi-panel.dtbo
  fi
  mcopy -i "$I" boot.scr ::boot.scr
  mcopy -i "$I" held.scr ::held.scr
}
flag() {
  { echo "R $1 0123456789abcdef0123456789abcdef"; echo "rest of the file, long enough for the 64 bytes U-Boot compares"; } > ROCKNIX.TXT
  mcopy -o -i "mmc1.img@@$OFF" ROCKNIX.TXT ::ROCKNIX.TXT
}
put_sector() { printf "$1" | dd of=mmc1.img bs=512 seek=$((2048 + 31)) conv=notrunc 2>/dev/null; }
# Sector 31 of the partition, first line.
sector() { dd if=mmc1.img bs=512 skip=$((2048 + 31)) count=1 2>/dev/null | tr -d "\0" | head -n 1; }
run() {
  $UB -d $DTB -c "setenv hwrev none; load mmc 1:1 0x800800 ${1:-boot}.scr && source 0x800800" 2>&1 | tr -d "\r" > out.txt || true
  RESULT=$(grep "^RESULT" out.txt | tail -1)
  ARGS=$(grep "^ARGS" out.txt | tail -1)
  DTBO=$(grep "^DTBO" out.txt | tail -1)
  TREE=$(grep "^DTB " out.txt | tail -1)
  APPLY=$(grep -ci "fdt_err\|failed to apply\|libfdt" out.txt || true)
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
# The partition without sector 31, to check nothing else was written.
others() { dd if=mmc1.img bs=512 skip=2048 2>/dev/null | dd bs=512 count=31 2>/dev/null | md5sum | cut -c1-8
           dd if=mmc1.img bs=512 skip=$((2048 + 32)) 2>/dev/null | md5sum | cut -c1-8; }
rocknix="RESULT 0x02000000 - 0x01f00000"
lume="RESULT 0x02000000 0x04000000 0x01f00000"
largs="ARGS rdinit=/lightos/init quiet panic=10 initcall_debug log_buf_len=1M console=ttyS2,115200 console=tty0 vt.global_cursor_default=0"
rargs() { echo "$ARGS" | grep -q "^ARGS boot=LABEL=ROCKNIX" && echo rocknix || echo "$ARGS"; }

echo "power-on, nothing armed"
make_image; before=$(others); run
check booti "$RESULT" "$lume"
check args "$ARGS" "$largs"
check sector "$(sector)" ""
check "kernel (no lightos/Image)" "$(grep -c "^1000000 bytes read" out.txt)" 1
check "overlay (no lightos/mipi-panel.dtbo)" "$DTBO" "DTBO overlays/mipi-panel.dtbo"
check "device tree" "$TREE" "DTB rk3326-gameconsole-r36s.dtb"
check "rest of the partition" "$(others)" "$before"
check "file system" "$(fsck_ok)" clean
grep -i "fdt_err\|failed to apply" out.txt | sed "s/^/  note  /"

echo "and the power-on after"
run
check booti "$RESULT" "$lume"

echo "VOL- held"
make_image; run held
check booti "$RESULT" "$rocknix"
check args "$(rargs)" rocknix
check sector "$(sector)" ""
echo "VOL- released"
run
check booti "$RESULT" "$lume"

echo "ROCKNIX.TXT armed with token A"
make_image; flag A; before=$(others); run
check booti "$RESULT" "$rocknix"
check args "$(rargs)" rocknix
check sector "$(sector)" "R A 0123456789abcdef0123456789abcdef"
check "kernel" "$(grep -c "^1000000 bytes read" out.txt)" 1
check "rest of the partition" "$(others)" "$before"
check "file system" "$(fsck_ok)" clean

echo "second power-on, same token"
run
check booti "$RESULT" "$lume"
check sector "$(sector)" "R A 0123456789abcdef0123456789abcdef"

echo "armed again with token B"
flag B; run
check booti "$RESULT" "$rocknix"
check sector "$(sector)" "R B 0123456789abcdef0123456789abcdef"
run
check "and the power-on after" "$RESULT" "$lume"

echo "armed, sector 31 left by the LightOS one-shot"
make_image; flag A; put_sector "L 20261113T084534 77c31685-e4a8-4b6a-bdc2-91e46cd4dc1d"; run
check booti "$RESULT" "$rocknix"
check sector "$(sector)" "R A 0123456789abcdef0123456789abcdef"

echo "armed, VOL- held too"
make_image; flag A; run held
check booti "$RESULT" "$rocknix"
check "token kept for the next power-on" "$(sector)" ""

echo "with lightos/Image"
make_image image; run
check booti "$RESULT" "$lume"
check kernel "$(grep -c "^1234567 bytes read" out.txt)" 1
check "not KERNEL" "$(grep -c "^1000000 bytes read" out.txt)" 0
flag A; run
check "ROCKNIX.TXT armed" "$RESULT" "$rocknix"
check "kernel then" "$(grep -c "^1000000 bytes read" out.txt)" 1

echo "with lightos/mipi-panel.dtbo"
if [ -f lightos-panel.dtbo ]; then
  make_image panel; run
  check booti "$RESULT" "$lume"
  check overlay "$DTBO" "DTBO lightos/mipi-panel.dtbo"
  check "overlay errors" "$APPLY" 0
  check "overlay bytes read" "$(grep -c "^$(wc -c < lightos-panel.dtbo) bytes read" out.txt)" 1
  check "delays in the tree" "$(grep -o "delays=[0-9,]*" out.txt)" "delays=20,10,20,0,20"
  run held
  check "VOL- held" "$RESULT" "$rocknix"
  check "overlay then" "$DTBO" "DTBO overlays/mipi-panel.dtbo"
  check "delays then" "$(grep -o "delays=[0-9,]*" out.txt)" "delays=20,150,20,120,20"
else
  echo "  skip  no out/panel/mipi-panel.dtbo (tools/build_panel_overlay.sh)"
fi

echo "with lightos/Image, its device tree and lightos/mipi-panel.dtbo (as installed)"
make_image image-dtb; run
check booti "$RESULT" "$lume"
check "device tree" "$TREE" "DTB lightos/rk3326-gameconsole-r36s.dtb"
check "overlay errors" "$APPLY" 0
if [ -f lightos-panel.dtbo ]; then
  check overlay "$DTBO" "DTBO lightos/mipi-panel.dtbo"
  check "delays in the tree" "$(grep -o "delays=[0-9,]*" out.txt)" "delays=20,10,20,0,20"
fi
run held
check "VOL- held" "$RESULT" "$rocknix"
check "device tree then" "$TREE" "DTB rk3326-gameconsole-r36s.dtb"

echo "lightos device tree without lightos/Image"
make_image dtb-only; run
check booti "$RESULT" "$lume"
check "device tree" "$TREE" "DTB rk3326-gameconsole-r36s.dtb"

echo "no lightos/initrd.img"
make_image no-initrd; run
check booti "$RESULT" "$rocknix"
check args "$(rargs)" rocknix
check sector "$(sector)" ""

echo "ROCKNIX.TXT starting with another letter"
make_image; { echo "L A 0123456789abcdef0123456789abcdef"; echo "rest of the file, long enough for the 64 bytes U-Boot compares"; } > ROCKNIX.TXT
mcopy -o -i "mmc1.img@@$OFF" ROCKNIX.TXT ::ROCKNIX.TXT; run
check booti "$RESULT" "$lume"
check sector "$(sector)" ""

echo "ROCKNIX.TXT shorter than 64 bytes"
make_image; echo "R short" > ROCKNIX.TXT; mcopy -o -i "mmc1.img@@$OFF" ROCKNIX.TXT ::ROCKNIX.TXT; run
check booti "$RESULT" "$lume"
check sector "$(sector)" ""

echo "sector 31 holds something else"
make_image; flag A; put_sector "XYZ not ours"; run
check booti "$RESULT" "$lume"
check sector "$(sector)" "XYZ not ours"

rm -f mmc1.img part.img dummy
[ $fails = 0 ] && echo "all checks passed" || { echo "$fails checks failed"; exit 1; }
'
