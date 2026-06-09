"""
generate_station.py — Stylized horizontal hexagonal space station.

The geometry is benzene scaled ~2× and laid flat in the XZ plane (Y is up
in the viewer). Each carbon hub and hydrogen pod has three angular-cone
face-cluster cutouts in its icosphere mesh, producing irregular polygonal
openings ("windows") that you can see through. The atom materials are
`doubleSided = true` so the interior of the shell is visible from outside
when looking through a hole, and the hull is visible from inside if the
camera enters the station.

The colour scheme matches benzene's molecule-scene split: heavy / hydrogen /
bonds — three solid-colour PBR materials, three submeshes.

Filenames:
    station-{heavy}-{hydrogen}-{bond}-{material}.glb

Scene graph:
    heavy     (root)   — 6 carbon hubs with cutouts
    ├── hydrogen        — 6 hydrogen pods with cutouts
    └── bonds           — 6 radial C–H bonds + 6 ring-segment C–C bonds (solid)

Usage:
    /tmp/glb_env/bin/python3 generate_station.py        # interactive
    /tmp/glb_env/bin/python3 generate_station.py -y     # default greyscale
"""

import os
import sys

import numpy as np
import trimesh
import trimesh.visual.material

from generate_models import (
    prompt_color, prompt_material,
    _apply_solid_color, _align_to, models_root,
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = models_root()   # app's Model Library folder (modelsPathSecondary)


# ─── Geometry parameters (≈ 2× scaled benzene) ──────────────────────────────
RING_R    = 0.66     # carbon hub ring radius
TIP_R     = 1.06     # hydrogen pod ring radius
C_ATOM_R  = 0.15     # carbon hub radius
H_ATOM_R  = 0.11     # hydrogen pod radius
CH_BOND_R = 0.044    # radial C–H bond cylinder radius
CC_BOND_R = 0.054    # ring-segment C–C bond cylinder radius

# Cone half-angles (degrees) for the icosphere cutouts.
#   *_WIN_*  : window openings — the "see through" holes
#   *_BOND_* : bond-entry openings — sized to fit the bond cross-section so the
#              bond cylinder docks cleanly with the atom hull
# At 22° on icosphere(2) about 12 faces fall inside the cone; at 28° about 24.
C_WIN_HALF_ANGLE  = 22.0
C_BOND_HALF_ANGLE = 22.0   # ≥ arcsin(CC_BOND_R / C_ATOM_R) = 21.1°
H_WIN_HALF_ANGLE  = 28.0
H_BOND_HALF_ANGLE = 25.0   # ≥ arcsin(CH_BOND_R / H_ATOM_R) = 23.6°

ICOSPHERE_SUBDIV = 2

# Inner shells inside every opaque part.  The atom/bond surfaces are rendered
# from both sides (the viewer's cull mode is .none) and the PBR shader uses the
# stored normal as-is, so a polished-metal back-face sprays the user's eye with
# strong HDRI reflections that don't match the outside.  An inverted-winding,
# slightly inset shell with a ceramic-style material gives the inside a soft,
# colour-matched look without altering the outside.
INNER_INSET     = 0.005   # 0.5% scale toward each part's local centre
INNER_METALNESS = 0.00    # matches the "Matte Plastic" preset in generate_models.py
INNER_ROUGHNESS = 0.85

# Glass panes filling the window cutouts (NOT the doorway cutouts — those
# stay open). The glass material is the same across every batch combination
# so the windows read as a consistent piece of station hardware.
GLASS_COLOR     = (180, 220, 255)   # pale arctic blue
GLASS_OPACITY   = 0.30              # a bit more smoke than the first pass
GLASS_METALNESS = 0.70              # stronger HDRI reflection
GLASS_ROUGHNESS = 0.10              # smooth surface for tidy reflections


# ─── Helpers ────────────────────────────────────────────────────────────────

def _icosphere_with_cutouts(radius, window_specs, doorway_specs,
                            subdivisions=ICOSPHERE_SUBDIV):
    """Build an icosphere centred at the origin and split its faces into
    two meshes: the opaque hull, and the translucent glass panes.

    `window_specs` and `doorway_specs` are each a list of
    (direction_vec3, half_angle_degrees) tuples.

    Faces inside a *window* cone are removed from the hull and kept as the
    `glass` mesh — they'll be filled in with a translucent material so the
    window perfectly matches the sphere's curvature.

    Faces inside a *doorway* cone are removed from the hull and discarded;
    those holes are left open (e.g. for the robot to travel through).

    Returns `(hull_mesh, glass_mesh)`. Caller is responsible for translating
    both into position.
    """
    sphere    = trimesh.creation.icosphere(subdivisions, radius)
    centroids = sphere.triangles_center
    norms     = np.linalg.norm(centroids, axis=1, keepdims=True)
    dirs      = centroids / np.where(norms > 1e-12, norms, 1.0)

    def faces_in_cones(specs):
        mask = np.zeros(len(sphere.faces), dtype=bool)
        for d, half_angle_deg in specs:
            d_norm = np.asarray(d, dtype=float)
            d_norm = d_norm / np.linalg.norm(d_norm)
            cos_thresh = np.cos(np.radians(half_angle_deg))
            mask |= (dirs @ d_norm) >= cos_thresh
        return mask

    win_mask  = faces_in_cones(window_specs)
    door_mask = faces_in_cones(doorway_specs)

    hull = sphere.copy()
    hull.update_faces(~(win_mask | door_mask))

    # Defensive `& ~door_mask`: if a window cone and doorway cone ever
    # overlapped (they don't in the station's 60°-spaced layout, but
    # asserting it here keeps the geometry honest), the doorway wins and
    # those faces stay open rather than becoming glass.
    glass = sphere.copy()
    glass.update_faces(win_mask & ~door_mask)

    return hull, glass


def _open_bond(p0, p1, radius, sections=10):
    """Cylinder connecting two 3D points, with end caps stripped — an open
    tube. The caller should pick p0 and p1 on the surfaces of the atoms it
    connects (not at their centres), so the tube terminates at the hull.
    """
    p0 = np.asarray(p0, dtype=float)
    p1 = np.asarray(p1, dtype=float)
    v  = p1 - p0
    cyl = trimesh.creation.cylinder(radius=radius,
                                     height=float(np.linalg.norm(v)),
                                     sections=sections)
    # Pre-transform the cylinder is Z-axial; end-cap face normals are ±Z.
    # Anything else is a side face. Strip the caps before aligning.
    nz = np.abs(cyl.face_normals[:, 2])
    cyl.update_faces(nz < 0.99)
    cyl.apply_transform(_align_to(v, (p0 + p1) * 0.5))
    return cyl


def _build_inner_shell(outer_mesh, inset=INNER_INSET):
    """Copy of `outer_mesh` with face winding reversed (normals now point
    inward) and vertices scaled toward the origin by `1 - inset`.

    Only valid when the source mesh is centred at the origin — which is the
    case for `_icosphere_with_cutouts` output, before it gets translated to its
    final position in the station.  Apply the same translation to both the
    outer and inner shells.
    """
    inner = outer_mesh.copy()
    inner.invert()
    inner.vertices = inner.vertices * (1.0 - inset)
    return inner


def _inner_bond(p0, p1, outer_radius, inset=INNER_INSET, sections=10):
    """Open tube along (p0, p1) at radius `outer_radius * (1 - inset)`, with
    face winding reversed so the normals face the interior of the tube.
    """
    inner = _open_bond(p0, p1, outer_radius * (1.0 - inset), sections=sections)
    inner.invert()
    return inner


def _apply_solid_color_doublesided(mesh, rgb, metalness, roughness):
    """Like _apply_solid_color but with doubleSided = True so the interior
    surface is visible through the cutout windows (and vice versa).
    """
    r, g, b = [c / 255.0 for c in rgb]
    mat = trimesh.visual.material.PBRMaterial(
        baseColorFactor=[r, g, b, 1.0],
        metallicFactor=metalness,
        roughnessFactor=roughness,
        doubleSided=True,
    )
    _  = mesh.vertex_normals
    uv = np.zeros((len(mesh.vertices), 2), dtype=np.float32)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)


def _apply_glass(mesh, rgb, opacity, metalness, roughness):
    """Translucent metallic PBR material for the glass panes. alphaMode=BLEND
    + baseColorFactor.w < 1 routes the mesh into the transparent pipeline
    automatically (Renderer.swift checks both opacity and baseColorFactor.w).
    """
    r, g, b = [c / 255.0 for c in rgb]
    mat = trimesh.visual.material.PBRMaterial(
        baseColorFactor=[r, g, b, opacity],
        metallicFactor=metalness,
        roughnessFactor=roughness,
        alphaMode="BLEND",
        doubleSided=True,
    )
    _  = mesh.vertex_normals
    uv = np.zeros((len(mesh.vertices), 2), dtype=np.float32)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)


def colorizer_to_rgb(colorizer, brightness=220):
    """Sample one representative RGB from a prompt_color colorizer.

    Greyscale tonal range → (v, v, v). Palette → the colorizer's RGB output
    at the given brightness. None → light grey.
    """
    if colorizer is None:
        return (brightness, brightness, brightness)
    sample = np.array([[brightness]], dtype=np.uint8)
    out = colorizer(sample)
    if out.ndim == 2:
        v = int(out[0, 0])
        return (v, v, v)
    return tuple(int(c) for c in out[0, 0])


# ─── Geometry ───────────────────────────────────────────────────────────────

def build_station_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness):
    angles = np.linspace(0, 2 * np.pi, 6, endpoint=False)

    # Ring lies flat in XZ (Y = 0). Y is up in the viewer.
    C_pos = np.column_stack([RING_R * np.cos(angles),
                              np.zeros(6),
                              RING_R * np.sin(angles)])
    H_pos = np.column_stack([TIP_R * np.cos(angles),
                              np.zeros(6),
                              TIP_R * np.sin(angles)])

    c_parts,       h_parts,       b_parts,       glass_parts = [], [], [], []
    c_inner_parts, h_inner_parts, b_inner_parts              = [], [], []

    # Helper to spell out an XZ-plane unit vector at a given angle.
    def xz(angle):
        return np.array([np.cos(angle), 0.0, np.sin(angle)])

    for i in range(6):
        theta  = angles[i]
        j_next = (i + 1) % 6
        j_prev = (i - 1) % 6

        # Direction from C_pos[i] toward each neighbour (unit vectors, all in XZ).
        radial_i      = xz(theta)                                 # toward H_pos[i]
        chord_to_next = (C_pos[j_next] - C_pos[i])
        chord_to_next = chord_to_next / np.linalg.norm(chord_to_next)
        chord_to_prev = (C_pos[j_prev] - C_pos[i])
        chord_to_prev = chord_to_prev / np.linalg.norm(chord_to_prev)

        # ─── Carbon hub: 3 windows (glass-filled) + 3 doorways (open) ─────
        #   Windows: ±60° outward (flank C–H) + 180° inward (between C–Cs)
        #   Doorways: along each of the 3 bond directions
        c_windows = [
            (xz(theta + np.pi / 3), C_WIN_HALF_ANGLE),
            (xz(theta - np.pi / 3), C_WIN_HALF_ANGLE),
            (xz(theta + np.pi),     C_WIN_HALF_ANGLE),
        ]
        c_doorways = [
            (radial_i,      C_BOND_HALF_ANGLE),
            (chord_to_next, C_BOND_HALF_ANGLE),
            (chord_to_prev, C_BOND_HALF_ANGLE),
        ]
        c_hull, c_glass = _icosphere_with_cutouts(C_ATOM_R, c_windows, c_doorways)
        c_inner         = _build_inner_shell(c_hull)
        c_hull .apply_translation(C_pos[i])
        c_inner.apply_translation(C_pos[i])
        c_glass.apply_translation(C_pos[i])
        c_parts      .append(c_hull)
        c_inner_parts.append(c_inner)
        glass_parts  .append(c_glass)

        # ─── Hydrogen pod: 3 windows (glass-filled) + 1 doorway (open) ────
        #   Windows: outward radial + ±120°
        #   Doorway: inward radial (back toward C)
        h_windows = [
            (xz(theta),                 H_WIN_HALF_ANGLE),
            (xz(theta + 2 * np.pi / 3), H_WIN_HALF_ANGLE),
            (xz(theta - 2 * np.pi / 3), H_WIN_HALF_ANGLE),
        ]
        h_doorways = [
            (-radial_i,                 H_BOND_HALF_ANGLE),
        ]
        h_hull, h_glass = _icosphere_with_cutouts(H_ATOM_R, h_windows, h_doorways)
        h_inner         = _build_inner_shell(h_hull)
        h_hull .apply_translation(H_pos[i])
        h_inner.apply_translation(H_pos[i])
        h_glass.apply_translation(H_pos[i])
        h_parts      .append(h_hull)
        h_inner_parts.append(h_inner)
        glass_parts  .append(h_glass)

        # ─── Bonds: open tubes, terminating at the atom surfaces ──────────
        # C–H: from C surface (along radial_i) to H surface (along -radial_i)
        ch_start = C_pos[i]      + radial_i * C_ATOM_R
        ch_end   = H_pos[i]      - radial_i * H_ATOM_R
        b_parts      .append(_open_bond (ch_start, ch_end, CH_BOND_R))
        b_inner_parts.append(_inner_bond(ch_start, ch_end, CH_BOND_R))

        # C–C: from C[i] surface (along chord_to_next) to C[j_next] surface
        cc_start = C_pos[i]      + chord_to_next * C_ATOM_R
        cc_end   = C_pos[j_next] - chord_to_next * C_ATOM_R
        b_parts      .append(_open_bond (cc_start, cc_end, CC_BOND_R))
        b_inner_parts.append(_inner_bond(cc_start, cc_end, CC_BOND_R))

    c_mesh       = trimesh.util.concatenate(c_parts)
    h_mesh       = trimesh.util.concatenate(h_parts)
    b_mesh       = trimesh.util.concatenate(b_parts)
    glass_mesh   = trimesh.util.concatenate(glass_parts)
    c_inner_mesh = trimesh.util.concatenate(c_inner_parts)
    h_inner_mesh = trimesh.util.concatenate(h_inner_parts)
    b_inner_mesh = trimesh.util.concatenate(b_inner_parts)

    # Outer hulls use the user's chosen material preset.
    _apply_solid_color_doublesided(c_mesh, heavy_rgb, metalness, roughness)
    _apply_solid_color_doublesided(h_mesh, h_rgb,     metalness, roughness)
    _apply_solid_color_doublesided(b_mesh, bond_rgb,  metalness, roughness)
    _apply_glass(glass_mesh, GLASS_COLOR, GLASS_OPACITY,
                 GLASS_METALNESS, GLASS_ROUGHNESS)
    # Inner shells share the outer colour but always use a fixed ceramic-ish
    # material so the interior reads as soft and colour-matched no matter
    # which outside preset (polished metal, brushed, matte, ceramic, rubber)
    # the station was generated with.
    _apply_solid_color_doublesided(c_inner_mesh, heavy_rgb, INNER_METALNESS, INNER_ROUGHNESS)
    _apply_solid_color_doublesided(h_inner_mesh, h_rgb,     INNER_METALNESS, INNER_ROUGHNESS)
    _apply_solid_color_doublesided(b_inner_mesh, bond_rgb,  INNER_METALNESS, INNER_ROUGHNESS)

    scene = trimesh.Scene()
    scene.add_geometry(c_mesh,       node_name="heavy",          geom_name="heavy")
    scene.add_geometry(h_mesh,       node_name="hydrogen",       geom_name="hydrogen",
                       parent_node_name="heavy")
    scene.add_geometry(b_mesh,       node_name="bonds",          geom_name="bonds",
                       parent_node_name="heavy")
    scene.add_geometry(glass_mesh,   node_name="glass",          geom_name="glass",
                       parent_node_name="heavy")
    scene.add_geometry(c_inner_mesh, node_name="heavy_inner",    geom_name="heavy_inner",
                       parent_node_name="heavy")
    scene.add_geometry(h_inner_mesh, node_name="hydrogen_inner", geom_name="hydrogen_inner",
                       parent_node_name="heavy")
    scene.add_geometry(b_inner_mesh, node_name="bonds_inner",    geom_name="bonds_inner",
                       parent_node_name="heavy")
    return scene


# ─── Main ───────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    use_defaults = "-y" in sys.argv or "--defaults" in sys.argv

    if use_defaults:
        heavy_rgb = h_rgb = bond_rgb = (180, 180, 180)
        heavy_label = h_label = bond_label = None
        metalness, roughness, mat_label = 0.0, 0.85, None
    else:
        print("\n  Three colour choices, matching benzene's heavy / hydrogen / bonds split.")
        print(f"  Output folder: {OUTPUT_DIR}")

        heavy_fn, _, heavy_label = prompt_color("Heavy",    "6 carbon hubs on the inner ring")
        h_fn,     _, h_label     = prompt_color("Hydrogen", "6 pods at the ring tips")
        bond_fn,  _, bond_label  = prompt_color("Bonds",    "12 connecting cylinders")
        metalness, roughness, mat_label, _ = prompt_material("Station")

        heavy_rgb = colorizer_to_rgb(heavy_fn)
        h_rgb     = colorizer_to_rgb(h_fn)
        bond_rgb  = colorizer_to_rgb(bond_fn)

    labels = [l for l in [heavy_label, h_label, bond_label, mat_label] if l]
    stem   = "-".join(["station"] + labels) if labels else "station"
    out    = os.path.join(OUTPUT_DIR, f"{stem}.glb")

    print(f"\nBuilding station...", end=" ", flush=True)
    scene = build_station_scene(heavy_rgb, h_rgb, bond_rgb, metalness, roughness)
    scene.export(out)
    size_kb  = os.path.getsize(out) / 1024
    rel_path = os.path.relpath(out, SCRIPT_DIR)
    print(f"→ {rel_path}  ({size_kb:.1f} KB)")

    print(f"\n   Scene graph ({len(scene.graph.nodes)} nodes):")
    for node in scene.graph.nodes:
        print(f"     • {node}")
