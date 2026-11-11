#!/bin/sh
# Builds the LightOS root file system with Buildroot in Docker (colima
# works; arm64 hosts build it natively): Buildroot 2026.02.3 (LTS, sha256
# from its .sign file) with buildroot/patches applied to it, the external
# tree buildroot/ and configs/lightos_r36s_defconfig. Its own toolchain
# (glibc), Mesa with Panfrost (GLES, EGL, GBM), kmscube, modetest, ALSA, and
# the stage 1 tree (out/stage1.tar) in /lightos.
#
# Buildroot, the downloads and the build are kept in the Docker volume
# lightos-buildroot, so a second run is incremental. The first one builds
# the toolchain and host LLVM (for Panfrost's precompiled shaders): hours.
#
# Parallel jobs: one per 1.8 GB of the memory the Docker VM has free, at
# most one per CPU (JOBS=n overrides it). Buildroot's default, CPUs + 1, ran
# colima's 6 GiB VM out of memory in host-llvm: the kernel killed a cc1plus
# using 1.4 GB.
#
# Usage: tools/build_rootfs.sh            build
#        tools/build_rootfs.sh clean      start the build over
# Output: out/rootfs/rootfs.sqfs (tools/install_card.sh copies it to
# lightos/rootfs.sqfs) and out/rootfs/build.txt (versions, packages, sizes).
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/out/stage1.tar" ] || { echo "No out/stage1.tar: run tools/build_initramfs.sh first" >&2; exit 1; }
mkdir -p "$here/out/rootfs"

docker run --rm -v lightos-buildroot:/b -v "$here:/src" -e WHAT="${1:-build}" -e JOBS="${JOBS:-}" debian:trixie bash -euc '
BR_VERSION=2026.02.3
BR_SHA256=5a59e7501b0b4ec52c41f4bfa79412320e0b37eae5f719605a258e8d0c6fc7fb   # buildroot-$BR_VERSION.tar.xz.sign

apt-get update -qq
apt-get install -y -qq build-essential file wget curl cpio unzip rsync bc \
  python3 perl git ca-certificates xz-utils bzip2 patch which >/dev/null 2>&1
id br >/dev/null 2>&1 || useradd -m -u 1000 br

cd /b
t=buildroot-$BR_VERSION.tar.xz
[ -f $t ] || { curl -fsSL -o $t.part https://buildroot.org/downloads/$t && mv $t.part $t; }
sum=$(sha256sum $t | cut -d" " -f1)
if [ "$sum" != "$BR_SHA256" ]; then
  echo "sha256 of $t is $sum, expected $BR_SHA256" >&2
  exit 1
fi

# A pristine Buildroot tree with our patches, redone when they change.
stamp=$(cat /src/buildroot/patches/*.patch | sha256sum | cut -c1-16)
br=/b/buildroot
if [ "$(cat $br/.lightos-stamp 2>/dev/null)" != "$BR_VERSION $stamp" ]; then
  rm -rf $br buildroot-$BR_VERSION
  tar -xf $t
  mv buildroot-$BR_VERSION $br
  for p in /src/buildroot/patches/*.patch; do
    patch -d $br -p1 -s --no-backup-if-mismatch < $p
  done
  echo "$BR_VERSION $stamp" > $br/.lightos-stamp
fi
[ "$WHAT" = clean ] && rm -rf /b/output
mkdir -p /b/output /b/dl
chown -R br /b

if [ -z "$JOBS" ]; then
  avail=$(awk "/^MemAvailable:/ { print \$2 }" /proc/meminfo)
  JOBS=$(( avail / 1800000 ))
  [ $JOBS -ge 1 ] || JOBS=1
  [ $JOBS -le $(nproc) ] || JOBS=$(nproc)
fi
echo "Buildroot: $JOBS parallel jobs ($(( $(awk "/^MemAvailable:/ { print \$2 }" /proc/meminfo) / 1024 )) MiB available, $(nproc) CPUs)"

# The defconfig is applied every time, so a change to it takes effect.
su br -c "make -C $br BR2_EXTERNAL=/src/buildroot O=/b/output BR2_DL_DIR=/b/dl lightos_r36s_defconfig >/dev/null"
if ! su br -c "make -C $br O=/b/output BR2_DL_DIR=/b/dl BR2_JLEVEL=$JOBS > /b/output/build.log 2>&1"; then
  tail -60 /b/output/build.log >&2
  exit 1
fi

o=/src/out/rootfs
cp /b/output/images/rootfs.squashfs $o/rootfs.sqfs
{
  echo "LightOS root file system: Buildroot $BR_VERSION (sha256 $BR_SHA256)"
  echo "patches:"; for p in /src/buildroot/patches/*.patch; do echo "  ${p#/src/}"; done
  echo "defconfig sha256: $(sha256sum /src/buildroot/configs/lightos_r36s_defconfig | cut -c1-16)"
  echo "gcc: $(/b/output/host/bin/aarch64-buildroot-linux-gnu-gcc --version | head -1)"
  echo "glibc: $(ls /b/output/target/lib/ | grep -o "^libc\.so\.[0-9]*" | head -1), $(ls /b/output/build | grep -o "^glibc-[^ ]*" | head -1)"
  echo "packages:"; ls /b/output/build | grep -vE "^(host-|buildroot-|skeleton|toolchain|packages-file-list|build-time|\.)" | sed "s/^/  /"
  echo "rootfs.sqfs: $(stat -c %s $o/rootfs.sqfs) bytes, sha256 $(sha256sum $o/rootfs.sqfs | cut -d" " -f1)"
  echo "target: $(du -sh /b/output/target | cut -f1)"
} > $o/build.txt
'
cat "$here/out/rootfs/build.txt"
