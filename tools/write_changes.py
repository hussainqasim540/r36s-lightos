#!/usr/bin/env python3
"""Writes to a card only the parts of an image that changed.

    sudo python3 tools/write_changes.py OLD.img NEW.img /dev/rdiskN

OLD.img is a dump of the card as it is now (dd), NEW.img the same image after
a change (tools/games_partition.sh on an APFS clone of it). The card gets
every 4 MiB block where the two differ, and each one is read back and
compared. Before writing it checks, on macOS, that the device is an external
disk exactly as big as the images, and that the card still holds OLD.img
where it is going to write (so a wrong disk number, or a card changed since
the dump, stops it before anything is written).
"""
import os
import plistlib
import subprocess
import sys

CHUNK = 4 << 20


def disk_info(dev):
    out = subprocess.run(["diskutil", "info", "-plist", dev], capture_output=True, check=True).stdout
    return plistlib.loads(out)


def chunks(old, new, size):
    """The offsets of the blocks where the two images differ."""
    with open(old, "rb") as a, open(new, "rb") as b:
        for off in range(0, size, CHUNK):
            if a.read(CHUNK) != b.read(CHUNK):
                yield off


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    old, new, dev = sys.argv[1:]
    size = os.path.getsize(old)
    if os.path.getsize(new) != size or size % 512:
        sys.exit("The two images differ in size")
    if not dev.startswith("/dev/rdisk") or "s" in dev[len("/dev/rdisk"):]:
        sys.exit("Give the whole raw disk, like /dev/rdisk4 (not a partition)")
    info = disk_info(dev)
    if info.get("Internal", True) or info.get("Size") != size:
        sys.exit(f"{dev}: not an external disk of {size} bytes "
                 f"(internal: {info.get('Internal')}, size: {info.get('Size')})")
    print(f"{dev}: {info.get('MediaName', '?')}, {size} bytes")

    print("Comparing the images...")
    todo = list(chunks(old, new, size))
    print(f"{len(todo)} blocks of 4 MiB changed ({len(todo) * CHUNK >> 20} MiB)")
    if not todo:
        return
    subprocess.run(["diskutil", "unmountDisk", dev.replace("rdisk", "disk")], check=True)
    fd = os.open(dev, os.O_RDWR)
    try:
        with open(old, "rb") as a:
            for off in todo:
                a.seek(off)
                n = min(CHUNK, size - off)
                if os.pread(fd, n, off) != a.read(n):
                    sys.exit(f"The card differs from {old} at {off}: not the card that was dumped. Nothing written.")
        print("The card matches the dump. Writing...")
        with open(new, "rb") as b:
            for i, off in enumerate(todo, 1):
                b.seek(off)
                data = b.read(min(CHUNK, size - off))
                os.pwrite(fd, data, off)
                if i % 64 == 0 or i == len(todo):
                    print(f"  {i}/{len(todo)}", flush=True)
            os.fsync(fd)
            print("Reading back...")
            for off in todo:
                b.seek(off)
                n = min(CHUNK, size - off)
                if os.pread(fd, n, off) != b.read(n):
                    sys.exit(f"Read back differs at {off}: write it again, or restore {old}")
    finally:
        os.close(fd)
    print("Done: the card is the new image.")


if __name__ == "__main__":
    main()
