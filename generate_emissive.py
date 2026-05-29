"""
generate_emissive.py — Pure-emissive variants of the simple primitives.

Builds the shape (cube / cylinder / pyramid / sphere / torus / tetrahedron /
octahedron / hexprism / capsule) with a self-illuminated PBR material:

    baseColorFactor  = (0, 0, 0, 1)    # no diffuse — no shading-induced colour
    metallicFactor   = 0               # no metallic reflection
    roughnessFactor  = 1               # no specular highlight
    emissiveFactor   = colour × intensity

Intensity is baked into emissiveFactor directly (instead of using the
KHR_materials_emissive_strength extension) because ThreeDViewport's
GLTFLoader collapses both forms into `mat.emissiveFactor` anyway, and the
fragment shader applies it without clamping.  Result: a `colour-tinted` glow
that ignores scene lighting — ideal for effect markers placed inside the
station.

Filenames:
    emissive-{shape}-{colour}-x{intensity}.glb

Usage:
    /tmp/glb_env/bin/python3 generate_emissive.py       # interactive
    /tmp/glb_env/bin/python3 generate_emissive.py -y    # default red, intensity 3
"""

import os
import sys

import numpy as np
import trimesh
import trimesh.visual.material

from generate_models import (
    prompt_color,
    build_cube, build_cylinder, build_pyramid, build_sphere, build_torus,
    build_tetrahedron, build_octahedron, build_hexprism, build_capsule,
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "Models")

# Shapes to expose as emissive — just the simple primitives.  Pulls the
# geometry from generate_models.py; the texture/UV that the builders also
# return is discarded since pure-emissive doesn't need a baseColor texture.
EMISSIVE_SHAPES = [
    ("cube",        build_cube),
    ("cylinder",    build_cylinder),
    ("pyramid",     build_pyramid),
    ("sphere",      build_sphere),
    ("torus",       build_torus),
    ("tetrahedron", build_tetrahedron),
    ("octahedron",  build_octahedron),
    ("hexprism",    build_hexprism),
    ("capsule",     build_capsule),
]

DEFAULT_INTENSITY = 3.0   # 1.0 = sticker-glow, ≥3 reads as "lit object"
INTENSITY_RANGE   = (0.1, 100.0)   # clamp window for typed values


# ─── Helpers ────────────────────────────────────────────────────────────────

def _apply_emissive(mesh, rgb, intensity):
    """Pure-emissive PBR material.  Black base colour + zero metallic + full
    roughness kill every non-emissive contribution.  Intensity is folded into
    `emissiveFactor` so the GLB doesn't need the KHR_emissive_strength
    extension.
    """
    r, g, b = [c / 255.0 * intensity for c in rgb]
    mat = trimesh.visual.material.PBRMaterial(
        baseColorFactor=[0.0, 0.0, 0.0, 1.0],
        metallicFactor=0.0,
        roughnessFactor=1.0,
        emissiveFactor=[r, g, b],
        doubleSided=False,
    )
    # trimesh's glTF exporter only emits the NORMAL accessor if vertex_normals
    # has been materialised.  Touch it so the shader can light back-faces.
    _ = mesh.vertex_normals
    uv = np.zeros((len(mesh.vertices), 2), dtype=np.float32)
    mesh.visual = trimesh.visual.TextureVisuals(uv=uv, material=mat)
    return mesh


def colorizer_to_rgb(colorizer, brightness=220):
    """Sample one representative RGB from a prompt_color colorizer.

    Greyscale tonal range → (v, v, v).  Palette → the RGB the colorizer
    produces at the given brightness sample.  None → white.
    """
    if colorizer is None:
        return (brightness, brightness, brightness)
    sample = np.array([[brightness]], dtype=np.uint8)
    out = colorizer(sample)
    if out.ndim == 2:
        v = int(out[0, 0])
        return (v, v, v)
    return tuple(int(c) for c in out[0, 0])


def _build_mesh(builder):
    """Run a generate_models.py builder and return just the mesh (ignore the
    accompanying uv / greyscale texture — pure-emissive doesn't need them).
    """
    mesh, _, _ = builder()
    return mesh


def _prompt_intensity(default=DEFAULT_INTENSITY):
    """Single float prompt; clamps to INTENSITY_RANGE; Enter accepts default."""
    lo, hi = INTENSITY_RANGE
    print(f"\n  Emissive intensity (1.0 = standard glow, higher = brighter).")
    raw = input(f"  Intensity [{lo}..{hi}, default {default}]: ").strip()
    if not raw:
        return default
    try:
        v = float(raw)
        return max(lo, min(hi, v))
    except ValueError:
        print(f"  Invalid value, using default {default}")
        return default


def build_emissive_shape(shape_name, builder, rgb, intensity):
    """Compose the geometry + pure-emissive material into a single mesh ready
    for `.export(path)`.  All the work lives in _apply_emissive — this just
    wires the builder output through it.
    """
    mesh = _build_mesh(builder)
    return _apply_emissive(mesh, rgb, intensity)


# ─── Main ───────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    use_defaults = "-y" in sys.argv or "--defaults" in sys.argv

    if use_defaults:
        chosen_rgb     = (255, 0, 0)     # red
        chosen_label   = None
        intensity      = DEFAULT_INTENSITY
    else:
        print("\n  Pure-emissive primitive — appears self-illuminated, ignores scene lights.")
        print(f"  Output folder: {OUTPUT_DIR}")
        print("\n  Choose ONE colour to apply to all primitives in this run.")

        fn, _, chosen_label = prompt_color("Emissive", "self-illumination colour")
        chosen_rgb = colorizer_to_rgb(fn)
        intensity  = _prompt_intensity()

    print(f"\n  RGB = {chosen_rgb}  intensity = {intensity}")
    for shape_name, builder in EMISSIVE_SHAPES:
        print(f"\nBuilding emissive {shape_name}...", end=" ", flush=True)
        mesh = build_emissive_shape(shape_name, builder, chosen_rgb, intensity)

        labels = [l for l in [chosen_label] if l]
        stem   = "-".join(["emissive", shape_name] + labels)
        stem  += f"-x{intensity:g}"
        out    = os.path.join(OUTPUT_DIR, f"{stem}.glb")
        mesh.export(out)
        size_kb  = os.path.getsize(out) / 1024
        rel_path = os.path.relpath(out, SCRIPT_DIR)
        print(f"→ {rel_path}  ({size_kb:.1f} KB)")

    print(f"\nDone.  Files written to: {OUTPUT_DIR}")
