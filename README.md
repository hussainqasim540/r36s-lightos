# R36S LightOS (work in progress)

The goal: a minimal image for the R36S that boots straight into
[slot](https://github.com/Quis03/slot-r36s), with no ArkOS underneath. A
mainline kernel, busybox instead of systemd, no X and no EmulationStation, and
cores built for the Cortex-A35.

**Status:** there is no image to flash yet. This repo holds the first step:
checking that the mainline kernel drives the R36S panel, using ROCKNIX as a
test bench on a spare microSD card. **Panel 4 works on mainline:** ROCKNIX
20250517 (kernel 6.12.17) with `rk3326-gameconsole-r36s.dtb` and the overlay
from `panel_overlay.py` shows a picture. The first overlays put `name=` first
on the `G` line; that version of `panel-generic-dsi` stops at the first
parameter it doesn't know (`unknown param name` in dmesg), so it never read
`lanes=4` and drove the panel on 1 lane, with a black screen. `name=` now goes
last. `sdcard/` adds boot logs on the FAT partition, to work without a UART.

## Back up the ArkOS card first

The steps below only read the ArkOS card, but keep an image of it anyway. On
macOS, with the card in the reader:

```bash
diskutil list external physical          # find the card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=/dev/rdisk4 bs=4m status=progress | gzip > ~/r36s-arkos-backup.img.gz
```

To restore it: `diskutil unmountDisk /dev/disk4`, then
`gunzip -c ~/r36s-arkos-backup.img.gz | sudo dd of=/dev/rdisk4 bs=4m`.
Check the disk number twice: `dd` overwrites whatever it is pointed at.

## Why mainline is workable

[ROCKNIX](https://github.com/ROCKNIX/distribution) already runs the R36S on a
mainline kernel (7.1 at the time of writing):

- `projects/ROCKNIX/devices/RK3326/linux/dts/rockchip/rk3326-gameconsole-r36s.dts`
  describes the board (joypad, RK817, DSI, backlight).
- That tree drives the original panel (Panel 0, a Sitronix ST7703) with a
  patched `panel-sitronix-st7703`.
- Every other panel goes through `panel-generic-dsi`, a ROCKNIX driver that
  reads the init sequence and timings from the device tree. The boot partition
  carries an overlay, `overlays/mipi-panel.dtbo`, that switches the panel node
  to that driver and supplies the description.

What the ArkOS panel DTBs contain:

| ArkOS panel | Controller | ArkOS mode |
|---|---|---|
| Panel 0 | Sitronix ST7703 | 50 MHz, 60.30 Hz |
| Panel 1 | unknown (`E0 AB BA`, `E1 BA AB` first) | 29 MHz, 68.54 Hz |
| Panel 2, 3, 4 | NewVision NV3051D, each with its own init sequence | 29 MHz, 77.38 Hz |

Mainline does have an NV3051D driver, but its init sequence is the RG351V's
and RG353's. The register values (gamma, GIP) belong to each panel's glass, so
Panel 4 needs its own sequence: the overlay route.

ArkOS runs Panels 2 to 4 at 77.38 Hz (29 MHz over 732 × 512). The community
DTB pack for `R36S-V21 2024-12-18 2552` boards brings Panel 4 to 59.94 Hz with
the same 29 MHz clock and a longer vertical front porch. `panel_overlay.py`
keeps the ArkOS mode as the default, unchanged, and adds two more. Like
ROCKNIX's own `importpanel.py`, it only lengthens the blanking or raises the
clock for them, never shortens anything the panel was driven with:

- the ArkOS mode, the default;
- 60.00 Hz;
- 59.73 Hz, the Game Boy's own rate.

A first version made 60 Hz the default by shortening the vertical front porch
(165 to 135 lines on a 59.94 Hz Panel 4); the screen stayed black on the first
try, though that boot was also cut short, so the cause is not proven.

## Making the overlay

From the computer, with the ArkOS card inserted (the BOOT partition is FAT):

```bash
python3 tools/panel_overlay.py /Volumes/BOOT -o mipi-panel.dtbo --dts mipi-panel.dtso
```

On Linux the partition is usually at `/media/$USER/BOOT`. The script needs
nothing beyond Python 3. It finds the ArkOS DTB (`rk3326-r35s-linux.dtb`,
`rk3326-r36s-linux.dtb`, ...), names the controller, says whether the init
sequence matches a known panel, and prints the modes it wrote. The `.dtso` is
the same overlay as readable source.

## Testing it on the console

This uses ROCKNIX's mainline kernel as a test bench. It needs a **second
microSD card**, and the ArkOS card is never touched.

1. Write the ROCKNIX RK3326 image (`ROCKNIX-RK3326.aarch64-*-a.img.gz`, the
   "a" image) to the spare card.
2. Make the overlay on the ArkOS card as described above.
3. Put the spare card back in the computer and copy `mipi-panel.dtbo` to the
   `overlays/` folder of its first partition (`ROCKNIX`).
4. If ROCKNIX does not pick the R36S tree by itself, set it in
   `extlinux/extlinux.conf`, with nothing after `.dtb` on the line:

   ```
   FDT /rk3326-gameconsole-r36s.dtb
   FDTOVERLAYS /overlays/mipi-panel.dtbo
   ```

5. Boot. A picture that is stable, with no shift, tearing or wrong colours,
   means the mainline kernel drives the panel. Check the rate under
   ROCKNIX's SSH, or in its terminal: `cat /sys/class/drm/card*-DSI-1/modes`
   lists the modes, and `dmesg | grep -i dsi` shows what the driver did.

The first boot installs the system and reboots on its own, several times on
some RK3326 clones (ROCKNIX's EE-clone notes give about 5 minutes). Leave it
alone for at least 5 minutes before deciding the screen is black, and don't
cut the power while it is writing.

If the screen stays black, ROCKNIX can make the overlay itself: copy the ArkOS
DTB to the console over SSH and run `/usr/libexec/generic-dsi/importpanel.py
rk3326-r35s-linux.dtb -O dtbo -o /flash/overlays/mipi-panel.dtbo` (after
`mount -o remount,rw /flash`). ROCKNIX also points to ready-made R36S panel
overlays (`mipi-panel.dtbo.r36s-panel*`) from
[stolen/r.nix-distribution](https://github.com/stolen/r.nix-distribution/releases/tag/panel_overlays).

## Working on the card without taking it out

`sdcard/` holds files for the FAT partition of a ROCKNIX **20250517 A** card,
whose Hardkernel U-Boot reads `boot.ini` as plain text. With the card in the
computer:

```bash
tools/install_card.sh /Volumes/ROCKNIX
```

The first run keeps the card's own `boot.ini` as `lightos/boot.ini.before`.
`sdcard/boot.ini` is the one that got the system as far as mounting
`/storage` on 7 November: `rk3326-gameconsole-r36s.dtb` plus
`overlays/mipi-panel.dtbo`.

**Not U-Boot's `ums`.** The SD card over USB from U-Boot does not work with
this U-Boot (ROCKNIX/hardkernel-uboot `611716f`, `odroidgoa_defconfig`), for
two reasons found in its source:

- no board code implements `g_dnl_board_usb_cable_connected()`, so the weak
  default reports a cable as always connected and `ums` never returns, even
  with the cable unplugged: the console stays in U-Boot until it is powered
  off;
- U-Boot runs on the ODROID-GO Advance tree (`odroidgoa.dts`), which sets the
  OTG port of the USB PHY to `disabled`, since that console has no data OTG
  port.

A first `boot.ini` that started `ums` on Vol- never showed a disk on the
computer, and no boot that day reached `/storage`. A USB path has to come
from Linux instead (ROCKNIX's dwc2 gadget), once the system is known to boot.

**The SD card over USB, from Linux.** The hook also puts **LightOS SD via
USB** in ROCKNIX's Ports. It writes it to
`/storage/games-internal/roms/ports`: with a single card, `rocknix-automount`
runs `mount --bind /storage/games-internal/roms /storage/roms` after the
initramfs (its log line leaves out `/roms`), and a file in the real
`/storage/roms` ends up hidden. Start it, then plug the console's OTG port (not the
charging port) into the computer within 2 minutes. `usb-disk.sh` stops the
log service, keeps `/flash` read-only, switches the dwc2 to device mode with
the same `usb_role` switch as ROCKNIX's `usbgadget`, and shares the partition
under `/flash` through a configfs mass-storage gadget. The `ROCKNIX` volume
mounts on the computer: change `boot.ini`, the overlays or `lightos/`, read
`lightos/logs/`, then eject it. On eject, or 20 s after the cable is pulled,
the console reboots and uses the new files. With no computer after 2
minutes it gives the port back to host mode and returns to the menu. Each run
is logged to `/storage/.cache/lightos-usb-disk.log`, copied to `usb-disk.txt`
in the next boot's log folder. Replacing `KERNEL` or `SYSTEM` this way works
only for the next boot: the running system reads `SYSTEM` from that partition,
and may crash before the reboot.

This needs Linux to get as far as the menu. When a change stops it from
booting, the card has to come out once: copy `lightos/boot.ini.before` (or
the last working files) back.

**Did it boot?** Without a UART, the STORAGE superblock tells: its mount count
and last mount time (offsets `0x34` and `0x2C` of the superblock, 1024 bytes
into the partition) only change when the initramfs gets as far as mounting
`/storage`.

```bash
sudo dd if=/dev/rdisk4s2 bs=4096 count=1 of=out/storage-sb.bin
```

**Boot logs instead of a UART.** ROCKNIX's initramfs runs
`/flash/mount-storage.sh` in place of its own `/storage` mount. Ours does that
mount, opens `lightos/logs/boot-N/` (the last 5 boots are kept), saves
`dmesg` from the initramfs, and installs `lightos-diag.service` in
`/storage/.config/system.d`. The service writes `dmesg.txt`, `journal.txt` and
`hardware.txt` (panel node, DRM connector and modes, backlight, USB device
controller, failed units) 20 s, 60 s and 180 s after starting. A
`boot-N` folder with only `cmdline.txt` and `dmesg-initramfs.txt` means the
system stopped between the initramfs and systemd; no new folder at all means
the kernel never reached the initramfs.

To go back: copy `lightos/boot.ini.before` over `boot.ini`, and delete
`mount-storage.sh` and `lightos/`. The service left in `/storage` does nothing
once `lightos/diag.sh` is gone.

## Next steps

1. Boot a LightOS kernel and busybox initramfs from the same card, next to
   ROCKNIX, and fall back to ROCKNIX on the next power-on so a broken kernel
   never needs the card taken out (the R36S OTG port works in device mode:
   macOS saw **LightOS SD via USB** as a `File-Stor Gadget`, reading at about
   28 MB/s).
2. A Buildroot tree (`buildroot/`) that builds:
   - mainline u-boot and the Rockchip TPL/BL31 from `rkbin`;
   - a mainline kernel with ROCKNIX's RK3326 patches, its R36S device tree and
     `panel-generic-dsi`;
   - Mesa with Panfrost for slot's GLES;
   - busybox, ALSA, slot and the GB/GBC/GBA cores.
3. Boot into slot from init in a few seconds, with clocks and the cpufreq
   governor managed by slot.
4. Overclocking: extra OPPs for CPU, GPU and DDR in the device tree, tested one
   step at a time.
