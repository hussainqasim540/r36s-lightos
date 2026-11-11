#!/bin/sh
# Runs initramfs/init in Docker as it starts on the console, and checks the
# hand-over from stage 1 (the initramfs) to stage 2 (lightos/rootfs.sqfs):
# a FAT image labelled ROCKNIX on a loop device, the stage 1 tree
# (out/stage1.tar) on a tmpfs as the root, init as PID 1 in its own PID and
# mount namespaces. Three cases:
#   none   no lightos/rootfs.sqfs: stage 1 goes on by itself;
#   good   a root file system: init switches to it, logs say stage 2;
#   bad    a damaged rootfs.sqfs: stage 1 goes on by itself.
# The root file system is out/rootfs/rootfs.sqfs (tools/build_rootfs.sh) if
# there is one, else the stage 1 tree with the stage 2 marker. The container
# has no buttons and no USB device controller: init gets to the USB step,
# finds none and reboots, which ends its PID namespace. Needs an arm64
# Docker host (colima on Apple silicon) and --privileged (loop, mount).
#
# Usage: tools/test_init_stages.sh       (after tools/build_initramfs.sh)
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/out/stage1.tar" ] || { echo "No out/stage1.tar: run tools/build_initramfs.sh first" >&2; exit 1; }

docker run --rm --privileged -v "$here:/src:ro" debian:trixie bash -euc '
apt-get update -qq && apt-get install -y -qq squashfs-tools dosfstools mtools util-linux >/dev/null 2>&1
w=/work; mkdir -p $w; cd $w

if [ -f /src/out/rootfs/rootfs.sqfs ]; then
  cp /src/out/rootfs/rootfs.sqfs good.sqfs
  echo "Root file system: out/rootfs/rootfs.sqfs"
else
  mkdir -p rfs/dev rfs/proc rfs/sys rfs/tmp rfs/flash
  tar -xf /src/out/stage1.tar -C rfs
  echo "LightOS stage 2: test tree" > rfs/lightos/stage2
  mksquashfs rfs good.sqfs -comp zstd -quiet -noappend
  echo "Root file system: the stage 1 tree with the stage 2 marker (no out/rootfs/rootfs.sqfs)"
fi
head -c 100000 /dev/urandom > bad.sqfs

fails=0
check() {  # check NAME WHAT FILE PATTERN
  if grep -q "$4" "$3"; then echo "  ok    $2"; else echo "  FAIL  $2"; fails=$((fails + 1)); fi
}
run() {  # run CASE
  rm -f fat.img
  dd if=/dev/zero of=fat.img bs=1M count=$(( $(stat -c %s good.sqfs) / 1048576 + 32 )) status=none
  mkfs.vfat -n ROCKNIX fat.img >/dev/null
  mmd -i fat.img ::lightos
  [ $1 = none ] || mcopy -i fat.img $1.sqfs ::lightos/rootfs.sqfs
  loop=$(losetup -f --show fat.img)
  mkdir -p /x; mount -t tmpfs tmpfs /x
  tar -xf /src/out/stage1.tar -C /x
  # Its reboot -f ends the namespace: bash reports a hangup, not shown.
  { timeout 120 unshare -p -f -m --mount-proc=/proc chroot /x /lightos/init > console-$1.txt 2>&1 || true; } 2>/dev/null
  umount /x
  mkdir -p /mnt/$1; mount -o ro $loop /mnt/$1
  b=/mnt/$1/lightos/logs/boot-1
  echo "== $1: $(cat $b/os.txt 2>/dev/null || echo "no logs")"
  sed "s/^[0-9.]* /    /" $b/init.txt 2>/dev/null | grep -E "Root file system|Could not|Stage 2|GPU" || true
  case $1 in
    good)
      check $1 "os.txt says stage 2" $b/os.txt "^LightOS stage 2"
      check $1 "init.txt: rootfs copied" $b/init.txt "Root file system: lightos/rootfs.sqfs"
      check $1 "/ is the squashfs" $b/hardware.txt "^/dev/loop[0-9]* / squashfs ro"
      check $1 "/tmp is a tmpfs" $b/hardware.txt "^tmpfs /tmp tmpfs"
      check $1 "logs on the FAT (rw)" $b/hardware.txt " /flash vfat rw"
      check $1 "reached the USB step" console-$1.txt "No USB device controller"
      if [ -f /src/out/rootfs/rootfs.sqfs ]; then
        # No GPU in Docker: kmscube has to start and fail on the DRM device.
        echo "    gpu.txt, last lines:"; tail -n 4 $b/gpu.txt | sed "s/^/      /"
        check $1 "gpu.txt: kmscube ran and exited" $b/gpu.txt "^== exit"
      fi ;;
    *)
      check $1 "os.txt says stage 1" $b/os.txt "^LightOS stage 1"
      check $1 "/ is the initramfs" $b/hardware.txt "^tmpfs / tmpfs"
      check $1 "reached the USB step" console-$1.txt "No USB device controller" ;;
  esac
  [ $1 = bad ] && check $1 "init.txt: could not mount" $b/init.txt "Could not mount lightos/rootfs.sqfs"
  umount /mnt/$1; losetup -d $loop
}
run none
run good
run bad
[ $fails = 0 ] && echo "All checks passed." || { echo "$fails checks failed."; exit 1; }
'
