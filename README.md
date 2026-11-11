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
LightOS stage 1, a busybox initramfs on ROCKNIX's kernel, boots once from the
same card when `LIGHTOS.TXT` is armed, and the next power-on is ROCKNIX again
(see [Booting LightOS once](#booting-lightos-once-next-to-rocknix)).

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

## Booting LightOS once, next to ROCKNIX

LightOS stage 1 is ROCKNIX's kernel with our own userland: a static busybox
initramfs (`initramfs/init`, built into `lightos/initrd.img`) that the kernel
unpacks over ROCKNIX's built-in initramfs, started with
`rdinit=/lightos/init`. Everything it needs is built into that kernel, not
in modules: vfat, configfs, the mass-storage gadget, the USB role switch,
evdev and the R36S joypad (`odroidgo3-joypad`). It

1. asks for each button in turn (D-pad up, right, down, left, X, A, B, Y,
   L1, L2, R2, R1, FN, START, SELECT, left and right stick, volume + and -,
   a short press of POWER), up to 30 s each, and writes the key code and
   device of each to `keys.txt`; then shows any button until 2 minutes
   from the start. Nothing in LightOS acts on `KEY_POWER`, but holding
   POWER powers off (the PMIC). RESET is a hardware reset and is left out;
2. writes `os.txt`, `init.txt`, `keys.txt`, `keys-raw.txt`, `dmesg.txt` and
   `hardware.txt` (panel, DRM
   modes, input devices, cpufreq, devfreq, temperatures, battery, the
   one-shot token) to `lightos/logs/boot-N`, with the same counter as
   ROCKNIX's boots;
3. shares the FAT partition over the OTG port, like **LightOS SD via USB**,
   for 2 minutes;
4. reboots when the computer ejects it, or when no computer came.

The first boot, on 11 November, reached `init` 1.98 s after the kernel
started. The R36S buttons, from the guided test of `boot-14` (11 November,
every button asked for and pressed once, then the same codes again in the
free part):

| Button | Code | evdev | Device |
|---|---|---|---|
| D-pad up, down, left, right | 544, 545, 546, 547 | `BTN_DPAD_UP`, `DOWN`, `LEFT`, `RIGHT` | `r36s_Gamepad` |
| A | 305 | `BTN_EAST` | `r36s_Gamepad` |
| B | 304 | `BTN_SOUTH` | `r36s_Gamepad` |
| X | 307 | `BTN_NORTH` | `r36s_Gamepad` |
| Y | 308 | `BTN_WEST` | `r36s_Gamepad` |
| L1, R1 | 310, 311 | `BTN_TL`, `BTN_TR` | `r36s_Gamepad` |
| L2, R2 | 312, 313 | `BTN_TL2`, `BTN_TR2` | `r36s_Gamepad` |
| SELECT, START | 314, 315 | `BTN_SELECT`, `BTN_START` | `r36s_Gamepad` |
| FN | 316 | `BTN_MODE` | `r36s_Gamepad` |
| Left stick, right stick (pressed) | 317, 318 | `BTN_THUMBL`, `BTN_THUMBR` | `r36s_Gamepad` |
| Volume +, volume - | 115, 114 | `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN` | `gpio-keys-vol` |
| POWER | 116 | `KEY_POWER` | `rk805 pwrkey` |

The face buttons follow the Nintendo layout: A is on the right
(`BTN_EAST`) and B at the bottom (`BTN_SOUTH`). RESET sends nothing: it
resets the SoC. LightOS writes `keys.txt` only when the 2 minutes are over,
so a RESET during the test loses it (that is what happened to the first
try, which left no `boot-N` folder of its own).

**The one-shot.** `boot.ini` boots LightOS only when `LIGHTOS.TXT`, in the
root of the FAT partition, starts with `L`, a token that is new each time it
is armed, and is at least 64 bytes long. U-Boot keeps the first 64 bytes of
the last `LIGHTOS.TXT` it booted in **sector 31 of the partition**, the last
of the 32 reserved sectors of this FAT32 (empty on the card, and nothing
else uses it). It boots LightOS only for a token that is not already there,
writes it there first with a raw `mmc write`, and only boots LightOS if the
write worked. So the power-on after that is ROCKNIX whatever LightOS does: a
kernel that hangs needs a power cycle, not the card taken out. It only
writes over a sector that is empty or starts with `L`. `panic=10` reboots by
itself if `init` dies.

Tried on the console on 11 November: armed from **LightOS boot once**,
LightOS booted (`boot-10`: its command line, and the same token in
`LIGHTOS.TXT` and in sector 31), `fsck_msdos` found the partition clean with
a single `LIGHTOS.TXT`, and after the eject the console came back on
ROCKNIX's menu. The logs of that ROCKNIX boot (`boot-11`) have not been read
yet.

The first version had U-Boot rewrite the `L` in `LIGHTOS.TXT` with
`fatwrite`, and the console booted LightOS on every power-on. This U-Boot's
2017 `fatwrite` lower-cases the name it looks for, but only lower-cases a
short name on disk when its NT case bits say so: an upper-case `LIGHTOS TXT`
never matches. It then appends a second `LIGHTOS.TXT` (with `R`) at the end
of the root directory and reports success, while Linux and macOS keep
reading the first one (fsck: "Duplicate directory entry"). U-Boot now never
writes to the file system.

To arm it:

- from the computer, with the card mounted (reader, or over USB from ROCKNIX
  or from LightOS itself): `tools/lightos_once.sh /Volumes/ROCKNIX`, then
  eject: the console reboots into LightOS;
- on the console: **LightOS boot once** in ROCKNIX's Ports.

A working loop, with no card taken out: change `initramfs/init`, run
`tools/build_initramfs.sh` (Docker, e.g. colima) and `tools/install_card.sh`
on the card shared by LightOS, then `tools/lightos_once.sh`, and eject.

`tools/test_boot_ini.sh /Volumes/ROCKNIX` runs `sdcard/boot.ini` in a
mainline U-Boot sandbox against a FAT32 image laid out like the card (the
card's R36S tree and overlay, so `fdt apply` runs on the real files): no
flag, a token, the same token again, a new token, no `initrd.img`, another
letter, a file under 64 bytes, a sector 31 that holds something else. It
checks what `booti` gets, what is in sector 31, and that the rest of the
partition is byte for byte the same. The sandbox's commands are newer than
the console's: it checks the script's logic, not this U-Boot's quirks, as
the `fatwrite` case showed. To look at the card itself, with it shared over
USB: `sudo dd if=/dev/rdisk4 bs=1m | cat > out/fat.img` copies the partition
(2 GB, about 75 s).

## Next steps

1. Our own kernel next to ROCKNIX's, through the same one-shot: mainline
   with ROCKNIX's RK3326 patches, its R36S device tree and
   `panel-generic-dsi`, only the drivers the R36S uses, built in.
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
