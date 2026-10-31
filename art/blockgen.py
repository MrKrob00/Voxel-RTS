#!/usr/bin/env python3
"""Generates the building blocks of the "Blocks" panel: one low-poly mesh each (assets/blocks/<id>.obj).

Every piece of a block is the convex hull of a short list of points (boxes and cylinders with chamfered edges, wedges, pyramids,
extruded profiles); a block is a few such pieces (steps of a stair, the flanks of a plug...). The meshes have flat normals on the
faces and smoothed ones round the curved parts.

Space of a block: x along its length (a 2-cell block is x -1..1, a 1-cell block x -0.5..0.5), y up (-0.5..0.5), z across (-0.5..0.5).
The game turns it about y. Run:  python3 art/blockgen.py   (then godot --import, then tools/bake_block_icons.gd for the icons).
No dependencies beyond the standard library.
"""

import itertools
import math
import os

OUT = os.environ.get("BLOCKGEN_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "blocks")
EPS = 1e-5
BEVEL = 0.035
MERGING = bool(os.environ.get("BLOCKGEN_MERGE"))   # BLOCKGEN_MERGE=stone|cren: make that set of blocks one mesh each; one-mesh blocks: no chamfers on the boxes, so no grooves where pieces meet
SMOOTH_DEG = 40.0


# ---- convex hull of a small point set --------------------------------------------------------------------------------------

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def norm(a):
    l = math.sqrt(dot(a, a))
    return (a[0] / l, a[1] / l, a[2] / l) if l > 0 else a


def hull(points):
    """Faces of the convex hull: a list of (normal, [points CCW seen from outside])."""
    pts = []
    for p in points:
        q = (round(p[0], 5), round(p[1], 5), round(p[2], 5))
        if q not in pts:
            pts.append(q)
    seen = set()
    faces = []
    n = len(pts)
    for i, j, k in itertools.combinations(range(n), 3):
        nn = cross(sub(pts[j], pts[i]), sub(pts[k], pts[i]))
        if dot(nn, nn) < 1e-12:
            continue
        nn = norm(nn)
        d = dot(nn, pts[i])
        side = [dot(nn, p) - d for p in pts]
        if all(s <= EPS for s in side):
            pass
        elif all(s >= -EPS for s in side):
            nn = (-nn[0], -nn[1], -nn[2])
            d = -d
        else:
            continue
        on = tuple(m for m in range(n) if abs(dot(nn, pts[m]) - d) < EPS)
        if on in seen:
            continue
        seen.add(on)
        poly = [pts[m] for m in on]
        c = (sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly), sum(p[2] for p in poly) / len(poly))
        u = norm(sub(poly[0], c)) if dot(sub(poly[0], c), sub(poly[0], c)) > 0 else (1, 0, 0)
        v = cross(nn, u)
        poly.sort(key=lambda p: math.atan2(dot(sub(p, c), v), dot(sub(p, c), u)))
        faces.append((nn, poly))
    return faces


# ---- pieces ----------------------------------------------------------------------------------------------------------------

def box(cx, cy, cz, sx, sy, sz, b=BEVEL):
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    b = 0.0 if MERGING else min(b, hx * 0.9, hy * 0.9, hz * 0.9)
    pts = []
    for x in (-1, 1):
        for y in (-1, 1):
            for z in (-1, 1):
                pts += [(cx + x * hx, cy + y * (hy - b), cz + z * (hz - b)),
                        (cx + x * (hx - b), cy + y * hy, cz + z * (hz - b)),
                        (cx + x * (hx - b), cy + y * (hy - b), cz + z * hz)]
    return pts


def ring(cy, r, seg, axis, c):
    out = []
    for i in range(seg):
        a = math.tau * i / seg
        u, w = math.cos(a) * r, math.sin(a) * r
        out.append(((c[0] + cy, c[1] + u, c[2] + w) if axis == "x" else (c[0] + u, c[1] + cy, c[2] + w)))
    return out


def cyl(cx, cy, cz, r0, r1, h, axis="y", seg=16, b=0.02):
    """A cylinder or frustum (r0 at the low end, r1 at the high end) along y (or x), edges chamfered by b."""
    c = (cx, cy, cz)
    lo, hi = -h / 2, h / 2
    return (ring(lo, max(r0 - b, 0.01), seg, axis, c) + ring(lo + b, r0, seg, axis, c)
            + ring(hi - b, r1, seg, axis, c) + ring(hi, max(r1 - b, 0.01), seg, axis, c))


def prism(profile, x0, x1, b=0.0):
    """A profile in (y, z) pushed along x from x0 to x1."""
    pts = []
    for (y, z) in profile:
        pts.append((x0, y, z))
        pts.append((x1, y, z))
    return pts


def plan(profile, y0, y1):
    """A profile in (x, z) pushed along y from y0 to y1."""
    pts = []
    for (x, z) in profile:
        pts.append((x, y0, z))
        pts.append((x, y1, z))
    return pts


def pts_of(*rows):
    return [tuple(r) for r in rows]


def solid(pieces, cuts=()):
    """One mesh from axis-aligned boxes: their union, with no faces inside it. `pieces` are box() point lists. Returns a ("tris", ...)
    piece that mesh_of passes through as it is: faces between neighbouring boxes disappear and coplanar neighbours merge."""
    def bounds(pts):
        xs, ys, zs = [p[0] for p in pts], [p[1] for p in pts], [p[2] for p in pts]
        return (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs))
    boxes = [bounds(pts) for pts in pieces]
    holes = [bounds(pts) for pts in cuts]
    cuts = [sorted({round(v, 5) for b in boxes + holes for v in (b[2 * a], b[2 * a + 1])}) for a in range(3)]
    n = [len(c) - 1 for c in cuts]
    full = {}
    for i in range(n[0]):
        for j in range(n[1]):
            for k in range(n[2]):
                mid = ((cuts[0][i] + cuts[0][i + 1]) / 2, (cuts[1][j] + cuts[1][j + 1]) / 2, (cuts[2][k] + cuts[2][k + 1]) / 2)
                full[(i, j, k)] = any(b[0] < mid[0] < b[1] and b[2] < mid[1] < b[3] and b[4] < mid[2] < b[5] for b in boxes) \
                    and not any(b[0] < mid[0] < b[1] and b[2] < mid[1] < b[3] and b[4] < mid[2] < b[5] for b in holes)
    def filled(c): return full.get(c, False)
    quads = []
    for axis in range(3):
        u, v = [a for a in range(3) if a != axis]
        for sign in (1, -1):
            for layer in range(n[axis]):
                cells = {}
                for a in range(n[u]):
                    for b in range(n[v]):
                        c = [0, 0, 0]
                        c[axis], c[u], c[v] = layer, a, b
                        o = list(c)
                        o[axis] += sign
                        if filled(tuple(c)) and not filled(tuple(o)):
                            cells[(a, b)] = True
                while cells:   # greedy rectangles of the free faces
                    a0, b0 = min(cells)
                    a1 = a0
                    while (a1 + 1, b0) in cells:
                        a1 += 1
                    b1 = b0
                    while all((a, b1 + 1) in cells for a in range(a0, a1 + 1)):
                        b1 += 1
                    for a in range(a0, a1 + 1):
                        for b in range(b0, b1 + 1):
                            del cells[(a, b)]
                    face = cuts[axis][layer + 1] if sign == 1 else cuts[axis][layer]
                    pts = []
                    for (ua, vb) in ((a0, b0), (a1 + 1, b0), (a1 + 1, b1 + 1), (a0, b1 + 1)):
                        q = [0.0, 0.0, 0.0]
                        q[axis], q[u], q[v] = face, cuts[u][ua], cuts[v][vb]
                        pts.append(tuple(q))
                    nrm = [0.0, 0.0, 0.0]
                    nrm[axis] = float(sign)
                    if dot(cross(sub(pts[1], pts[0]), sub(pts[2], pts[0])), tuple(nrm)) < 0:
                        pts.reverse()
                    quads.append((tuple(nrm), pts))
    return ("tris", quads)


def merge(pieces):
    """One mesh from convex pieces: their union (needs `pip install manifold3d`). The faces where pieces meet and the faces inside the
    block disappear; what is left is one closed surface. Returns a ("tris", ...) piece that mesh_of passes through."""
    import numpy as np
    import manifold3d as m3d
    def solid_of(piece):
        if isinstance(piece, tuple) and piece[0] == "clip":   # ("clip", points, [mask pieces]): the piece cut to the union of the masks
            masks = m3d.Manifold.batch_boolean([m3d.Manifold.hull_points(np.array(m, dtype=np.float64)) for m in piece[2]], m3d.OpType.Add)
            return m3d.Manifold.hull_points(np.array(piece[1], dtype=np.float64)) ^ masks
        return m3d.Manifold.hull_points(np.array(piece, dtype=np.float64))
    cuts = [solid_of(piece[1]) for piece in pieces if isinstance(piece, tuple) and piece[0] == "cut"]   # ("cut", points): taken away from the union
    late = [solid_of(piece[1]) for piece in pieces if isinstance(piece, tuple) and piece[0] == "late"]   # ("late", points): added after the cuts
    parts = [solid_of(piece) for piece in pieces if not (isinstance(piece, tuple) and piece[0] in ("cut", "late"))]
    union = m3d.Manifold.batch_boolean(parts, m3d.OpType.Add)
    if cuts:
        union = union - m3d.Manifold.batch_boolean(cuts, m3d.OpType.Add)
    if late:
        union = union + m3d.Manifold.batch_boolean(late, m3d.OpType.Add)
    mesh = union.to_mesh()
    vp, tv = mesh.vert_properties, mesh.tri_verts
    out = []
    for a, b, c in tv:
        pa, pb, pc = [tuple(round(float(v), 5) for v in vp[i][:3]) for i in (a, b, c)]
        nn = cross(sub(pb, pa), sub(pc, pa))
        if dot(nn, nn) < 1e-12:
            continue
        out.append((norm(nn), [pa, pb, pc]))
    return ("tris", out)


# ---- the blocks ------------------------------------------------------------------------------------------------------------

def stairs(length, steps, start=None):
    """Steps rising towards +x over `length`, the low end at x = start (default: the block's low end)."""
    out = []
    w = length / steps
    x0 = -length / 2 if start is None else start
    for i in range(steps):
        top = -0.5 + (i + 1) / steps
        out.append(box(x0 + w * (i + 0.5), (top - 0.5) / 2, 0, w, top + 0.5, 1, 0.015))
    return out


def moved(pieces, dx=0.0, mirror_x=False):
    """The pieces shifted along x (after mirroring x, if asked)."""
    return [[((-x if mirror_x else x) + dx, y, z) for (x, y, z) in piece] for piece in pieces]


def corner_cell(steps=4):
    """A one-cell corner stair (outer corner): L-shaped layers that shrink towards the (+x, -z) corner, so steps go down on the -x
    and +z sides."""
    out = []
    h = 1.0 / steps
    for k in range(steps):
        cut = k / steps
        sx = 1.0 - cut
        out.append(box(0.5 - sx / 2, -0.5 + h * (k + 0.5), -0.5 + sx / 2, sx, h, sx, 0.015))
    return out


def corner_cell_in(steps=4):
    """A one-cell inner corner stair: two stair runs meeting at a right angle, lowest in the (-x, +z) corner. Each layer is the cell
    without a square notch in that corner; the notch grows with the layer."""
    out = []
    h = 1.0 / steps
    for k in range(steps):
        cut = k / steps
        y = -0.5 + h * (k + 0.5)
        if cut <= 0.001:
            out.append(box(0, y, 0, 1.0, h, 1.0, 0.015))
        else:
            out.append(box(0.5 - (1.0 - cut) / 2, y, 0, 1.0 - cut, h, 1.0, 0.015))                  # beyond the notch in x
            out.append(box(-0.5 + cut / 2, y, -0.5 + (1.0 - cut) / 2, cut, h, 1.0 - cut, 0.015))    # the strip before it, away from the corner in z
    return out


def fan_cell(steps=4):
    """A one-cell winding stair: wedge-shaped treads fanning round the (+x, +z) corner (the corner where the cell meets the cube, at
    the front): the lowest along the front wall, the highest along the cube."""
    out = []
    px, pz = 0.5, 0.5
    def edge(theta):
        c, s_ = math.cos(theta), math.sin(theta)
        t = min(1.0 / c if c > 1e-6 else 1e9, 1.0 / s_ if s_ > 1e-6 else 1e9)
        return (px - c * t, pz - s_ * t)
    for k in range(steps):
        a0 = math.pi / 2 * k / steps
        a1 = math.pi / 2 * (k + 1) / steps
        pts = [(px, pz), edge(a0), edge(a1)]
        if a0 < math.pi / 4 < a1:
            pts.append((-0.5, -0.5))
        top = -0.5 + (k + 1) / steps
        out.append(plan(pts, -0.5, top))
    return out


def with_cube(cell, right):
    """A 2 x 1 x 1 block: a one-cell piece and a cube. `right`: the piece is the right-hand cell (and mirrored)."""
    cube = [box(0.5 if not right else -0.5, 0, 0, 1.0, 1.0, 1.0)]
    return moved(cell, -0.5 if not right else 0.5, mirror_x=right) + cube


def tower(base_h, flare_h, r_low, r_top, top_h, lip=0.0):
    out = [box(0, -0.5 + base_h / 2, 0, 1.0, base_h, 1.0, 0.04)]
    y = -0.5 + base_h
    out.append(cyl(0, y + flare_h / 2, 0, r_low, r_top, flare_h))
    y += flare_h
    out.append(cyl(0, y + top_h / 2, 0, r_top, r_top, top_h))
    if lip > 0:
        out.append(cyl(0, y + top_h - 0.04, 0, r_top + lip, r_top + lip, 0.08))
    return out


def column():
    return [box(0, -0.42, 0, 1.0, 0.16, 1.0, 0.04), cyl(0, -0.29, 0, 0.4, 0.4, 0.1), cyl(0, 0.03, 0, 0.3, 0.3, 0.54, b=0.01),
            cyl(0, 0.38, 0, 0.36, 0.36, 0.12)]


def plug_slab(slots, y0, y1, half, d, w, core_scale=1.0):
    """One layer of a plug: a square of side 2*half with U-shaped channels (width w, depth d from the edge) in the given sides. The
    core in the middle is `core_scale` times the size the channels leave; a bigger core makes the channels shorter, the columns beside
    them keep their size."""
    yc, hy = (y0 + y1) / 2, y1 - y0
    core = 2 * (half - d) * core_scale
    out = [box(0, yc, 0, core, hy, core, 0.0)]    # the core
    def band_z(sign, slotted):
        zc = sign * (half - d / 2)
        if not slotted:
            out.append(box(0, yc, zc, 2 * half, hy, d, 0.0))
        else:
            fw = (2 * half - w) / 2
            out.append(box(-(w / 2 + fw / 2), yc, zc, fw, hy, d, 0.0))
            out.append(box((w / 2 + fw / 2), yc, zc, fw, hy, d, 0.0))
    def band_x(sign, slotted):
        xc = sign * (half - d / 2)
        span = 2 * half - 2 * d
        if not slotted:
            out.append(box(xc, yc, 0, d, hy, span, 0.0))
        else:
            fw = (span - w) / 2
            out.append(box(xc, yc, -(w / 2 + fw / 2), d, hy, fw, 0.0))
            out.append(box(xc, yc, (w / 2 + fw / 2), d, hy, fw, 0.0))
    band_z(1, "F" in slots)
    band_z(-1, "B" in slots)
    band_x(-1, "L" in slots)
    band_x(1, "R" in slots)
    return out


def plug(slots):
    """A plain platform below (15% of the height) and above it a cube with U-shaped channels from the sides reaching nearly to the
    middle: F +z, B -z, L -x, R +x. The core in the middle is 2.25 times what the channels leave, so the channels are short. Below the
    top layer (5% of the height, left whole) every channel has a recess 0.18 deep into the core. One mesh."""
    w, core = 0.34, 2 * (0.5 - 0.34) * 2.25
    reach, floor, top = core / 2, -0.35, 0.45
    holes = []
    for side, (ax, sign) in {"F": (2, 1), "B": (2, -1), "L": (0, -1), "R": (0, 1)}.items():
        if side not in slots:
            continue
        lo, hi = sorted((sign * (reach - 0.18), sign * (reach + 0.01)))
        if ax == 2:
            holes.append(box(0, (floor + top) / 2, (lo + hi) / 2, w, top - floor, hi - lo, 0.0))
        else:
            holes.append(box((lo + hi) / 2, (floor + top) / 2, 0, hi - lo, top - floor, w, 0.0))
    return [solid([box(0, -0.425, 0, 1.0, 0.15, 1.0, 0.0)] + plug_slab(slots, -0.35, 0.5, 0.5, 0.34, 0.34, 2.25), holes)]


def quarter(cx, cz, sx, sz, r=1.0, seg=12):
    """Plan points of a quarter disc of radius r centred on the corner (cx, cz), bulging away from it towards (sx, sz)."""
    pts = [(cx, cz)]
    for i in range(0, seg + 1):
        a = math.pi / 2 * i / seg
        pts.append((cx + sx * math.cos(a) * r, cz + sz * math.sin(a) * r))
    return pts


def round_brick(kind):
    """The round bricks are built of a rounded corner (a quarter disc, one cell) and a cube.
    a: rounded corner + cube; b: cube + rounded corner; c: two rounded corners; d: one rounded corner."""
    if kind == "a":     # left cell rounded (bulging towards -x, +z), right cell a cube
        pts = quarter(0.0, -0.5, -1.0, 1.0) + [(1.0, -0.5), (1.0, 0.5)]
    elif kind == "b":
        pts = quarter(0.0, -0.5, 1.0, 1.0) + [(-1.0, -0.5), (-1.0, 0.5)]
    elif kind == "c":   # both: a half disc 2 wide
        pts = quarter(0.0, -0.5, -1.0, 1.0) + quarter(0.0, -0.5, 1.0, 1.0)
    else:               # d: one cell
        pts = quarter(0.5, -0.5, -1.0, 1.0)
    return [plan(pts, -0.5, 0.5)]


def squircle(y, half, seg=20, n=4.0):
    pts = []
    for i in range(seg):
        a = math.tau * i / seg
        c, s_ = math.cos(a), math.sin(a)
        pts.append((half * math.copysign(abs(c) ** (2 / n), c), y, half * math.copysign(abs(s_) ** (2 / n), s_)))
    return pts


def tower_square(base_h, flare_h, half_low, half_top, top_h):
    """The same as `tower`, but square: a plate, a flare from a wide square to a narrower one, a square top."""
    y0 = -0.5 + base_h
    flare = [(sx * half_low, y0, sz * half_low) for sx in (-1, 1) for sz in (-1, 1)] \
        + [(sx * half_top, y0 + flare_h, sz * half_top) for sx in (-1, 1) for sz in (-1, 1)]
    return [box(0, -0.5 + base_h / 2, 0, 1.0, base_h, 1.0, 0.04), flare,
            box(0, y0 + flare_h + top_h / 2, 0, half_top * 2, top_h, half_top * 2, 0.03)]


def squat():
    return [box(0, -0.43, 0, 1.0, 0.14, 1.0, 0.03), squircle(-0.36, 0.5) + squircle(0.28, 0.4) + squircle(0.24, 0.43)]


def cren_slab():
    """The overhang (2 cells along x): a whole cube at -x and, in front of it (+x), a flat platform 22.5% of a block thick along the top.
    Under the platform a slope runs from its underside at half the platform's length back down to the cube's face at 30% of the
    height from the bottom. Slope and platform have the width of the cube."""
    cube = box(-0.5, 0, 0, 1.0, 1.0, 1.0, 0.0)
    platform = box(0.5, 0.3875, 0, 1.0, 0.225, 1.0, 0.0)
    brace = [(x, y, z) for (x, y) in ((0.0, 0.275), (0.5, 0.275), (0.0, -0.2)) for z in (-0.5, 0.5)]
    return [cube, platform, brace]


def cren_bracket():
    """A bracket, the whole block 30% as wide as a cell: a flat platform on top (15% of the height), a back platform (35% of the length),
    and between them, in the free zone, half an arch whose front is a quarter ellipse from the foot of the back platform up to the front
    of the top platform (two of these mirrored make a whole arch)."""
    top = box(0, 0.425, 0, 1.0, 0.15, 0.30, 0.0)
    back = box(-0.325, 0, 0, 0.35, 1.0, 0.30, 0.0)
    wall, cx, cy, ra, rb, n = -0.15, 0.5, -0.5, 0.65, 0.85, 10
    arc = [(cx - ra * math.cos(math.pi / 2 * i / n), cy + rb * math.sin(math.pi / 2 * i / n)) for i in range(n + 1)]
    rib = []
    for (x0, y0), (x1, y1) in zip(arc, arc[1:]):
        rib.append([(x, y, z) for (x, y) in ((wall, y0), (x0, y0), (x1, y1), (wall, y1)) for z in (-0.15, 0.15)])
    return [top, back] + rib


def cren_corner():
    """The corner bracket is, for now, the same as the bracket."""
    return cren_bracket()


ROOF_BASE_TOP = -0.05    # the whole lower part of a roof block is 45% high
ROOF_SETBACK = 0.15      # and set back this much at the front
ROOF_NOSE = 0.13         # radius of the rounded edge that juts out over the set-back


def roof_nose(extent):
    """Points (front, y) of the rounded edge of the slope: a circle touching the front (at `extent`) and the underside of the slope."""
    r = ROOF_NOSE
    c = (extent - r, ROOF_BASE_TOP + r)
    return [(c[0] + r * math.cos(math.tau * i / 20), c[1] + r * math.sin(math.tau * i / 20)) for i in range(20)]


def cren_roof(length=1.0):
    """The roof block, front towards +z, `length` cells along x: the lower 45% is whole and set back 15% at the front; above it a slope (a
    right triangle with the right angle at the back; the long side climbs from the front to the top of the back wall) whose front edge
    juts out over the set-back with a rounded nose, and the back is the whole block again."""
    lower = box(0, -0.275, (-0.5 + 0.5 - ROOF_SETBACK) / 2 - 0.0, length, 0.45, 1.0 - ROOF_SETBACK, 0.0)
    pts = [(-0.5, ROOF_BASE_TOP), (-0.5, 0.5)] + roof_nose(0.5)
    upper = [(x, y, z) for (z, y) in pts for x in (-length / 2, length / 2)]
    return [lower, upper]


def cren_roof_corner():
    """The diagonal roof block that joins two roofs at a corner: the lower 45% is whole and set back 15% on both front sides (+z and
    +x); above it two sloped triangles, one facing +z and one facing +x, climb to one point at the back left, the top corner
    (-x, -z); their edges jut out with the same rounded nose."""
    lower = box((-0.5 + 0.5 - ROOF_SETBACK) / 2, -0.275, (-0.5 + 0.5 - ROOF_SETBACK) / 2, 1.0 - ROOF_SETBACK, 0.45, 1.0 - ROOF_SETBACK, 0.0)
    pts = [(-0.5, 0.5, -0.5), (-0.5, ROOF_BASE_TOP, -0.5), (-0.5, ROOF_BASE_TOP, 0.5), (0.5, ROOF_BASE_TOP, -0.5)]
    for (f, y) in roof_nose(0.5):
        for k in (-0.5, 0.5):
            pts.append((k, y, f))   # the +z edge: the nose across the whole width
            pts.append((f, y, k))   # the +x edge
    return [lower, pts]


def cren_roof_inner():
    """The concave (inner) corner of two roofs: a whole lower part (45% high, the full cell) and on it two slopes, one facing +z and one
    facing +x, that meet in a valley falling to the front right corner; the back walls along -x and -z stand whole."""
    lower = box(0, -0.275, 0, 1.0, 0.45, 1.0, 0.0)
    pts = [(-0.5, ROOF_BASE_TOP), (-0.5, 0.5), (0.5, ROOF_BASE_TOP)]
    slope_z = [(x, y, z) for (z, y) in pts for x in (-0.5, 0.5)]
    slope_x = [(z, y, x) for (x, y, z) in slope_z]
    return [lower, slope_z, slope_x]


def corbel_slab(scale, facets=0):
    """A corbel of 2 cells along x: a whole cube at -x; in front of it a flat platform 22% of a block thick along the top; under the
    platform, from the cube to its end, a block 30% as wide as the cell. Two straight slopes join that block to the rest:
      - from the side edges of the platform, down the narrow block (scale 1: half its straight part; scale 2: all of it);
      - from the side edges of the cube's face, along the narrow block (scale 1: 10% of a block; scale 2: 20%).
    At the corner where the two meet a wedge closes the gap, so the slopes join as one.
    `facets`: each slope is made of that many flat steps bulging outwards (a slope on a slope), which reads as a rounded one."""
    cube = box(-0.5, 0, 0, 1.0, 1.0, 1.0, 0.0)
    platform = box(0.5, 0.39, 0, 1.0, 0.22, 1.0, 0.0)
    w, under = 0.15, 0.28                          # half the width of the narrow block, the underside of the platform
    rise = 0.1 * scale                             # the slope at the cube
    low = max(-0.5, under - 0.5 * scale * (under + 0.5))   # how far down the platform's slope reaches
    out = [cube, platform, box(0.5, (-0.5 + under) / 2, 0, 1.0, under + 0.5, 2 * w, 0.0)]
    for side in (-1, 1):
        if facets:
            k = facets
            arc = [(w + (0.5 - w) * math.cos(math.pi / 2 * i / k), under - (under - low) * math.sin(math.pi / 2 * i / k)) for i in range(k + 1)]   # (z, y)
            for (z0, y0), (z1, y1) in zip(arc, arc[1:]):
                out.append([(x, y, side * z) for x in (0.0, 1.0) for (y, z) in ((y0, w), (y0, z0), (y1, z1), (y1, w))])
            arc = [(rise * math.sin(math.pi / 2 * i / k), w + (0.5 - w) * math.cos(math.pi / 2 * i / k)) for i in range(k + 1)]   # (x, z)
            for (x0, z0), (x1, z1) in zip(arc, arc[1:]):
                out.append([(x, y, side * z) for y in (-0.5, under) for (x, z) in ((x0, w), (x0, z0), (x1, z1), (x1, w))])
        else:
            out.append([(x, y, side * z) for x in (0.0, 1.0) for (y, z) in ((under, w), (under, 0.5), (low, w))])
            out.append([(x, y, side * z) for y in (-0.5, under) for (x, z) in ((0.0, w), (0.0, 0.5), (rise, w))])
        if scale > 1:
            out.append([(0.0, under, side * 0.5), (0.0, under, side * w), (0.0, low, side * w), (rise, under, side * w)])
    return out


def cren_slope(length=1.0, half=False):
    hl = length / 2
    lower = box(0, -0.25, 0, length, 0.5, 1.0, 0.03)
    roof = pts_of((-hl, 0.0, 0.5), (hl, 0.0, 0.5), (-hl, 0.5, 0.5), (hl, 0.5, 0.5), (-hl, 0.08, -0.5), (hl, 0.08, -0.5), (-hl, 0.0, -0.5), (hl, 0.0, -0.5))
    if half:
        # A triangular prism on the low block: the vertical wall on the +x side, the slope falling away towards -x.
        roof = pts_of((-hl, 0.0, -0.5), (hl, 0.0, -0.5), (hl, 0.5, -0.5), (-hl, 0.0, 0.5), (hl, 0.0, 0.5), (hl, 0.5, 0.5))
    return [lower, roof]


def cren_hip():
    return [box(0, -0.25, 0, 1.0, 0.5, 1.0, 0.03),
            pts_of((-0.5, 0.0, -0.5), (0.5, 0.0, -0.5), (0.5, 0.0, 0.5), (-0.5, 0.0, 0.5), (0.0, 0.5, 0.0))]


def cren_corbel(length=2.0, shift=0.0):
    """The small corbel, 2 cells along x: a whole cube at the back (-x) and, in front of it, a flat platform 22% thick along the top.
    A little lower goes a vertical plate 30% as wide as the cell. It keeps a strip 22% high along the top (the crown of the arch) and
    at the bottom, from the cube's face, a length of 22%; the rest of it is cut away as an arch, a quarter ellipse (as in the bracket)
    from the floor at the end of that foot up to the front of the crown."""
    plate_w, foot, crown = 0.15, 0.22, 0.22
    top_low = 0.28                                   # the underside of the platform
    arch_top = top_low - crown                       # the underside of the crown
    cube = box(-0.5, 0, 0, 1.0, 1.0, 1.0, 0.0)
    platform = box(0.5, 0.39, 0, 1.0, 0.22, 1.0, 0.0)
    strip = box(0.5, (arch_top + top_low) / 2, 0, 1.0, crown, 2 * plate_w, 0.0)
    cx, cy, ra, rb, n = 1.0, -0.5, 1.0 - foot, arch_top + 0.5, 12
    arc = [(cx - ra * math.cos(math.pi / 2 * i / n), cy + rb * math.sin(math.pi / 2 * i / n)) for i in range(n + 1)]
    rib = []
    mask = [[(x, y, z) for (x, y) in ((0.0, arch_top), (1.0, arch_top), (1.0, top_low), (0.0, top_low)) for z in (-0.6, 0.6)]]   # the plate's side view
    for (x0, y0), (x1, y1) in zip(arc, arc[1:]):
        rib.append([(x, y, z) for (x, y) in ((0.0, y0), (x0, y0), (x1, y1), (0.0, y1)) for z in (-plate_w, plate_w)])
        mask.append([(x, y, z) for (x, y) in ((0.0, y0), (x0, y0), (x1, y1), (0.0, y1)) for z in (-0.6, 0.6)])
    out = [cube, platform, strip] + rib
    # The slopes of the big corbel where the plate meets the platform and the cube: from the side edges of the platform half way down the
    # plate (cut to the arch), and 10% of a block along the plate from the side edges of the cube's face.
    low = top_low - 0.5 * (top_low + 0.5)
    for side in (-1, 1):
        slope = [(x, y, side * z) for x in (0.0, 1.0) for (y, z) in ((top_low, plate_w), (top_low, plate_w + 0.15), (low, plate_w))]
        out.append(("clip", slope, mask))   # the slope follows the arch: it is only where the plate is
        out.append([(x, y, side * z) for y in (-0.5, top_low) for (x, z) in ((0.0, plate_w), (0.0, 0.5), (0.1, plate_w))])
    return out


def wood_log():
    return [cyl(0, 0, 0, 0.4, 0.4, 2.0, axis="x", seg=14, b=0.03)]


def wood_beam():
    return [box(0, -0.2, 0, 2.0, 0.3, 0.4, 0.03)]


def wood_post():
    return [box(0, 0, 0, 0.4, 1.0, 0.4, 0.03)]


def wood_brace():
    p = [(-0.5, -0.5), (-0.15, -0.5), (0.5, 0.5), (0.15, 0.5)]
    return [[(x, y, z) for (x, y) in p for z in (-0.12, 0.12)]]


def board(length, width):
    return [box(0, -0.44, 0, length, 0.12, width, 0.02)]


ROUND_STONE = ["tower_a", "tower_b", "tower_squat", "column"]   # the stone blocks with curved parts: only these get smoothed normals
CREN_BLOCKS = ["cren_slab", "cren_bracket", "cren_corner", "cren_slope", "cren_slope_corner", "cren_slope_long", "cren_hip", "cren_corbel_long",
               "cren_corbel", "cren_corbel_small"]
MERGE_SETS = {"stone": None, "cren": CREN_BLOCKS}


# ---- the structures (assets/structures/<id>.obj): bigger than a block, in their own frame: x along the length, y up, z across, all from 0 ----

def frustum(cx, cz, y0, y1, w0, w1):
    h0, h1 = w0 / 2, w1 / 2
    return [(cx + sx * h0, y0, cz + sz * h0) for sx in (-1, 1) for sz in (-1, 1)] + [(cx + sx * h1, y1, cz + sz * h1) for sx in (-1, 1) for sz in (-1, 1)]


FURNACE_WIDTHS = [(0.43, 1.72), (0.93, 1.72), (1.43, 1.34), (1.82, 1.07), (2.2, 0.92), (2.43, 0.92)]   # the width of the clay body at a height: a little under 2, straight up to one block with the plinth, then a concave bell (like a cooling tower) with a flat top, a ledge round the chimney


def furnace_width(y):
    for (y0, w0), (y1, w1) in zip(FURNACE_WIDTHS, FURNACE_WIDTHS[1:]):
        if y <= y1:
            return w0 + (w1 - w0) * (y - y0) / (y1 - y0)
    return FURNACE_WIDTHS[-1][1]


def arch_profile(y0, width, rect_h, steps=8, rise=None):
    """The outline of an arched opening in (y, across): a rectangle with a half circle on top (or a flatter arc of height `rise`)."""
    r = width / 2
    rise = r if rise is None else rise
    out = [(y0, -r), (y0, r), (y0 + rect_h, -r), (y0 + rect_h, r)]
    for i in range(steps + 1):
        a = math.pi * i / steps
        out.append((y0 + rect_h + rise * math.sin(a), r * math.cos(a)))
    return out


def arch_piece(face, centre, profile, inner_of_y, outer_of_y):
    """The profile pushed along the face's axis from `inner_of_y(y)` to `outer_of_y(y)`: 'x' faces look +x, 'z' faces look -z."""
    pts = []
    for (y, t) in profile:
        for d in (inner_of_y(y), outer_of_y(y)):
            pts.append((d, y, centre + t) if face == "x" else (centre + t, y, d))
    return pts


def furnace():
    """The furnace: 3 x 2 blocks, 3 high, ONE mesh (x 0..3 with the front towards +x, y 0..3, z 0..2). A grey platform under the body (smaller than 2 x 2,
    straight sides), a flat stone slab in front of it (the tray with the ingots), the clay body straight up to a block and then a bell narrowing to a
    small square chimney with a square hole; two arched mouths with a ring of stones: the front one over a clay tongue ending in a V, the left one over
    a stone step (the second tray). Everything stays inside 3 x 2."""
    cx, cz = 1.01, 1.04
    top = 0.43
    # The whole furnace stays inside 3 x 2. The platform under the body is smaller than 2 x 2 (1.9 x 1.8, straight sides, no taper) so that the
    # two trays stand out of it and still do not leave the volume: the flat stone slab in front (towards the tray side, +x) and the step at the
    # left mouth (-z). The body stands a hair inside the platform.
    pieces = [box(cx, top / 2, cz, 1.72, top, 1.72)]       # flush with the foot of the body (no ledge round it)
    pieces.append(box(cx, top / 2, 0.22, 1.24, top, 0.16))                      # the left tray: the platform juts out 0.04 under the left mouth (the width of its arch)
    pieces.append(box(2.39, 0.155, 1.0, 1.04, 0.31, 1.72))                      # the base under the tray: smaller than the slab on top of it
    pieces.append(box(2.435, 0.37, 1.0, 1.13, 0.12, 1.9))                         # the tray slab, level with the platform, wider than its base: it juts out to the left, right and front
    for (y0, w0), (y1, w1) in zip(FURNACE_WIDTHS, FURNACE_WIDTHS[1:]):     # the body: straight, a concave narrowing, a short vertical collar
        pieces.append(frustum(cx, cz, y0, y1, w0, w1))
    # the chimney: a square tube, a hair narrower at the bottom than at the top, with a square hole
    pieces.append(frustum(cx, cz, 2.43, 2.78, 0.65, 0.70))
    pieces.append(("cut", box(cx, 2.7, cz, 0.27, 0.2, 0.27, 0.0)))
    # the mouths: the same height, the same arch ring (0.2 thick). The walls go straight up from the platform; where the body begins to narrow
    # (y 0.93) the arches begin: the openings are straight-sided up to there and then arched; the arches go straight up (a vertical outer plane)
    # and are rooted deep in the body. The front one (to the tray) is a round arch over a low wall with a V notch, the left one a flat arch over a
    # stone step.
    face = 0.86
    niche = 0.25
    spring = 0.93 - top                     # the straight part of the openings, from the platform
    ring_front = arch_profile(0.93, 1.0, 0.0, rise=0.4)    # only the ARCH is a ring of stones: it begins where the straight walls end, not at the platform
    ring_left = arch_profile(0.93, 1.24, 0.0, rise=0.4)
    front_hole = arch_profile(top, 0.6, spring, rise=0.22)
    left_hole = arch_profile(top, 0.84, spring, rise=0.22)
    pieces.append(arch_piece("x", cz, ring_front, lambda y: cx + 0.4, lambda y: cx + face))
    pieces.append(arch_piece("z", cx, ring_left, lambda y: cz - 0.4, lambda y: cz - face))
    # the front mouth, from the left across the bottom of the opening (the designer's sketch): the wall "-", the arch "(", a low wall "_", an EMPTY
    # V-shaped notch "v" (through it the ingots are poured out onto the tray), a low wall "_", the arch ")", the wall "-"
    sill = 0.2
    for side in (-1, 1):
        wall = []
        for xx in (cx + 0.5, cx + 0.88):
            wall += [(xx, top, cz + side * 0.3), (xx, top + sill, cz + side * 0.3), (xx, top, cz), (xx, top + sill, cz + side * 0.1)]
        pieces.append(("late", wall))   # (after the cut of the opening: it lies in the opening)
    pieces.append(("cut", arch_piece("x", cz, front_hole, lambda y: cx + 0.86 - niche, lambda y: cx + 1.4)))
    pieces.append(("cut", arch_piece("z", cx, left_hole, lambda y: cz - 0.86 + niche, lambda y: cz - 1.4)))
    return pieces


def ingot():
    """An ingot (its real proportions are about 7 : 2.4 : 1, a flat bar; this one is a stouter game bar, 0.8 x 0.46 x 0.32): a trapezoid prism,
    narrower at the top (0.62 x 0.34), the edges chamfered."""
    def rect(y, lx, lz): return [(sx * lx / 2, y, sz * lz / 2) for sx in (-1, 1) for sz in (-1, 1)]
    return [rect(-0.16, 0.74, 0.40) + rect(-0.13, 0.80, 0.46) + rect(0.12, 0.66, 0.37) + rect(0.16, 0.60, 0.32)]


def ellipsoid(cx, cy, cz, rx, ry, rz, rings=7, seg=14):
    """The points of an ellipsoid (a hull of them is a smooth-looking blob)."""
    out = [(cx, cy + ry, cz), (cx, cy - ry, cz)]
    for i in range(1, rings):
        a = math.pi * i / rings
        for j in range(seg):
            b = math.tau * j / seg
            out.append((cx + rx * math.sin(a) * math.cos(b), cy + ry * math.cos(a), cz + rz * math.sin(a) * math.sin(b)))
    return out


def loft(rows, seg=20, cx=0.0, cz=0.0):
    """Rings of ellipses, one over another: rows of (y, half width x, half depth z); a row with 0 size is a pole. The hull is a smooth blob."""
    out = []
    for y, rx, rz in rows:
        if rx <= 0.0 or rz <= 0.0:
            out.append((cx, y, cz))
            continue
        for j in range(seg):
            a = math.tau * j / seg
            out.append((cx + rx * math.cos(a), y, cz + rz * math.sin(a)))
    return out


def unit_t_pose(idle=False):
    """The worker (docs/unit-model.md: the numbers come from the Bricktron of Castle Story) in a T pose, ONE mesh, no face (the face is a texture:
    art/facegen.py). 1.88 high, standing on y = 0 between the feet, looking towards +z (the game's front of a unit; the load is on its back, -z)."""
    def rings(rows, seg):
        out = []
        for y, rx, rz, dz in rows:
            if rx <= 0.0:
                out.append((0.0, y, dz))
                continue
            for j in range(seg):
                a = math.tau * j / seg
                out.append((rx * math.cos(a), y, dz + rz * math.sin(a)))
        return out
    pieces = []
    # the body: a pear (widest 1.0 at y 0.53, the belly a little forward); its top rises to y 1.4 round the head (the shoulders come up to the
    # bottom of the eyes at the sides) but is shallow at the front, so the face shows down to the chin (y 1.16)
    pieces.append(rings([(0.27, 0.30, 0.26, 0.02), (0.34, 0.42, 0.36, 0.04), (0.46, 0.51, 0.41, 0.05), (0.56, 0.52, 0.425, 0.05),
                         (0.72, 0.505, 0.41, 0.04), (0.90, 0.475, 0.39, 0.02), (1.08, 0.49, 0.33, 0.0), (1.18, 0.49, 0.28, -0.02),
                         (1.26, 0.46, 0.22, -0.03), (1.33, 0.385, 0.16, -0.03), (1.37, 0.32, 0.12, -0.03)], 16))   # (the shoulders slope down from the head)
    # the head: an egg, the broad end down (0.72 wide low, at the cheeks), narrowing all the way up to a round top at 1.88; sunk into the body
    pieces.append(rings([(1.08, 0.33, 0.29, 0.02), (1.20, 0.36, 0.31, 0.02), (1.32, 0.36, 0.31, 0.02), (1.44, 0.35, 0.305, 0.02),
                         (1.54, 0.335, 0.295, 0.02), (1.63, 0.31, 0.275, 0.02), (1.71, 0.275, 0.245, 0.02), (1.78, 0.225, 0.20, 0.02),
                         (1.83, 0.165, 0.15, 0.02), (1.865, 0.095, 0.085, 0.02), (1.88, 0.0, 0.0, 0.02)], 16))
    for sx in (-1, 1):
        pieces.append([(sx * 0.30 + x, y, z) for (x, y, z) in rings([(0.10, 0.16, 0.17, 0.03), (0.22, 0.18, 0.19, 0.02), (0.36, 0.20, 0.21, 0.02)], 10)])   # a thick short leg
        pieces.append([(sx * 0.30 + x, y, z) for (x, y, z) in rings([(0.0, 0.18, 0.21, 0.08), (0.04, 0.21, 0.25, 0.08), (0.10, 0.20, 0.23, 0.08),
                                                                      (0.15, 0.14, 0.16, 0.06)], 12)])   # a foot: an oval slipper, the toe forward
        if idle:   # a meaty arm hanging down at the side, the elbow a little out, close to the belly; a big round fist at y 0.35..0.69
            shoulder, elbow, wrist = (sx * 0.55, 1.10, 0.185), (sx * 0.67, 0.84, 0.16), (sx * 0.66, 0.62, 0.135)
            fist = (sx * 0.655, 0.52, 0.17)
        else:      # an arm straight out under the shoulders: it ends at x 1.24
            shoulder, elbow, wrist = (sx * 0.45, 1.10, 0.185), (sx * 0.78, 1.10, 0.16), (sx * 0.98, 1.10, 0.135)
            fist = (sx * 1.12, 1.10, 0.17)
        for (x0, y0, r0), (x1, y1, r1) in ((shoulder, elbow), (elbow, wrist)):   # thick, thinner to the wrist
            pieces.append(ellipsoid(x0, y0, 0.0, r0, r0, r0, 5, 10) + ellipsoid(x1, y1, 0.0, r1, r1, r1, 5, 10))
        pieces.append(ellipsoid(fist[0], fist[1], 0.02, fist[2], fist[2], fist[2], 5, 10))
    return pieces


STRUCTURES = {
    "furnace": furnace,
    "unit":    unit_t_pose,
    "unit_idle": lambda: unit_t_pose(idle=True),
    "ingot":   ingot,
}
STONE_BLOCKS = ["brick", "cube", "stairs", "stairs_small", "corner_out_l", "corner_out_r", "corner_in_l", "corner_in_r", "corner_in_cell",
                "corner_out_cell", "tower_a", "tower_b", "tower_squat", "column", "tower_flared"]

BLOCKS = {
    # --- Stone Blocks
    "brick":        lambda: [box(0, 0, 0, 2.0, 1.0, 1.0)],
    "cube":         lambda: [box(0, 0, 0, 1.0, 1.0, 1.0)],
    "stairs":       lambda: stairs(1.0, 3, -1.0) + [box(0.5, 0, 0, 1.0, 1.0, 1.0)],   # one cell of steps and one cell of block
    "stairs_small": lambda: stairs(1.0, 3),
    "corner_out_l": lambda: with_cube(fan_cell(), False),     # 5, 6: a cell of fanned treads and a cube
    "corner_out_r": lambda: with_cube(fan_cell(), True),
    "corner_in_l":  lambda: with_cube(corner_cell_in(), False),
    "corner_in_r":  lambda: with_cube(corner_cell_in(), True),
    "corner_in_cell": lambda: moved(corner_cell_in(), 0.0, mirror_x=True),    # the notch in the near corner: chevrons point at the viewer
    "corner_out_cell": lambda: moved(corner_cell(), 0.0, mirror_x=True),      # the high corner is the far one: it reads as a stepped pyramid
    "tower_a":      lambda: tower(0.18, 0.42, 0.46, 0.3, 0.4, 0.03),
    "tower_b":      lambda: tower(0.14, 0.3, 0.44, 0.34, 0.56, 0.02),
    "tower_squat":  squat,
    "column":       column,
    "tower_flared": lambda: tower_square(0.16, 0.5, 0.5, 0.3, 0.34),
    # --- Plugs
    "plug_1":       lambda: plug("F"),
    "plug_2":       lambda: plug("LR"),
    "plug_3":       lambda: plug("FR"),
    "plug_4":       lambda: plug("FLR"),
    "plug_5":       lambda: plug("FBLR"),
    # --- Round Bricks
    "round_a":      lambda: round_brick("a"),
    "round_b":      lambda: round_brick("b"),
    "round_c":      lambda: round_brick("c"),
    "round_corner": lambda: round_brick("d"),
    # --- Crenelations
    "cren_slab":    cren_slab,
    "cren_bracket": cren_bracket,
    "cren_corner":  cren_corner,
    "cren_slope":   lambda: cren_roof(1.0),
    "cren_slope_corner": cren_roof_corner,
    "cren_slope_long": lambda: cren_roof(2.0),
    "cren_hip":     cren_roof_inner,
    "cren_corbel_long": lambda: corbel_slab(1.1),
    "cren_corbel":  lambda: corbel_slab(1),
    "cren_corbel_small": cren_corbel,
    # --- Wood Blocks
    "log":          wood_log,
    "beam":         wood_beam,
    "post":         wood_post,
    "brace":        wood_brace,
    "board":        lambda: board(2.0, 1.0),
    "plank":        lambda: board(2.0, 0.5),
    "plank_small":  lambda: board(1.0, 0.5),
}


def mesh_of(pieces, smooth=True):
    """Triangles with per-vertex normals: flat on the faces, smoothed where neighbouring faces differ by less than SMOOTH_DEG."""
    tris = []
    cos_limit = math.cos(math.radians(SMOOTH_DEG)) if smooth else 0.99999   # only faces in the same plane share a normal
    for piece in pieces:
        faces = piece[1] if isinstance(piece, tuple) and piece[0] == "tris" else hull(piece)
        by_pos = {}
        for fi, (nn, poly) in enumerate(faces):
            for p in poly:
                by_pos.setdefault(p, []).append(fi)
        for fi, (nn, poly) in enumerate(faces):
            vn = []
            for p in poly:
                s = (0.0, 0.0, 0.0)
                for fj in by_pos[p]:
                    if dot(faces[fj][0], nn) > cos_limit:
                        s = (s[0] + faces[fj][0][0], s[1] + faces[fj][0][1], s[2] + faces[fj][0][2])
                vn.append(norm(s))
            for t in range(1, len(poly) - 1):
                a, b, c = poly[0], poly[t], poly[t + 1]
                if dot(cross(sub(b, a), sub(c, a)), cross(sub(b, a), sub(c, a))) < 1e-10:
                    continue
                tris.append(((a, vn[0]), (b, vn[t]), (c, vn[t + 1])))
    return tris


def write_obj(name, tris):
    lines = ["# generated by art/blockgen.py", "o %s" % name]
    n = 0
    for tri in tris:
        for p, _ in tri:
            lines.append("v %.4f %.4f %.4f" % p)
        for _, v in tri:
            lines.append("vn %.4f %.4f %.4f" % v)
    for i in range(len(tris)):
        b = i * 3 + 1
        lines.append("f %d//%d %d//%d %d//%d" % (b, b, b + 1, b + 1, b + 2, b + 2))
    with open(os.path.join(OUT, name + ".obj"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    if os.environ.get("BLOCKGEN_STRUCTURE"):   # BLOCKGEN_STRUCTURE=furnace (or ingot): that structure, as one mesh, into BLOCKGEN_OUT
        for name in os.environ["BLOCKGEN_STRUCTURE"].split(","):
            pieces = STRUCTURES[name]()
            if name != "ingot":
                pieces = [merge(pieces)]
            tris = mesh_of(pieces, smooth=False)
            write_obj(name, tris)
            print("%-10s %d triangles" % (name, len(tris)))
        raise SystemExit
    which = os.environ.get("BLOCKGEN_MERGE", "")
    chosen = (STONE_BLOCKS if which == "stone" else MERGE_SETS.get(which)) if which else None
    for name, make in BLOCKS.items():
        if which and name not in chosen:
            continue
        pieces = make()
        if which:
            pieces = [merge(pieces)]
        tris = mesh_of(pieces, smooth=not which or name in ROUND_STONE)
        write_obj(name, tris)
        xs = [p[0] for t in tris for p, _ in t]
        ys = [p[1] for t in tris for p, _ in t]
        zs = [p[2] for t in tris for p, _ in t]
        print("%-18s %4d triangles  x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f" % (name, len(tris), min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
