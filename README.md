# Lume (R36S)

![Lume](assets/logo/lume-su-chiaro.svg)

Lume is the system this repo builds; it started as "R36S LightOS", and the
files, scripts and folders on the card still say `lightos`. The goal: a
minimal image for the R36S that boots straight into
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
Since 13 November the bench card boots Lume at every power-on, with
ROCKNIX kept on it as the way out (see [Lume, the card's
default](#lume-the-cards-default)).

## Lume, the card's default

The bench card (ROCKNIX 20250517's FAT partition and its U-Boot) boots Lume
at every power-on: the logo at about 1 s after the kernel, slot from stage 2,
the game on screen about 3.6 s after the kernel, at 60 fps (boot-53, boot-54).

- **ROCKNIX, once.** Hold **VOL-** while powering on, until the logo
  gives way to a line of text, or run `tools/rocknix_once.sh` with the card
  on the computer. Both write `ROCKNIX.TXT`, `R` and a new token, and
  `boot.ini` boots ROCKNIX for a token it has not booted yet and keeps it in
  sector 31 of the partition, as the LightOS one-shot did (below), so the
  power-on after is Lume again. Without `lightos/initrd.img` it boots
  ROCKNIX too. `tools/test_boot_ini.sh` runs every case in a U-Boot sandbox.
  VOL- is read by Lume's stage 1, not by U-Boot: `gpio input c1` (GPIO2 A1;
  this U-Boot names the banks A to D) never saw the key (boot-56, boot-57),
  and reading GPIO2's registers from `boot.ini` hung U-Boot on a black
  screen. The event device does not tell either: gpio-keys reports the keys
  already down only to its first opener, the console's `kbd` handler
  (boot-58 to boot-60). So stage 1, as soon as it finds the FAT partition,
  reads the line from debugfs's gpio list (`|VOLUMEDOWN ... in  lo` when
  held; the line goes to `init.txt` at every boot), writes `ROCKNIX.TXT`
  and reboots (`tools/test_init_stages.sh`, case volheld).
- **The logo.** `assets/logo/` holds Lume's logo in QuisLab's style
  (`~/dev/quislab`, decision 0001: two tones, the first letter heavy and
  lilac, the rest thin in a neutral tone, the H's detached slanted bar; the
  U's dots are the Game Boy's A and B buttons, lilac, set as on the pad),
  drawn by `tools/lume_logo.py`. `lume-avvio.svg` goes into the initramfs
  as `lightos/splash.fb.gz` (6 KB): stage 1 writes
  it to `/dev/fb0` (640x480, XRGB8888, stride 2560; the frame buffer is
  there 0.85 s after the kernel) and keeps the console quiet until slot
  draws. The button test, kmscube and the USB disk clear it and show their
  text. `vt.global_cursor_default=0` hides the cursor.
- **Power.** slot's power-off powers the console off right after the logs
  (`poweroff -f`; the rk817 is the system power controller), and its
  restart reboots. Once slot has saved and synced, its `poweroff` (init's
  shim) stops it with SIGKILL: slot then sleeps 10 s waiting for the system
  to kill it, and SIGTERM did not end that sleep (boot-59, boot-60 took
  10 s more). If slot stops by itself, the screen says so for 10 s and
  the console powers off. The USB disk is for development only: with
  `lightos/usbdisk` on the card, the card is shared over the OTG port first,
  for 8 s after slot (`WAIT_PLUG`) or 2 minutes without it, and for as long
  as a computer that showed up keeps it. The rk817 charger is no sign of a
  cable: boot-54 had it offline with the computer on the OTG port.

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

This was the bench until 13 November; `boot.ini` now boots Lume by default
(see [Lume, the card's default](#lume-the-cards-default)) and the one-shot
works the other way round, for ROCKNIX.

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

## The LightOS kernel

`tools/build_kernel.sh` builds our own kernel in Docker (now Linux 7.1.2,
see "Linux 7.1" below). First it was Linux 6.12.17 from kernel.org (sha256 checked against `sha256sums.asc`) with ROCKNIX
20250517's RK3326 patches in the order its `scripts/unpack` applies them
(`packages/kernel/linux/patches/{mainline,panfrost}`, then
`projects/Rockchip/patches/linux/{mainline,RK3326}`), its
`panel-generic-dsi.c` added as `obj-y`, and its RK3326 config. It builds
with gcc 14.2, as ROCKNIX did. The changes from ROCKNIX's kernel are only:

- no built-in initramfs: LightOS's `initrd.img` is the only one;
- `-lightos` after the version, and the hostname `lightos`.

Checked against the card: the R36S device tree comes out byte for byte the
same as ROCKNIX's (`DTC_FLAGS=-@`, as ROCKNIX, keeps the `__symbols__` that
`fdt apply` needs for the panel overlay), and the config extracted from
ROCKNIX's `KERNEL` (IKCONFIG) differs only in the binutils version, the
hostname, the initramfs and the version suffix. The built-in drivers
LightOS uses (vfat, configfs, the mass-storage gadget, the USB role switch,
evdev, the joypad, the panel) are built in here too. No modules are built.

`tools/install_card.sh` copies it to `lightos/Image`; when the one-shot is
armed and that file is there, `boot.ini` boots it instead of `KERNEL`
(still with ROCKNIX's device tree and the panel overlay). `os.txt` in the
logs says which kernel ran.

**Booted on the console on 11 November** (`boot-15`): `os.txt` says
`LightOS kernel 6.12.17-lightos`, `init` started at 1.97 s (1.98 s on
ROCKNIX's kernel), the panel came up the same way (overlay applied, 4
lanes, DSI-1 connected at 640x480), the buttons and the USB disk worked.
`hardware.txt` matches the boot on ROCKNIX's kernel apart from the version
and 128 KB more RAM without ROCKNIX's initramfs; cpufreq offers only 1008
and 1296 MHz and devfreq is empty on both. The dmesg has no errors or
warnings, and differs only in measured numbers (XOR speed, stick
calibration, the MMC tuning phase) and in the `raid6` benchmark, which only
shows in ours and is the first thing to cut for boot time.

The guided button test now runs only with a file `lightos/keytest` on the
card; without it, buttons show on the screen for 10 s.

### Slimming it down

`kernel/lightos.config` is merged on top of ROCKNIX's config, and the build
fails if any of its lines does not hold in the final `.config`. It turns
off what the R36S does not have and lists what LightOS needs built in, so a
change that drops one of those fails the build instead of the boot. Only
built-in code matters: `=m` options are never built.

Where `boot-15`'s 1.96 s before `init` went (dmesg timestamps):

| What | Time | |
|---|---|---|
| `raid6` benchmark (Btrfs selects `RAID6_PQ`) and `xor` | 520 ms | cut |
| panel power-on and init sequence (the overlay's `delays=20,150,20,120,20`, then `11 wait=c8`, `29 wait=14`) | about 680 ms, `[drm] Initialized` to `Console: switching` | the panel's timings, later |
| SD card SDR104 tuning | 400 ms, in parallel with the panel | hardware |
| dwc2 reset | 123 ms | hardware |
| 0.75 s to 0.88 s, after the initramfs is unpacked | 131 ms | unknown: `initcall_debug` will say |

First round, cut: Btrfs (and with it `raid6`/`xor`), NFS, ISO 9660, FUSE,
overlayfs, IPv6, the other handhelds' joypads, `adc-keys` and panels, the
HDMI/DP/LVDS/RGB outputs, the EHCI/OHCI host (disabled in the R36S device
tree), USB storage/HID/ACM, the network gadget functions, VFIO and EDAC.
The `Image` goes from 19.8 MB to 16.3 MB, 94 fewer built-in options, and
the device tree is unchanged. LightOS's boot arguments now carry
`initcall_debug log_buf_len=1M`, so `dmesg.txt` gives the time of each
initcall for the next round.

**Booted on the console on 11 November** (`boot-16`): `init` started at
1.44 s instead of 1.97 s. `hardware.txt` is the same as `boot-15`'s
(panel, DRM, input devices, USB disk, cpufreq) apart from the boot
arguments, the token and 1.3 MB less `MemTotal` (the 1 MB log buffer); the
buttons and the USB disk worked, and the dmesg has no messages that
`boot-15` did not have. The slowest initcalls (`initcall_debug`):

| Initcall | Time | What it is |
|---|---|---|
| `deferred_probe_initcall` | 712 ms | DRM bind and the panel's power-on and init sequence, `0.72 s` to `Console: switching` at `1.38 s` |
| `jent_mod_init` | 156 ms | the jitter entropy RNG's start-up test: the unknown gap of `boot-15` |
| `dwc2_platform_driver_init` | 128 ms | the OTG controller's reset |
| `rk3x_i2c_driver_init` | 61 ms | the PMIC and its regulators |
| `of_platform_default_populate_init` | 43 ms | creating the device tree's devices |

The SD card's tuning (done at 0.92 s) now ends before the panel does.

Second round, the two biggest waits that are not hardware:

- **The jitter entropy RNG** (156 ms): the crypto API's DRBG pulls it in,
  set `=y` in ROCKNIX's config and selected by `echainiv` (IPsec). All
  three are modules now, so not built; the kernel's own `/dev/random` does
  not use them.
- **The panel's delays.** `panel-generic-dsi` reads
  `delays=prepare,reset,init,enable,ready` (ms) from the overlay's G line:
  it powers the panel, waits *prepare*, holds the reset line for *reset*,
  waits *init*, sends the init sequence (each command with its own wait),
  then display on and sleep out, and waits *enable* (*ready* is unused).
  The R36S overlay has `20,150,20,120,20`, and its sequence already ends
  with sleep out (`11`, 200 ms) and display on (`29`, 20 ms). The reset
  line has to be held for microseconds, not 150 ms (the wait after it is
  *init*, unchanged), and the driver's display on and sleep out go to a
  panel already out of sleep, so the 120 ms after them wait for nothing.
  `tools/build_panel_overlay.sh` makes `lightos/mipi-panel.dtbo` from the
  card's own `overlays/mipi-panel.dtbo` (the R36S clones have different
  panels), with only those two changed: `20,10,20,0,20`. It checks that
  dtc rebuilds the card's file byte for byte first, and keeps *enable* if
  the sequence lacks sleep out or display on. `boot.ini` applies it only
  when it boots LightOS; ROCKNIX keeps its overlay. `tools/install_card.sh`
  copies it only if it was made from the overlay the card has now. The
  sandbox test checks which overlay is applied and the delays in the
  resulting tree, for LightOS and for the ROCKNIX boot after it.
  `hardware.txt` now shows the G line the kernel got.

Together about 415 ms (156 + 140 + 120) out of boot-16's 1.44 s.

**Booted on the console on 11 November** (`boot-17`): `init` started at
1.02 s (1.44 s in `boot-16`, 1.97 s in `boot-15`). `hardware.txt` shows
the G line with `delays=20,10,20,0,20`, DSI-1 connected and on at
640x480 (and on the screen the picture looked normal, no lines or
flicker), and is otherwise the same as `boot-16`'s; the dmesg has no new
messages and no `jent_mod_init`. The panel's probe took 418 ms instead of
684 ms. What is left of it: 270 ms of waits the panel asks for (20 ms after
power, 10 ms reset, 20 ms after it, 200 ms after sleep out, 20 ms after
display on) and about 150 ms to send the 190 commands of the init
sequence. Next in line: dwc2's reset (130 ms), the PMIC on i2c (61 ms).
These numbers are for 6.12.17; the kernel is now 7.1.2 (below).

### Linux 7.1

ROCKNIX moved its RK3326 build to Linux 7.1.2 (tag 20261101), and its tree
changed shape: the kernel package is `projects/ROCKNIX/packages/linux`,
the RK3326 patches are in `projects/ROCKNIX/devices/RK3326/patches/linux`,
and the RK3326 device trees are ROCKNIX's own files
(`devices/RK3326/linux/dts`), copied over the kernel's. `build_kernel.sh`
follows it: Linux 7.1.2 from kernel.org (sha256 checked), the package's
`mainline`, `mainline-rockchip` and `7.0` patches and then the device's,
in `scripts/unpack`'s order, `panel-generic-dsi.c` as before, the device
trees, and ROCKNIX's RK3326 config with `kernel/lightos.config` on top.
The 6.12.17 build is in the git history (ROCKNIX 20250517).

What changed for LightOS:

- **The joypad.** The new R36S tree has `rocknix-singleadc-joypad`
  instead of `odroidgo3-joypad`. ROCKNIX builds that driver as an
  out-of-tree module (`hackbar/rocknix-joypad`, the commit and sha256 of
  its `package.mk`); `build_kernel.sh` puts `rocknix-singleadc-joypad.c`
  into `drivers/input/joystick` as `obj-y`. It links against
  `joypad_input_g` from ROCKNIX's patch to `adc-keys`, so `KEYBOARD_ADC`
  is back in (and in the fragment's required list), though the tree has no
  adc-keys node. `odroidgo3-joypad` is off.
- **Its own device tree.** The card's `rk3326-gameconsole-r36s.dtb` is
  6.12's; `install_card.sh` copies the one built with the kernel to
  `lightos/`, and `boot.ini` loads it only together with `lightos/Image`
  (never with ROCKNIX's `KERNEL`). The panel node is still
  `/dsi@ff450000/panel@0` (`gameconsole,r36s-panel`, `sitronix,st7703`),
  so the card's overlay and LightOS's apply to it: the sandbox test boots
  the installed combination (kernel, its tree, LightOS's overlay) and
  checks the delays in the resulting tree.
- **The fragment still holds** line for line on 7.1's config. Crypto
  self-tests are now `CRYPTO_SELFTESTS`, off. New built in from ROCKNIX's
  config: full preemption (`PREEMPT_LAZY`), the PX30 memory controller's
  devfreq (its node is disabled in the R36S tree), some netfilter. The
  `Image` is 17.8 MB (16.3 MB on 6.12).

**Booted on the console on 11 November** (`boot-18`): `os.txt` says
`LightOS kernel 7.1.2-lightos`, `init` started at 1.00 s (1.02 s on
6.12, `boot-17`). `hardware.txt` matches `boot-17` apart from the version
(now `SMP PREEMPT`) and the joypad: `r36s_Gamepad` now comes from
`rocknix-singleadc-joypad`, with the same key bitmap as before and force
feedback (the driver found the rumble motor). Panel, DRM, cpufreq,
devfreq, power supplies and the USB disk are the same. The dmesg has no
errors or warnings. The panel's probe still takes 419 ms; dwc2's reset
(125 ms) now runs in the deferred probe after it, so the total before
`init` is the same.

The guided button test on 7.1 (`boot-19`): all 20 buttons were pressed and
each sent the same key code from the same device as on 6.12 (the table
above, from `boot-14`), POWER included.

## The root file system

Stage 2 is a Buildroot root file system (`buildroot/`, an external tree
for Buildroot 2026.02.3 LTS), on the card as `lightos/rootfs.sqfs`. The
card's U-Boot and boot.ini stay as they are. Stage 1, the busybox
initramfs, does the hand-over:

1. it copies `lightos/rootfs.sqfs` from the FAT partition to RAM (the card
   then stays free for the logs and the USB disk, as in stage 1);
2. it loop-mounts the copy read-only, mounts a tmpfs on its `/tmp` and
   moves `/dev`, `/proc` and `/sys` into it;
3. it runs `switch_root` to `/lightos/init` there. That is the same
   script and the same static busybox (Buildroot's post-build copies
   `out/stage1.tar` in). It finds the `/lightos/stage2` marker and goes
   on as stage 2.

If the file is missing, can't be copied or doesn't mount, stage 1 goes on
by itself, as before. busybox's `switch_root` refuses to run without a
regular file `/init` in the initramfs (a check before it empties it). Ours
starts from `rdinit=/lightos/init`, so init creates an empty `/init`
first. `tools/test_init_stages.sh` runs init as PID 1 in Docker against a
FAT image labelled ROCKNIX, in three cases (no rootfs, a good one, a
damaged one); its first run found the `/init` check.

Stage 2 adds one step before the button test: `kmscube` for 600 frames
(10 s at 60 Hz) on the panel, through Mesa's Panfrost. Its output (the EGL
and GL renderer) goes to `gpu.txt` in the boot's logs, with the DRM
connectors from `modetest`.

The defconfig (`configs/lightos_r36s_defconfig`): Buildroot's own
toolchain (glibc, C++, for slot), Cortex-A35, kernel headers 6.18, Mesa
26.0.1 with Panfrost (GBM, EGL, GLES), kmscube, libdrm with its tests
(`modetest`), ALSA's `amixer`, `aplay` and `speaker-test`, and a zstd
squashfs. The LightOS kernel builds Panfrost in (`kernel/lightos.config`).

Buildroot's Panfrost depends on target LLVM, which pulls in OpenCL and
SPIR-V. Mesa 26 needs those only to precompile Panfrost's internal shaders
(`panfrost_compile`, with `mesa_clc`), and those tools run on the build
machine, in host-mesa3d with host LLVM. The patch
`buildroot/patches/0001-mesa3d-panfrost-without-target-llvm.patch`
removes the target dependencies, so the root file system has no LLVM.

`tools/build_rootfs.sh` builds it in Docker (in the volume
`lightos-buildroot`, incremental after the first run). Order:
`build_initramfs.sh` (it writes `out/stage1.tar`), then `build_rootfs.sh`,
then `install_card.sh`.

The first build (11 November) took about 2 h 20 min on colima's VM (4
CPUs, 6 GiB), most of it host LLVM and clang. Two things stopped it on
the way:

- **Out of memory in host-llvm.** Buildroot runs CPUs + 1 jobs, and a
  cc1plus using 1.4 GB was killed. `build_rootfs.sh` now starts one job
  per 1.8 GB of free memory (2 or 3 here).
- **RTTI.** Without OpenCL nothing selects `BR2_PACKAGE_LLVM_RTTI`, so
  host LLVM has no RTTI, and host-mesa3d's meson refused to go on. The
  patch sets host-mesa3d's `cpp_rtti` from that option, as Buildroot
  already does for the target's Mesa.

After the first build, a change to init or to the defconfig's packages
costs minutes. The result: `rootfs.sqfs` is 9.3 MB (33 MB unpacked): glibc
2.42, gcc 14.3's libstdc++, Mesa's `libgallium` (19 MB, Panfrost only),
EGL, GLESv2, GBM, kmscube, modetest and ALSA. It has no LLVM. In
`test_init_stages.sh` this root file system reaches stage 2, and kmscube
starts and exits on finding no DRM device (Docker has no GPU).

### On the console

boot-29 (12 November) was the first boot into stage 2. init started at
1.03 s, the copy of `rootfs.sqfs` (9.3 MB) took 0.55 s, and stage 2
started at 1.69 s. Panfrost found the Mali-G31 (id 0x7093) and Mesa
reported `Mali-G31 MC1 (Panfrost)`, OpenGL ES 3.1, Mesa 26.0.1, on DSI-1
at 640x480, 59.94 Hz. Then kmscube stopped after 4.4 s with "user
interrupted!" before drawing a frame: in its default mode it quits as
soon as its stdin is readable, and its stdin was the console. Two fixes
followed:

- **A pipe from `sleep`.** kmscube ran, but ash's `wait` also waited for
  the `sleep`: in Docker the GPU step took 25 s.
- **A FIFO opened read and write** (`<>`). It never has anything to read,
  and no second process runs. This is what init does now.

boot-31 is the FIFO version. The cube drew on the panel, smoothly and
without tearing, and gpu.txt ends with "Rendered 599 frames in 9.994 sec
(59.93 fps)". That is the panel's refresh rate: each frame waits for
vsync, and none was dropped. kmscube exits with 0.

The whole step took 14.8 s, from 2.35 s to 17.12 s. Drawing took 10 s,
so about 4.8 s went before the first frame. On boot-31 init itself
started at 1.60 s, not 1.03 s: the SD card's probe (mmc1) took 0.93 s
("Busy; trying anyway"), so the card's reset time varies from boot to
boot.

### Where kmscube's 4.8 s went: the random number generator

With a file `lightos/gputrace` on the card, stage 2 first runs kmscube
three times for 120 frames under `strace -f -ttt -T` (in the root file
system for this), and the boot's logs get `strace-1.txt` to
`strace-3.txt`:

1. everything cold;
2. again, with the files in the page cache and Mesa's shader cache
   filled;
3. again after `drop_caches`, so the libraries come from the squashfs
   again.

On boot-32, the first frame came after 4.37 s, 0.49 s and 0.83 s. Of the
first run's 4.37 s, 3.54 s was a single `getrandom(16 bytes, 0)`. Mesa
reads its `drirc` with expat, which takes a hash salt from glibc's
`arc4random`, and that call blocks until the kernel's random number
generator is ready. That was late on every boot: "crng init done" came at
5.6 to 10 s. The RK3326 has no hardware RNG the kernel uses (no node in
`px30.dtsi`, and `rockchip-rng` starts at the RK3568), and ROCKNIX's
U-Boot passes no seed. Reading Mesa from the squashfs costs about
0.35 s; the GPU and the mode set are quick. slot, or anything else that
asks for random bytes early, would have waited the same way.

The fix is a seed kept on the card, as `seedrng` does on other systems:

- early in stage 2, init runs busybox's `seedrng` (Buildroot's busybox,
  in the root file system) on `lightos/seed`. It credits the seed saved at
  the previous boot and writes a new one.
- When it writes the logs, init runs `seedrng` again. The generator is
  ready by then, so the seed is creditable for the next boot.

Without a seed, the first boot waits as before. The first seed on the
card came from the Mac's `/dev/urandom`. The seed is on the FAT
partition, so anyone with the card can read it. For a game console that
is acceptable.

boot-33 shows the result:

- seedrng takes 0.09 s;
- "crng init done" comes at 2.39 s;
- the GPU step goes from 14.8 s to 10.6 s, so the first frame now
  comes about 0.6 s after kmscube starts, cold;
- 599 frames at 59.94 fps, as before.

### Sound: the speaker is on the headphone output

The rk817's sound card (`rk817_int`) works on the LightOS kernel without
any changes. The R36S device tree routes the speaker to the codec's
class D output (SPKO), and the codec's "Playback Mux" chooses between HP
and SPK. On this console the speaker is not wired that way. These boots
showed it:

| Boot | Mux | Volume | Heard |
|---|---|---|---|
| boot-34 | SPK | -24 dB, left channel only | nothing |
| boot-35 | SPK | 0 dB, both channels | nothing |
| boot-36 | SPK, then HP | 0 dB | only the HP tone, very loud, with no headphones in |

On boot-35 every DAPM widget of the speaker path was on (SPK DAC, Class
D, SPKO), so the configuration was right and the class D output simply
goes nowhere. The speaker is driven from the headphone outputs
(HPOL/HPOR), through an amplifier on the board.

So the mux stays on HP, which is the codec's default. On boot-37 a 2 s
tone at 191 of 255 (-24 dB) came out at the right level. After that the
tone was taken out of the boot: slot now plays the sound, with the codec
at full and its own volume in software.

The `Headphones Jack` control reads "on" with no headphones in, so the
jack detection (`hp-det-gpios`, active high in the device tree) may be
inverted. It does not matter for the speaker, which uses the same
output. It needs checking with real headphones before slot relies on
it.

## slot on LightOS

With `slot/` on the FAT partition, stage 2 starts slot in place of the
self-tests and the button test. `slot/` is slot-r36s's `dist-r36s/slot`
with games in `slot/Games/GBA`. The environment is the one slot's ArkOS
launcher sets: `SLOT_ROOT=/flash/slot`, `SLOT_RUN=/run` on a tmpfs, gpSP
for the GBA, and the codec on HP at full, since slot sets the volume in
software. slot's poweroff and reboot are shims that end slot. init then
writes the logs, with `slot.log`, shares the card over USB, and reboots
to ROCKNIX. `lightos/noslot` or `lightos/keytest` on the card brings back
the old boot.

slot needs no libudev. It loads EGL, GLES, GBM, libdrm and ALSA itself,
and reads `/dev/input` directly.

On the mainline kernel the joypad is called `r36s_Gamepad`, not ArkOS's
`GO-Super Gamepad`. slot fell back to its Anbernic map, so no button
worked (boot-40). slot-r36s 2646538 gives that name its own map: the
same as ArkOS's, but with SELECT, START and FN on `BTN_SELECT`,
`BTN_START` and `BTN_MODE`. On boot-41 the buttons, gpSP games and sound
worked.

Mesa's shader cache is kept on the card, in `lightos/cache`; in `/tmp`
it was empty at every boot. slot keeps its label cache in
`slot/System/Cache`. Here is the time from slot's start to its first
frame, from `slot.log`:

| | boot-41 | boot-42 | boot-44 |
|---|---|---|---|
| Caches | none | labels | labels and shaders |
| Surface (KMS, EGL, Mesa from the squashfs) | 0.39 s | 0.44 s | 0.39 s |
| Compositor (shaders) | 0.21 s | 0.21 s | 0.13 s |
| Cart and shelf faces, bezel | 0.93 s | 0.66 s | 0.67 s |
| UI faces | 0.78 s | 0.72 s | 0.79 s |
| First frame | 2.50 s | 2.21 s | 2.16 s |

On boot-44 slot started at 1.98 s after the kernel, so its first frame
came at 4.14 s. Of that, 2.16 s is slot's own start-up.

The same build of slot on ArkOS reached its first frame in 1.61 s
(`slot.log` on the ArkOS card). It drew its UI in 0.38 s, against 0.79 s
on LightOS. The difference was the clocks. ArkOS runs the CPU at
1512 MHz, LightOS at 1296 MHz. ArkOS also scales the DDR (its `dmc` was
at 528 MHz). LightOS never did: ROCKNIX's U-Boot starts the DDR at
333 MHz (rkbin's `rk3326_ddr_333MHz_v2.11.bin`), and `rk3326.dtsi` has
the dmc node disabled. Only ROCKNIX's eeclone tree turns it on.

`kernel/lightos-r36s.dtsi`, which `build_kernel.sh` includes at the end
of the R36S tree, turns it on for LightOS's dtb. The driver is ROCKNIX's
`px30_dmc`; BL31 makes the switch, with vdd_logic as its supply.
Before slot starts, init sets every devfreq device to `performance`, as
slot's ArkOS launcher does, so the DDR runs at 666 MHz and the GPU at
560 MHz. boot-45:

| | boot-44, DDR 333 MHz | boot-45, DDR 666 MHz | ArkOS |
|---|---|---|---|
| Surface | 0.39 s | 0.33 s | 0.05 s |
| Compositor | 0.13 s | 0.11 s | 0.44 s |
| Faces and bezel | 0.67 s | 0.52 s | 0.48 s |
| UI faces | 0.79 s | 0.57 s | 0.38 s |
| First frame | 2.16 s | 1.70 s | 1.61 s |

slot started at 1.89 s after the kernel, so its first frame came at
3.59 s. The DFI, which would measure the DDR's load for an ondemand
governor, says "unsupported memory type 0x3". With `performance` it is
not needed.

The CPU at 1512 MHz did not boot. ArkOS's dtb has an `opp-1512000000`
at 1.35 V, the same voltage as mainline's top OPP at 1296 MHz, and the
same node in `lightos-r36s.dtsi` gave a black screen: no console text,
no logs on the card, slot never started. The hang came before the
panel was up, which is about when cpufreq takes the CPU to its top OPP.
LightOS stays at 1296 MHz. With it, boot-47 had slot's first frame at
1.65 s, slot having started at 1.90 s after the kernel.

### 60 frames a second: what cost the frames

In steady play of Kirby, slot missed 22 to 28 flips in every 600 frames
(boot-49), against about 5 on ArkOS. Its audio ring starved for about
2400 samples a second. The clocks held (CPU 1296 MHz, GPU 560 MHz) and
nothing throttled (47 to 52 C). `lightos/slottrace` on the card runs slot
with its traces and samples the system (see the comment in
`initramfs/init`). Three boots narrowed it down:

| Boot | What it showed |
|---|---|
| boot-50 | Every missed flip had the frontend's advance step at 20 to 48 ms, against 0.1 ms in other frames. The emulator thread never took over 8 ms (gpSP 3 ms a frame) and drawing took 2 to 3 ms. |
| boot-52 | strace on slot's threads for 20 s: 40 calls to `close()` on `/dev/input/event1` took 37 to 41 ms each, on the main thread. That is the codec's Headphones jack, which slot opened, read and closed every 500 ms. On the mainline kernel, closing an evdev node waits for an RCU grace period (`input_close_device`). The main thread also opened the `Bezels/GBA` folder on the card twice a frame (2176 times in 20 s). |
| boot-53 | With slot-r36s 9d7fb36 (the jack's event device kept open, the bezel list cached until the folder changes): no missed flips in 9 of the 11 windows outside strace's 20 s, and 1 in the window with the game's launch. The worst frame's work went from 25 to 54 ms down to 6.2 to 6.6 ms. The audio ring did not starve outside the launch and strace's window. |

The jack itself read wrong: `rk3326-gameconsole-r3xs.dtsi` has its
detection pin, GPIO2 PC6, active high. On this R36S it reads high with
nothing plugged in, so slot used its headphone volume. ArkOS's tree has the
pin active low, and so does `lightos-r36s.dtsi` now.

## Next steps

1. Make the LightOS kernel ours: only the drivers the R36S uses, built in,
   a faster boot (first round done, 1.97 s to 1.44 s, see "Slimming it
   down"; second round, the jitter entropy RNG and the panel's delays,
   1.44 s to 1.02 s); Linux 7.1.2 as ROCKNIX 20261101, booted, all
   buttons checked.
2. A Buildroot root file system (`buildroot/`, see "The root file
   system"): Mesa with Panfrost and kmscube, ALSA, then slot and its
   gpSP and mGBA cores, done (see "slot on LightOS"; eudev turned out
   not to be needed). The kernel stays
   `tools/build_kernel.sh`'s. Mainline U-Boot with the Rockchip TPL/BL31
   from `rkbin` comes later, on a card of its own, since the bench card
   keeps ROCKNIX's bootloader.
3. Boot into slot from init in a few seconds, with clocks and the cpufreq
   governor managed by slot: slot's first frame is at 3.6 s after the
   kernel (boot-47), 1.65 s of it in slot's own start-up. In play it holds
   60 fps without missed flips or audio gaps (boot-53).
4. Overclocking: extra OPPs for CPU, GPU and DDR in the device tree, tested one
   step at a time. The DDR at 666 MHz works; the CPU at 1512 MHz and
   1.35 V does not boot.
