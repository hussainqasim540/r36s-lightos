# R36S LightOS hook. ROCKNIX's initramfs sources /flash/mount-storage.sh in
# place of its own /storage mount, so the first line does that mount. The rest
# runs in a subshell and can never stop the boot: it starts a new log folder
# in /flash/lightos/logs and installs lightos-diag.service, which fills it.

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

  sync
  mount -o remount,ro /flash
) || true
