#!/bin/sh
# R36S LightOS: writes what the system did into /flash/lightos/logs/boot-N,
# the folder mount-storage.sh opened for this boot, so it can be read on the
# computer without a UART. Snapshots at 0 s, 20 s, 60 s and 180 s after start; each
# one replaces the previous files, so a hang leaves the last state it reached.

logs=/flash/lightos/logs
dir=$logs/boot-$(cat $logs/count 2>/dev/null)
tmp=/tmp/lightos-diag
mkdir -p $tmp

hardware() {
  echo "== uptime"; cat /proc/uptime
  echo "== panel node"
  panel=/proc/device-tree/dsi@ff450000/panel@0
  tr '\0' ' ' < $panel/compatible; echo
  [ -e $panel/panel_description ] && echo "panel_description present: the overlay was applied"
  for c in /sys/class/drm/card*-*; do
    [ -d "$c" ] || continue
    echo "== $c"
    echo "status=$(cat $c/status) enabled=$(cat $c/enabled) dpms=$(cat $c/dpms)"
    cat $c/modes
  done
  for b in /sys/class/backlight/*; do
    [ -d "$b" ] || continue
    echo "== $b"
    for f in brightness actual_brightness max_brightness bl_power; do
      echo "$f=$(cat $b/$f)"
    done
  done
  echo "== usb device controller"; ls /sys/class/udc
  echo "== failed units"; systemctl --failed --no-pager
  echo "== ui"; systemctl status emustation weston --no-pager
  echo "== modules"; lsmod
}

snapshot() {
  dmesg > $tmp/dmesg.txt 2>&1
  journalctl -b --no-pager > $tmp/journal.txt 2>&1
  hardware > $tmp/hardware.txt 2>&1
  echo "$1" > $tmp/snapshot.txt

  mount -o remount,rw /flash || return
  mkdir -p $dir
  cp $tmp/*.txt $dir/
  sync
  mount -o remount,ro /flash
}

snapshot 0s
sleep 20;  snapshot 20s
sleep 40;  snapshot 60s
sleep 120; snapshot 180s
