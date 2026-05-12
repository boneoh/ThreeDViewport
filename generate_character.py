"""
Generate a robot character as character.glb.

The robot is built from primitive shapes (spheres, cylinders, boxes) with
greyscale textures, assembled into a trimesh Scene with named nodes so
individual parts can be animated independently in ThreeDViewport.

The character stands ~2 units tall, Y-up, centred at the origin.

Usage:
    /tmp/glb_env/bin/python3 generate_character.py
"""

import io
import os

import numpy as np
import trimesh
import trimesh.transformations as tf
from PIL import Image

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
TEX = 256  # texture resolution


# ─────────────────────────────────────────────────────────────── textures ──

def _png(arr):
    img = Image.fromarray(arr.astype(np.uint8), "L").convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


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

def textured(mesh, png_bytes, uv_fn=None):
    """Apply a greyscale texture + UV map to a mesh in-place."""
    mat = trimesh.visual.texture.SimpleMaterial(
        image=Image.open(io.BytesIO(png_bytes)).convert("RGB")
    )
    uv = uv_fn(mesh) if uv_fn else uv_box(mesh)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)
    return mesh


def moved(mesh, xyz):
    mesh.apply_transform(tf.translation_matrix(xyz))
    return mesh


def rotated(mesh, angle_deg, axis):
    mesh.apply_transform(tf.rotation_matrix(np.radians(angle_deg), axis))
    return mesh


def cyl(r, h, sections=16):
    """Cylinder along Z — caller rotates to desired orientation."""
    return trimesh.creation.cylinder(radius=r, height=h, sections=sections)


# ──────────────────────────────────────────────────────── character build ──

def build_robot():
    scene = trimesh.Scene()

    # Pre-bake all textures once
    T_metal = _png(tex_metal_panels())
    T_head  = _png(tex_head())
    T_visor = _png(tex_visor())
    T_joint = _png(tex_joint())
    T_glow  = _png(tex_glow())
    T_foot  = _png(tex_foot())

    def add(name, mesh):
        scene.add_geometry(mesh, node_name=name, geom_name=name)

    # ── HEAD ──────────────────────────────────────────────────────────────
    head = trimesh.creation.icosphere(3, radius=0.185)
    textured(head, T_head, lambda m: uv_sphere(m.vertices))
    add("head", moved(head, [0, 0.88, 0]))

    # Visor — flattened ellipsoid pressed against the face
    visor = trimesh.creation.icosphere(3, radius=0.12)
    visor.apply_scale([1.5, 0.55, 0.25])
    textured(visor, T_visor, lambda m: uv_sphere(m.vertices))
    add("visor", moved(visor, [0, 0.875, 0.155]))

    # Eye LEDs
    for label, ex in [("eye_L", -0.065), ("eye_R", 0.065)]:
        eye = trimesh.creation.icosphere(2, radius=0.025)
        textured(eye, T_glow, lambda m: uv_sphere(m.vertices))
        add(label, moved(eye, [ex, 0.885, 0.185]))

    # Ear nubs
    for label, sx in [("ear_L", -1), ("ear_R", 1)]:
        ear = cyl(0.03, 0.04, 8)
        textured(ear, T_joint, lambda m: uv_cylinder(m.vertices))
        rotated(ear, 90, [0, 1, 0])
        add(label, moved(ear, [sx * 0.21, 0.88, 0]))

    # Antenna pole + glowing tip
    pole = cyl(0.014, 0.13, 8)
    textured(pole, T_joint, lambda m: uv_cylinder(m.vertices))
    add("antenna_pole", moved(pole, [0, 1.10, 0]))

    ball = trimesh.creation.icosphere(2, radius=0.038)
    textured(ball, T_glow, lambda m: uv_sphere(m.vertices))
    add("antenna_ball", moved(ball, [0, 1.185, 0]))

    # ── NECK ──────────────────────────────────────────────────────────────
    neck = cyl(0.065, 0.09, 12)
    textured(neck, T_joint, lambda m: uv_cylinder(m.vertices))
    add("neck", moved(neck, [0, 0.645, 0]))

    # ── TORSO ─────────────────────────────────────────────────────────────
    torso = trimesh.creation.box([0.44, 0.46, 0.27])
    textured(torso, T_metal, uv_box)
    add("torso", moved(torso, [0, 0.375, 0]))

    # Chest inset panel (glassy)
    panel = trimesh.creation.box([0.26, 0.22, 0.025])
    textured(panel, T_visor, uv_box)
    add("chest_panel", moved(panel, [0, 0.39, 0.148]))

    # ── HIPS ──────────────────────────────────────────────────────────────
    hips = trimesh.creation.box([0.40, 0.13, 0.24])
    textured(hips, T_metal, uv_box)
    add("hips", moved(hips, [0, 0.08, 0]))

    # ── ARMS & LEGS (mirrored L / R) ──────────────────────────────────────
    for side, sx in [("L", -1), ("R", 1)]:

        # Shoulder
        sh = trimesh.creation.icosphere(2, radius=0.105)
        textured(sh, T_metal, lambda m: uv_sphere(m.vertices))
        add(f"shoulder_{side}", moved(sh, [sx * 0.305, 0.565, 0]))

        # Upper arm (cylinder rotated to Y-axis)
        ua = cyl(0.068, 0.24, 12)
        textured(ua, T_metal, lambda m: uv_cylinder(m.vertices))
        rotated(ua, 90, [1, 0, 0])
        add(f"upper_arm_{side}", moved(ua, [sx * 0.305, 0.355, 0]))

        # Elbow joint
        el = trimesh.creation.icosphere(2, radius=0.075)
        textured(el, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"elbow_{side}", moved(el, [sx * 0.305, 0.215, 0]))

        # Forearm
        fa = cyl(0.057, 0.22, 12)
        textured(fa, T_metal, lambda m: uv_cylinder(m.vertices))
        rotated(fa, 90, [1, 0, 0])
        add(f"forearm_{side}", moved(fa, [sx * 0.305, 0.085, 0]))

        # Hand
        hand = trimesh.creation.box([0.105, 0.13, 0.085])
        textured(hand, T_joint, uv_box)
        add(f"hand_{side}", moved(hand, [sx * 0.305, -0.09, 0]))

        # Upper leg
        ul = cyl(0.085, 0.28, 12)
        textured(ul, T_metal, lambda m: uv_cylinder(m.vertices))
        rotated(ul, 90, [1, 0, 0])
        add(f"upper_leg_{side}", moved(ul, [sx * 0.135, -0.165, 0]))

        # Knee joint
        kn = trimesh.creation.icosphere(2, radius=0.09)
        textured(kn, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"knee_{side}", moved(kn, [sx * 0.135, -0.325, 0]))

        # Lower leg
        ll = cyl(0.072, 0.27, 12)
        textured(ll, T_metal, lambda m: uv_cylinder(m.vertices))
        rotated(ll, 90, [1, 0, 0])
        add(f"lower_leg_{side}", moved(ll, [sx * 0.135, -0.475, 0]))

        # Ankle joint
        an = trimesh.creation.icosphere(2, radius=0.065)
        textured(an, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"ankle_{side}", moved(an, [sx * 0.135, -0.625, 0]))

        # Foot
        foot = trimesh.creation.box([0.13, 0.085, 0.22])
        textured(foot, T_foot, uv_box)
        add(f"foot_{side}", moved(foot, [sx * 0.135, -0.685, 0.04]))

    return scene


# ───────────────────────────────────────────────────────────────── main ──

if __name__ == "__main__":
    print("Building robot character...", end=" ", flush=True)
    scene = build_robot()
    out = os.path.join(OUTPUT_DIR, "character.glb")
    scene.export(out)
    size_kb = os.path.getsize(out) / 1024
    print(f"→ character.glb  ({size_kb:.1f} KB)")
    parts = list(scene.geometry.keys())
    print(f"   {len(parts)} named parts:")
    for p in parts:
        print(f"     • {p}")
