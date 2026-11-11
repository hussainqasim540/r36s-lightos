#!/bin/sh
# R36S LightOS: hands the FAT partition (/flash, the one with boot.ini, the
# overlays and lightos/) to a computer over the OTG port, as a USB disk.
#
# Started from Ports in ROCKNIX's menu. Linux keeps /flash read-only while
# the computer has it. When the computer ejects the disk (or the cable stays
# unplugged for 20 s), the console reboots, so the new files are used and no
# stale view of the partition stays around. If no computer shows up within
# 2 minutes, it puts the port back as it was and returns to the menu.
#
# What it did goes to /storage/.cache/lightos-usb-disk.log, which diag.sh
# copies into lightos/logs/boot-N/ on the next boot.

LOG=/storage/.cache/lightos-usb-disk.log
G=/sys/kernel/config/usb_gadget/lightos
WAIT_HOST=120
WAIT_GONE=20

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $LOG; }
: > $LOG

UDC=$(ls -1 /sys/class/udc 2>/dev/null | head -n1)
if [ -z "$UDC" ]; then
  log "no USB device controller in /sys/class/udc"
  exit 1
fi
# The OTG port is the only port: a device plugged into it (wifi, gamepad)
# means it is working as a host, as ROCKNIX's usbgadget also checks.
if grep -q configured "/sys/class/udc/$UDC/device/usb1/1-0:1.0/usb1-port1/state" 2>/dev/null; then
  log "a USB device is plugged into the OTG port, not starting"
  exit 1
fi
PART=$(awk '$2 == "/flash" { print $1 }' /proc/mounts)
if [ ! -b "$PART" ]; then
  log "no block device for /flash ($PART)"
  exit 1
fi

role() {
  for sw in /sys/class/udc/$UDC/device/usb_role/*/role; do
    [ -w "$sw" ] && echo "$1" > "$sw" && log "role $1: $sw"
  done
}

teardown() {
  [ -d $G ] || return 0
  echo "" > $G/UDC 2>/dev/null
  rm -f $G/configs/c.1/mass_storage.0
  rmdir $G/configs/c.1/strings/0x409 $G/configs/c.1 \
        $G/functions/mass_storage.0 $G/strings/0x409 $G 2>/dev/null
}

# Nothing may write to /flash while the computer has it.
systemctl stop lightos-diag 2>/dev/null
sync
mount -o remount,ro /flash

# Take the controller from whatever gadget ROCKNIX bound to it.
for udc in /sys/kernel/config/usb_gadget/*/UDC; do
  [ -n "$(cat "$udc" 2>/dev/null)" ] && echo "" > "$udc" && log "unbound $udc"
done
teardown

modprobe -q usb_f_mass_storage
mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/mass_storage.0
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0200 > $G/bcdUSB
echo "R36S LightOS" > $G/strings/0x409/manufacturer
echo "R36S SD (ROCKNIX partition)" > $G/strings/0x409/product
cat /storage/.cache/systemd-machine-id > $G/strings/0x409/serialnumber 2>/dev/null
echo "mass storage" > $G/configs/c.1/strings/0x409/configuration
echo 250 > $G/configs/c.1/MaxPower
lun=$G/functions/mass_storage.0/lun.0
echo 1 > $lun/removable
echo 0 > $lun/ro
echo 0 > $lun/cdrom
echo "$PART" > $lun/file
ln -s $G/functions/mass_storage.0 $G/configs/c.1/

role device
if ! echo "$UDC" > $G/UDC; then
  log "could not bind the gadget to $UDC"
  teardown
  role host
  exit 1
fi
log "sharing $PART on $UDC"

waited=0
seen=no
gone=0
while :; do
  state=$(cat /sys/class/udc/$UDC/state 2>/dev/null)
  file=$(cat $lun/file 2>/dev/null)
  if [ "$state" = configured ]; then
    [ $seen = no ] && log "computer connected"
    seen=yes
    gone=0
  elif [ $seen = yes ]; then
    gone=$((gone + 1))
  fi

  if [ $seen = yes ] && [ -z "$file" ]; then
    log "ejected by the computer"
    break
  fi
  if [ $seen = yes ] && [ $gone -ge $WAIT_GONE ]; then
    log "cable gone for ${WAIT_GONE}s (state $state)"
    break
  fi
  if [ $seen = no ] && [ $waited -ge $WAIT_HOST ]; then
    log "no computer after ${WAIT_HOST}s, back to the menu"
    teardown
    role host
    [ -x /usr/bin/usbgadget ] && /usr/bin/usbgadget --start >/dev/null 2>&1
    systemctl start lightos-diag 2>/dev/null
    exit 0
  fi

  sleep 1
  waited=$((waited + 1))
done

teardown
sync
log "rebooting"
systemctl reboot
