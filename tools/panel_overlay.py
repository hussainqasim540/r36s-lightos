#!/usr/bin/env python3
import argparse
import hashlib
import math
import struct
import sys
from pathlib import Path

FDT_MAGIC = 0xD00DFEED
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9
DSI_PANEL = "dsi@ff450000/panel@0"
ARKOS_NAMES = ["rk3326-r35s-linux.dtb", "rk3326-r36s-linux.dtb", "rk3326-rg351mp-linux.dtb", "rg351mp-kernel.dtb"]
FORMATS = ["rgb888", "rgb666", "rgb666_packed", "rgb565"]
CLOCK_NON_CONTINUOUS = 0x400
TARGETS = [(60.0, True), (59.7275, False)]
KNOWN_PANELS = {
    "4962c6341fcf": "Panel 0 (original)",
    "cc3ecb6ee691": "Panel 1",
    "18ab78d4d21e": "Panel 2",
    "fea2ddd54883": "Panel 3",
    "bc571422d07c": "Panel 4",
    "8875cacc7225": "Panel 4 (R36S-V21 2024-12-18 2552 pack)",
}


class Node:
    def __init__(self, name):
        self.name = name
        self.props = {}
        self.children = {}

    def find(self, path):
        node = self
        for part in path.strip("/").split("/"):
            node = node.children.get(part)
            if node is None:
                return None
        return node

    def u32(self, name, default=None):
        value = self.props.get(name)
        if value is None or len(value) < 4:
            return default
        return struct.unpack(">I", value[:4])[0]


def parse_dtb(blob):
    magic, _, off_struct, off_strings = struct.unpack(">IIII", blob[:16])
    if magic != FDT_MAGIC:
        raise ValueError("not a device tree blob")
    stack, root, pos = [], None, off_struct

    def string_at(offset):
        end = blob.index(b"\0", offset)
        return blob[offset:end].decode()

    while True:
        (token,) = struct.unpack(">I", blob[pos : pos + 4])
        pos += 4
        if token == BEGIN_NODE:
            end = blob.index(b"\0", pos)
            node = Node(blob[pos:end].decode())
            pos = (end + 4) & ~3
            if stack:
                stack[-1].children[node.name] = node
            else:
                root = node
            stack.append(node)
        elif token == END_NODE:
            stack.pop()
        elif token == PROP:
            length, nameoff = struct.unpack(">II", blob[pos : pos + 8])
            pos += 8
            stack[-1].props[string_at(off_strings + nameoff)] = blob[pos : pos + length]
            pos = (pos + length + 3) & ~3
        elif token == NOP:
            continue
        elif token == END:
            return root
        else:
            raise ValueError(f"bad token {token:#x} at {pos - 4}")


def build_dtb(root):
    strings, offsets, body = bytearray(), {}, bytearray()

    def name_offset(name):
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return offsets[name]

    def pad():
        while len(body) % 4:
            body.append(0)

    def emit(node):
        body.extend(struct.pack(">I", BEGIN_NODE))
        body.extend(node.name.encode() + b"\0")
        pad()
        for name, value in node.props.items():
            body.extend(struct.pack(">III", PROP, len(value), name_offset(name)))
            body.extend(value)
            pad()
        for child in node.children.values():
            emit(child)
        body.extend(struct.pack(">I", END_NODE))

    emit(root)
    body.extend(struct.pack(">I", END))
    header_size, rsvmap = 40, bytes(16)
    off_struct = header_size + len(rsvmap)
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    header = struct.pack(
        ">10I", FDT_MAGIC, total, off_struct, off_strings, header_size, 17, 16, 0, len(strings), len(body)
    )
    return header + rsvmap + bytes(body) + bytes(strings)


def init_sequence(raw):
    commands, pos = [], 0
    while pos + 3 <= len(raw):
        kind, wait, length = raw[pos], raw[pos + 1], raw[pos + 2]
        commands.append((kind, wait, raw[pos + 3 : pos + 3 + length]))
        pos += 3 + length
    return commands


def controller(commands):
    first = [data.hex() for _, _, data in commands[:3]]
    if first[:3] == ["ff30", "ff52", "ff01"]:
        return "NewVision NV3051D"
    if first and first[0].startswith("b9f11283"):
        return "Sitronix ST7703"
    return "unknown"


def native_mode(panel):
    timings = panel.children.get("display-timings")
    if timings is None:
        raise ValueError("the panel has no display-timings")
    native = timings.u32("native-mode")
    modes = list(timings.children.values())
    chosen = next((m for m in modes if m.u32("phandle") == native), modes[0])
    hor = [chosen.u32(k) for k in ("hactive", "hfront-porch", "hsync-len", "hback-porch")]
    ver = [chosen.u32(k) for k in ("vactive", "vfront-porch", "vsync-len", "vback-porch")]
    return round(chosen.u32("clock-frequency") / 1000), hor, ver


def best_totals(clocks, htotal, vmin, vtotal, target, vstretch):
    best = None
    for c in clocks:
        for vt in range(vmin, round(vtotal * vstretch) + 1):
            ht = round(c * 1000 / target / vt)
            if not htotal <= ht < htotal * 1.05:
                continue
            fps = c * 1000 / (ht * vt)
            key = (abs(fps - target), abs(c - clocks[0]), ht + vt)
            if best is None or key < best[0]:
                best = (key, c, ht, vt, fps)
    return best


def fit_mode(clock, hor, ver, target):
    htotal, vtotal = sum(hor), sum(ver)
    vmin = vtotal - ver[1] + min(ver[1], 16)
    best = best_totals([clock], htotal, vmin, vtotal, target, 1.35)
    if best is None or best[0][0] > 0.01:
        perfect = target * htotal * vtotal / 1000
        start = math.ceil(perfect / 10) * 10
        clocks = list(range(start, max(start, math.floor(1.25 * perfect / 10) * 10) + 1, 10))
        best = best_totals(clocks, htotal, vtotal, vtotal, target, 1.25)
    if best is None:
        return None
    _, c, ht, vt, fps = best
    hor, ver = hor.copy(), ver.copy()
    hor[1] += ht - htotal
    ver[1] += vt - vtotal
    return c, hor, ver, fps


def description(panel, name):
    commands = init_sequence(panel.props["panel-init-sequence"])
    flags = panel.u32("dsi,flags", 0) | CLOCK_NON_CONTINUOUS
    fmt = FORMATS[panel.u32("dsi,format", 0)]
    delays = [
        panel.u32("prepare-delay-ms", 50),
        panel.u32("reset-delay-ms", 50),
        panel.u32("init-delay-ms", 50),
        panel.u32("enable-delay-ms", 50),
        20,
    ]
    size = (panel.u32("width-mm", 52), panel.u32("height-mm", 70))
    lines = [
        f"G name='{name}' size={size[0]},{size[1]} delays={','.join(map(str, delays))} "
        f"format={fmt} lanes={panel.u32('dsi,lanes', 4)} flags=0x{flags:x}"
    ]
    clock, hor, ver = native_mode(panel)
    modes = []
    for target, default in TARGETS:
        fitted = fit_mode(clock, hor, ver, target)
        if fitted:
            c, h, v, fps = fitted
            modes.append((c, h, v, fps, default))
    original_fps = clock * 1000 / (sum(hor) * sum(ver))
    modes.append((clock, hor, ver, original_fps, not any(m[4] for m in modes)))
    for c, h, v, fps, default in modes:
        tail = " default=1" if default else ""
        lines.append(f"M clock={c} horizontal={','.join(map(str, h))} vertical={','.join(map(str, v))}{tail}")
    for _, wait, data in commands:
        lines.append(f"I seq={data.hex()}" + (f" wait={wait:x}" if wait else ""))
    return lines, commands, modes, (clock, hor, ver, original_fps)


def overlay(lines):
    root = Node("")
    fragment = Node("fragment@0")
    fragment.props["target-path"] = f"/{DSI_PANEL}".encode() + b"\0"
    body = Node("__overlay__")
    body.props["compatible"] = b"rocknix,generic-dsi\0"
    body.props["panel_description"] = b"".join(line.encode() + b"\0" for line in lines)
    fragment.children[body.name] = body
    root.children[fragment.name] = fragment
    return build_dtb(root)


def overlay_source(lines):
    quoted = ",\n\t\t\t\t".join('"' + line.replace('"', '\\"') + '"' for line in lines)
    return (
        "/dts-v1/;\n/plugin/;\n\n/ {\n\tfragment@0 {\n"
        f'\t\ttarget-path = "/{DSI_PANEL}";\n\t\t__overlay__ {{\n'
        '\t\t\tcompatible = "rocknix,generic-dsi";\n'
        f"\t\t\tpanel_description = {quoted};\n\t\t}};\n\t}};\n}};\n"
    )


def find_dtb(path):
    if path.is_file():
        return path
    for name in ARKOS_NAMES:
        if (path / name).is_file():
            return path / name
    raise SystemExit(f"no ArkOS dtb in {path} (looked for {', '.join(ARKOS_NAMES)})")


def main():
    parser = argparse.ArgumentParser(
        description="Make a mainline (ROCKNIX generic-dsi) panel overlay from the ArkOS dtb of an R36S"
    )
    parser.add_argument("dtb", type=Path, help="the ArkOS dtb, or the BOOT partition that holds it")
    parser.add_argument("-o", "--out", type=Path, default=Path("mipi-panel.dtbo"))
    parser.add_argument("--dts", type=Path, help="also write the overlay as readable source")
    parser.add_argument("-n", "--name", help="panel name in the overlay")
    args = parser.parse_args()

    path = find_dtb(args.dtb)
    blob = path.read_bytes()
    root = parse_dtb(blob)
    panel = root.find(DSI_PANEL)
    if panel is None or "panel-init-sequence" not in panel.props:
        raise SystemExit(f"{path} has no {DSI_PANEL} with an init sequence")
    model = root.props.get("model", b"").rstrip(b"\0").decode(errors="replace")
    lines, commands, modes, (clock, hor, ver, fps) = description(panel, args.name or model or "R36S")

    print(f"dtb:        {path} (md5 {hashlib.md5(blob).hexdigest()})")
    print(f"model:      {model}")
    known = KNOWN_PANELS.get(hashlib.sha1(panel.props["panel-init-sequence"]).hexdigest()[:12], "not in the list")
    print(f"controller: {controller(commands)}, {len(commands)} init commands")
    print(f"known as:   {known}")
    print(f"ArkOS mode: {clock} kHz, {'+'.join(map(str, hor))} x {'+'.join(map(str, ver))} = {fps:.2f} Hz")
    for c, h, v, mode_fps, default in modes:
        print(f"mode:       {c} kHz, {'+'.join(map(str, h))} x {'+'.join(map(str, v))} = {mode_fps:.4f} Hz{' (default)' if default else ''}")
    kinds = {kind for kind, _, _ in commands} - {0x05, 0x15, 0x39}
    if kinds:
        print(f"warning:    generic (non-DCS) packets {sorted(hex(k) for k in kinds)} are sent as DCS", file=sys.stderr)

    args.out.write_bytes(overlay(lines))
    print(f"wrote:      {args.out}")
    if args.dts:
        args.dts.write_text(overlay_source(lines))
        print(f"wrote:      {args.dts}")


if __name__ == "__main__":
    main()
