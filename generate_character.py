"""
Generate a robot character as character.glb with a proper FK hierarchy.

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


# ──────────────────────────────────────────────────────── character build ──

def build_robot():
    scene = trimesh.Scene()

    # Pre-bake all textures once.
    T_metal = _png(tex_metal_panels())
    T_head  = _png(tex_head())
    T_visor = _png(tex_visor())
    T_joint = _png(tex_joint())
    T_glow  = _png(tex_glow())
    T_foot  = _png(tex_foot())

    def tr(xyz):
        """Return a 4×4 translation matrix for [x, y, z]."""
        return tf.translation_matrix(xyz)

    def add(name, mesh, parent=None, node_xyz=None, mesh_xyz=None):
        """
        Insert one body part into the scene hierarchy.

        name      – unique node / geometry name.
        mesh      – trimesh geometry already shaped & textured, centred at [0,0,0]
                    in its own local frame (before mesh_xyz offset).
        parent    – parent node name; None → child of the world root.
        node_xyz  – [x, y, z] position of this node's origin in the PARENT's
                    local frame.  Equivalently: (this joint's world pos)
                    minus (parent joint's world pos).  None → [0, 0, 0].
        mesh_xyz  – [x, y, z] offset of the mesh centre from this node's
                    origin.  Equivalently: (mesh world centre) minus
                    (this joint's world pos).  None → [0, 0, 0].
        """
        if mesh_xyz is not None and not np.allclose(mesh_xyz, 0):
            mesh.apply_transform(tr(mesh_xyz))

        node_tf = tr(node_xyz) if node_xyz is not None else np.eye(4)
        kwargs  = {"geom_name": name, "transform": node_tf}
        if parent is not None:
            kwargs["parent_node_name"] = parent
        scene.add_geometry(mesh, node_name=name, **kwargs)

    # ── HIPS (world root, pivot = hips centre) ───────────────────────────
    # World pivot: [0, 0.08, 0]
    # node_xyz from world root: [0, 0.08, 0]
    # mesh_xyz: [0, 0, 0]  (box centred on its own pivot)
    hips = trimesh.creation.box([0.40, 0.13, 0.24])
    textured(hips, T_metal, uv_box)
    add("hips", hips, parent=None, node_xyz=[0, 0.08, 0], mesh_xyz=None)

    # ── TORSO ────────────────────────────────────────────────────────────
    # Pivot: hip-spine joint = top of hips box = [0, 0.145, 0]
    # node_xyz from hips pivot [0, 0.08, 0]:  [0, 0.065, 0]
    # mesh_xyz: torso centre [0, 0.375, 0] - pivot [0, 0.145, 0] = [0, 0.230, 0]
    torso = trimesh.creation.box([0.44, 0.46, 0.27])
    textured(torso, T_metal, uv_box)
    add("torso", torso, "hips", [0, 0.065, 0], [0, 0.230, 0])

    # Chest panel — cosmetic, shares torso's spine-joint pivot.
    # mesh_xyz: panel centre [0, 0.39, 0.148] - spine pivot [0, 0.145, 0]
    panel = trimesh.creation.box([0.26, 0.22, 0.025])
    textured(panel, T_visor, uv_box)
    add("chest_panel", panel, "torso", [0, 0, 0], [0, 0.245, 0.148])

    # ── NECK ─────────────────────────────────────────────────────────────
    # Pivot: neck base = top of torso = [0, 0.60, 0]
    # node_xyz from spine pivot [0, 0.145, 0]: [0, 0.455, 0]
    # mesh_xyz: neck centre [0, 0.645, 0] - neck pivot [0, 0.60, 0] = [0, 0.045, 0]
    neck = trimesh.creation.cylinder(radius=0.065, height=0.09, sections=12)
    textured(neck, T_joint, lambda m: uv_cylinder(m.vertices))
    add("neck", neck, "torso", [0, 0.455, 0], [0, 0.045, 0])

    # ── HEAD ─────────────────────────────────────────────────────────────
    # Pivot: head base = top of neck = [0, 0.69, 0]
    # node_xyz from neck pivot [0, 0.60, 0]: [0, 0.09, 0]
    # mesh_xyz: head centre [0, 0.88, 0] - head pivot [0, 0.69, 0] = [0, 0.190, 0]
    head = trimesh.creation.icosphere(3, radius=0.185)
    textured(head, T_head, lambda m: uv_sphere(m.vertices))
    add("head", head, "neck", [0, 0.09, 0], [0, 0.190, 0])

    # All head attachments share the head pivot [0, 0.69, 0] (node_xyz = [0,0,0]).
    # mesh_xyz = (world centre) - (head pivot [0, 0.69, 0]).

    visor = trimesh.creation.icosphere(3, radius=0.12)
    visor.apply_scale([1.5, 0.55, 0.25])
    textured(visor, T_visor, lambda m: uv_sphere(m.vertices))
    add("visor", visor, "head", [0, 0, 0], [0, 0.185, 0.155])

    for label, ex in [("eye_L", -0.065), ("eye_R", 0.065)]:
        eye = trimesh.creation.icosphere(2, radius=0.025)
        textured(eye, T_glow, lambda m: uv_sphere(m.vertices))
        add(label, eye, "head", [0, 0, 0], [ex, 0.195, 0.185])

    for label, sx in [("ear_L", -1), ("ear_R", 1)]:
        ear = trimesh.creation.cylinder(radius=0.03, height=0.04, sections=8)
        # UV on the Z-axis cylinder before rotating to X-axis.
        textured(ear, T_joint, lambda m: uv_cylinder(m.vertices))
        ear.apply_transform(tf.rotation_matrix(np.radians(90), [0, 1, 0]))
        add(label, ear, "head", [0, 0, 0], [sx * 0.21, 0.190, 0])

    pole = trimesh.creation.cylinder(radius=0.014, height=0.13, sections=8)
    textured(pole, T_joint, lambda m: uv_cylinder(m.vertices))
    add("antenna_pole", pole, "head", [0, 0, 0], [0, 0.410, 0])

    ball = trimesh.creation.icosphere(2, radius=0.038)
    textured(ball, T_glow, lambda m: uv_sphere(m.vertices))
    add("antenna_ball", ball, "head", [0, 0, 0], [0, 0.495, 0])

    # ── ARMS & LEGS (mirrored L / R) ─────────────────────────────────────
    for side, sx in [("L", -1), ("R", 1)]:

        # ── Shoulder sphere ───────────────────────────────────────────────
        # Pivot: shoulder joint = sphere centre = [sx*0.305, 0.565, 0]
        # node_xyz from spine pivot [0, 0.145, 0]:
        #   [sx*0.305 - 0, 0.565 - 0.145, 0] = [sx*0.305, 0.420, 0]
        # mesh_xyz: [0, 0, 0]  (sphere centred on its joint)
        sh = trimesh.creation.icosphere(2, radius=0.105)
        textured(sh, T_metal, lambda m: uv_sphere(m.vertices))
        add(f"shoulder_{side}", sh, "torso", [sx * 0.305, 0.420, 0], None)

        # ── Upper arm ─────────────────────────────────────────────────────
        # Pivot: shoulder joint (child of shoulder_X with zero offset).
        # mesh_xyz: upper-arm centre [sx*0.305, 0.355, 0]
        #           - shoulder pivot [sx*0.305, 0.565, 0] = [0, -0.210, 0]
        ua = trimesh.creation.cylinder(radius=0.068, height=0.24, sections=12)
        textured(ua, T_metal, lambda m: uv_cylinder(m.vertices))
        ua.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"upper_arm_{side}", ua, f"shoulder_{side}", [0, 0, 0], [0, -0.210, 0])

        # ── Elbow sphere ──────────────────────────────────────────────────
        # Pivot: elbow joint = sphere centre = [sx*0.305, 0.215, 0]
        # node_xyz from shoulder pivot [sx*0.305, 0.565, 0]:
        #   [0, 0.215 - 0.565, 0] = [0, -0.350, 0]
        # mesh_xyz: [0, 0, 0]
        el = trimesh.creation.icosphere(2, radius=0.075)
        textured(el, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"elbow_{side}", el, f"upper_arm_{side}", [0, -0.350, 0], None)

        # ── Forearm ───────────────────────────────────────────────────────
        # Pivot: elbow joint (child of elbow_X with zero offset).
        # mesh_xyz: forearm centre [sx*0.305, 0.085, 0]
        #           - elbow pivot [sx*0.305, 0.215, 0] = [0, -0.130, 0]
        fa = trimesh.creation.cylinder(radius=0.057, height=0.22, sections=12)
        textured(fa, T_metal, lambda m: uv_cylinder(m.vertices))
        fa.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"forearm_{side}", fa, f"elbow_{side}", [0, 0, 0], [0, -0.130, 0])

        # ── Hand ──────────────────────────────────────────────────────────
        # Pivot: wrist joint = bottom of forearm = [sx*0.305, -0.025, 0]
        # node_xyz from elbow pivot [sx*0.305, 0.215, 0]:
        #   [0, -0.025 - 0.215, 0] = [0, -0.240, 0]
        # mesh_xyz: hand centre [sx*0.305, -0.090, 0]
        #           - wrist pivot [sx*0.305, -0.025, 0] = [0, -0.065, 0]
        hand = trimesh.creation.box([0.105, 0.13, 0.085])
        textured(hand, T_joint, uv_box)
        add(f"hand_{side}", hand, f"forearm_{side}", [0, -0.240, 0], [0, -0.065, 0])

        # ── Upper leg ─────────────────────────────────────────────────────
        # Pivot: hip-leg joint = top of upper-leg cyl = [sx*0.135, -0.025, 0]
        # node_xyz from hips pivot [0, 0.08, 0]:
        #   [sx*0.135 - 0, -0.025 - 0.08, 0] = [sx*0.135, -0.105, 0]
        # mesh_xyz: upper-leg centre [sx*0.135, -0.165, 0]
        #           - hip-leg pivot [sx*0.135, -0.025, 0] = [0, -0.140, 0]
        ul = trimesh.creation.cylinder(radius=0.085, height=0.28, sections=12)
        textured(ul, T_metal, lambda m: uv_cylinder(m.vertices))
        ul.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"upper_leg_{side}", ul, "hips", [sx * 0.135, -0.105, 0], [0, -0.140, 0])

        # ── Knee sphere ───────────────────────────────────────────────────
        # Pivot: knee joint = sphere centre = [sx*0.135, -0.325, 0]
        # node_xyz from hip-leg pivot [sx*0.135, -0.025, 0]:
        #   [0, -0.325 - (-0.025), 0] = [0, -0.300, 0]
        # mesh_xyz: [0, 0, 0]
        kn = trimesh.creation.icosphere(2, radius=0.09)
        textured(kn, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"knee_{side}", kn, f"upper_leg_{side}", [0, -0.300, 0], None)

        # ── Lower leg ─────────────────────────────────────────────────────
        # Pivot: knee joint (child of knee_X with zero offset).
        # mesh_xyz: lower-leg centre [sx*0.135, -0.475, 0]
        #           - knee pivot [sx*0.135, -0.325, 0] = [0, -0.150, 0]
        ll = trimesh.creation.cylinder(radius=0.072, height=0.27, sections=12)
        textured(ll, T_metal, lambda m: uv_cylinder(m.vertices))
        ll.apply_transform(tf.rotation_matrix(np.radians(90), [1, 0, 0]))
        add(f"lower_leg_{side}", ll, f"knee_{side}", [0, 0, 0], [0, -0.150, 0])

        # ── Ankle sphere ──────────────────────────────────────────────────
        # Pivot: ankle joint = sphere centre = [sx*0.135, -0.625, 0]
        # node_xyz from knee pivot [sx*0.135, -0.325, 0]:
        #   [0, -0.625 - (-0.325), 0] = [0, -0.300, 0]
        # mesh_xyz: [0, 0, 0]
        an = trimesh.creation.icosphere(2, radius=0.065)
        textured(an, T_joint, lambda m: uv_sphere(m.vertices))
        add(f"ankle_{side}", an, f"lower_leg_{side}", [0, -0.300, 0], None)

        # ── Foot ──────────────────────────────────────────────────────────
        # Pivot: ankle joint (child of ankle_X with zero offset).
        # mesh_xyz: foot centre [sx*0.135, -0.685, 0.04]
        #           - ankle pivot [sx*0.135, -0.625, 0] = [0, -0.060, 0.040]
        foot = trimesh.creation.box([0.13, 0.085, 0.22])
        textured(foot, T_foot, uv_box)
        add(f"foot_{side}", foot, f"ankle_{side}", [0, 0, 0], [0, -0.060, 0.040])

    return scene


# ───────────────────────────────────────────────────────────────── main ──

if __name__ == "__main__":
    print("Building robot character...", end=" ", flush=True)
    scene = build_robot()
    out = os.path.join(OUTPUT_DIR, "character.glb")
    scene.export(out)
    size_kb = os.path.getsize(out) / 1024
    print(f"→ character.glb  ({size_kb:.1f} KB)")

    # Print the scene graph so we can verify the hierarchy.
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
