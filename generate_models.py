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
import trimesh.visual.material
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


def palette_molecule_colors(palette_key, variant):
    """
    Return (heavy_rgb, h_rgb, bond_rgb) for a C1 or C2 palette molecule variant.

    C1:  heavy = palette bright · H = comp1        · bond = palette mid
    C2:  heavy = palette bright · H = comp2b       · bond = comp2a
    """
    _, base_stops, comp1, (comp2a, comp2b) = PALETTES[palette_key]
    bright = base_stops[-1][1]
    mid    = base_stops[1][1]
    if variant == "c1":
        return bright, comp1, mid
    return bright, comp2b, comp2a   # "c2"


# Keys "p","b","m","c","r": PBR material presets — (display_name, metallicFactor, roughnessFactor)
MATERIAL_PRESETS = {
    "p": ("Polished Metal", 1.00, 0.10),
    "b": ("Brushed Metal",  0.90, 0.45),
    "m": ("Matte Plastic",  0.00, 0.85),
    "c": ("Ceramic",        0.05, 0.40),
    "r": ("Rubber",         0.00, 0.95),
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


def prompt_material(shape_name):
    """
    Show the material preset menu for one shape.
    Returns (metalness, roughness, label | None, apply_all).

    Input syntax:
      Enter      Matte Plastic default, this shape only
      p b m c r  preset key
      Append 'a' to apply to all remaining shapes
      a          default for this shape AND all remaining
    """
    print(f"\n  {'─' * 46}")
    print(f"  Material for: {shape_name}")
    print(f"  {'─' * 46}")
    for key, (name, metal, rough) in MATERIAL_PRESETS.items():
        print(f"   {key}  {name:<16}  metal {metal:.2f}  rough {rough:.2f}")
    print("  Append 'a' to apply to all remaining.  Enter = Matte Plastic")

    while True:
        raw = input("  > ").strip().lower()

        if raw == "":
            return 0.0, 0.85, None, False

        if raw == "a":
            return 0.0, 0.85, None, True

        apply_all = raw.endswith("a")
        key       = raw[:-1] if apply_all else raw

        if key in MATERIAL_PRESETS:
            name, metal, rough = MATERIAL_PRESETS[key]
            label = name.lower().replace(" ", "-")
            return metal, rough, label, apply_all

        print("  Please enter p, b, m, c, or r (optionally with 'a'), Enter, or 'a'.")


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
# Geometry helpers  (used by molecule and tube builders)
# ---------------------------------------------------------------------------

def _align_to(direction, midpoint):
    """4×4 matrix: rotate Z axis to direction, translate to midpoint."""
    d = np.asarray(direction, float)
    d = d / np.linalg.norm(d)
    z = np.array([0.0, 0.0, 1.0])
    dot = float(np.clip(np.dot(z, d), -1.0, 1.0))
    if dot > 1.0 - 1e-9:
        R = np.eye(3)
    elif dot < -1.0 + 1e-9:
        R = np.diag([1.0, -1.0, -1.0])
    else:
        axis  = np.cross(z, d);  axis /= np.linalg.norm(axis)
        angle = np.arccos(dot)
        K = np.array([[ 0,        -axis[2],  axis[1]],
                      [ axis[2],   0,        -axis[0]],
                      [-axis[1],   axis[0],   0      ]])
        R = np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)
    T = np.eye(4);  T[:3, :3] = R;  T[:3, 3] = midpoint
    return T


def _bond(p0, p1, radius=0.028):
    """Cylinder mesh connecting two 3D points."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    v      = p1 - p0
    cyl    = trimesh.creation.cylinder(radius=radius,
                                       height=float(np.linalg.norm(v)),
                                       sections=10)
    cyl.apply_transform(_align_to(v, (p0 + p1) * 0.5))
    return cyl


def _tube(pts, radius, sections=14, closed=True):
    """Sweep a circular cross-section along a 3D path.
    Returns (trimesh.Trimesh, uv_array) where uv is per-vertex.
    """
    pts = np.asarray(pts, float)
    N   = len(pts)

    # Tangents via central differences
    if closed:
        tang = np.roll(pts, -1, axis=0) - np.roll(pts, 1, axis=0)
    else:
        tang = np.zeros_like(pts)
        tang[1:-1] = pts[2:] - pts[:-2]
        tang[0]    = pts[1]  - pts[0]
        tang[-1]   = pts[-1] - pts[-2]
    nrm  = np.linalg.norm(tang, axis=1, keepdims=True)
    tang /= np.where(nrm > 1e-10, nrm, 1.0)

    # Rotation-minimizing (parallel-transport) frame
    ref = np.array([0, 0, 1.0]) if abs(tang[0, 2]) < 0.9 else np.array([1, 0, 0.0])
    n0  = np.cross(tang[0], ref);  n0 /= np.linalg.norm(n0)
    normals = [n0]
    for i in range(1, N):
        v  = pts[i] - pts[i - 1]
        c1 = float(np.dot(v, v))
        if c1 > 1e-12:
            nL = normals[-1] - (2 / c1) * np.dot(v, normals[-1]) * v
            tL = tang[i - 1]  - (2 / c1) * np.dot(v, tang[i - 1])  * v
            v2 = tang[i] - tL;  c2 = float(np.dot(v2, v2))
            n  = nL - (2 / c2) * np.dot(v2, nL) * v2 if c2 > 1e-12 else nL
        else:
            n = normals[-1]
        normals.append(n / np.linalg.norm(n))
    normals = np.array(normals)
    binorm  = np.cross(tang, normals)

    # Ring vertices
    theta = np.linspace(0, 2 * np.pi, sections, endpoint=False)
    ct, st = np.cos(theta), np.sin(theta)
    rings = (pts[:, None, :]
             + radius * (ct[None, :, None] * normals[:, None, :]
                         + st[None, :, None] * binorm[:, None, :]))
    verts = rings.reshape(-1, 3)

    # Quad faces
    faces = []
    Nf = N if closed else N - 1
    for i in range(Nf):
        ni = (i + 1) % N
        for j in range(sections):
            nj = (j + 1) % sections
            a, b = i * sections + j,  ni * sections + j
            c, d = ni * sections + nj, i * sections + nj
            faces += [[a, b, c], [a, c, d]]
    mesh = trimesh.Trimesh(vertices=verts, faces=np.array(faces), process=True)

    # UVs: u along path, v around tube (both per vertex)
    u_vals = np.arange(N) / (N if closed else N - 1)
    uv = np.column_stack([np.repeat(u_vals, sections),
                          np.tile(np.arange(sections) / sections, N)])
    return mesh, uv


# ---------------------------------------------------------------------------
# Mesh builders  — return (mesh, uv, gray_array) tuples
# ---------------------------------------------------------------------------

def apply_texture(mesh, uv, png_bytes, metalness=0.0, roughness=0.85):
    mat = trimesh.visual.material.PBRMaterial(
        baseColorTexture=Image.open(io.BytesIO(png_bytes)).convert("RGB"),
        metallicFactor=metalness,
        roughnessFactor=roughness,
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

# ---------------------------------------------------------------------------
# Molecule builders
# ---------------------------------------------------------------------------

def build_water():
    bl   = 0.38
    half = np.radians(104.5) / 2
    O    = np.zeros(3)
    H1   = np.array([ np.sin(half), -np.cos(half), 0]) * bl
    H2   = np.array([-np.sin(half), -np.cos(half), 0]) * bl
    o    = trimesh.creation.icosphere(3, 0.13)
    parts = [o]
    for H in (H1, H2):
        h = trimesh.creation.icosphere(2, 0.09);  h.apply_translation(H)
        parts += [h, _bond(O, H, 0.032)]
    mesh = trimesh.util.concatenate(parts)
    return mesh, uv_spherical(mesh.vertices), tex_radial_gradient()


def build_methane():
    bl   = 0.40
    tips = np.array([[1,1,1],[1,-1,-1],[-1,1,-1],[-1,-1,1]], float)
    tips = tips / np.linalg.norm(tips[0]) * bl
    C    = np.zeros(3)
    parts = [trimesh.creation.icosphere(3, 0.12)]
    for H in tips:
        h = trimesh.creation.icosphere(2, 0.085);  h.apply_translation(H)
        parts += [h, _bond(C, H, 0.028)]
    mesh = trimesh.util.concatenate(parts)
    return mesh, uv_spherical(mesh.vertices), tex_marble()


def build_benzene():
    Cr     = 0.33
    Hr     = 0.53
    angles = np.linspace(0, 2 * np.pi, 6, endpoint=False)
    C_pos  = np.column_stack([Cr * np.cos(angles), Cr * np.sin(angles), np.zeros(6)])
    H_pos  = np.column_stack([Hr * np.cos(angles), Hr * np.sin(angles), np.zeros(6)])
    parts  = []
    for i in range(6):
        c = trimesh.creation.icosphere(2, 0.075);  c.apply_translation(C_pos[i])
        h = trimesh.creation.icosphere(2, 0.055);  h.apply_translation(H_pos[i])
        parts += [c, h,
                  _bond(C_pos[i], H_pos[i], 0.022),
                  _bond(C_pos[i], C_pos[(i + 1) % 6], 0.027)]
    mesh = trimesh.util.concatenate(parts)
    return mesh, uv_box(mesh), tex_angular_stripes()


def _dna_strand_points(turns, n_pts, helix_r, height, phase):
    t = np.linspace(0, turns * 2 * np.pi, n_pts, endpoint=False)
    z = np.linspace(-height / 2, height / 2, n_pts)
    return np.column_stack([helix_r * np.cos(t + phase),
                            helix_r * np.sin(t + phase),
                            z])


def build_dna():
    turns, n_pts, n_rungs   = 2.5, 200, 10
    helix_r, tube_r, rung_r = 0.25, 0.04, 0.025
    height                  = 1.0

    a_pts = _dna_strand_points(turns, n_pts, helix_r, height, 0.0)
    b_pts = _dna_strand_points(turns, n_pts, helix_r, height, np.pi)

    mesh_a, _ = _tube(a_pts, tube_r, sections=12, closed=False)
    mesh_b, _ = _tube(b_pts, tube_r, sections=12, closed=False)

    rung_idx = np.linspace(0, n_pts - 1, n_rungs, dtype=int)
    rungs    = [_bond(a_pts[i], b_pts[i], rung_r) for i in rung_idx]

    mesh = trimesh.util.concatenate([mesh_a, mesh_b] + rungs)
    return mesh, uv_cylindrical(mesh.vertices), tex_spiral()


# ---------------------------------------------------------------------------
# Mathematical shape builders
# ---------------------------------------------------------------------------

def build_trefoil():
    t   = np.linspace(0, 2 * np.pi, 180, endpoint=False)
    pts = np.column_stack([np.sin(t) + 2 * np.sin(2 * t),
                           np.cos(t) - 2 * np.cos(2 * t),
                           -np.sin(3 * t)])
    pts = pts / np.abs(pts).max() * 0.55
    mesh, uv = _tube(pts, 0.055, sections=14, closed=True)
    return mesh, uv, tex_diagonal_stripes()


def build_helix():
    turns = 3
    t     = np.linspace(0, turns * 2 * np.pi, 200, endpoint=False)
    r, pitch = 0.38, 0.16
    pts   = np.column_stack([r * np.cos(t),
                              r * np.sin(t),
                              pitch * t / (2 * np.pi) - pitch * turns / 2])
    mesh, uv = _tube(pts, 0.055, sections=12, closed=False)
    return mesh, uv, tex_wood_grain()


def build_hyperboloid():
    U, V  = 64, 32
    a, c  = 0.26, 0.52
    t_max = 1.15
    u     = np.linspace(0, 2 * np.pi, U, endpoint=False)
    v     = np.linspace(-t_max, t_max, V)
    uu, vv = np.meshgrid(u, v)
    x = a * np.cosh(vv) * np.cos(uu)
    y = a * np.cosh(vv) * np.sin(uu)
    z = c * np.sinh(vv)
    verts  = np.column_stack([x.ravel(), y.ravel(), z.ravel()])
    uv_arr = np.column_stack([uu.ravel() / (2 * np.pi),
                               (vv.ravel() - vv.min()) / (vv.max() - vv.min())])
    faces  = []
    for i in range(V - 1):
        for j in range(U):
            nj = (j + 1) % U
            a_i, b_i = i*U+j,     i*U+nj
            c_i, d_i = (i+1)*U+nj, (i+1)*U+j
            faces += [[a_i, b_i, c_i], [a_i, c_i, d_i]]
    mesh = trimesh.Trimesh(vertices=verts, faces=np.array(faces), process=True)
    return mesh, uv_arr, tex_concentric_rings()


# ---------------------------------------------------------------------------
# Buckyball builders  (icospheres at three resolutions)
# ---------------------------------------------------------------------------

def build_buckyball_162():
    mesh = trimesh.creation.icosphere(subdivisions=2, radius=0.6)
    return mesh, uv_spherical(mesh.vertices), tex_marble()

def build_buckyball_642():
    mesh = trimesh.creation.icosphere(subdivisions=3, radius=0.6)
    return mesh, uv_spherical(mesh.vertices), tex_concentric_rings()

def build_buckyball_2562():
    mesh = trimesh.creation.icosphere(subdivisions=4, radius=0.6)
    return mesh, uv_spherical(mesh.vertices), tex_spiral()


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
# Molecule scene builders  (C1 / C2 palette variants only)
#
# Each returns a trimesh.Scene with three solid-colour nodes:
#   "heavy"    — O or C spheres   (root mesh)
#   "hydrogen" — H spheres        (parented to "heavy")
#   "bonds"    — all bond cylinders (parented to "heavy")
#
# Parenting "hydrogen" and "bonds" to "heavy" mirrors how the robot's GLB is
# structured (hips as the root mesh with everything else descending from it).
# On import, ThreeDViewport's GLTFLoader sees one root mesh and two children,
# renames the root to the filename basename, and the whole molecule appears as
# a single hierarchical object in the scene HUD instead of three siblings.
# All three meshes are pre-positioned in scene coordinates and the parent's
# local transform is identity, so the children render in place without any
# additional translation.
# ---------------------------------------------------------------------------

def _apply_solid_color(mesh, rgb, metalness, roughness):
    r, g, b = [c / 255.0 for c in rgb]
    mat = trimesh.visual.material.PBRMaterial(
        baseColorFactor=[r, g, b, 1.0],
        metallicFactor=metalness,
        roughnessFactor=roughness,
    )
    # trimesh's glTF exporter only emits the NORMAL accessor if vertex_normals
    # has been materialised in the mesh cache.  Touch it here so molecule scenes
    # ship as POSITION+NORMAL rather than positions-only.  Dummy UVs alone are
    # not enough — verified empirically.
    _ = mesh.vertex_normals
    uv = np.zeros((len(mesh.vertices), 2), dtype=np.float32)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)


def build_water_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness):
    bl   = 0.38
    half = np.radians(104.5) / 2
    O    = np.zeros(3)
    H1   = np.array([ np.sin(half), -np.cos(half), 0.0]) * bl
    H2   = np.array([-np.sin(half), -np.cos(half), 0.0]) * bl

    o_mesh = trimesh.creation.icosphere(3, 0.13)

    h1 = trimesh.creation.icosphere(2, 0.09);  h1.apply_translation(H1)
    h2 = trimesh.creation.icosphere(2, 0.09);  h2.apply_translation(H2)
    h_mesh = trimesh.util.concatenate([h1, h2])

    b_mesh = trimesh.util.concatenate([_bond(O, H1, 0.032), _bond(O, H2, 0.032)])

    _apply_solid_color(o_mesh, heavy_rgb, metalness, roughness)
    _apply_solid_color(h_mesh, h_rgb,     metalness, roughness)
    _apply_solid_color(b_mesh, bond_rgb,  metalness, roughness)

    scene = trimesh.Scene()
    scene.add_geometry(o_mesh, node_name="heavy",    geom_name="heavy")
    scene.add_geometry(h_mesh, node_name="hydrogen", geom_name="hydrogen", parent_node_name="heavy")
    scene.add_geometry(b_mesh, node_name="bonds",    geom_name="bonds",    parent_node_name="heavy")
    return scene


def build_methane_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness):
    bl   = 0.40
    tips = np.array([[1,1,1],[1,-1,-1],[-1,1,-1],[-1,-1,1]], float)
    tips = tips / np.linalg.norm(tips[0]) * bl
    C    = np.zeros(3)

    c_mesh = trimesh.creation.icosphere(3, 0.12)

    h_parts = []
    b_parts = []
    for H in tips:
        h = trimesh.creation.icosphere(2, 0.085);  h.apply_translation(H)
        h_parts.append(h)
        b_parts.append(_bond(C, H, 0.028))
    h_mesh = trimesh.util.concatenate(h_parts)
    b_mesh = trimesh.util.concatenate(b_parts)

    _apply_solid_color(c_mesh, heavy_rgb, metalness, roughness)
    _apply_solid_color(h_mesh, h_rgb,     metalness, roughness)
    _apply_solid_color(b_mesh, bond_rgb,  metalness, roughness)

    scene = trimesh.Scene()
    scene.add_geometry(c_mesh, node_name="heavy",    geom_name="heavy")
    scene.add_geometry(h_mesh, node_name="hydrogen", geom_name="hydrogen", parent_node_name="heavy")
    scene.add_geometry(b_mesh, node_name="bonds",    geom_name="bonds",    parent_node_name="heavy")
    return scene


def build_benzene_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness):
    Cr     = 0.33
    Hr     = 0.53
    angles = np.linspace(0, 2 * np.pi, 6, endpoint=False)
    C_pos  = np.column_stack([Cr * np.cos(angles), Cr * np.sin(angles), np.zeros(6)])
    H_pos  = np.column_stack([Hr * np.cos(angles), Hr * np.sin(angles), np.zeros(6)])

    c_parts, h_parts, b_parts = [], [], []
    for i in range(6):
        c = trimesh.creation.icosphere(2, 0.075);  c.apply_translation(C_pos[i])
        h = trimesh.creation.icosphere(2, 0.055);  h.apply_translation(H_pos[i])
        c_parts.append(c)
        h_parts.append(h)
        b_parts.append(_bond(C_pos[i], H_pos[i], 0.022))
        b_parts.append(_bond(C_pos[i], C_pos[(i + 1) % 6], 0.027))

    c_mesh = trimesh.util.concatenate(c_parts)
    h_mesh = trimesh.util.concatenate(h_parts)
    b_mesh = trimesh.util.concatenate(b_parts)

    _apply_solid_color(c_mesh, heavy_rgb, metalness, roughness)
    _apply_solid_color(h_mesh, h_rgb,     metalness, roughness)
    _apply_solid_color(b_mesh, bond_rgb,  metalness, roughness)

    scene = trimesh.Scene()
    scene.add_geometry(c_mesh, node_name="heavy",    geom_name="heavy")
    scene.add_geometry(h_mesh, node_name="hydrogen", geom_name="hydrogen", parent_node_name="heavy")
    scene.add_geometry(b_mesh, node_name="bonds",    geom_name="bonds",    parent_node_name="heavy")
    return scene


def build_dna_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness):
    turns, n_pts, n_rungs   = 2.5, 200, 10
    helix_r, tube_r, rung_r = 0.25, 0.04, 0.025
    height                  = 1.0

    a_pts = _dna_strand_points(turns, n_pts, helix_r, height, 0.0)
    b_pts = _dna_strand_points(turns, n_pts, helix_r, height, np.pi)

    mesh_a, _ = _tube(a_pts, tube_r, sections=12, closed=False)
    mesh_b, _ = _tube(b_pts, tube_r, sections=12, closed=False)
    strands_mesh = trimesh.util.concatenate([mesh_a, mesh_b])

    rung_idx   = np.linspace(0, n_pts - 1, n_rungs, dtype=int)
    rungs_mesh = trimesh.util.concatenate(
        [_bond(a_pts[i], b_pts[i], rung_r) for i in rung_idx]
    )

    _apply_solid_color(strands_mesh, heavy_rgb, metalness, roughness)
    _apply_solid_color(rungs_mesh,   h_rgb,     metalness, roughness)

    scene = trimesh.Scene()
    scene.add_geometry(strands_mesh, node_name="heavy",    geom_name="heavy")
    scene.add_geometry(rungs_mesh,   node_name="hydrogen", geom_name="hydrogen", parent_node_name="heavy")
    return scene


MOLECULE_BUILDERS = {
    "water":   build_water_scene,
    "methane":  build_methane_scene,
    "benzene":  build_benzene_scene,
    "dna":      build_dna_scene,
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SHAPES = [
    ("cube",            build_cube,            "linear gradient"),
    ("cylinder",        build_cylinder,        "radial gradient"),
    ("pyramid",         build_pyramid,         "angular stripes"),
    ("sphere",          build_sphere,          "marble"),
    ("torus",           build_torus,           "concentric rings"),
    ("tetrahedron",     build_tetrahedron,     "checkerboard"),
    ("octahedron",      build_octahedron,      "diagonal stripes"),
    ("hexprism",        build_hexprism,        "crosshatch"),
    ("capsule",         build_capsule,         "wood grain"),
    ("mobius",          build_mobius,          "spiral"),
    ("star",            build_star,            "cells"),
    ("buckyball-162",   build_buckyball_162,   "marble"),
    ("buckyball-642",   build_buckyball_642,   "concentric rings"),
    ("buckyball-2562",  build_buckyball_2562,  "spiral"),
    ("water",           build_water,           "radial gradient"),
    ("methane",         build_methane,         "marble"),
    ("benzene",         build_benzene,         "angular stripes"),
    ("dna",             build_dna,             "spiral"),
    ("trefoil",         build_trefoil,         "diagonal stripes"),
    ("helix",           build_helix,           "wood grain"),
    ("hyperboloid",     build_hyperboloid,     "concentric rings"),
]

# Maps shape names to their output subdirectory when it differs from the shape name.
# Used by generate_all.py to route files into the correct folder.
SHAPE_OUTPUT_DIRS = {
    "buckyball-162":  "buckyball",
    "buckyball-642":  "buckyball",
    "buckyball-2562": "buckyball",
}

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
    mat_locked       = False
    locked_metal     = 0.0
    locked_rough     = 0.85
    locked_mat_label = None

    for name, builder, pattern_name in SHAPES:
        print(f"\nBuilding {name}...", end=" ", flush=True)
        mesh, uv, gray = builder()

        if use_defaults or locked:
            colorizer   = locked_colorizer
            color_label = locked_label
        else:
            colorizer, apply_all, color_label = prompt_color(name, pattern_name)
            if apply_all:
                locked_colorizer = colorizer
                locked_label     = color_label
                locked           = True

        if use_defaults or mat_locked:
            metalness = locked_metal
            roughness = locked_rough
            mat_label = locked_mat_label
        else:
            metalness, roughness, mat_label, apply_all_mat = prompt_material(name)
            if apply_all_mat:
                locked_metal     = metalness
                locked_rough     = roughness
                locked_mat_label = mat_label
                mat_locked       = True
            print(f"  Building {name}...", end=" ", flush=True)

        colored  = colorizer(gray) if colorizer is not None else gray
        parts    = [p for p in [color_label, mat_label] if p]
        stem     = "-".join([name] + parts) if parts else name
        out_mesh = apply_texture(mesh, uv, make_png_bytes(colored), metalness, roughness)
        out      = os.path.join(OUTPUT_DIR, f"{stem}.glb")
        out_mesh.export(out)
        size_kb  = os.path.getsize(out) / 1024
        print(f"→ Models/{stem}.glb  ({size_kb:.1f} KB)")

    print(f"\nDone. Files written to: {OUTPUT_DIR}")
