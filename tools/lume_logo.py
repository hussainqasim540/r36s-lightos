#!/usr/bin/env python3
"""Draws Lume's logo as SVG, in QuisLab's style (~/dev/quislab, decision
0001): two tones, the first letter heavy and lilac with a symbol in it (the
Q holds </>, the L holds a play triangle), the rest thin in one neutral
tone that follows the background, and the H's detached, slanted crossbar
(here the E's middle bar).

Writes assets/logo/lume-su-scuro.svg, lume-su-chiaro.svg (the wordmark),
lume-marchio-su-scuro.svg, lume-marchio-su-chiaro.svg (the L alone) and
lume-avvio.svg, the boot logo: 640x480, the wordmark on notte, which
tools/build_initramfs.sh turns into the frame buffer image.
Usage: tools/lume_logo.py
"""
import os

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "logo")

# QuisLab's palette (ricerca/2026-11-12-palette-e-logo.md).
TONES = {
    "su-scuro": ("#9D88EC", "#F2EEE8"),   # lilla, testo (on notte #0E0C16)
    "su-chiaro": ("#9883E5", "#1B1726"),  # lilla, inchiostro (on carta #F7F4EF)
}

TOP, BASE = 40, 280          # cap height 240, as the QH's H (245)
HEAVY, THIN = 52, 34         # the Q's stroke, the H's stems
GAP = 13                     # the H's crossbar to its free stem
SLANT = 0.9                  # the H crossbar's end: 472 across for 520 up


def poly(points, fill):
    pts = " ".join(f"{x:g},{y:g}" for x, y in points)
    return f'<polygon points="{pts}" fill="{fill}"/>'


def mark(lilac, ink):
    """The L, with a play triangle in its corner and the foot cut at 45
    degrees, as the Q's tail."""
    foot = BASE - HEAVY
    shapes = [
        poly([(0, TOP), (HEAVY, TOP), (HEAVY, foot), (148, foot),
              (148 + HEAVY, BASE), (0, BASE)], lilac),
        poly([(84, 118), (84, 190), (146, 154)], ink),
    ]
    return shapes, 148 + HEAVY


def word(x, ink):
    """U, M and E, thin, from x."""
    out = []
    # U: two stems and a half ring.
    w, r = 180, 90
    cx, cy = x + w / 2, BASE - r
    out.append(
        f'<path d="M{x:g},{TOP} H{x + THIN:g} V{cy:g} '
        f'A{r - THIN:g},{r - THIN:g} 0 0 0 {x + w - THIN:g},{cy:g} V{TOP} H{x + w:g} V{cy:g} '
        f'A{r:g},{r:g} 0 0 1 {x:g},{cy:g} Z" fill="{ink}"/>')
    x += w + 46
    # M: two stems and a V, clipped to the cap height.
    w = 200
    out.append(
        f'<clipPath id="m"><rect x="{x:g}" y="{TOP}" width="{w}" height="{BASE - TOP}"/></clipPath>'
        f'<path d="M{x + THIN / 2:g},{BASE + 40} V{TOP - 10} L{x + w / 2:g},214 '
        f'L{x + w - THIN / 2:g},{TOP - 10} V{BASE + 40}" fill="none" stroke="{ink}" '
        f'stroke-width="{THIN}" stroke-linejoin="miter" stroke-miterlimit="10" clip-path="url(#m)"/>')
    x += w + 46
    # E: stem, top and bottom bars, and the middle bar detached from the
    # stem with a slanted end, as the H's crossbar.
    w = 150
    mid = (TOP + BASE) / 2 - THIN / 2
    out.append(poly([(x, TOP), (x + w, TOP), (x + w, TOP + THIN), (x + THIN, TOP + THIN),
                     (x + THIN, BASE - THIN), (x + w, BASE - THIN), (x + w, BASE), (x, BASE)], ink))
    left = x + THIN + GAP
    out.append(poly([(left, mid), (x + w - 18, mid), (x + w - 18, mid + THIN),
                     (left + THIN * SLANT, mid + THIN)], ink))
    return out, x + w


def svg(shapes, width, height=BASE + TOP, pad=0):
    body = "\n  ".join(shapes)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-pad} 0 {width + 2 * pad} {height}" '
            f'width="{width + 2 * pad}" height="{height}">\n  {body}\n</svg>\n')


NOTTE = "#0E0C16"
SCREEN = (640, 480)
SPLASH_WIDTH = 360


def splash():
    """The boot logo: the wordmark, on dark, SPLASH_WIDTH wide in the middle
    of the panel."""
    lilac, ink = TONES["su-scuro"]
    shapes, end = mark(lilac, ink)
    rest, end = word(end + 46, ink)
    k = SPLASH_WIDTH / end
    x = (SCREEN[0] - SPLASH_WIDTH) / 2
    y = SCREEN[1] / 2 - (TOP + BASE) / 2 * k
    body = "\n    ".join(shapes + rest)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SCREEN[0]}" height="{SCREEN[1]}" '
            f'viewBox="0 0 {SCREEN[0]} {SCREEN[1]}">\n'
            f'  <rect width="{SCREEN[0]}" height="{SCREEN[1]}" fill="{NOTTE}"/>\n'
            f'  <g transform="translate({x:g} {y:.2f}) scale({k:.5f})">\n    {body}\n  </g>\n</svg>\n')


def main():
    with open(os.path.join(HERE, "lume-avvio.svg"), "w") as f:
        f.write(splash())
    for name, (lilac, ink) in TONES.items():
        shapes, end = mark(lilac, ink)
        with open(os.path.join(HERE, f"lume-marchio-{name}.svg"), "w") as f:
            f.write(svg(shapes, end, pad=20))
        rest, end = word(end + 46, ink)
        with open(os.path.join(HERE, f"lume-{name}.svg"), "w") as f:
            f.write(svg(shapes + rest, end, pad=20))
    print("wrote", ", ".join(sorted(os.listdir(HERE))))


if __name__ == "__main__":
    main()
