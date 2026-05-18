"""
Generate a robot character as character.glb with a proper FK hierarchy.

Prompts for a colour palette for each of four body regions:
  Body (hips · torso · neck) · Head · Arms + Hands · Legs + Feet

Filenames include the palette choices, e.g.:
  character-sunset-c2-ocean-warm-amber-forest.glb

Output goes into a  Models/  subfolder next to this script.

Each part's node origin sits at the joint that controls it, so rotating a
node in ThreeDViewport pivots naturally around the anatomical joint.
The hierarchy exported into the GLB is:

    hips  (world root)
    ├── torso               pivot: hip-spine joint  [0, 0.145, 0]
    │   ├── chest_panel
    │   ├── neck            pivot: top of torso     [0, 0.60, 0]
    │   │   └── head        pivot: top of neck      [0, 0.69, 0]
    │   │       ├── visor, eye_L, eye_R
    │   │       ├── ear_L, ear_R
    │   │       ├── antenna_pole, antenna_ball
    │   ├── shoulder_L/R    pivot: shoulder joint   [±0.305, 0.565, 0]
    │   │   └── upper_arm_L/R  (same pivot as shoulder)
    │   │       └── elbow_L/R  pivot: elbow joint   [±0.305, 0.215, 0]
    │   │           └── forearm_L/R  (same pivot as elbow)
    │   │               └── hand_L/R  pivot: wrist  [±0.305, -0.025, 0]
    ├── upper_leg_L/R       pivot: hip-leg joint    [±0.135, -0.025, 0]
    │   └── knee_L/R        pivot: knee joint       [±0.135, -0.325, 0]
    │       └── lower_leg_L/R  (same pivot as knee)
    │           └── ankle_L/R  pivot: ankle joint   [±0.135, -0.625, 0]
    │               └── foot_L/R  (same pivot as ankle)

Usage:
    /tmp/glb_env/bin/python3 generate_character.py       # interactive prompts
    /tmp/glb_env/bin/python3 generate_character.py -y    # default greyscale
"""

import io
import os
import sys

import numpy as np
import trimesh
import trimesh.transformations as tf
import trimesh.visual.material
from PIL import Image

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "Models")
TEX = 256  # texture resolution


# ---------------------------------------------------------------------------
# Colour / tonal options  (shared with generate_models.py)
# ---------------------------------------------------------------------------

GREY_RANGES = {
    "1": ("Dark",       ( 10,  90)),
    "2": ("Dark-Mid",   ( 40, 150)),
    "3": ("Mid",        ( 80, 180)),
    "4": ("Mid-Bright", (130, 220)),
    "5": ("Bright",     (180, 255)),
    "6": ("Wide",       (  0, 255)),
}

# Each entry: (display_name, base_stops, comp1_rgb, (comp2_dark_rgb, comp2_mid_rgb))
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
    stop_colors = np.array([s[1] for s in stops], dtype=np.float32)

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
    Show the colour/tone selection menu for one body region.
    Returns (colorizer_fn | None, apply_all: bool, label: str | None).

    colorizer_fn: takes a 2D uint8 greyscale array, returns 2D or H×W×3 uint8.
                  None = keep default greyscale.
    apply_all:    True = apply this choice to all remaining regions too.
    label:        short string used in the output filename, or None for default.
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

        if raw == "":
            return None, False, None

        if raw == "a":
            return None, True, None

        apply_all = raw.endswith("a")
        key_part  = raw[:-1] if apply_all else raw

        variant = "normal"
        if key_part.endswith("c2"):
            variant  = "c2"
            key_part = key_part[:-2]
        elif key_part.endswith("c1"):
            variant  = "c1"
            key_part = key_part[:-2]

        if key_part in GREY_RANGES:
            name_str, (low, high) = GREY_RANGES[key_part]
            label = name_str.lower().replace(" ", "-")
            fn = lambda g, lo=low, hi=high: apply_tonal_range(g, lo, hi)
            return fn, apply_all, label

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
# PNG helpers
# ---------------------------------------------------------------------------

def _png(arr):
    """Convert a 2D greyscale or H×W×3 RGB uint8 array to PNG bytes."""
    if arr.ndim == 3:
        img = Image.fromarray(arr.astype(np.uint8), "RGB")
    else:
        img = Image.fromarray(arr.astype(np.uint8), "L").convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def colorize(grey, fn):
    """Apply colorizer fn (or None = identity) to a greyscale array."""
    return grey if fn is None else fn(grey)


# ─────────────────────────────────────────────────────────────── textures ──

def tex_metal_panels(size=TEX):
    """Riveted-panel look: dark recessed grid, lighter face."""
    y, x = np.mgrid[:size, :size]
    cell = size // 6
    gx = ((x % cell) / cell * 2 * np.pi)
    gy = ((y % cell) / cell * 2 * np.pi)
    seam = np.maximum(
        np.exp(-((gx - np.pi) ** 2) / 0.6),
        np.exp(-((gy - np.pi) ** 2) / 0.6),
    )
    face = 0.62 + 0.08 * np.sin(x / 28) * np.cos(y / 28)
    val = face - seam * 0.35
    return (np.clip(val, 0, 1) * 255).astype(np.uint8)


def tex_head(size=TEX):
    """Smooth gradient face plate."""
    y, x = np.mgrid[:size, :size]
    cx, cy = size / 2, size / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / (size / 2)
    val = 0.78 - 0.25 * r ** 2 + 0.05 * np.sin(x / 20) * np.sin(y / 20)
    return (np.clip(val, 0, 1) * 255).astype(np.uint8)


def tex_visor(size=TEX):
    """Dark glassy visor with a central highlight streak."""
    y, x = np.ogrid[:size, :size]
    cx = size / 2
    cy = size / 2 * 0.4
    r = np.sqrt(((x - cx) / (size * 0.7)) ** 2 + ((y - cy) / (size * 0.25)) ** 2)
    val = 0.15 + 0.55 * np.exp(-(r ** 2) / 0.15)
    return (np.clip(val, 0, 1) * 255).astype(np.uint8)


def tex_joint(size=TEX):
    """Dark ribbed joint material."""
    y, x = np.mgrid[:size, :size]
    ribs = np.sin(y / (size / 14) * np.pi) * 0.25 + 0.38
    return (np.clip(ribs, 0, 1) * 255).astype(np.uint8)


def tex_glow(size=TEX):
    """Bright radial glow for antenna tip and eye LEDs."""
    y, x = np.ogrid[:size, :size]
    cx, cy = size / 2, size / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / (size / 2)
    val = np.exp(-(r ** 2) / 0.2)
    return (np.clip(val, 0, 1) * 255).astype(np.uint8)


def tex_foot(size=TEX):
    """Slightly lighter with tread-like horizontal grooves."""
    y, x = np.mgrid[:size, :size]
    tread = np.abs(np.sin(y / (size / 10) * np.pi)) * 0.2 + 0.5
    return (np.clip(tread, 0, 1) * 255).astype(np.uint8)


# ──────────────────────────────────────────────────────────── UV helpers ──

def uv_sphere(verts):
    x, y, z = verts[:, 0], verts[:, 1], verts[:, 2]
    r = np.sqrt(x ** 2 + y ** 2 + z ** 2)
    r = np.where(r > 1e-6, r, 1.0)
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = np.arccos(np.clip(z / r, -1, 1)) / np.pi
    return np.column_stack([u, v])


def uv_cylinder(verts):
    """Cylindrical UV on a Z-axis cylinder (before any rotation)."""
    x, y, z = verts[:, 0], verts[:, 1], verts[:, 2]
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = (z - z.min()) / max(z.max() - z.min(), 1e-6)
    return np.column_stack([u, v])


def uv_box(mesh):
    verts = mesh.vertices[mesh.faces]
    normals = mesh.face_normals
    uvs = np.zeros((len(mesh.faces) * 3, 2))
    for i, (tri, n) in enumerate(zip(verts, normals)):
        dom = np.argmax(np.abs(n))
        axes = [a for a in range(3) if a != dom]
        local = tri[:, axes]
        lo, hi = local.min(0), local.max(0)
        rng = np.where(hi - lo > 1e-6, hi - lo, 1.0)
        uvs[i * 3: i * 3 + 3] = (local - lo) / rng
    return uvs


# ─────────────────────────────────────────────────────── mesh primitives ──

def textured(mesh, png_bytes, uv_fn=None, metalness=0.0, roughness=0.8,
             emissive_png=None, emissive_factor=None):
    """Apply a PBR material + UV map to a mesh in-place."""
    mat = trimesh.visual.material.PBRMaterial(
        baseColorTexture=Image.open(io.BytesIO(png_bytes)).convert("RGB"),
        metallicFactor=metalness,
        roughnessFactor=roughness,
        emissiveTexture=Image.open(io.BytesIO(emissive_png)).convert("RGB") if emissive_png else None,
        emissiveFactor=emissive_factor,
    )
    uv = uv_fn(mesh) if uv_fn else uv_box(mesh)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)
    return mesh


# ──────────────────────────────────────────────────────── character build ──

# Per-surface PBR defaults passed as keyword args to textured()
_METAL = dict(metalness=0.80, roughness=0.45)
_HEAD  = dict(metalness=0.50, roughness=0.50)
_GLASS = dict(metalness=0.00, roughness=0.08)
_JOINT = dict(metalness=0.05, roughness=0.88)
_FOOT  = dict(metalness=0.05, roughness=0.92)


def _GLOW(emissive_png):
    return dict(metalness=0.00, roughness=1.00,
                emissive_png=emissive_png, emissive_factor=[1.0, 1.0, 1.0])


def build_robot(body_fn=None, head_fn=None, arm_fn=None, leg_fn=None):
    """
    Build the robot scene.

    body_fn / head_fn / arm_fn / leg_fn:
        Colorizer functions (greyscale array → greyscale or RGB array),
        or None for default greyscale.

    Body region assignments
    ───────────────────────
    body:  hips, torso, chest_panel, neck
    head:  head sphere, face visor, ears, antenna pole + ball, eye LEDs
    arm:   shoulder, upper arm, elbow, forearm, hand
    leg:   upper leg, knee, lower leg, ankle, foot
    """
    scene = trimesh.Scene()

    # ── Base greyscale textures ───────────────────────────────────────────
    G_metal = tex_metal_panels()
    G_head  = tex_head()
    G_visor = tex_visor()
    G_joint = tex_joint()
    G_glow  = tex_glow()
    G_foot  = tex_foot()

    # ── Per-region coloured textures ──────────────────────────────────────
    # Body
    T_body_metal = _png(colorize(G_metal, body_fn))   # hips, torso
    T_body_visor = _png(colorize(G_visor, body_fn))   # chest_panel
    T_body_joint = _png(colorize(G_joint, body_fn))   # neck

    # Head
    T_head_main  = _png(colorize(G_head,  head_fn))   # head sphere
    T_head_visor = _png(colorize(G_visor, head_fn))   # face visor
    T_head_joint = _png(colorize(G_joint, head_fn))   # ears, antenna pole
    T_head_glow  = _png(colorize(G_glow,  head_fn))   # eye LEDs, antenna ball

    # Arms + Hands
    T_arm_metal  = _png(colorize(G_metal, arm_fn))    # shoulder, upper arm, forearm
    T_arm_joint  = _png(colorize(G_joint, arm_fn))    # elbow, hand

    # Legs + Feet
    T_leg_metal  = _png(colorize(G_metal, leg_fn))    # upper leg, lower leg
    T_leg_joint  = _png(colorize(G_joint, leg_fn))    # knee, ankle
    T_leg_foot   = _png(colorize(G_foot,  leg_fn))    # foot

    def tr(xyz):
        return tf.translation_matrix(xyz)

    def add(name, mesh, parent=None, node_xyz=None, mesh_xyz=None):
        if mesh_xyz is not None and not np.allclose(mesh_xyz, 0):
            mesh.apply_transform(tr(mesh_xyz))
        node_tf = tr(node_xyz) if node_xyz is not None else np.eye(4)
        kwargs  = {"geom_name": name, "transform": node_tf}
        if parent is not None:
            kwargs["parent_node_name"] = parent
        scene.add_geometry(mesh, node_name=name, **kwargs)

    # ── HIPS ─────────────────────────────────────────────────────────────
    hips = trimesh.creation.box([0.40, 0.13, 0.24])
    textured(hips, T_body_metal, uv_box, **_METAL)
    add("hips", hips, parent=None, node_xyz=[0, 0.08, 0], mesh_xyz=None)

    # ── TORSO ────────────────────────────────────────────────────────────
    torso = trimesh.creation.box([0.44, 0.46, 0.27])
    textured(torso, T_body_metal, uv_box, **_METAL)
    add("torso", torso, "hips", [0, 0.065, 0], [0, 0.230, 0])

    panel = trimesh.creation.box([0.26, 0.22, 0.025])
    textured(panel, T_body_visor, uv_box, **_GLASS)
    add("chest_panel", panel, "torso", [0, 0, 0], [0, 0.245, 0.148])

    # ── NECK ─────────────────────────────────────────────────────────────
    neck = trimesh.creation.cylinder(radius=0.065, height=0.09, sections=12)
    textured(neck, T_body_joint, lambda m: uv_cylinder(m.vertices), **_JOINT)
    add("neck", neck, "torso", [0, 0.455, 0], [0, 0.045, 0])

    # ── HEAD ─────────────────────────────────────────────────────────────
    head = trimesh.creation.icosphere(3, radius=0.185)
    textured(head, T_head_main, lambda m: uv_sphere(m.vertices), **_HEAD)
    add("head", head, "neck", [0, 0.09, 0], [0, 0.190, 0])

    visor = trimesh.creation.icosphere(3, radius=0.12)
    visor.apply_scale([1.5, 0.55, 0.25])
    textured(visor, T_head_visor, lambda m: uv_sphere(m.vertices), **_GLASS)
    add("visor", visor, "head", [0, 0, 0], [0, 0.185, 0.155])

    for label, ex in [("eye_L", -0.065), ("eye_R", 0.065)]:
        eye = trimesh.creation.icosphere(2, radius=0.025)
        textured(eye, T_head_glow, lambda m: uv_sphere(m.vertices), **_GLOW(T_head_glow))
        add(label, eye, "head", [0, 0, 0], [ex, 0.195, 0.185])

    for label, sx in [("ear_L", -1), ("ear_R", 1)]:
        ear = trimesh.creation.cylinder(radius=0.03, height=0.04, sections=8)
        textured(ear, T_head_joint, lambda m: uv_cylinder(m.vertices), **_JOINT)
        ear.apply_transform(tf.rotation_matrix(np.radians(90), [0, 1, 0]))
        add(label, ear, "head", [0, 0, 0], [sx * 0.21, 0.190, 0])

    pole = trimesh.creation.cylinder(radius=0.014, height=0.13, sections=8)
    textured(pole, T_head_joint, lambda m: uv_cylinder(m.vertices), **_METAL)
    add("antenna_pole", pole, "head", [0, 0, 0], [0, 0.410, 0])

    ball = trimesh.creation.icosphere(2, radius=0.038)
    textured(ball, T_head_glow, lambda m: uv_sphere(m.vertices), **_GLOW(T_head_glow))
    add("antenna_ball", ball, "head", [0, 0, 0], [0, 0.495, 0])

    # ── ARMS & LEGS (mirrored L / R) ─────────────────────────────────────
    for side, sx in [("L", -1), ("R", 1)]:

        # ── Shoulder sphere ───────────────────────────────────────────────
        sh = trimesh.creation.icosphere(2, radius=0.105)
        textured(sh, T_arm_metal, lambda m: uv_sphere(m.vertices), **_METAL)
        add(f"shoulder_{side}", sh, "torso", [sx * 0.305, 0.420, 0], None)

        # ── Upper arm ─────────────────────────────────────────────────────
        ua = trimesh.creation.cylinder(radius=0.068, height=0.24, sections=12)
        textured(ua, T_arm_metal, lambda m: uv_cylinder(m.vertices), **_METAL)
        ua.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"upper_arm_{side}", ua, f"shoulder_{side}", [0, 0, 0], [0, -0.210, 0])

        # ── Elbow sphere ──────────────────────────────────────────────────
        el = trimesh.creation.icosphere(2, radius=0.075)
        textured(el, T_arm_joint, lambda m: uv_sphere(m.vertices), **_JOINT)
        add(f"elbow_{side}", el, f"upper_arm_{side}", [0, -0.350, 0], None)

        # ── Forearm ───────────────────────────────────────────────────────
        fa = trimesh.creation.cylinder(radius=0.057, height=0.22, sections=12)
        textured(fa, T_arm_metal, lambda m: uv_cylinder(m.vertices), **_METAL)
        fa.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"forearm_{side}", fa, f"elbow_{side}", [0, 0, 0], [0, -0.130, 0])

        # ── Hand ──────────────────────────────────────────────────────────
        hand = trimesh.creation.box([0.105, 0.13, 0.085])
        textured(hand, T_arm_joint, uv_box, **_JOINT)
        add(f"hand_{side}", hand, f"forearm_{side}", [0, -0.240, 0], [0, -0.065, 0])

        # ── Upper leg ─────────────────────────────────────────────────────
        ul = trimesh.creation.cylinder(radius=0.085, height=0.28, sections=12)
        textured(ul, T_leg_metal, lambda m: uv_cylinder(m.vertices), **_METAL)
        ul.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"upper_leg_{side}", ul, "hips", [sx * 0.135, -0.105, 0], [0, -0.140, 0])

        # ── Knee sphere ───────────────────────────────────────────────────
        kn = trimesh.creation.icosphere(2, radius=0.09)
        textured(kn, T_leg_joint, lambda m: uv_sphere(m.vertices), **_JOINT)
        add(f"knee_{side}", kn, f"upper_leg_{side}", [0, -0.300, 0], None)

        # ── Lower leg ─────────────────────────────────────────────────────
        ll = trimesh.creation.cylinder(radius=0.072, height=0.27, sections=12)
        textured(ll, T_leg_metal, lambda m: uv_cylinder(m.vertices), **_METAL)
        ll.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"lower_leg_{side}", ll, f"knee_{side}", [0, 0, 0], [0, -0.150, 0])

        # ── Ankle sphere ──────────────────────────────────────────────────
        an = trimesh.creation.icosphere(2, radius=0.065)
        textured(an, T_leg_joint, lambda m: uv_sphere(m.vertices), **_JOINT)
        add(f"ankle_{side}", an, f"lower_leg_{side}", [0, -0.300, 0], None)

        # ── Foot ──────────────────────────────────────────────────────────
        foot = trimesh.creation.box([0.13, 0.085, 0.22])
        textured(foot, T_leg_foot, uv_box, **_FOOT)
        add(f"foot_{side}", foot, f"ankle_{side}", [0, 0, 0], [0, -0.060, 0.040])

    return scene


# ───────────────────────────────────────────────────────────────── main ──

if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    use_defaults = "-y" in sys.argv

    if use_defaults:
        body_fn = head_fn = arm_fn = leg_fn = None
        body_label = head_label = arm_label = leg_label = None
    else:
        print("\n  Colour choices apply to the baseColor texture embedded in each .glb.")
        print(f"  Output folder: {OUTPUT_DIR}")

        remaining = [None]  # set to (fn, label) once an 'a' choice is made

        def get_color(shape_name, pattern_name):
            if remaining[0] is not None:
                return remaining[0]
            fn, apply_all, label = prompt_color(shape_name, pattern_name)
            if apply_all:
                remaining[0] = (fn, label)
            return fn, label

        body_fn, body_label = get_color("Body",        "hips · torso · neck")
        head_fn, head_label = get_color("Head",        "head · visor · ears · antenna")
        arm_fn,  arm_label  = get_color("Arms + Hands","shoulder · upper arm · forearm · hand")
        leg_fn,  leg_label  = get_color("Legs + Feet", "upper leg · knee · lower leg · foot")

    # ── Build filename ────────────────────────────────────────────────────
    labels = [l for l in [body_label, head_label, arm_label, leg_label] if l]
    stem   = "-".join(["character"] + labels) if labels else "character"
    out    = os.path.join(OUTPUT_DIR, f"{stem}.glb")

    print(f"\nBuilding robot character...", end=" ", flush=True)
    scene = build_robot(body_fn, head_fn, arm_fn, leg_fn)
    scene.export(out)
    size_kb  = os.path.getsize(out) / 1024
    rel_path = os.path.relpath(out, SCRIPT_DIR)
    print(f"→ {rel_path}  ({size_kb:.1f} KB)")

    # ── Scene graph verification ──────────────────────────────────────────
    print(f"\n   Scene graph ({len(scene.graph.nodes)} nodes):")
    for node in scene.graph.nodes:
        t, g = scene.graph[node]
        parent = None
        for edge in scene.graph.transforms.edge_data:
            if edge[1] == node and edge[0] != "world":
                parent = edge[0]
                break
        indent = "  " if parent else ""
        label  = f"'{node}'" + (f"  ← '{parent}'" if parent else "  [root]")
        print(f"     {indent}• {label}")
