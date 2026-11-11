#!/bin/sh
# R36S LightOS: Ports entry for usb-disk.sh. It runs a copy in /tmp, since the
# computer may change the one on /flash while it runs.
cp /flash/lightos/usb-disk.sh /tmp/lightos-usb-disk.sh && exec /bin/sh /tmp/lightos-usb-disk.sh
