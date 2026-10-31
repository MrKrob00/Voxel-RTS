#!/usr/bin/env python3
"""The face of the unit (docs/unit-model.md): assets/units/face.png. The texture covers the front of the head as a box, x -0.34..0.34 (u 0..1)
and y 2.0..1.1 (v 0..1); everything outside the features is the colour of the skin (the rest of the body takes a pixel of it too).
Two tall dark eyes with a white glint in their upper third, a small thin mouth a little sad. Run: python3 art/facegen.py (needs Pillow)."""

import os
from PIL import Image, ImageDraw

SIZE = 256
SS = 4                                   # drawn 4 times larger and scaled down: smooth edges
SKIN = (0xFF, 0xC0, 0x00)
EYE = (0x2A, 0x2B, 0x40)
GLINT = (0xF8, 0xFA, 0xF9)
MOUTH = (0x6F, 0x38, 0x00)
X0, X1, Y0, Y1 = -0.34, 0.34, 2.0, 1.1  # the box of the face in the model


def px(x, y):
    return ((x - X0) / (X1 - X0) * SIZE * SS, (y - Y0) / (Y1 - Y0) * SIZE * SS)


def main():
    img = Image.new("RGB", (SIZE * SS, SIZE * SS), SKIN)
    d = ImageDraw.Draw(img)
    for sx in (-1, 1):
        cx, cy, w, h = sx * 0.13, 1.48, 0.07, 0.15          # an eye: a tall oval
        a, b = px(cx - w / 2, cy + h / 2), px(cx + w / 2, cy - h / 2)
        d.ellipse([a, b], fill=EYE)
        gw, gh = w * 0.45, h * 0.28                         # its glint, in the upper third
        a, b = px(cx - gw / 2, cy + h * 0.38), px(cx + gw / 2, cy + h * 0.38 - gh)
        d.ellipse([a, b], fill=GLINT)
    # the mouth: a thin arc, the ends down (a little sad), 0.08 wide at y 1.27
    a, b = px(-0.04, 1.27 + 0.01), px(0.04, 1.27 - 0.05)
    d.arc([a, b], 200, 340, fill=MOUTH, width=int(0.011 / (Y0 - Y1) * SIZE * SS))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "units", "face.png")
    img.resize((SIZE, SIZE), Image.LANCZOS).save(out)
    print("face.png", SIZE)


if __name__ == "__main__":
    main()
