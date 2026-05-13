"""
Generate simple 3D shapes as .glb files with embedded textures.
Prompts for a tonal range or colour palette before each shape.

Usage:
    python3 generate_models.py          # interactive colour prompts
    python3 generate_models.py -y       # skip prompts, use default greyscale

Output goes into a  Models/  subfolder next to this script.
Filenames include the chosen palette, e.g. sphere-sunset-c2.glb
"""

import sys
import numpy as np
import trimesh
from PIL import Image
import io
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "Models")
TEX_SIZE   = 512


# ---------------------------------------------------------------------------
# Colour / tonal options
# ---------------------------------------------------------------------------

# Keys "1"–"6": greyscale tonal ranges — remaps the 0–255 texture to [low, high].
GREY_RANGES = {
    "1": ("Dark",       ( 10,  90)),
    "2": ("Dark-Mid",   ( 40, 150)),
    "3": ("Mid",        ( 80, 180)),
    "4": ("Mid-Bright", (130, 220)),
    "5": ("Bright",     (180, 255)),
    "6": ("Wide",       (  0, 255)),
}

# Keys "7"–"14": colour palettes.
# Each entry: (display_name, base_stops, comp1_rgb, (comp2_dark_rgb, comp2_mid_rgb))
#
# base_stops: [(grey_value, (R,G,B)), ...]  — the normal 3-stop gradient.
# comp1:      one complementary colour that replaces the dark (t=0) stop.
# comp2:      two complementary colours placed at t=0 and t=96 before the
#             palette's mid stop, creating a richer dark-to-complement blend.
#
# Suffix c1 → [(0, comp1)]          + base_stops[1:]
# Suffix c2 → [(0, comp2a), (96, comp2b)] + base_stops[1:]
PALETTES = {
    "7": ("Warm Amber",
          [(  0, ( 25,  12,   3)), (128, (190,  85,  15)), (255, (255, 210, 110))],
          ( 40,  30, 120),
          (( 20,  15,  80), ( 55,  40, 150))),

    "8": ("Cool Steel",
          [(  0, (  5,  10,  25)), (128, ( 60, 120, 180)), (255, (190, 230, 255))],
          (140,  65,  10),
          (( 80,  35,   5), (170,  85,  20))),

    "9": ("Forest",
          [(  0, ( 10,  30,   5)), (128, ( 30, 130,  40)), (255, (150, 240,  80))],
          (110,  10,  65),
          (( 70,   5,  40), (150,  20,  90))),

    "10": ("Rose",
           [(  0, ( 40,   5,  15)), (128, (200,  60, 100)), (255, (255, 200, 220))],
           ( 10,  90,  60),
           ((  5,  55,  35), ( 20, 120,  80))),

    "11": ("Sunset",
           [(  0, ( 20,   0,   0)), (128, (220,  80,  10)), (255, (255, 240, 120))],
           ( 10,  85, 130),
           ((  5,  50,  80), ( 20, 115, 160))),

    "12": ("Ocean",
           [(  0, (  5,  10,  40)), (128, ( 20, 130, 150)), (255, (120, 240, 230))],
           (140,  40,  20),
           (( 90,  20,  10), (175,  60,  30))),

    "13": ("Cosmic",
           [(  0, ( 15,   5,  40)), (128, (120,  30, 180)), (255, (220, 180, 255))],
           ( 65, 105,  10),
           (( 40,  70,   5), ( 85, 135,  20))),

    "14": ("Copper",
           [(  0, ( 30,  10,   5)), (128, (170,  90,  30)), (255, (240, 190,  80))],
           ( 15,  45, 120),
           ((  8,  25,  75), ( 25,  60, 150))),
}


def apply_tonal_range(gray_2d, low, high):
    """Remap a greyscale [0–255] array into the sub-range [low, high]."""
    scaled = low + (gray_2d.astype(np.float32) / 255.0) * (high - low)
    return scaled.clip(0, 255).astype(np.uint8)


def apply_palette(gray_2d, stops):
    """
    Map a 2D greyscale array to RGB using a multi-stop colour gradient.
    stops: list of (grey_value, (R, G, B)) tuples sorted by grey_value.
    Returns a (H, W, 3) uint8 array.
    """
    stop_vals   = np.array([s[0] for s in stops], dtype=np.float32)
    stop_colors = np.array([s[1] for s in stops], dtype=np.float32)  # (n, 3)

    g   = gray_2d.astype(np.float32).ravel()
    idx = np.searchsorted(stop_vals, g, side="right") - 1
    idx = np.clip(idx, 0, len(stops) - 2)

    t0    = stop_vals[idx]
    t1    = stop_vals[idx + 1]
    denom = np.where(t1 > t0, t1 - t0, 1.0)
    alpha = np.clip((g - t0) / denom, 0.0, 1.0)

    c0  = stop_colors[idx]
    c1  = stop_colors[idx + 1]
    rgb = c0 + alpha[:, np.newaxis] * (c1 - c0)

    h, w = gray_2d.shape
    return rgb.clip(0, 255).astype(np.uint8).reshape(h, w, 3)


def prompt_color(shape_name, pattern_name):
    """
    Show the colour/tone selection menu for one shape.
    Returns (colorizer_fn | None, apply_all: bool, label: str | None).

    colorizer_fn: takes a 2D uint8 greyscale array, returns 2D or H×W×3 uint8.
                  None = keep default greyscale.
    apply_all:    True = lock this choice for every subsequent shape.
    label:        short string used in the output filename, or None for default.

    Input syntax:
      Enter          default greyscale, this shape only
      1 – 6          greyscale tonal range
      7 – 14         colour palette (normal)
      7c1 … 14c1     palette with one complementary colour at dark end
      7c2 … 14c2     palette with two complementary colours at dark end
      Append 'a' to any of the above to apply to all remaining shapes
      a              default for this shape AND all remaining (skip prompts)
    """
    grey_items    = list(GREY_RANGES.items())
    palette_items = list(PALETTES.items())

    print(f"\n  {'━' * 46}")
    print(f"  Colour for: {shape_name}  [{pattern_name}]")
    print(f"  {'━' * 46}")

    print("  Greyscale")
    for i in range(0, len(grey_items), 2):
        lk, (ln, _) = grey_items[i]
        if i + 1 < len(grey_items):
            rk, (rn, _) = grey_items[i + 1]
            print(f"   {lk:>2}  {ln:<14}  {rk:>2}  {rn}")
        else:
            print(f"   {lk:>2}  {ln}")

    print()
    print("  Color palettes")
    for i in range(0, len(palette_items), 2):
        lk, (ln, *_) = palette_items[i]
        if i + 1 < len(palette_items):
            rk, (rn, *_) = palette_items[i + 1]
            print(f"   {lk:>2}  {ln:<14}  {rk:>2}  {rn}")
        else:
            print(f"   {lk:>2}  {ln}")

    print()
    print("  Append c1 or c2 for a complementary dark end  (e.g. 11c1 · 11c2 · 11c2a)")
    print("  Enter = default   <n>a = choice for all remaining   a = default for all")

    while True:
        raw = input("  > ").strip().lower()

        # Plain Enter: default for this shape only.
        if raw == "":
            return None, False, None

        # "a" alone: default for all remaining.
        if raw == "a":
            return None, True, None

        # Strip trailing 'a' to detect apply-all.
        apply_all = raw.endswith("a")
        key_part  = raw[:-1] if apply_all else raw

        # Detect c1 / c2 variant suffix (must come before the numeric key).
        variant = "normal"
        if key_part.endswith("c2"):
            variant  = "c2"
            key_part = key_part[:-2]
        elif key_part.endswith("c1"):
            variant  = "c1"
            key_part = key_part[:-2]

        # Greyscale range — c1/c2 silently ignored (no complement defined).
        if key_part in GREY_RANGES:
            name_str, (low, high) = GREY_RANGES[key_part]
            label = name_str.lower().replace(" ", "-")
            fn = lambda g, lo=low, hi=high: apply_tonal_range(g, lo, hi)
            return fn, apply_all, label

        # Colour palette.
        if key_part in PALETTES:
            name_str, base_stops, comp1, (comp2a, comp2b) = PALETTES[key_part]
            base_label = name_str.lower().replace(" ", "-")

            if variant == "c1":
                stops = [(0, comp1)] + base_stops[1:]
                label = base_label + "-c1"
            elif variant == "c2":
                stops = [(0, comp2a), (96, comp2b)] + base_stops[1:]
                label = base_label + "-c2"
            else:
                stops = base_stops
                label = base_label

            fn = lambda g, s=stops: apply_palette(g, s)
            return fn, apply_all, label

        print("  Please enter 1–14 (optionally with c1/c2 and/or 'a'), Enter, or 'a'.")


# ---------------------------------------------------------------------------
# Texture generators  (return 2D uint8 greyscale arrays)
# ---------------------------------------------------------------------------

def tex_linear_gradient():
    row = np.linspace(0, 255, TEX_SIZE, dtype=np.uint8)
    return np.tile(row, (TEX_SIZE, 1))

def tex_radial_gradient():
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    r = r / r.max()
    return (255 * (1 - r)).astype(np.uint8)

def tex_angular_stripes():
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    angle = np.arctan2(y - cy, x - cx)
    return (255 * (np.sin(angle * 8) * 0.5 + 0.5)).astype(np.uint8)

def tex_marble():
    y, x = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    noise = np.sin((x + y * 0.5) / 20) * 0.5 + np.sin(x / 15 - y / 25) * 0.5
    noise = (noise - noise.min()) / (noise.max() - noise.min())
    return (255 * noise).astype(np.uint8)

def tex_concentric_rings():
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    return (255 * (np.sin(r / 12) * 0.5 + 0.5)).astype(np.uint8)

def tex_checkerboard():
    coords = np.arange(TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    checker = ((xi // (TEX_SIZE // 8)) + (yi // (TEX_SIZE // 8))) % 2
    return (checker * 255).astype(np.uint8)

def tex_diagonal_stripes():
    coords = np.arange(TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    return (255 * (np.sin((xi + yi) / 16) * 0.5 + 0.5)).astype(np.uint8)

def tex_crosshatch():
    coords = np.linspace(0, 4 * np.pi, TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    return (255 * np.abs(np.sin(xi)) * np.abs(np.sin(yi))).astype(np.uint8)

def tex_wood_grain():
    y, x = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    distort = np.sin(x / 30) * 15
    grain = np.sin((y + distort) / 10) * 0.4 + np.sin((y + distort) / 3) * 0.1 + 0.5
    return (255 * np.clip(grain, 0, 1)).astype(np.uint8)

def tex_spiral():
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r     = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    theta = np.arctan2(y - cy, x - cx)
    return (255 * (np.sin(r / 10 - theta * 3) * 0.5 + 0.5)).astype(np.uint8)

def tex_cells():
    rng     = np.random.default_rng(42)
    seeds   = rng.integers(0, TEX_SIZE, size=(20, 2)).astype(float)
    y, x    = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    dist    = np.full((TEX_SIZE, TEX_SIZE), np.inf)
    for sx, sy in seeds:
        dist = np.minimum(dist, np.sqrt((x - sx) ** 2 + (y - sy) ** 2))
    return (255 * dist / dist.max()).astype(np.uint8)


def make_png_bytes(arr):
    """Convert a 2D (greyscale) or H×W×3 (RGB) uint8 array to PNG bytes."""
    img = Image.fromarray(arr, mode="L" if arr.ndim == 2 else "RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# ---------------------------------------------------------------------------
# UV helpers
# ---------------------------------------------------------------------------

def uv_box(mesh):
    verts   = mesh.vertices[mesh.faces]
    normals = mesh.face_normals
    uvs     = np.zeros((len(mesh.faces) * 3, 2))
    for i, (tri, n) in enumerate(zip(verts, normals)):
        axes  = [a for a in range(3) if a != np.argmax(np.abs(n))]
        local = tri[:, axes]
        lo, hi = local.min(axis=0), local.max(axis=0)
        rng = np.where(hi - lo > 1e-6, hi - lo, 1.0)
        uvs[i * 3: i * 3 + 3] = (local - lo) / rng
    return uvs

def uv_cylindrical(vertices):
    x, y, z = vertices[:, 0], vertices[:, 1], vertices[:, 2]
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = (z - z.min()) / max(z.max() - z.min(), 1e-6)
    return np.column_stack([u, v])

def uv_spherical(vertices):
    x, y, z = vertices[:, 0], vertices[:, 1], vertices[:, 2]
    r = np.where(np.sqrt(x**2 + y**2 + z**2) > 1e-6,
                 np.sqrt(x**2 + y**2 + z**2), 1.0)
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = np.arccos(np.clip(z / r, -1, 1)) / np.pi
    return np.column_stack([u, v])


# ---------------------------------------------------------------------------
# Mesh builders  — return (mesh, uv, gray_array) tuples
# ---------------------------------------------------------------------------

def apply_texture(mesh, uv, png_bytes):
    mat = trimesh.visual.texture.SimpleMaterial(
        image=Image.open(io.BytesIO(png_bytes)).convert("RGB")
    )
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)
    return mesh

def build_cube():
    mesh = trimesh.creation.box(extents=[1, 1, 1]).subdivide()
    return mesh, uv_box(mesh), tex_linear_gradient()

def build_cylinder():
    mesh = trimesh.creation.cylinder(radius=0.5, height=1.0, sections=64)
    return mesh, uv_cylindrical(mesh.vertices), tex_radial_gradient()

def build_pyramid():
    mesh = trimesh.creation.cone(radius=0.6, height=1.2, sections=4)
    return mesh, uv_cylindrical(mesh.vertices), tex_angular_stripes()

def build_sphere():
    mesh = trimesh.creation.icosphere(subdivisions=4, radius=0.6)
    return mesh, uv_spherical(mesh.vertices), tex_marble()

def build_torus():
    mesh = trimesh.creation.torus(major_radius=0.5, minor_radius=0.18,
                                  major_sections=64, minor_sections=32)
    return mesh, uv_cylindrical(mesh.vertices), tex_concentric_rings()

def build_tetrahedron():
    verts = np.array([[ 1,1,1],[ 1,-1,-1],[-1,1,-1],[-1,-1,1]], dtype=float)
    verts /= np.linalg.norm(verts[0])
    mesh  = trimesh.Trimesh(vertices=verts,
                            faces=np.array([[0,1,2],[0,2,3],[0,3,1],[1,3,2]]),
                            process=True)
    return mesh, uv_box(mesh), tex_checkerboard()

def build_octahedron():
    verts = np.array([[1,0,0],[-1,0,0],[0,1,0],[0,-1,0],[0,0,1],[0,0,-1]], dtype=float)
    faces = np.array([[0,2,4],[2,1,4],[1,3,4],[3,0,4],
                      [0,5,2],[2,5,1],[1,5,3],[3,5,0]])
    mesh  = trimesh.Trimesh(vertices=verts, faces=faces, process=True)
    return mesh, uv_spherical(mesh.vertices), tex_diagonal_stripes()

def build_hexprism():
    mesh = trimesh.creation.cylinder(radius=0.55, height=1.0, sections=6)
    return mesh, uv_cylindrical(mesh.vertices), tex_crosshatch()

def build_capsule():
    mesh = trimesh.creation.capsule(radius=0.35, height=0.7)
    return mesh, uv_spherical(mesh.vertices), tex_wood_grain()

def build_mobius():
    U, V = 128, 32
    u = np.linspace(0, 2 * np.pi, U, endpoint=False)
    v = np.linspace(-0.4, 0.4, V)
    uu, vv = np.meshgrid(u, v, indexing='ij')
    x = (1 + vv * np.cos(uu / 2)) * np.cos(uu)
    y = (1 + vv * np.cos(uu / 2)) * np.sin(uu)
    z = vv * np.sin(uu / 2)
    verts  = np.column_stack([x.ravel(), y.ravel(), z.ravel()])
    uv_arr = np.column_stack([(uu.ravel() / (2 * np.pi)),
                               (vv.ravel() - vv.min()) / (vv.max() - vv.min())])
    faces  = []
    for i in range(U):
        for j in range(V - 1):
            ni = (i + 1) % U
            a, b = i*V+j, ni*V+j
            c, d = ni*V+j+1, i*V+j+1
            faces += [[a,b,c],[a,c,d]]
    mesh = trimesh.Trimesh(vertices=verts, faces=np.array(faces), process=False)
    return mesh, uv_arr, tex_spiral()

def build_star():
    n = 5
    outer_r, inner_r, height = 0.6, 0.25, 0.4
    ao = np.linspace(0, 2*np.pi, n, endpoint=False) - np.pi/2
    ai = ao + np.pi/n
    ring = np.array([[outer_r*np.cos(a), outer_r*np.sin(a)]
                     if k%2==0 else [inner_r*np.cos(ai[k//2]), inner_r*np.sin(ai[k//2])]
                     for k, a in enumerate(np.repeat(ao, 2))])
    ring = []
    for a, b in zip(ao, ai):
        ring += [[outer_r*np.cos(a), outer_r*np.sin(a)],
                 [inner_r*np.cos(b), inner_r*np.sin(b)]]
    ring = np.array(ring)
    top    = np.column_stack([ring,  np.full(len(ring),  height/2)])
    bottom = np.column_stack([ring,  np.full(len(ring), -height/2)])
    ct, cb = np.array([[0,0,height/2]]), np.array([[0,0,-height/2]])
    verts  = np.vstack([top, bottom, ct, cb])
    nv     = len(ring)
    idx_ct, idx_cb = nv*2, nv*2+1
    faces  = []
    for i in range(nv):
        ni = (i+1)%nv
        faces.append([i, ni, idx_ct])
        faces.append([nv+i, idx_cb, nv+ni])
    for i in range(nv):
        ni = (i+1)%nv
        faces += [[i, ni, nv+ni], [i, nv+ni, nv+i]]
    mesh = trimesh.Trimesh(vertices=verts, faces=np.array(faces), process=True)
    return mesh, uv_cylindrical(mesh.vertices), tex_cells()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SHAPES = [
    ("cube",        build_cube,        "linear gradient"),
    ("cylinder",    build_cylinder,    "radial gradient"),
    ("pyramid",     build_pyramid,     "angular stripes"),
    ("sphere",      build_sphere,      "marble"),
    ("torus",       build_torus,       "concentric rings"),
    ("tetrahedron", build_tetrahedron, "checkerboard"),
    ("octahedron",  build_octahedron,  "diagonal stripes"),
    ("hexprism",    build_hexprism,    "crosshatch"),
    ("capsule",     build_capsule,     "wood grain"),
    ("mobius",      build_mobius,      "spiral"),
    ("star",        build_star,        "cells"),
]

if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    use_defaults = "-y" in sys.argv or "--defaults" in sys.argv

    if not use_defaults:
        print("\n  Colour choices apply to the baseColor texture embedded in each .glb.")
        print("  The live viewer's lighting and PBR material multiply on top of this.")
        print(f"  Output folder: {OUTPUT_DIR}")

    locked_colorizer = None
    locked_label     = None
    locked           = False

    for name, builder, pattern_name in SHAPES:
        print(f"\nBuilding {name}...", end=" ", flush=True)
        mesh, uv, gray = builder()

        if use_defaults or locked:
            colorizer = locked_colorizer
            label     = locked_label
        else:
            colorizer, apply_all, label = prompt_color(name, pattern_name)
            if apply_all:
                locked_colorizer = colorizer
                locked_label     = label
                locked           = True
            print(f"  Building {name}...", end=" ", flush=True)

        colored  = colorizer(gray) if colorizer is not None else gray
        stem     = f"{name}-{label}" if label else name
        out_mesh = apply_texture(mesh, uv, make_png_bytes(colored))
        out      = os.path.join(OUTPUT_DIR, f"{stem}.glb")
        out_mesh.export(out)
        size_kb  = os.path.getsize(out) / 1024
        print(f"→ Models/{stem}.glb  ({size_kb:.1f} KB)")

    print(f"\nDone. Files written to: {OUTPUT_DIR}")
