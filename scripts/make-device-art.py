"""Draws the device pictures for Settings → Кнопки: MX Master 3S from the side (636 x 1024) and
MX Keys Mini from the front (1382 x 616), in pencil: steady lines, soft graphite shading. Writes
<model>.png and <model>-dark.png (light ink for the dark appearance) into the given folder.
The button positions in DeviceArt.swift are in the same coordinates.
Needs rsvg-convert (brew install librsvg); with Pillow the PNGs are cut to a 64-colour palette
(~1 MB for all four instead of ~8 MB).
Usage: python3 scripts/make-device-art.py MXCtl/Resources/Devices"""
import math, os, random, subprocess, sys, tempfile

INK = "#232428"

def catmull(pts, closed):
    n = len(pts)
    get = (lambda i: pts[i % n]) if closed else (lambda i: pts[max(0, min(n - 1, i))])
    d = f"M{pts[0][0]:.1f},{pts[0][1]:.1f}"
    for i in range(n if closed else n - 1):
        p0, p1, p2, p3 = get(i - 1), get(i), get(i + 1), get(i + 2)
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}"
    return d + (" Z" if closed else "")

def line(pts, closed=False, w=2.0, op=0.9, passes=2, wob=0.5):
    """A steady pencil line: a main stroke and a lighter second pass almost on top of it."""
    out = []
    for p in range(passes):
        j = wob * p
        q = [(x + random.uniform(-j, j), y + random.uniform(-j, j)) for x, y in pts]
        out.append(f'<path d="{catmull(q, closed)}" fill="none" stroke="{INK}" stroke-width="{w * (1 if p == 0 else .55):.2f}" '
                   f'stroke-linecap="round" stroke-linejoin="round" opacity="{op * (1 if p == 0 else .45):.2f}"/>')
    return "\n".join(out)

def tone(d, op, filt="smudge"):
    """Graphite shading: a grey fill, roughened by the paper grain."""
    return f'<path d="{d}" fill="{INK}" opacity="{op}" filter="url(#{filt})"/>'

def rrect(x, y, w, h, r):
    return (f"M{x + r},{y} H{x + w - r} Q{x + w},{y} {x + w},{y + r} V{y + h - r} Q{x + w},{y + h} {x + w - r},{y + h} "
            f"H{x + r} Q{x},{y + h} {x},{y + h - r} V{y + r} Q{x},{y} {x + r},{y} Z")

def rrect_line(x, y, w, h, r, wd=1.8, op=0.9):
    return (f'<path d="{rrect(x, y, w, h, r)}" fill="none" stroke="{INK}" stroke-width="{wd}" opacity="{op}"/>\n'
            f'<path d="{rrect(x + .6, y + .5, w - .8, h - .6, r)}" fill="none" stroke="{INK}" stroke-width="{wd * .5}" opacity="{op * .4}"/>')

def hatch(clip, box, angle, gap, op, w=0.9):
    x0, y0, x1, y1 = box
    a = math.radians(angle); dx, dy = math.cos(a), math.sin(a); nx, ny = -dy, dx
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2; R = math.hypot(x1 - x0, y1 - y0) / 2
    out = [f'<g clip-path="url(#{clip})" filter="url(#grain)">']
    k = -R
    while k < R:
        px, py = cx + nx * k, cy + ny * k
        out.append(f'<path d="M{px - dx * R:.1f},{py - dy * R:.1f} L{px + dx * R:.1f},{py + dy * R:.1f}" '
                   f'stroke="{INK}" stroke-width="{w}" opacity="{op * random.uniform(.7, 1):.2f}"/>')
        k += gap
    out.append("</g>")
    return "\n".join(out)

DEFS = '''<defs>
  <filter id="grain" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="1.2" numOctaves="2" seed="4" result="n"/>
    <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -2.2 1.7" result="holes"/>
    <feComposite in="SourceGraphic" in2="holes" operator="in"/>
  </filter>
  <filter id="smudge" x="-10%" y="-10%" width="120%" height="120%">
    <feGaussianBlur stdDeviation="6" result="b"/>
    <feTurbulence type="fractalNoise" baseFrequency="0.95" numOctaves="2" seed="8" result="n"/>
    <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.8 1.45" result="holes"/>
    <feComposite in="b" in2="holes" operator="in"/>
  </filter>
  <filter id="pencil" x="-2%" y="-2%" width="104%" height="104%">
    <feTurbulence type="fractalNoise" baseFrequency="1.4" numOctaves="1" seed="2" result="n"/>
    <feDisplacementMap in="SourceGraphic" in2="n" scale="1.2" xChannelSelector="R" yChannelSelector="G" result="r"/>
    <feTurbulence type="fractalNoise" baseFrequency="2.2" numOctaves="1" seed="6" result="g"/>
    <feColorMatrix in="g" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.2 1.4" result="holes"/>
    <feComposite in="r" in2="holes" operator="in"/>
  </filter>
'''

def svg(w, h, shade, lines, clips):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">\n{DEFS}{clips}</defs>\n'
            f'<g>{shade}</g>\n<g filter="url(#pencil)">{lines}</g>\n</svg>\n')

# ------------------------------------------------------------------ mouse

def mouse():
    S, L, C = [], [], ""
    body = [(204, 40), (214, 12), (240, 3), (290, 8), (352, 26), (416, 49), (448, 64), (480, 84), (512, 121),
            (544, 185), (576, 271), (608, 376), (624, 448), (632, 512), (635, 576), (628, 640), (614, 704),
            (594, 768), (572, 832), (539, 896), (503, 960), (470, 1000), (420, 1021), (384, 1021), (330, 1009),
            (288, 993), (224, 962), (160, 926), (96, 885), (50, 846), (16, 800), (4, 740), (1, 672), (2, 608),
            (4, 544), (9, 480), (20, 448), (52, 416), (112, 384), (153, 352), (189, 320), (209, 288), (203, 224),
            (197, 160), (195, 96)]
    bd = catmull(body, True)
    C += f'<clipPath id="body"><path d="{bd}"/></clipPath>\n'

    # shading, from light to dark, all inside the body
    S.append(f'<g clip-path="url(#body)">')
    S.append(tone(bd, .05))
    S.append(tone(catmull([(560, 300), (640, 380), (640, 700), (560, 900), (480, 1000), (430, 960), (520, 800), (560, 600), (540, 420)], True), .20))
    S.append(tone(catmull([(0, 770), (90, 840), (230, 900), (380, 960), (480, 1005), (420, 1040), (200, 980), (0, 880)], True), .26))
    S.append(tone(catmull([(196, 60), (240, 40), (300, 330), (250, 330), (205, 300)], True), .12))   # side of the main button
    S.append(tone(catmull([(205, 318), (250, 322), (300, 400), (300, 640), (250, 640), (215, 520)], True), .10))  # thumb panel
    S.append('</g>')
    S.append(f'<path d="M346,560 Q342,640 350,660 Q372,668 386,640 Q392,600 384,560 Z" fill="{INK}" opacity=".08" filter="url(#smudge)"/>')

    L.append(line(body, True, w=2.6, passes=2, wob=.7))
    # main buttons: a plain seam down to the wheel and on from it to the plate, the edge of the
    # left button, the plate under the wheel, the side of the right button
    L.append(line([(396, 40), (406, 76), (416, 111)], w=1.8))
    L.append(line([(455, 289), (461, 320), (466, 352)], w=1.8))
    L.append(line([(206, 44), (232, 120), (262, 210), (290, 290), (318, 378)], w=1.5, op=.7))
    L.append(line([(318, 384), (380, 372), (430, 360), (466, 352)], w=1.8))
    L.append(line([(488, 92), (508, 170), (520, 250), (528, 330), (540, 368), (580, 398), (612, 420)], w=1.8))
    # scroll wheel: a knurled tyre in a thin recess, along the seam
    wh = '<g transform="rotate(-12.5 436 200)">'
    wh += rrect_line(403, 111, 66, 178, 30, wd=1.2, op=.55)
    wh += f'<path d="{rrect(411, 120, 50, 160, 24)}" fill="{INK}" opacity=".07"/>'
    wh += rrect_line(411, 120, 50, 160, 24, wd=2.0)
    for k in range(17):
        y = 132 + k * 8.5
        wh += f'<path d="M417,{y:.1f} H455" stroke="{INK}" stroke-width="1" opacity=".5"/>'
    wh += '<path d="M428,126 V274" stroke="#fff" stroke-width="6" opacity=".45"/></g>'
    L.append(wh)
    # mode shift button
    L.append(f'<g transform="rotate(-6 504 382)">{rrect_line(480, 346, 48, 72, 12)}</g>')
    # thumb panel: its edge and the nose with the status light
    L.append(line([(190, 320), (220, 318), (252, 330), (292, 372), (322, 396)], w=1.6, op=.8))
    L.append(line([(206, 330), (210, 420), (226, 540), (250, 618), (296, 640)], w=1.3, op=.6))
    L.append(line([(300, 556), (306, 620), (322, 652), (348, 662), (376, 650), (388, 610), (384, 556)], w=1.8))
    L.append('<path d="M352,590 L356,612" stroke="#3a9a4a" stroke-width="5" stroke-linecap="round" opacity=".85"/>')
    # forward / back buttons
    L.append(f'<g transform="rotate(-8 236 460)">{rrect_line(216, 404, 40, 112, 18)}</g>')
    L.append(f'<g transform="rotate(-12 264 568)">{rrect_line(242, 520, 42, 98, 18)}</g>')
    # thumb wheel: a knurled cylinder in two halves
    tw = '<g transform="rotate(-14 314 478)">'
    tw += f'<path d="{rrect(279, 402, 70, 152, 14)}" fill="{INK}" opacity=".10"/>'
    tw += rrect_line(279, 402, 70, 152, 14, wd=2.0)
    tw += f'<path d="M279,478 H349" stroke="{INK}" stroke-width="2" opacity=".8"/>'
    for k in range(26):
        y = 408 + k * 5.6
        if abs(y - 478) < 4: continue
        tw += f'<path d="M{284 + (y % 3):.1f},{y:.1f} H{344:.1f}" stroke="{INK}" stroke-width=".9" opacity=".5"/>'
    tw += f'<path d="M296,406 V550 M332,406 V550" stroke="#fff" stroke-width="5" opacity=".35"/></g>'
    L.append(tw)
    # front lip and the gesture button mark
    L.append(line([(6, 772), (90, 838), (230, 900), (380, 960), (476, 1002)], w=1.8, op=.8))
    L.append(line([(43, 596), (45, 616), (47, 636)], w=3.2))
    # faint ridges of the thumb rest
    for i, x in enumerate([40, 90, 140, 190]):
        L.append(line([(x + 20, 440 - i * 20), (x + 40, 600), (x + 75, 740), (x + 110, 850 + i * 25)], w=.9, op=.22, passes=1))

    return svg(636, 1024, "\n".join(S), "\n".join(L), C)

# ------------------------------------------------------------------ keyboard

def keyboard():
    S, L, C = [], [], ""
    S.append(f'<path d="M72,60 L72,30 Q74,6 104,6 L1278,6 Q1310,8 1310,60 Z" fill="{INK}" opacity=".35" filter="url(#grain)"/>')
    S.append(tone(rrect(4, 56, 1374, 556, 46), .07))
    L.append(line([(72, 60), (72, 30), (86, 12), (104, 6), (1278, 6), (1298, 12), (1310, 30), (1310, 60)], w=2.2))
    L.append(f'<path d="{rrect(4, 56, 1374, 556, 46)}" fill="none" stroke="{INK}" stroke-width="2.6" opacity=".9"/>')
    L.append(f'<path d="{rrect(14, 66, 1354, 536, 38)}" fill="none" stroke="{INK}" stroke-width="1" opacity=".35"/>')
    L.append(f'<path d="M1254,33 H1270" stroke="{INK}" stroke-width="4" stroke-linecap="round" opacity=".6"/>')

    keys = []
    def row(y, h, items, x=34, gap=11):
        for w, label, sub in items:
            keys.append((x, y, w, h, label, sub)); x += w + gap
    std = 77
    row(92, 52, [(std, "esc", ""), (std, "1 ▭", "F1"), (std, "2 ▭", "F2"), (std, "3 ▭", "F3"), (std, "☼ −", "F4"),
                 (std, "☼ +", "F5"), (std, "dict", "F6"), (std, "☺", "F7"), (std, "⬚", "F8"), (std, "mic ×", "F9"),
                 (std, "▶ ❙❙", "F10"), (std, "◁ ×", "F11"), (std, "◁ )", "F12"), (std, "◁ ))", "ins"), (std, "del", "")], gap=11.6)
    row(157, 76, [(std, "~ `", "")] + [(std, s, "") for s in "1 2 3 4 5 6 7 8 9 0 − =".split()] + [(165, "backspace", "")])
    row(245, 76, [(120, "tab", "")] + [(std, s, "") for s in "Q W E R T Y U I O P [ ]".split()] + [(120, "\\", "")])
    row(333, 76, [(143, "caps lock", "")] + [(std, s, "") for s in "A S D F G H J K L ; '".split()] + [(188, "enter", "")])
    row(421, 76, [(187, "shift", "")] + [(std, s, "") for s in "Z X C V B N M , . /".split()] + [(232, "shift", "")])
    row(509, 76, [(88, "ctrl", ""), (std, "fn", ""), (std, "opt", ""), (88, "cmd", ""), (478, "", ""), (88, "cmd", ""), (std, "opt", "")])
    keys += [(1087, 547, 77, 37, "◂", ""), (1176, 509, 77, 37, "▴", ""), (1176, 548, 77, 37, "▾", ""), (1264, 547, 86, 37, "▸", "")]

    for (x, y, w, h, label, sub) in keys:
        # the key cap: soft shadow at the bottom, a lighter top face
        S.append(f'<path d="{rrect(x, y + 4, w, h - 2, 9)}" fill="{INK}" opacity=".13" filter="url(#grain)"/>')
        L.append(rrect_line(x, y, w, h, 9, wd=1.7))
        L.append(f'<path d="{rrect(x + 5, y + 4, w - 10, h - 11, 7)}" fill="none" stroke="{INK}" stroke-width=".8" opacity=".25"/>')
        if label:
            size = (20 if len(label) <= 3 else 17) if h > 40 else 15
            L.append(f'<text x="{x + w / 2:.1f}" y="{y + h / 2 + (2 if sub else 7):.1f}" text-anchor="middle" '
                     f'font-family="\'Bradley Hand\', Noteworthy, cursive" font-size="{size}" fill="{INK}" opacity=".85">{label}</text>')
        if sub:
            L.append(f'<text x="{x + w - 7:.1f}" y="{y + h - 6:.1f}" text-anchor="end" font-family="\'Bradley Hand\', cursive" '
                     f'font-size="11" fill="{INK}" opacity=".6">{sub}</text>')
    return svg(1382, 616, "\n".join(S), "\n".join(L), C)

def main():
    global INK
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for suffix, ink in [("", "#232428"), ("-dark", "#e4e1da")]:
        INK = ink
        for model, draw in [("2b034", mouse), ("2b369", keyboard)]:
            random.seed(11)  # the same strokes in both appearances
            with tempfile.NamedTemporaryFile("w", suffix=".svg") as f:
                f.write(draw()); f.flush()
                path = os.path.join(out, f"{model}{suffix}.png")
                subprocess.run(["rsvg-convert", f.name, "-o", path], check=True)
                shrink(path)

def shrink(path):
    try:
        from PIL import Image
    except ImportError:
        print(f"{path}: no Pillow, left at full size")
        return
    image = Image.open(path).convert("RGBA")
    image.quantize(colors=64, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).save(path, optimize=True)

main()
