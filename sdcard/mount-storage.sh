# R36S LightOS hook. ROCKNIX's initramfs sources /flash/mount-storage.sh in
# place of its own /storage mount, so the first line does that mount. The rest
# runs in a subshell and can never stop the boot: it starts a new log folder
# in /flash/lightos/logs, installs lightos-diag.service, which fills it, and
# puts the "LightOS SD via USB" entry in Ports.

mount_part "$disk" "/storage" "rw,noatime"

(
  src=/flash/lightos
  logs=$src/logs
  [ -f $src/lightos-diag.service ] || exit 0
  mount -o remount,rw /flash || exit 0

  mkdir -p $logs
  count=$(cat $logs/count 2>/dev/null)
  count=$(( ${count:-0} + 1 ))
  echo $count > $logs/count
  for old in $logs/boot-*; do
    [ -d "$old" ] && [ "${old##*-}" -le $(( count - 5 )) ] && rm -rf "$old"
  done
  mkdir -p $logs/boot-$count
  cat /proc/cmdline > $logs/boot-$count/cmdline.txt
  dmesg > $logs/boot-$count/dmesg-initramfs.txt

  units=/storage/.config/system.d
  mkdir -p $units/rocknix.target.wants
  cp $src/lightos-diag.service $units/lightos-diag.service
  ln -sf ../lightos-diag.service $units/rocknix.target.wants/lightos-diag.service

  # Ports entry for usb-disk.sh; diag.sh makes it executable (this busybox
  # has no chmod). rocknix-automount later runs
  # "mount --bind /storage/games-internal/roms /storage/roms" (with a single
  # card), so the entry goes there. Earlier versions left copies in the real
  # /storage/roms (hidden by that mount) and in /storage/games-internal/ports.
  rm -f "/storage/roms/ports/LightOS SD via USB.sh" \
        "/storage/games-internal/ports/LightOS SD via USB.sh"
  rmdir /storage/games-internal/ports 2>/dev/null
  if [ -f $src/usb-disk-port.sh ]; then
    mkdir -p /storage/games-internal/roms/ports
    cp $src/usb-disk-port.sh "/storage/games-internal/roms/ports/LightOS SD via USB.sh"
  fi

  sync
  mount -o remount,ro /flash
) || true
