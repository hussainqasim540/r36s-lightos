#!/bin/sh
# Builds the LightOS kernel in Docker (colima works; arm64 hosts build it
# natively): Linux 6.12.17 with ROCKNIX 20250517's RK3326 patches, its
# panel-generic-dsi driver and its RK3326 config, the kernel that drives the
# R36S panel on the ROCKNIX card. Two changes from ROCKNIX's build: no
# built-in initramfs (LightOS passes lightos/initrd.img) and the version
# suffix "-lightos" (and the hostname, a placeholder ROCKNIX fills in). It
# builds with gcc 14.2 (Debian trixie), the version ROCKNIX used. No modules
# are built: what LightOS uses is built in.
#
# Output in out/kernel/: Image, rk3326-gameconsole-r36s.dtb, config and
# build.txt (sources, patches, hashes). The kernel tree and object files are
# kept in the Docker volume lightos-kernel, so a second run is incremental.
#
# Usage: tools/build_kernel.sh
# Then: tools/install_card.sh copies Image to lightos/Image on the card.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/out/kernel"

docker run --rm -v lightos-kernel:/w -v "$here/out/kernel:/o" debian:trixie bash -euc '
LINUX_VERSION=6.12.17
LINUX_SHA256=5c205cd34f80974e4973e321cb008f5f6895a8aa8c2577f06a9448cd77de63b3   # kernel.org sha256sums.asc
ROCKNIX_COMMIT=fec842b58559ee973a0100abd726370e4a032b77   # tag 20250517

apt-get update -qq
apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev \
  cpio xz-utils git python3 ca-certificates curl kmod >/dev/null 2>&1

cd /w
tarball=linux-$LINUX_VERSION.tar.xz
[ -f $tarball ] || curl -fsSL -o $tarball https://cdn.kernel.org/pub/linux/kernel/v6.x/$tarball
sum=$(sha256sum $tarball | cut -d" " -f1)
if [ "$sum" != "$LINUX_SHA256" ]; then
  echo "sha256 of $tarball is $sum, expected $LINUX_SHA256" >&2
  exit 1
fi

if [ ! -d rocknix ]; then
  git clone -q --filter=blob:none --no-checkout https://github.com/ROCKNIX/distribution.git rocknix
  git -C rocknix sparse-checkout set --no-cone /packages/kernel/linux/patches/ \
    /packages/kernel/drivers/generic-dsi/ /projects/Rockchip/patches/linux/ \
    /projects/Rockchip/devices/RK3326/linux/
fi
git -C rocknix checkout -q $ROCKNIX_COMMIT
R=/w/rocknix

# The order of ROCKNIX scripts/unpack for DEVICE=RK3326: the package patch
# dirs (mainline, panfrost), then the project ones (mainline, RK3326).
patches="$(ls $R/packages/kernel/linux/patches/mainline/*.patch
           ls $R/packages/kernel/linux/patches/panfrost/*.patch
           ls $R/projects/Rockchip/patches/linux/mainline/*.patch
           ls $R/projects/Rockchip/patches/linux/RK3326/*.patch)"
stamp=$(echo "$LINUX_VERSION $ROCKNIX_COMMIT $patches" | sha256sum | cut -c1-16)

src=/w/linux-$LINUX_VERSION
if [ "$(cat $src/.lightos-stamp 2>/dev/null)" != "$stamp" ]; then
  rm -rf $src
  tar -xf $tarball
  for p in $patches; do
    patch -d $src -p1 -s --no-backup-if-mismatch < $p
  done
  cp $R/packages/kernel/drivers/generic-dsi/sources/panel-generic-dsi.c $src/drivers/gpu/drm/panel/
  echo "obj-y += panel-generic-dsi.o" >> $src/drivers/gpu/drm/panel/Makefile
  echo $stamp > $src/.lightos-stamp
fi

cd $src
cp $R/projects/Rockchip/devices/RK3326/linux/linux.aarch64.conf .config
scripts/config --set-str INITRAMFS_SOURCE "" --set-str LOCALVERSION "-lightos" \
  --set-str DEFAULT_HOSTNAME "lightos" \
  --disable LOCALVERSION_AUTO
make -s olddefconfig
# -@ keeps __symbols__ in the tree, as ROCKNIX does: fdt apply needs it for
# the panel overlay.
if ! make -j$(nproc) DTC_FLAGS=-@ Image rockchip/rk3326-gameconsole-r36s.dtb > /w/make.log 2>&1; then
  tail -40 /w/make.log >&2
  exit 1
fi
grep -i "warning:" /w/make.log | sort -u | head -20 || true

cp arch/arm64/boot/Image /o/Image
cp arch/arm64/boot/dts/rockchip/rk3326-gameconsole-r36s.dtb /o/
cp .config /o/config
{
  echo "LightOS kernel: $(make -s kernelrelease)"
  echo "linux-$LINUX_VERSION.tar.xz sha256 $LINUX_SHA256"
  echo "ROCKNIX $ROCKNIX_COMMIT (20250517)"
  echo "gcc: $(gcc --version | head -1)"
  echo "patches:"
  for p in $patches; do echo "  ${p#$R/}"; done
  echo "  + packages/kernel/drivers/generic-dsi/sources/panel-generic-dsi.c (obj-y)"
  echo "Image sha256: $(sha256sum /o/Image | cut -d" " -f1)"
  echo "dtb sha256:   $(sha256sum /o/rk3326-gameconsole-r36s.dtb | cut -d" " -f1)"
} > /o/build.txt
'
cat "$here/out/kernel/build.txt"
