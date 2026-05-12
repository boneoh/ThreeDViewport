"""
Generate simple 3D shapes as .glb files with embedded greyscale textures.
Each shape has a unique texture pattern for later colorization.

Usage:
    python3 generate_models.py
    # or with the venv:
    /tmp/glb_env/bin/python3 generate_models.py

Output: cube.glb, cylinder.glb, pyramid.glb, sphere.glb, torus.glb,
        tetrahedron.glb, octahedron.glb, hexprism.glb, capsule.glb,
        mobius.glb, star.glb
"""

import numpy as np
import trimesh
from PIL import Image
import io
import os

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
TEX_SIZE = 512


# ---------------------------------------------------------------------------
# Texture generators
# ---------------------------------------------------------------------------

def tex_linear_gradient():
    """Left-to-right gradient: black → white."""
    row = np.linspace(0, 255, TEX_SIZE, dtype=np.uint8)
    return np.tile(row, (TEX_SIZE, 1))


def tex_radial_gradient():
    """Bright centre fading to dark edges."""
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    r = r / r.max()
    return (255 * (1 - r)).astype(np.uint8)


def tex_angular_stripes():
    """Alternating light/dark angular bands from centre."""
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    angle = np.arctan2(y - cy, x - cx)
    bands = (np.sin(angle * 8) * 0.5 + 0.5)
    return (255 * bands).astype(np.uint8)


def tex_marble():
    """Sine-based marble-like veining."""
    y, x = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    noise = np.sin((x + y * 0.5) / 20) * 0.5 + np.sin(x / 15 - y / 25) * 0.5
    noise = (noise - noise.min()) / (noise.max() - noise.min())
    return (255 * noise).astype(np.uint8)


def tex_concentric_rings():
    """Concentric bright/dark rings."""
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    rings = np.sin(r / 12) * 0.5 + 0.5
    return (255 * rings).astype(np.uint8)


def tex_checkerboard():
    """Hard-edged 8×8 checkerboard."""
    coords = np.arange(TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    checker = ((xi // (TEX_SIZE // 8)) + (yi // (TEX_SIZE // 8))) % 2
    return (checker * 255).astype(np.uint8)


def tex_diagonal_stripes():
    """45-degree diagonal sine stripes."""
    coords = np.arange(TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    val = np.sin((xi + yi) / 16) * 0.5 + 0.5
    return (255 * val).astype(np.uint8)


def tex_crosshatch():
    """Sine grid in both axes — crosshatch pattern."""
    coords = np.linspace(0, 4 * np.pi, TEX_SIZE)
    xi, yi = np.meshgrid(coords, coords)
    val = np.abs(np.sin(xi)) * np.abs(np.sin(yi))
    return (255 * val).astype(np.uint8)


def tex_wood_grain():
    """Horizontal wood-grain bands with slight wave distortion."""
    y, x = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    distort = np.sin(x / 30) * 15
    grain = np.sin((y + distort) / 10) * 0.4 + np.sin((y + distort) / 3) * 0.1 + 0.5
    grain = np.clip(grain, 0, 1)
    return (255 * grain).astype(np.uint8)


def tex_spiral():
    """Archimedean spiral brightening outward."""
    y, x = np.ogrid[:TEX_SIZE, :TEX_SIZE]
    cx, cy = TEX_SIZE / 2, TEX_SIZE / 2
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    theta = np.arctan2(y - cy, x - cx)
    spiral = np.sin(r / 10 - theta * 3) * 0.5 + 0.5
    return (255 * spiral).astype(np.uint8)


def tex_cells():
    """Voronoi-like cell pattern using a grid of random seed points."""
    rng = np.random.default_rng(42)
    n_seeds = 20
    seeds = rng.integers(0, TEX_SIZE, size=(n_seeds, 2)).astype(float)
    y, x = np.mgrid[:TEX_SIZE, :TEX_SIZE]
    dist = np.full((TEX_SIZE, TEX_SIZE), np.inf)
    for sx, sy in seeds:
        d = np.sqrt((x - sx) ** 2 + (y - sy) ** 2)
        dist = np.minimum(dist, d)
    dist = dist / dist.max()
    return (255 * dist).astype(np.uint8)


def make_png_bytes(array_2d):
    """Convert a 2D uint8 greyscale array to PNG bytes."""
    img = Image.fromarray(array_2d, mode="L")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# ---------------------------------------------------------------------------
# UV helpers
# ---------------------------------------------------------------------------

def uv_box(mesh):
    """
    Simple per-face box UV: map each face's vertices to [0,1]² using the
    two most-varying local axes.
    """
    verts = mesh.vertices[mesh.faces]          # (F, 3, 3)
    normals = mesh.face_normals                # (F, 3)
    uvs = np.zeros((len(mesh.faces) * 3, 2))

    for i, (tri, n) in enumerate(zip(verts, normals)):
        abs_n = np.abs(n)
        dominant = np.argmax(abs_n)
        axes = [a for a in range(3) if a != dominant]
        local = tri[:, axes]
        lo, hi = local.min(axis=0), local.max(axis=0)
        rng = np.where(hi - lo > 1e-6, hi - lo, 1.0)
        uvs[i * 3: i * 3 + 3] = (local - lo) / rng

    return uvs


def uv_cylindrical(vertices):
    """Cylindrical UV: u = azimuth / 2π, v = normalised height."""
    x, y, z = vertices[:, 0], vertices[:, 1], vertices[:, 2]
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = (z - z.min()) / max(z.max() - z.min(), 1e-6)
    return np.column_stack([u, v])


def uv_spherical(vertices):
    """Spherical UV mapping."""
    x, y, z = vertices[:, 0], vertices[:, 1], vertices[:, 2]
    r = np.sqrt(x**2 + y**2 + z**2)
    r = np.where(r > 1e-6, r, 1.0)
    u = (np.arctan2(y, x) / (2 * np.pi)) % 1.0
    v = np.arccos(np.clip(z / r, -1, 1)) / np.pi
    return np.column_stack([u, v])


# ---------------------------------------------------------------------------
# Mesh builders
# ---------------------------------------------------------------------------

def apply_texture(mesh, uv, png_bytes):
    """Attach a texture image and UV map to a trimesh."""
    mat = trimesh.visual.texture.SimpleMaterial(
        image=Image.open(io.BytesIO(png_bytes)).convert("RGB")
    )
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)
    return mesh


def build_cube():
    mesh = trimesh.creation.box(extents=[1, 1, 1])
    mesh = mesh.subdivide()          # more verts for smoother UV stretch
    uv = uv_box(mesh)
    png = make_png_bytes(tex_linear_gradient())
    return apply_texture(mesh, uv, png)


def build_cylinder():
    mesh = trimesh.creation.cylinder(radius=0.5, height=1.0, sections=64)
    uv = uv_cylindrical(mesh.vertices)
    png = make_png_bytes(tex_radial_gradient())
    return apply_texture(mesh, uv, png)


def build_pyramid():
    # Low-segment cone = pyramid-like shape (8 sides for a cleaner look)
    mesh = trimesh.creation.cone(radius=0.6, height=1.2, sections=4)
    uv = uv_cylindrical(mesh.vertices)
    png = make_png_bytes(tex_angular_stripes())
    return apply_texture(mesh, uv, png)


def build_sphere():
    mesh = trimesh.creation.icosphere(subdivisions=4, radius=0.6)
    uv = uv_spherical(mesh.vertices)
    png = make_png_bytes(tex_marble())
    return apply_texture(mesh, uv, png)


def build_torus():
    mesh = trimesh.creation.torus(major_radius=0.5, minor_radius=0.18,
                                  major_sections=64, minor_sections=32)
    uv = uv_cylindrical(mesh.vertices)
    png = make_png_bytes(tex_concentric_rings())
    return apply_texture(mesh, uv, png)


def build_tetrahedron():
    """Classic 4-faced platonic solid."""
    verts = np.array([
        [ 1,  1,  1],
        [ 1, -1, -1],
        [-1,  1, -1],
        [-1, -1,  1],
    ], dtype=float)
    verts /= np.linalg.norm(verts[0])
    faces = np.array([[0,1,2],[0,2,3],[0,3,1],[1,3,2]])
    mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=True)
    uv = uv_box(mesh)
    png = make_png_bytes(tex_checkerboard())
    return apply_texture(mesh, uv, png)


def build_octahedron():
    """8-faced platonic solid."""
    verts = np.array([
        [ 1, 0, 0], [-1, 0, 0],
        [ 0, 1, 0], [ 0,-1, 0],
        [ 0, 0, 1], [ 0, 0,-1],
    ], dtype=float)
    faces = np.array([
        [0,2,4],[2,1,4],[1,3,4],[3,0,4],
        [0,5,2],[2,5,1],[1,5,3],[3,5,0],
    ])
    mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=True)
    uv = uv_spherical(mesh.vertices)
    png = make_png_bytes(tex_diagonal_stripes())
    return apply_texture(mesh, uv, png)


def build_hexprism():
    """Hexagonal prism — cylinder with 6 sections."""
    mesh = trimesh.creation.cylinder(radius=0.55, height=1.0, sections=6)
    uv = uv_cylindrical(mesh.vertices)
    png = make_png_bytes(tex_crosshatch())
    return apply_texture(mesh, uv, png)


def build_capsule():
    """Pill / capsule — cylinder with hemispherical caps."""
    mesh = trimesh.creation.capsule(radius=0.35, height=0.7)
    uv = uv_spherical(mesh.vertices)
    png = make_png_bytes(tex_wood_grain())
    return apply_texture(mesh, uv, png)


def build_mobius():
    """Möbius strip — one-sided surface, parametrically generated."""
    U = 128   # steps around the loop
    V = 32    # steps across the width
    u = np.linspace(0, 2 * np.pi, U, endpoint=False)
    v = np.linspace(-0.4, 0.4, V)
    uu, vv = np.meshgrid(u, v, indexing='ij')

    x = (1 + vv * np.cos(uu / 2)) * np.cos(uu)
    y = (1 + vv * np.cos(uu / 2)) * np.sin(uu)
    z = vv * np.sin(uu / 2)

    verts = np.column_stack([x.ravel(), y.ravel(), z.ravel()])
    uvs_u = (uu.ravel() / (2 * np.pi))
    uvs_v = (vv.ravel() - vv.min()) / (vv.max() - vv.min())
    uvs = np.column_stack([uvs_u, uvs_v])

    faces = []
    for i in range(U):
        for j in range(V - 1):
            ni = (i + 1) % U
            a = i * V + j
            b = ni * V + j
            c = ni * V + j + 1
            d = i * V + j + 1
            faces += [[a, b, c], [a, c, d]]
    faces = np.array(faces)

    mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=False)
    png = make_png_bytes(tex_spiral())
    return apply_texture(mesh, uvs, png)


def build_star():
    """5-pointed star prism, extruded along Z."""
    n = 5
    outer_r, inner_r, height = 0.6, 0.25, 0.4
    angles_outer = np.linspace(0, 2 * np.pi, n, endpoint=False) - np.pi / 2
    angles_inner = angles_outer + np.pi / n

    ring = []
    for ao, ai in zip(angles_outer, angles_inner):
        ring.append([outer_r * np.cos(ao), outer_r * np.sin(ao)])
        ring.append([inner_r * np.cos(ai), inner_r * np.sin(ai)])
    ring = np.array(ring)

    top    = np.column_stack([ring,  np.full(len(ring),  height / 2)])
    bottom = np.column_stack([ring,  np.full(len(ring), -height / 2)])
    center_top    = np.array([[0, 0,  height / 2]])
    center_bottom = np.array([[0, 0, -height / 2]])

    verts = np.vstack([top, bottom, center_top, center_bottom])
    idx_ct = len(top) + len(bottom)
    idx_cb = idx_ct + 1
    nv = len(ring)

    faces = []
    # Top and bottom fans
    for i in range(nv):
        ni = (i + 1) % nv
        faces.append([i, ni, idx_ct])
        j = nv + i
        nj = nv + (i + 1) % nv
        faces.append([j, idx_cb, nj])
    # Side quads
    for i in range(nv):
        ni = (i + 1) % nv
        a, b = i, ni
        c, d = nv + ni, nv + i
        faces += [[a, b, c], [a, c, d]]

    mesh = trimesh.Trimesh(vertices=verts, faces=np.array(faces), process=True)
    uv = uv_cylindrical(mesh.vertices)
    png = make_png_bytes(tex_cells())
    return apply_texture(mesh, uv, png)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SHAPES = [
    ("cube",        build_cube),
    ("cylinder",    build_cylinder),
    ("pyramid",     build_pyramid),
    ("sphere",      build_sphere),
    ("torus",       build_torus),
    ("tetrahedron", build_tetrahedron),
    ("octahedron",  build_octahedron),
    ("hexprism",    build_hexprism),
    ("capsule",     build_capsule),
    ("mobius",      build_mobius),
    ("star",        build_star),
]

if __name__ == "__main__":
    for name, builder in SHAPES:
        print(f"Building {name}...", end=" ", flush=True)
        mesh = builder()
        out = os.path.join(OUTPUT_DIR, f"{name}.glb")
        mesh.export(out)
        size_kb = os.path.getsize(out) / 1024
        print(f"→ {name}.glb  ({size_kb:.1f} KB)")

    print("\nDone. Files written to:", OUTPUT_DIR)
