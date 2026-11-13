#!/bin/sh
# Builds out/initrd.img, the LightOS stage 1 initramfs, in Docker (colima
# works): a static busybox from Alpine with its applets in /lightos/bin, and
# initramfs/init as /lightos/init, in a newc cpio wrapped as a U-Boot legacy
# ramdisk (this U-Boot has no raw initrd support). Uncompressed, so any
# kernel can unpack it. out/initrd.txt lists what went in. out/stage1.tar
# holds the same /lightos tree, for the Buildroot root file system
# (tools/build_rootfs.sh), so stage 2 runs the same init with the same tools.
# The boot logo, assets/logo/lume-avvio.svg (tools/lume_logo.py), goes in as
# lightos/splash.fb.gz: 640x480 in the frame buffer's XRGB8888 (bytes B, G,
# R, X), gzipped; stage 1 writes it to /dev/fb0.
#
# Usage: tools/build_initramfs.sh
# Then: tools/install_card.sh copies it to lightos/initrd.img on the card.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/out"

docker run --rm -v "$here:/src" alpine:3.20 sh -euc '
  apk add -q busybox-static u-boot-tools rsvg-convert imagemagick
  r=/tmp/root
  mkdir -p $r/lightos/bin $r/dev $r/proc $r/sys $r/tmp $r/flash
  cp /bin/busybox.static $r/lightos/bin/busybox
  for a in $($r/lightos/bin/busybox --list); do
    [ "$a" = busybox ] || ln -s busybox $r/lightos/bin/$a
  done
  install -m 755 /src/initramfs/init $r/lightos/init
  rsvg-convert /src/assets/logo/lume-avvio.svg -o /tmp/splash.png
  magick /tmp/splash.png -alpha off -depth 8 BGRA:/tmp/splash.fb
  [ $(wc -c < /tmp/splash.fb) = $((640 * 480 * 4)) ]
  gzip -9 -n -c /tmp/splash.fb > $r/lightos/splash.fb.gz
  mknod -m 600 $r/dev/console c 5 1
  $r/lightos/bin/sh -n $r/lightos/init
  (cd $r && find . -mindepth 1 | sort | cpio -o -H newc 2>/dev/null) > /tmp/initrd.cpio
  tar -cf /src/out/stage1.tar -C $r lightos
  mkimage -A arm64 -O linux -T ramdisk -C none -n "Lume stage 1" \
    -d /tmp/initrd.cpio /src/out/initrd.img > /tmp/mkimage.txt
  {
    echo "R36S LightOS stage 1 initramfs"
    apk list -I 2>/dev/null | grep -E "^(busybox-static|u-boot-tools)-"
    echo "cpio: $(wc -c < /tmp/initrd.cpio) bytes"
    cat /tmp/mkimage.txt
    echo "init sha256: $(sha256sum /src/initramfs/init | cut -d" " -f1)"
    echo "splash.fb.gz: $(wc -c < $r/lightos/splash.fb.gz) bytes, sha256 $(sha256sum /src/assets/logo/lume-avvio.svg | cut -c1-16) of lume-avvio.svg"
  } > /src/out/initrd.txt
'
cat "$here/out/initrd.txt"
