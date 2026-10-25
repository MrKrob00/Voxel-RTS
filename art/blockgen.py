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
    parts = [m3d.Manifold.hull_points(np.array(piece, dtype=np.float64)) for piece in pieces]
    union = m3d.Manifold.batch_boolean(parts, m3d.OpType.Add)
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
    """The overhang (2 cells along x): a whole cube at -x and, in front of it (+x), a flat platform 15% of a block thick along the top.
    Under the platform a slope runs from its underside at half the platform's length back down to the cube's face at 30% of the
    height from the top. Slope and platform have the width of the cube."""
    cube = box(-0.5, 0, 0, 1.0, 1.0, 1.0, 0.0)
    platform = box(0.5, 0.425, 0, 1.0, 0.15, 1.0, 0.0)
    brace = [(x, y, z) for (x, y) in ((0.0, 0.35), (0.5, 0.35), (0.0, 0.2)) for z in (-0.5, 0.5)]
    return [cube, platform, brace]


def cren_bracket():
    top = box(0, 0.4, 0, 1.0, 0.2, 1.0, 0.03)
    body = pts_of((-0.3, 0.3, 0.5), (0.3, 0.3, 0.5), (-0.3, -0.5, 0.5), (0.3, -0.5, 0.5), (-0.3, 0.3, -0.35), (0.3, 0.3, -0.35))
    return [top, body]


def cren_corner():
    """A corner corbel: a triangular top plate on a body that narrows to a point under the middle of it."""
    tri = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5)]
    top = plan(tri, 0.3, 0.5)
    body = [(-0.5, 0.3, -0.5), (0.5, 0.3, -0.5), (0.5, 0.3, 0.5), (0.17, -0.5, -0.17)]
    return [top, body]


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


def cren_corbel(length, shift):
    hl = length / 2
    top = box(0, 0.32, 0, length, 0.36, 1.0, 0.04)
    body = box(shift, -0.18, 0.1, length * 0.7, 0.64, 0.8, 0.04)
    nose = box(shift - length * 0.2, -0.38, 0.25, length * 0.35, 0.24, 0.5, 0.04)
    return [top, body, nose]


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
    "cren_slope":   lambda: cren_slope(1.0),
    "cren_slope_corner": lambda: cren_slope(1.0, True),
    "cren_slope_long": lambda: cren_slope(2.0),
    "cren_hip":     cren_hip,
    "cren_corbel_long": lambda: cren_corbel(2.0, 0.1),
    "cren_corbel":  lambda: cren_corbel(2.0, -0.1),
    "cren_corbel_small": lambda: cren_corbel(1.0, 0.0),
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
