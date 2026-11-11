#!/bin/sh
# Builds the LightOS kernel in Docker (colima works; arm64 hosts build it
# natively): Linux 7.1.2 with ROCKNIX 20261101's RK3326 patches, device
# trees, panel-generic-dsi driver and RK3326 config (the kernel ROCKNIX
# ships for these handhelds since then), with kernel/lightos.config merged
# on top:
# no built-in initramfs (LightOS passes lightos/initrd.img), the version
# suffix "-lightos", and without what the R36S does not have (other boards'
# panels and joypads, HDMI, USB host, Btrfs and its raid6 benchmark). The
# build fails if a line of that fragment does not hold in the final config.
# It builds with gcc 14.2 (Debian trixie), the version ROCKNIX used. No
# modules are built: what LightOS uses is built in.
#
# Output in out/kernel/: Image, rk3326-gameconsole-r36s.dtb, config and
# build.txt (sources, patches, hashes). The kernel tree and object files are
# kept in the Docker volume lightos-kernel, so a second run is incremental;
# dtc is also copied to /w/bin/dtc there (tools/build_panel_overlay.sh).
#
# Usage: tools/build_kernel.sh
# Then: tools/install_card.sh copies Image and the device tree to lightos/
# on the card. The card's own device tree is from ROCKNIX 20250517 (6.12):
# this kernel boots with its own.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/out/kernel"

docker run --rm -v lightos-kernel:/w -v "$here/out/kernel:/o" \
  -v "$here/kernel:/k:ro" debian:trixie bash -euc '
LINUX_VERSION=7.1.2
LINUX_SHA256=37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f   # kernel.org sha256sums.asc
ROCKNIX_COMMIT=cefc14339a4ae18c02bb69888f27835e50664b60   # tag 20261101
ROCKNIX_TAG=20261101
# projects/ROCKNIX/packages/linux-drivers/rocknix-joypad/package.mk at that tag
JOYPAD_VERSION=005033d1ddd8746c771f2c81f1174f2d892541c9
JOYPAD_SHA256=7a9a90d9d25d48384771bf8fe7cfb53bba708b64aa4e56d44e71205a8bcc699a

apt-get update -qq
apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev \
  cpio xz-utils git python3 ca-certificates curl kmod >/dev/null 2>&1

cd /w
tarball=linux-$LINUX_VERSION.tar.xz
[ -f $tarball ] || { curl -fsSL -o $tarball.part https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VERSION%%.*}.x/$tarball && mv $tarball.part $tarball; }
sum=$(sha256sum $tarball | cut -d" " -f1)
if [ "$sum" != "$LINUX_SHA256" ]; then
  echo "sha256 of $tarball is $sum, expected $LINUX_SHA256" >&2
  exit 1
fi

[ -d rocknix ] || git clone -q --filter=blob:none --no-checkout https://github.com/ROCKNIX/distribution.git rocknix
git -C rocknix cat-file -e $ROCKNIX_COMMIT^{commit} 2>/dev/null || git -C rocknix fetch -q origin
git -C rocknix sparse-checkout set --no-cone /projects/ROCKNIX/packages/linux/patches/ \
  /projects/ROCKNIX/packages/linux-drivers/generic-dsi/sources/ /projects/ROCKNIX/devices/RK3326/
git -C rocknix checkout -q $ROCKNIX_COMMIT

# The R36S joypad (rocknix-singleadc-joypad in the device tree): ROCKNIX
# builds it as an out-of-tree module, LightOS builds it in.
joypad=rocknix-joypad-$JOYPAD_VERSION.tar.gz
[ -f $joypad ] || { curl -fsSL -o $joypad.part https://github.com/hackbar/rocknix-joypad/archive/$JOYPAD_VERSION.tar.gz && mv $joypad.part $joypad; }
sum=$(sha256sum $joypad | cut -d" " -f1)
if [ "$sum" != "$JOYPAD_SHA256" ]; then
  echo "sha256 of $joypad is $sum, expected $JOYPAD_SHA256" >&2
  exit 1
fi
R=/w/rocknix
P=$R/projects/ROCKNIX
D=$P/devices/RK3326

# The order of ROCKNIX scripts/unpack for DEVICE=RK3326 (projects/ROCKNIX/
# packages/linux/package.mk): the package patch dirs in PKG_PATCH_DIRS
# order that exist (mainline, mainline-rockchip, 7.0), then the device ones.
patches="$(ls $P/packages/linux/patches/mainline/*.patch
           ls $P/packages/linux/patches/mainline-rockchip/*.patch
           ls $P/packages/linux/patches/7.0/*.patch
           ls $D/patches/linux/*.patch)"
stamp=$(echo "$LINUX_VERSION $ROCKNIX_COMMIT $JOYPAD_VERSION $patches" | sha256sum | cut -c1-16)

src=/w/linux-$LINUX_VERSION
if [ "$(cat $src/.lightos-stamp 2>/dev/null)" != "$stamp" ]; then
  rm -rf $src
  tar -xf $tarball
  for p in $patches; do
    # As scripts/unpack: git apply for renames and binary patches.
    if grep -qE "^GIT binary patch$|^rename from|^rename to" $p; then
      git apply --directory=linux-$LINUX_VERSION -p1 --whitespace=nowarn --unsafe-paths < $p
    else
      sed -e "s#@TARGET_CPU@#cortex-a35#g" -e "s#@DEVICE@#RK3326#g" $p | patch -d $src -p1 -s --no-backup-if-mismatch
    fi
  done
  # post_patch: the generic DSI panel driver, built in, and the device trees.
  cp $P/packages/linux-drivers/generic-dsi/sources/panel-generic-dsi.c $src/drivers/gpu/drm/panel/
  echo "obj-y += panel-generic-dsi.o" >> $src/drivers/gpu/drm/panel/Makefile
  cp -r $D/linux/dts/. $src/arch/arm64/boot/dts/
  tar -xzf $joypad -C $src/drivers/input/joystick --strip-components=1 \
    rocknix-joypad-$JOYPAD_VERSION/rocknix-singleadc-joypad.c rocknix-joypad-$JOYPAD_VERSION/rocknix-joypad.h
  echo "obj-y += rocknix-singleadc-joypad.o" >> $src/drivers/input/joystick/Makefile
  echo $stamp > $src/.lightos-stamp
fi

cd $src
cp $D/linux/linux.aarch64.conf .config
scripts/kconfig/merge_config.sh -m -Q .config /k/lightos.config > /w/merge.log 2>&1
make -s olddefconfig
# Every line of the fragment must hold: an option set there can be turned
# back on by a select, or off by a missing dependency.
bad=0
while read -r line; do
  case $line in
    CONFIG_*=*) grep -qxF "$line" .config || { echo "not as in lightos.config: $line -> $(grep "^${line%%=*}=" .config || echo "not set")" >&2; bad=1; } ;;
    "# CONFIG_"*" is not set")
      o=${line#\# }; o=${o%% *}
      if grep -q "^$o=" .config; then echo "not as in lightos.config: $line -> $(grep "^$o=" .config)" >&2; bad=1; fi ;;
  esac
done < /k/lightos.config
[ $bad = 0 ] || exit 1
# -@ keeps __symbols__ in the tree, as ROCKNIX does: fdt apply needs it for
# the panel overlay.
if ! make -j$(nproc) DTC_FLAGS=-@ Image rockchip/rk3326-gameconsole-r36s.dtb > /w/make.log 2>&1; then
  tail -40 /w/make.log >&2
  exit 1
fi
grep -i "warning:" /w/make.log | sort -u | head -20 || true

mkdir -p /w/bin
cp scripts/dtc/dtc /w/bin/dtc
cp arch/arm64/boot/Image /o/Image
cp arch/arm64/boot/dts/rockchip/rk3326-gameconsole-r36s.dtb /o/
cp .config /o/config
{
  echo "LightOS kernel: $(make -s kernelrelease)"
  echo "linux-$LINUX_VERSION.tar.xz sha256 $LINUX_SHA256"
  echo "ROCKNIX $ROCKNIX_COMMIT ($ROCKNIX_TAG)"
  echo "gcc: $(gcc --version | head -1)"
  echo "patches:"
  for p in $patches; do echo "  ${p#$R/}"; done
  echo "  + projects/ROCKNIX/packages/linux-drivers/generic-dsi/sources/panel-generic-dsi.c (obj-y)"
  echo "  + projects/ROCKNIX/devices/RK3326/linux/dts/ over arch/arm64/boot/dts/"
  echo "  + hackbar/rocknix-joypad $JOYPAD_VERSION rocknix-singleadc-joypad.c (obj-y)"
  echo "config: linux.aarch64.conf + kernel/lightos.config (sha256 $(sha256sum /k/lightos.config | cut -c1-16))"
  echo "built in: $(grep -c "=y$" .config) options, Image $(stat -c %s /o/Image) bytes"
  echo "Image sha256: $(sha256sum /o/Image | cut -d" " -f1)"
  echo "dtb sha256:   $(sha256sum /o/rk3326-gameconsole-r36s.dtb | cut -d" " -f1)"
} > /o/build.txt
'
cat "$here/out/kernel/build.txt"
