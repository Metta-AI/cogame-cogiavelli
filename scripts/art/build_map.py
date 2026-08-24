#!/usr/bin/env python3
"""Build data/italy1499.json — the hand-authored vector map of the Cogiavelli
board: 42 areas as polygons in a 1000x900 space, each with a label anchor, a
city dot and a unit anchor.

How it is authored, and why:

* Every land province is a hand-placed disc at its geographic position with a
  hand-chosen radius. The union of those discs IS the land: the boot, the Po
  valley, Sicily (deliberately detached across the Strait of Messina) and the
  Balkan coast. Everything the discs do not cover is sea.
* Cells of a fine grid are assigned to the nearest seed OF THEIR OWN KIND, so
  a land cell never falls to a sea and vice versa. That keeps the coastline
  where the geography puts it instead of where a plain Voronoi would.
* The region outlines are then traced along grid edges and smoothed as ONE
  planar graph — every boundary vertex has a single global position and a
  single global keep/drop decision — so two provinces that share a border
  emit exactly the same vertices and their polygons abut with no seam.

Run:  python3 scripts/art/build_map.py
"""

import json
import math
import os
from collections import defaultdict

W, H = 1000, 900
STEP = 8                       # grid cell, px
COLS, ROWS = W // STEP, H // STEP

# code -> the discs that make up the province: (x, y, radius). The FIRST
# disc is the province's home position; the union of every disc on the board
# is the land, so extra discs are how a province reaches off the frame (the
# Balkan hinterland) or takes in a peninsula.
LAND_SEEDS = {
    "SAV": [(96, 268, 86)], "TUR": [(168, 200, 74)], "COM": [(256, 92, 62), (150, 24, 140)],
    "MIL": [(212, 162, 66)], "PAV": [(250, 250, 74)], "GEN": [(186, 346, 80)],
    "TRE": [(340, 96, 66), (376, 22, 80)], "MAN": [(312, 194, 64)], "VER": [(398, 142, 62)],
    "PAD": [(452, 178, 58)], "VEN": [(500, 226, 56)], "FRI": [(528, 128, 64), (546, 26, 96)],
    "TRI": [(596, 176, 78)], "FER": [(410, 254, 58)], "MOD": [(326, 300, 64)],
    "BOL": [(374, 318, 58)], "RMG": [(452, 320, 58)], "PIS": [(316, 388, 66)],
    "FLO": [(392, 386, 56)], "SIE": [(376, 456, 60)], "URB": [(474, 396, 56)],
    "ANC": [(534, 406, 56)], "PER": [(450, 474, 58)], "ROM": [(424, 556, 68)],
    "ABR": [(536, 504, 66)], "NAP": [(520, 622, 66)], "APU": [(630, 572, 68)],
    "BAR": [(686, 618, 58)], "CAL": [(612, 700, 62)], "MES": [(562, 818, 52)],
    "PAL": [(452, 806, 60)],
    "BOS": [(712, 268, 90), (700, 96, 120), (880, 120, 190), (890, 290, 120)],
    "RAG": [(716, 396, 60), (816, 344, 70)],
    "ALB": [(890, 570, 110), (820, 400, 100)],
    "DUR": [(806, 556, 58)],
    "AVL": [(836, 660, 66), (940, 720, 110)],
}
SEA_SEEDS = {
    "LIG": (150, 396), "UTS": (232, 566), "LTS": (392, 700),
    "ION": (700, 820), "LAD": (676, 468), "UAD": (582, 286),
}

NAMES = {
    "TUR": "Turin", "SAV": "Savoy", "COM": "Como", "MIL": "Milan",
    "PAV": "Pavia", "GEN": "Genoa", "TRE": "Trent", "MAN": "Mantua",
    "VER": "Verona", "PAD": "Padua", "VEN": "Venice", "FRI": "Friuli",
    "TRI": "Trieste", "FER": "Ferrara", "MOD": "Modena", "BOL": "Bologna",
    "RMG": "Romagna", "PIS": "Pisa", "FLO": "Florence", "SIE": "Siena",
    "URB": "Urbino", "ANC": "Ancona", "PER": "Perugia", "ROM": "Rome",
    "ABR": "Abruzzi", "NAP": "Naples", "APU": "Apulia", "BAR": "Bari",
    "CAL": "Calabria", "MES": "Messina", "PAL": "Palermo", "BOS": "Bosnia",
    "RAG": "Ragusa", "ALB": "Albania", "DUR": "Durazzo", "AVL": "Avlona",
    "LIG": "Ligurian Sea", "UTS": "Upper Tyrrhenian Sea",
    "LTS": "Lower Tyrrhenian Sea", "ION": "Ionian Sea",
    "LAD": "Lower Adriatic Sea", "UAD": "Upper Adriatic Sea",
}
COASTAL = {
    "GEN", "VEN", "FRI", "TRI", "FER", "RMG", "PIS", "ANC", "ROM", "ABR",
    "NAP", "APU", "BAR", "CAL", "MES", "PAL", "RAG", "DUR", "AVL",
}
CITIES = ("TUR COM MIL PAV GEN VER PAD VEN TRI FER BOL PIS FLO SIE ANC PER "
          "ROM NAP BAR MES PAL RAG DUR AVL").split()
HOME = {
    "VENICE": "VEN PAD VER", "MILAN": "MIL PAV COM", "FLORENCE": "FLO PIS SIE",
    "PAPACY": "ROM ANC PER", "NAPLES": "NAP BAR PAL", "TURK": "RAG DUR AVL",
}
ORDER = ("TUR SAV COM MIL PAV GEN TRE MAN VER PAD VEN FRI TRI FER MOD BOL "
         "RMG PIS FLO SIE URB ANC PER ROM ABR NAP APU BAR CAL MES PAL BOS "
         "RAG ALB DUR AVL LIG UTS LTS ION LAD UAD").split()

# The declared land adjacency, for the report at the end.
LAND_ADJ = {
    "TUR": "SAV PAV GEN MIL", "SAV": "TUR GEN PAV", "COM": "MIL TRE",
    "MIL": "TUR COM PAV MAN", "PAV": "TUR SAV MIL GEN MAN MOD",
    "GEN": "TUR SAV PAV MOD PIS", "TRE": "COM VER MAN",
    "MAN": "MIL PAV TRE VER MOD FER", "VER": "TRE MAN PAD FER",
    "PAD": "VER VEN FER FRI", "VEN": "PAD FRI FER", "FRI": "PAD VEN TRI",
    "TRI": "FRI BOS", "FER": "MAN VER PAD VEN BOL RMG",
    "MOD": "GEN PAV MAN BOL PIS", "BOL": "FER MOD RMG FLO",
    "RMG": "FER BOL FLO URB", "PIS": "GEN MOD FLO SIE",
    "FLO": "BOL RMG PIS SIE URB", "SIE": "PIS FLO PER ROM",
    "URB": "RMG FLO PER ANC", "ANC": "URB PER ABR",
    "PER": "SIE URB ANC ROM ABR", "ROM": "SIE PER ABR NAP",
    "ABR": "ANC PER ROM NAP APU", "NAP": "ROM ABR APU CAL",
    "APU": "ABR NAP BAR CAL", "BAR": "APU CAL", "CAL": "NAP APU BAR",
    "MES": "PAL", "PAL": "MES", "BOS": "TRI RAG ALB", "RAG": "BOS ALB",
    "ALB": "BOS RAG DUR AVL", "DUR": "ALB AVL", "AVL": "ALB DUR",
}
SEAS_OF = {
    "GEN": "LIG", "VEN": "UAD", "FRI": "UAD", "TRI": "UAD", "FER": "UAD",
    "RMG": "UAD", "PIS": "LIG UTS", "ANC": "LAD", "ROM": "UTS LTS",
    "ABR": "LAD", "NAP": "LTS", "APU": "LAD", "BAR": "LAD", "CAL": "LTS ION",
    "MES": "LTS ION", "PAL": "LTS", "RAG": "LAD", "DUR": "LAD",
    "AVL": "LAD ION",
}
SEA_LINKS = {"LIG": "UTS", "UTS": "LIG LTS", "LTS": "UTS ION",
             "ION": "LTS LAD", "LAD": "ION UAD", "UAD": "LAD"}


def assign():
    """Grid cell -> area code. Land cells go to land seeds, sea to sea."""
    grid = [[None] * COLS for _ in range(ROWS)]
    for row in range(ROWS):
        y = row * STEP + STEP / 2.0
        for col in range(COLS):
            x = col * STEP + STEP / 2.0
            best, bestd = None, 1e18
            onland = False
            for code, discs in LAND_SEEDS.items():
                for sx, sy, r in discs:
                    d = math.hypot(x - sx, y - sy)
                    if d <= r:
                        onland = True
                    if d < bestd:
                        best, bestd = code, d
            if not onland:
                best, bestd = None, 1e18
                for code, (sx, sy) in SEA_SEEDS.items():
                    d = math.hypot(x - sx, y - sy)
                    if d < bestd:
                        best, bestd = code, d
            grid[row][col] = best
    return grid


def enforce_connectivity(grid):
    """Every area must be ONE connected region: a design-note polygon is a
    single ring. The disc mask can strand a pocket of sea behind a coastal
    province (the Alpine corner, the mid-Adriatic wedge); each stranded
    component is handed to whichever neighbour it shares the longest border
    with, until every area is in one piece."""
    for _ in range(40):
        seen = [[False] * COLS for _ in range(ROWS)]
        components = defaultdict(list)
        for row in range(ROWS):
            for col in range(COLS):
                if seen[row][col]:
                    continue
                code = grid[row][col]
                stack = [(row, col)]
                seen[row][col] = True
                cells = []
                while stack:
                    r, c = stack.pop()
                    cells.append((r, c))
                    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nr, nc = r + dr, c + dc
                        if 0 <= nr < ROWS and 0 <= nc < COLS and \
                                not seen[nr][nc] and grid[nr][nc] == code:
                            seen[nr][nc] = True
                            stack.append((nr, nc))
                components[code].append(cells)
        stray = []
        for code, groups in components.items():
            if len(groups) < 2:
                continue
            groups.sort(key=len, reverse=True)
            stray.extend(groups[1:])
        if not stray:
            return grid
        for cells in stray:
            border = defaultdict(int)
            for r, c in cells:
                for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    other = region_of(grid, r + dr, c + dc)
                    if other and other != grid[r][c]:
                        border[other] += 1
            if not border:
                continue
            winner = max(sorted(border), key=lambda k: border[k])
            for r, c in cells:
                grid[r][c] = winner
    return grid


def region_of(grid, row, col):
    if row < 0 or col < 0 or row >= ROWS or col >= COLS:
        return None
    return grid[row][col]


def boundary_graph(grid):
    """Every grid edge that separates two different regions, keyed by the
    unordered pair, plus the point -> incident regions map."""
    edges = defaultdict(set)     # point -> set of neighbour points
    regions_at = defaultdict(set)
    for row in range(ROWS + 1):
        for col in range(COLS + 1):
            for a, b, p, q in (
                # horizontal edge between (row-1,col) and (row,col)
                ((row - 1, col), (row, col), (col, row), (col + 1, row)),
                # vertical edge between (row,col-1) and (row,col)
                ((row, col - 1), (row, col), (col, row), (col, row + 1)),
            ):
                ra = region_of(grid, a[0], a[1])
                rb = region_of(grid, b[0], b[1])
                if ra == rb:
                    continue
                if p[0] > COLS or p[1] > ROWS or q[0] > COLS or q[1] > ROWS:
                    continue
                edges[p].add(q)
                edges[q].add(p)
    ## The world outside the canvas counts as a region, so the point where
    ## two areas reach the frame is a junction and gets pinned.
    for point in list(edges):
        col, row = point
        for dr, dc in ((-1, -1), (-1, 0), (0, -1), (0, 0)):
            regions_at[point].add(region_of(grid, row + dr, col + dc))
    return edges, regions_at


def smooth(edges, regions_at):
    """One global position per boundary vertex: junctions (three or more
    regions meeting) are pinned, everything else relaxes a little toward the
    mean of its neighbours so the staircase reads as a coastline."""
    pos = {p: (p[0] * float(STEP), p[1] * float(STEP)) for p in edges}
    pinned = set()
    for point in edges:
        if len(regions_at.get(point, ())) >= 3 or len(edges[point]) != 2:
            pinned.add(point)
    for corner in ((0, 0), (COLS, 0), (0, ROWS), (COLS, ROWS)):
        if corner in edges:
            pinned.add(corner)
    for _ in range(4):
        nxt = {}
        for point, neighbours in edges.items():
            if point in pinned:
                nxt[point] = pos[point]
                continue
            sx = sum(pos[n][0] for n in neighbours) / len(neighbours)
            sy = sum(pos[n][1] for n in neighbours) / len(neighbours)
            x, y = pos[point]
            nx, ny = x + (sx - x) * 0.42, y + (sy - y) * 0.42
            ## A vertex on the frame slides along it, never off it.
            if point[0] == 0:
                nx = 0.0
            elif point[0] == COLS:
                nx = float(W)
            if point[1] == 0:
                ny = 0.0
            elif point[1] == ROWS:
                ny = float(H)
            nxt[point] = (nx, ny)
        pos = nxt
    return pos, pinned


def keep_set(edges, pos, pinned, spacing=52.0):
    """One global keep/drop decision per vertex.

    The boundary is cut into CHAINS between junctions. A chain is shared by
    exactly two regions, which walk it in opposite directions, so the keep
    decision is taken once per chain — canonically, from its lexicographically
    smaller endpoint — and both regions emit exactly the same vertices. That
    is what makes the polygons abut with no seam."""
    keep = set(pinned)
    seen = set()
    covered = set(pinned)

    def walk(start, first):
        chain = [start, first]
        previous, point = start, first
        guard = 0
        while point not in pinned and guard < 100000:
            guard += 1
            nexts = [n for n in edges[point] if n != previous]
            if not nexts:
                break
            previous, point = point, nexts[0]
            chain.append(point)
            if point == start:
                break
        return chain

    def mark(chain):
        if chain[0] > chain[-1]:
            chain = list(reversed(chain))
        total = 0.0
        for index in range(1, len(chain)):
            a, b = pos[chain[index - 1]], pos[chain[index]]
            total += math.hypot(b[0] - a[0], b[1] - a[1])
        ## A long chain (a sea frontage, the canvas frame) is sampled more
        ## coarsely so no area's polygon runs past the design note's budget.
        step = spacing if total < 520.0 else spacing * 1.8
        run = 0.0
        for index in range(1, len(chain) - 1):
            a, b = pos[chain[index - 1]], pos[chain[index]]
            run += math.hypot(b[0] - a[0], b[1] - a[1])
            if run >= step:
                keep.add(chain[index])
                run = 0.0

    for start in sorted(pinned):
        for first in sorted(edges[start]):
            if (start, first) in seen:
                continue
            chain = walk(start, first)
            seen.add((start, first))
            seen.add((chain[-1], chain[-2]))
            covered.update(chain)
            mark(chain)
    ## A boundary loop with no junction at all (one region wholly inside
    ## another) still needs a deterministic anchor: its smallest vertex.
    for point in sorted(edges):
        if point in covered:
            continue
        loop = [point]
        previous, current = point, sorted(edges[point])[0]
        guard = 0
        while current != point and guard < 100000:
            guard += 1
            loop.append(current)
            nexts = [n for n in edges[current] if n != previous]
            if not nexts:
                break
            previous, current = current, nexts[0]
        covered.update(loop)
        anchor = min(loop)
        rotated = loop[loop.index(anchor):] + loop[:loop.index(anchor)]
        keep.add(anchor)
        mark(rotated + [anchor])
    return keep


def trace(grid, code):
    """The blocky outline of one region as a closed loop of grid points,
    walked so the interior is on the left. A region that pinches at a corner
    yields several loops; the longest one is the outline."""
    cells = {(c, r) for r in range(ROWS) for c in range(COLS)
             if grid[r][c] == code}
    if not cells:
        return []
    succ = defaultdict(list)
    for (c, r) in cells:
        if (c, r - 1) not in cells:
            succ[(c, r)].append((c + 1, r))          # top, left to right
        if (c + 1, r) not in cells:
            succ[(c + 1, r)].append((c + 1, r + 1))  # right, down
        if (c, r + 1) not in cells:
            succ[(c + 1, r + 1)].append((c, r + 1))  # bottom, right to left
        if (c - 1, r) not in cells:
            succ[(c, r + 1)].append((c, r))          # left, up
    loops = []
    remaining = {point: list(nexts) for point, nexts in succ.items()}
    while any(remaining.values()):
        start = next(p for p in sorted(remaining) if remaining[p])
        loop = [start]
        point = start
        while True:
            nexts = remaining.get(point)
            if not nexts:
                break
            nxt = nexts.pop(0)
            if nxt == start:
                break
            loop.append(nxt)
            point = nxt
        loops.append(loop)
    return max(loops, key=len) if loops else []


def centroid(points):
    area = cx = cy = 0.0
    for i in range(len(points)):
        x0, y0 = points[i]
        x1, y1 = points[(i + 1) % len(points)]
        cross = x0 * y1 - x1 * y0
        area += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(area) < 1e-9:
        return (sum(p[0] for p in points) / len(points),
                sum(p[1] for p in points) / len(points))
    area *= 0.5
    return cx / (6 * area), cy / (6 * area)


def main():
    grid = enforce_connectivity(assign())
    edges, regions_at = boundary_graph(grid)
    pos, pinned = smooth(edges, regions_at)
    keep = keep_set(edges, pos, pinned)

    home_of = {}
    for power, codes in HOME.items():
        for code in codes.split():
            home_of[code] = power

    areas = []
    for code in ORDER:
        loop = trace(grid, code)
        poly = [pos[p] for p in loop if p in keep]
        if len(poly) < 3:
            poly = [pos[p] for p in loop]
        cx, cy = centroid(poly)
        areas.append({
            "code": code,
            "name": NAMES[code],
            "kind": ("sea" if code in SEA_SEEDS
                     else "coastal" if code in COASTAL else "inland"),
            "city": code in CITIES,
            "home": home_of.get(code, ""),
            "polygon": [[round(x, 1), round(y, 1)] for x, y in poly],
            "label": [round(cx, 1), round(cy - 15, 1)],
            "dot": [round(cx, 1), round(cy + 15, 1)],
            "unit": [round(cx, 1), round(cy, 1)],
        })

    payload = {"map": "italy1499", "width": W, "height": H, "areas": areas}
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    path = os.path.normpath(os.path.join(root, "data", "italy1499.json"))
    with open(path, "w") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")

    counts = [len(a["polygon"]) for a in areas]
    print(f"wrote {path}: {len(areas)} areas, "
          f"{min(counts)}..{max(counts)} points each")

    # Report: how many declared adjacencies are drawn as touching regions.
    touch = defaultdict(set)
    for row in range(ROWS):
        for col in range(COLS):
            here = grid[row][col]
            for dr, dc in ((1, 0), (0, 1)):
                other = region_of(grid, row + dr, col + dc)
                if other and other != here:
                    touch[here].add(other)
                    touch[other].add(here)
    want = defaultdict(set)
    for code, text in LAND_ADJ.items():
        for other in text.split():
            want[code].add(other)
            want[other].add(code)
    for code, text in SEAS_OF.items():
        for sea in text.split():
            want[code].add(sea)
            want[sea].add(code)
    for code, text in SEA_LINKS.items():
        for other in text.split():
            want[code].add(other)
            want[other].add(code)
    # The Strait of Messina is a FLEET-only edge: Sicily is deliberately
    # drawn detached from Calabria, so it is not expected to share a border.
    total = sum(len(v) for v in want.values()) // 2
    hit = sum(len(want[c] & touch[c]) for c in want) // 2
    print(f"declared adjacencies drawn as shared borders: {hit}/{total}")
    missing = sorted({f"{min(c, o)}-{max(c, o)}"
                      for c in want for o in want[c] - touch[c]})
    if missing:
        print("not visually adjacent:", " ".join(missing))


if __name__ == "__main__":
    main()
