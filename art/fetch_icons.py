#!/usr/bin/env python3
"""Copies the icons the interface uses from a checkout of https://github.com/game-icons/icons (game-icons.net, CC BY 3.0) into
assets/icons/, ready for Godot: the black background square is cut out, the shape stays white (the game tints it) and the size is
128 x 128.   git clone --depth 1 https://github.com/game-icons/icons /tmp/gi && python3 art/fetch_icons.py /tmp/gi
The authors are listed in CREDITS.md."""

import os
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gi"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "icons")

# name used by the game -> path in the repository
ICONS = {
    "fell_trees": "delapouite/axe-in-log",
    "cut_grass": "delapouite/high-grass",
    "quarry": "lorc/mining",
    "build": "lorc/hammer-nails",
    "dig_now": "delapouite/dig-hole",
    "fill_ground": "delapouite/stone-pile",
    "free_stone": "delapouite/clay-brick",
    "free_wood": "delapouite/wood-beam",
    "home": "delapouite/house",
    "idle": "delapouite/person-in-bed",
    "all_units": "delapouite/person",
    "rotate": "delapouite/clockwise-rotation",
    "stop": "delapouite/night-sleep",      # "stop making it": it rests
    "brick_wall": "delapouite/brick-wall",
    "wood_pile": "delapouite/wood-pile",
    "rope": "delapouite/rope-coil",
    "planks": "delapouite/planks",
    "sack": "lorc/knapsack",
    "trowel": "delapouite/trowel",
}

os.makedirs(OUT, exist_ok=True)
authors = set()
for name, rel in ICONS.items():
    svg = open(os.path.join(SRC, rel + ".svg")).read()
    svg = re.sub(r'<path d="M0 0h512v512H0z"/>', "", svg, count=1)          # the black background
    svg = svg.replace('<svg xmlns="http://www.w3.org/2000/svg"', '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"', 1)
    if 'fill="#fff"' not in svg:
        svg = svg.replace("<path ", '<path fill="#fff" ', 1)
    open(os.path.join(OUT, name + ".svg"), "w").write(svg)
    authors.add(rel.split("/")[0])
    print(name, "<-", rel)
print("authors:", ", ".join(sorted(authors)))
