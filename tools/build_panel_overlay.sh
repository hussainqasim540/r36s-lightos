#!/bin/sh
# Makes LightOS's panel overlay from the one on the card: the same panel
# description (the R36S clones have different panels, so it is never
# written by hand here) with two of its delays shortened. boot.ini applies
# it, as lightos/mipi-panel.dtbo, only when it boots LightOS; ROCKNIX keeps
# overlays/mipi-panel.dtbo.
#
# panel-generic-dsi reads "delays=prepare,reset,init,enable,ready" on the G
# line, in ms, and on prepare: powers the panel, waits prepare, holds the
# reset line for reset, waits init, sends the init sequence (with each
# command's own wait), then display on and sleep out, and waits enable
# ("ready" is not used). The R36S overlay has delays=20,150,20,120,20 and
# its sequence already ends with sleep out (11, wait 200) and display on
# (29, wait 20). So:
#   - reset: the line only has to be held 10 us (the panel controllers'
#     reset pulse); the wait after it is init, unchanged. 150 -> 10 ms.
#   - enable: the driver's display on and sleep out come after the
#     sequence's own, to a panel that is already out of sleep, where they
#     do nothing. 120 -> 0 ms, only if the sequence has both commands.
# prepare, init and the sequence's waits stay as they are.
#
# Usage: tools/build_panel_overlay.sh [/Volumes/ROCKNIX]
# Output: out/panel/mipi-panel.dtbo (tools/install_card.sh copies it),
# out/panel/rocknix.dts and lightos.dts.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
card=${1:-/Volumes/ROCKNIX}
o=$here/out/panel
src=$card/overlays/mipi-panel.dtbo
[ -f "$src" ] || { echo "No $src" >&2; exit 1; }
rm -rf "$o"
mkdir -p "$o"
cp -X "$src" "$o/rocknix.dtbo"

# dtc from the kernel tree (tools/build_kernel.sh copies it to /w/bin).
dtc() {
  docker run --rm -v lightos-kernel:/w -v "$o:/o" debian:trixie \
    /w/bin/dtc -q "$@"
}
dtc -I dtb -O dts -o /o/rocknix.dts /o/rocknix.dtbo
# Check that dtc gives the card's file back, byte for byte, from its source.
dtc -I dts -O dtb -o /o/roundtrip.dtbo /o/rocknix.dts
cmp -s "$o/rocknix.dtbo" "$o/roundtrip.dtbo" || {
  echo "dtc does not rebuild $src byte for byte: not making an overlay from it" >&2
  exit 1
}

python3 - "$o/rocknix.dts" "$o/lightos.dts" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'"G [^"]*?delays=(\d+),(\d+),(\d+),(\d+)(,\d+)?', s)
if not m:
    sys.exit("no delays= on the G line")
prepare, reset, init, enable = (int(x) for x in m.groups()[:4])
seq = re.findall(r'"I seq=([0-9a-f]+)', s)
# The sequence ends the panel's init itself with sleep out and display on.
has_on = any(c == "11" for c in seq) and any(c == "29" for c in seq)
new_reset = min(reset, 10)
new_enable = 0 if has_on else enable
old = m.group(0)
new = old[:old.index("delays=")] + "delays=%d,%d,%d,%d%s" % (
    prepare, new_reset, init, new_enable, m.group(5) or "")
s = s.replace(old, new, 1)
open(sys.argv[2], "w").write(s)
print("delays: prepare %d, reset %d -> %d, init %d, enable %d -> %d%s" % (
    prepare, reset, new_reset, init, enable, new_enable,
    "" if has_on else " (no sleep out and display on in the sequence: enable kept)"))
EOF
dtc -I dts -O dtb -o /o/mipi-panel.dtbo /o/lightos.dts
rm -f "$o/roundtrip.dtbo"
echo "Differences from the card's overlay:"
diff "$o/rocknix.dts" "$o/lightos.dts" | sed -n 's/^\([<>]\).*\(delays=[0-9,]*\).*/  \1 \2/p'
echo "out/panel/mipi-panel.dtbo: $(wc -c < "$o/mipi-panel.dtbo" | tr -d ' ') bytes"
