"""
generate_all.py  —  Batch-generate every colour × material combination.

Shape output     : ~/Documents/ThreeDViewport/Models/<shape>/
Robot output     : ~/Documents/ThreeDViewport/Models/robot/
Station output   : ~/Documents/ThreeDViewport/Models/station/
Emissive output  : ~/Documents/ThreeDViewport/Models/emissive/

Filenames
  shapes   : {shape}-{colour}-{material}.glb        (150 per shape)
  robot    : robot-{colour}.glb                     (30 uniform-colour)
             robot-{body-colour}-{head-colour}.glb  (900 two-tone, opt-in)
  station  : station-{colour}-{material}.glb        (150 — palette c1/c2 get
             distinct heavy/hydrogen/bond colours via palette_molecule_colors)
  emissive : emissive-{shape}-{colour}.glb          (9 shapes × 30 colours)

Usage:
    python3 generate_all.py              # shapes + robots + stations + emissives
    python3 generate_all.py --two-tone   # adds 900 two-tone robots
    python3 generate_all.py --shapes-only
    python3 generate_all.py --robot-only
    python3 generate_all.py --station-only
    python3 generate_all.py --emissive-only
"""

import os
import sys

from generate_models import (
    GREY_RANGES, PALETTES, MATERIAL_PRESETS, SHAPES, SHAPE_OUTPUT_DIRS,
    MOLECULE_BUILDERS, palette_molecule_colors,
    apply_palette, apply_tonal_range, apply_texture, make_png_bytes,
)
from generate_character import build_robot
from generate_station   import build_station_scene, colorizer_to_rgb
from generate_emissive  import (
    EMISSIVE_SHAPES, DEFAULT_INTENSITY, build_emissive_shape,
)

MODELS_ROOT = os.path.expanduser("~/Documents/ThreeDViewport/Models")


def all_colors():
    """Yield (label, colorizer_fn, palette_key, variant) for all 30 named colour options.

    palette_key and variant are None for greyscale and normal palette entries.
    For C1/C2 palette entries, palette_key is the PALETTES dict key ("7"–"14")
    and variant is "c1" or "c2" — used by molecule scene builders.
    """
    for _, (name, (low, high)) in GREY_RANGES.items():
        label = name.lower().replace(" ", "-")
        yield label, lambda g, lo=low, hi=high: apply_tonal_range(g, lo, hi), None, None

    for key, (name, base_stops, comp1, (comp2a, comp2b)) in PALETTES.items():
        base = name.lower().replace(" ", "-")
        yield base,         lambda g, s=base_stops:                     apply_palette(g, s), key, None
        yield base + "-c1", lambda g, s=[(0, comp1)] + base_stops[1:]:  apply_palette(g, s), key, "c1"
        c2 = [(0, comp2a), (96, comp2b)] + base_stops[1:]
        yield base + "-c2", lambda g, s=c2:                             apply_palette(g, s), key, "c2"


def generate_shapes():
    colors    = list(all_colors())
    materials = [(n.lower().replace(" ", "-"), metal, rough)
                 for _, (n, metal, rough) in MATERIAL_PRESETS.items()]
    total = len(SHAPES) * len(colors) * len(materials)
    done  = 0

    for shape_name, builder, _ in SHAPES:
        out_dir = os.path.join(MODELS_ROOT, SHAPE_OUTPUT_DIRS.get(shape_name, shape_name))
        os.makedirs(out_dir, exist_ok=True)
        print(f"  {shape_name}  ({len(colors) * len(materials)} files)")

        mol_builder = MOLECULE_BUILDERS.get(shape_name)

        for color_label, colorizer, palette_key, variant in colors:
            for mat_label, metalness, roughness in materials:
                stem = f"{shape_name}-{color_label}-{mat_label}"
                out  = os.path.join(out_dir, f"{stem}.glb")

                if mol_builder and palette_key and variant in ("c1", "c2"):
                    heavy, h, bond = palette_molecule_colors(palette_key, variant)
                    mol_builder(heavy, h, bond, metalness, roughness).export(out)
                else:
                    mesh, uv, gray = builder()
                    apply_texture(mesh, uv, make_png_bytes(colorizer(gray)),
                                  metalness, roughness).export(out)

                done += 1
                print(f"\r    {done}/{total}  {stem}.glb", end="", flush=True)

    print(f"\r  {done} shape files written.{' ' * 60}")


def generate_robot(two_tone=False):
    colors  = list(all_colors())
    out_dir = os.path.join(MODELS_ROOT, "robot")
    os.makedirs(out_dir, exist_ok=True)

    print(f"  Uniform colour  ({len(colors)} files)")
    for i, (label, fn, *_) in enumerate(colors, 1):
        out = os.path.join(out_dir, f"robot-{label}.glb")
        build_robot(fn, fn, fn, fn).export(out)
        print(f"\r    {i}/{len(colors)}  robot-{label}.glb", end="", flush=True)
    print(f"\r  {len(colors)} uniform robot files written.{' ' * 60}")

    if not two_tone:
        return

    # body+legs = one colour, head+arms = another
    pairs = [(bl, bf, hl, hf)
             for bl, bf, *_ in colors
             for hl, hf, *_ in colors]
    print(f"  Two-tone  ({len(pairs)} files)")
    for i, (bl, bf, hl, hf) in enumerate(pairs, 1):
        stem = f"robot-{bl}-{hl}"
        out  = os.path.join(out_dir, f"{stem}.glb")
        build_robot(bf, hf, hf, bf).export(out)
        print(f"\r    {i}/{len(pairs)}  {stem}.glb", end="", flush=True)
    print(f"\r  {len(pairs)} two-tone robot files written.{' ' * 60}")


def generate_station():
    """Iterate (colour × material) just like the molecule shapes do:
       - palette c1/c2 variants → distinct heavy/hydrogen/bond colours
       - everything else (greyscale + base-palette) → uniform colour all parts
    """
    colors    = list(all_colors())
    materials = [(n.lower().replace(" ", "-"), metal, rough)
                 for _, (n, metal, rough) in MATERIAL_PRESETS.items()]
    out_dir   = os.path.join(MODELS_ROOT, "station")
    os.makedirs(out_dir, exist_ok=True)

    total = len(colors) * len(materials)
    done  = 0
    print(f"  station  ({total} files)")
    for color_label, colorizer, palette_key, variant in colors:
        if palette_key and variant in ("c1", "c2"):
            heavy, h, bond = palette_molecule_colors(palette_key, variant)
        else:
            rgb = colorizer_to_rgb(colorizer)
            heavy = h = bond = rgb

        for mat_label, metalness, roughness in materials:
            stem = f"station-{color_label}-{mat_label}"
            out  = os.path.join(out_dir, f"{stem}.glb")
            build_station_scene(heavy, h, bond, metalness, roughness).export(out)
            done += 1
            print(f"\r    {done}/{total}  {stem}.glb", end="", flush=True)
    print(f"\r  {done} station files written.{' ' * 60}")


def generate_emissive(intensity=DEFAULT_INTENSITY):
    """Iterate (shape × colour) with a fixed emissive intensity.  Pure-emissive
    material (no diffuse / metallic / specular) — see generate_emissive.py.
    """
    colors  = list(all_colors())
    out_dir = os.path.join(MODELS_ROOT, "emissive")
    os.makedirs(out_dir, exist_ok=True)

    total = len(EMISSIVE_SHAPES) * len(colors)
    done  = 0
    print(f"  emissive  ({total} files, intensity {intensity})")
    # c1/c2 share the bright palette stop with the base variant, so sampling
    # at the default brightness (220) makes all three look identical.  Sample
    # the variant-specific stop instead: c1's comp1 lives at 0; c2's comp2b
    # lives at 96.  Base palette + greyscale keep the default bright sample.
    for shape_name, builder in EMISSIVE_SHAPES:
        for color_label, colorizer, _palette_key, variant in colors:
            if variant == "c1":
                rgb = colorizer_to_rgb(colorizer, brightness=0)
            elif variant == "c2":
                rgb = colorizer_to_rgb(colorizer, brightness=96)
            else:
                rgb = colorizer_to_rgb(colorizer)
            stem = f"emissive-{shape_name}-{color_label}"
            out  = os.path.join(out_dir, f"{stem}.glb")
            mesh = build_emissive_shape(shape_name, builder, rgb, intensity)
            mesh.export(out)
            done += 1
            print(f"\r    {done}/{total}  {stem}.glb", end="", flush=True)
    print(f"\r  {done} emissive files written.{' ' * 60}")


if __name__ == "__main__":
    two_tone      = "--two-tone"      in sys.argv
    shapes_only   = "--shapes-only"   in sys.argv
    robot_only    = "--robot-only"    in sys.argv
    station_only  = "--station-only"  in sys.argv
    emissive_only = "--emissive-only" in sys.argv

    any_only   = shapes_only or robot_only or station_only or emissive_only
    do_shapes   = (not any_only) or shapes_only
    do_robot    = (not any_only) or robot_only
    do_station  = (not any_only) or station_only
    do_emissive = (not any_only) or emissive_only

    if do_shapes:
        shape_total = len(list(all_colors())) * len(MATERIAL_PRESETS) * len(SHAPES)
        print(f"\nGenerating shapes ({shape_total:,} files)...")
        generate_shapes()

    if do_robot:
        robot_total = 30 + (900 if two_tone else 0)
        print(f"\nGenerating robots ({robot_total} files)...")
        generate_robot(two_tone=two_tone)

    if do_station:
        station_total = len(list(all_colors())) * len(MATERIAL_PRESETS)
        print(f"\nGenerating stations ({station_total} files)...")
        generate_station()

    if do_emissive:
        emissive_total = len(EMISSIVE_SHAPES) * len(list(all_colors()))
        print(f"\nGenerating emissives ({emissive_total} files)...")
        generate_emissive()

    print("\nDone.")
