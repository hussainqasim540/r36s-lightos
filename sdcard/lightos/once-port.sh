#!/bin/sh
# R36S LightOS: Ports entry "LightOS boot once". Writes LIGHTOS.TXT, "L" and
# a new token, in the root of /flash and reboots: U-Boot boots LightOS once
# for that token, and the power-on after that is ROCKNIX again.
[ -f /flash/lightos/initrd.img ] || exit 1
mount -o remount,rw /flash || exit 1
{
  echo "L $(date +%Y%m%dT%H%M%S) $(cat /proc/sys/kernel/random/uuid)"
  cat /flash/lightos/once.txt
} > /flash/LIGHTOS.TXT
sync
mount -o remount,ro /flash
systemctl reboot
