# R36S LightOS hook. ROCKNIX's initramfs sources /flash/mount-storage.sh in
# place of its own /storage mount, so the first line does that mount. The rest
# runs in a subshell and can never stop the boot: it starts a new log folder
# in /flash/lightos/logs, installs lightos-diag.service, which fills it, and
# puts the "LightOS SD via USB" and "LightOS boot once" entries in Ports.

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

  # Ports entries for usb-disk.sh and the LightOS one-shot; diag.sh makes
  # them executable (this busybox has no chmod). rocknix-automount later runs
  # "mount --bind /storage/games-internal/roms /storage/roms" (with a single
  # card), so the entries go there. Earlier versions left copies in the real
  # /storage/roms (hidden by that mount) and in /storage/games-internal/ports.
  rm -f "/storage/roms/ports/LightOS SD via USB.sh" \
        "/storage/games-internal/ports/LightOS SD via USB.sh"
  rmdir /storage/games-internal/ports 2>/dev/null
  ports=/storage/games-internal/roms/ports
  mkdir -p $ports
  [ -f $src/usb-disk-port.sh ] && cp $src/usb-disk-port.sh "$ports/LightOS SD via USB.sh"
  # Lume is the default now: the old "LightOS boot once" entry goes.
  rm -f "$ports/LightOS boot once.sh"

  sync
  mount -o remount,ro /flash
) || true
