#!/bin/sh
# Builds out/initrd.img, the LightOS stage 1 initramfs, in Docker (colima
# works): a static busybox from Alpine with its applets in /lightos/bin, and
# initramfs/init as /lightos/init, in a newc cpio wrapped as a U-Boot legacy
# ramdisk (this U-Boot has no raw initrd support). Uncompressed, so any
# kernel can unpack it. out/initrd.txt lists what went in.
#
# Usage: tools/build_initramfs.sh
# Then: tools/install_card.sh copies it to lightos/initrd.img on the card.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/out"

docker run --rm -v "$here:/src" alpine:3.20 sh -euc '
  apk add -q busybox-static u-boot-tools
  r=/tmp/root
  mkdir -p $r/lightos/bin $r/dev $r/proc $r/sys $r/tmp $r/flash
  cp /bin/busybox.static $r/lightos/bin/busybox
  for a in $($r/lightos/bin/busybox --list); do
    [ "$a" = busybox ] || ln -s busybox $r/lightos/bin/$a
  done
  install -m 755 /src/initramfs/init $r/lightos/init
  mknod -m 600 $r/dev/console c 5 1
  $r/lightos/bin/sh -n $r/lightos/init
  (cd $r && find . -mindepth 1 | sort | cpio -o -H newc 2>/dev/null) > /tmp/initrd.cpio
  mkimage -A arm64 -O linux -T ramdisk -C none -n "R36S LightOS stage 1" \
    -d /tmp/initrd.cpio /src/out/initrd.img > /tmp/mkimage.txt
  {
    echo "R36S LightOS stage 1 initramfs"
    apk list -I 2>/dev/null | grep -E "^(busybox-static|u-boot-tools)-"
    echo "cpio: $(wc -c < /tmp/initrd.cpio) bytes"
    cat /tmp/mkimage.txt
    echo "init sha256: $(sha256sum /src/initramfs/init | cut -d" " -f1)"
  } > /src/out/initrd.txt
'
cat "$here/out/initrd.txt"
