#!/bin/sh
# Runs initramfs/init in Docker as it starts on the console, and checks the
# hand-over from stage 1 (the initramfs) to stage 2 (lightos/rootfs.sqfs):
# a FAT image labelled ROCKNIX on a loop device, the stage 1 tree
# (out/stage1.tar) on a tmpfs as the root, init as PID 1 in its own PID and
# mount namespaces. The cases:
#   none   no lightos/rootfs.sqfs: stage 1 goes on by itself;
#   good   a root file system: init switches to it, logs say stage 2;
#   bad    a damaged rootfs.sqfs: stage 1 goes on by itself;
#   trace  the root file system and lightos/gputrace: kmscube runs three
#          times under strace first (only with out/rootfs/rootfs.sqfs);
#   slot   the root file system and a stand-in slot/System/slot that asks
#          for poweroff: init starts it, and its poweroff ends it;
#   slottrace  the same with lightos/slottrace: slot gets the trace
#          variables, init samples the system into sys.txt;
#   realslot  slot's own R36S build (SLOT_DIST, by default
#          ~/dev/slot-r36s/dist-r36s/slot, if it is there): it has to load
#          its libraries and stop on finding no display.
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

SLOT_DIST=${SLOT_DIST:-$HOME/dev/slot-r36s/dist-r36s/slot}
slot_mount=
[ -f "$SLOT_DIST/System/slot" ] && slot_mount="-v $SLOT_DIST:/slot:ro"
docker run --rm --privileged -v "$here:/src:ro" $slot_mount debian:trixie bash -euc '
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
lacks() {  # lacks NAME WHAT FILE PATTERN: the file has no such line
  if grep -q "$4" "$3"; then echo "  FAIL  $2"; fails=$((fails + 1)); else echo "  ok    $2"; fi
}
run() {  # run CASE
  rm -f fat.img
  dd if=/dev/zero of=fat.img bs=1M count=$(( $(stat -c %s good.sqfs) / 1048576 + 32 )) status=none
  mkfs.vfat -n ROCKNIX fat.img >/dev/null
  mmd -i fat.img ::lightos
  case $1 in
    none) ;;
    trace) mcopy -i fat.img good.sqfs ::lightos/rootfs.sqfs
           : > gputrace; mcopy -i fat.img gputrace ::lightos/gputrace ;;
    slot|slottrace) mcopy -i fat.img good.sqfs ::lightos/rootfs.sqfs
          [ $1 = slottrace ] && { : > slottrace; mcopy -i fat.img slottrace ::lightos/slottrace; }
          mkdir -p fake/System
          printf "#!/bin/sh\necho \"stand-in slot, root \$SLOT_ROOT, run \$SLOT_RUN, trace \${SLOT_TRACE:-off} \${SLOT_TRACE_LATENCY:-off}\"\nls -ld /data /run\nsleep 2\npoweroff\nsleep 30\necho not stopped\n" > fake/System/slot
          chmod +x fake/System/slot
          mcopy -s -i fat.img fake ::slot ;;
    realslot) mcopy -i fat.img good.sqfs ::lightos/rootfs.sqfs
          mcopy -s -i fat.img /slot ::slot ;;
    *) mcopy -i fat.img $1.sqfs ::lightos/rootfs.sqfs ;;
  esac
  loop=$(losetup -f --show fat.img)
  mkdir -p /x; mount -t tmpfs tmpfs /x
  tar -xf /src/out/stage1.tar -C /x
  # Its reboot -f ends the namespace: bash reports a hangup, not shown.
  { timeout 120 unshare -p -f -m --mount-proc=/proc chroot /x /lightos/init > console-$1.txt 2>&1 || true; } 2>/dev/null
  umount /x
  mkdir -p /mnt/$1; mount -o ro $loop /mnt/$1
  b=/mnt/$1/lightos/logs/boot-1
  echo "== $1: $(cat $b/os.txt 2>/dev/null || echo "no logs")"
  sed "s/^[0-9.]* /    /" $b/init.txt 2>/dev/null | grep -E "Root file system|Could not|Stage 2|GPU|seedrng|slot:" || true
  case $1 in
    good)
      check $1 "os.txt says stage 2" $b/os.txt "^LightOS stage 2"
      check $1 "init.txt: rootfs copied" $b/init.txt "Root file system: lightos/rootfs.sqfs"
      check $1 "/ is the squashfs" $b/hardware.txt "^/dev/loop[0-9]* / squashfs ro"
      check $1 "/tmp is a tmpfs" $b/hardware.txt "^tmpfs /tmp tmpfs"
      check $1 "logs on the FAT (rw)" $b/hardware.txt " /flash vfat rw"
      check $1 "reached the USB step" console-$1.txt "No USB device controller"
      if [ -f /src/out/rootfs/rootfs.sqfs ]; then
        ls /mnt/$1/lightos/seed > seed-$1.txt 2>&1 || true
        check $1 "init.txt: seedrng at the start" $b/init.txt "seedrng from"
        check $1 "a creditable seed on the card" seed-$1.txt "seed.credit"
        # No GPU in Docker: kmscube has to start and fail on the DRM device.
        echo "    gpu.txt, last lines:"; tail -n 4 $b/gpu.txt | sed "s/^/      /"
        check $1 "gpu.txt: kmscube ran and exited" $b/gpu.txt "^== exit"
      fi ;;
    trace)
      check $1 "os.txt says stage 2" $b/os.txt "^LightOS stage 2"
      check $1 "gpu.txt: three traced runs" $b/gpu.txt "^== trace 3"
      check $1 "strace-1.txt in the logs" $b/strace-1.txt "execve"
      check $1 "strace-3.txt in the logs" $b/strace-3.txt "execve"
      check $1 "the 600 frames after them" $b/gpu.txt "^== kmscube"
      check $1 "reached the USB step" console-$1.txt "No USB device controller" ;;
    slot)
      check $1 "os.txt says stage 2" $b/os.txt "^LightOS stage 2"
      check $1 "init.txt: slot started" $b/init.txt "slot: started"
      check $1 "init.txt: slot ended by its poweroff" $b/init.txt "after asking for poweroff"
      check $1 "slot.log: its environment" $b/slot.log "root /flash/slot, run /run"
      lacks $1 "slot.log: its poweroff stopped it" $b/slot.log "not stopped"
      lacks $1 "no kmscube when slot runs" $b/init.txt "GPU: kmscube"
      check $1 "slot/Logs/slot.log: copied from /tmp" /mnt/$1/slot/Logs/slot.log "stand-in slot"
      check $1 "slot.log: no trace without slottrace" $b/slot.log "trace off off"
      check $1 "reached the USB step" console-$1.txt "No USB device controller" ;;
    slottrace)
      check $1 "init.txt: slot started with the traces" $b/init.txt "with SLOT_TRACE=1 SLOT_TRACE_LATENCY=1 SLOT_TRACE_FRAMES=1"
      check $1 "slot.log: the trace variables" $b/slot.log "trace 1 1"
      check $1 "init.txt: slot ended by its poweroff" $b/init.txt "after asking for poweroff"
      check $1 "init.txt: the trace line counts" $b/init.txt "latency lines"
      echo "    sys.txt:"; grep -v "open /sys" $b/sys.txt | sed "s/^/      /" | head -n 6
      check $1 "sys.txt: the sampler header" $b/sys.txt "^uptime cpu_mhz"
      check $1 "sys.txt: a sample" $b/sys.txt "^[0-9.]* [0-9]* [0-9]* "
      check $1 "sys-snap.txt: the end snapshot" $b/sys-snap.txt "^== end"
      check $1 "reached the USB step" console-$1.txt "No USB device controller" ;;
    realslot)
      echo "    slot.log:"; sed "s/^/      /" $b/slot.log | head -n 12
      check $1 "init.txt: slot started and exited" $b/init.txt "slot: exited"
      check $1 "slot.log: slot ran (no loader error)" $b/slot.log "^slot"
      check $1 "reached the USB step" console-$1.txt "No USB device controller" ;;
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
[ -f /src/out/rootfs/rootfs.sqfs ] && run trace
[ -f /src/out/rootfs/rootfs.sqfs ] && run slot
[ -f /src/out/rootfs/rootfs.sqfs ] && run slottrace
[ -f /src/out/rootfs/rootfs.sqfs ] && [ -f /slot/System/slot ] && run realslot
[ $fails = 0 ] && echo "All checks passed." || { echo "$fails checks failed."; exit 1; }
'
