#!/bin/sh
# R36S LightOS: Ports entry "LightOS boot once". Puts LIGHTOS.TXT, starting
# with "L", in the root of /flash and reboots: U-Boot then boots LightOS
# once, and the power-on after that is ROCKNIX again.
[ -f /flash/lightos/initrd.img ] || exit 1
mount -o remount,rw /flash || exit 1
cp /flash/lightos/once.txt /flash/LIGHTOS.TXT
sync
mount -o remount,ro /flash
systemctl reboot
