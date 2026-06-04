# Atmosphere (Fog & Weather)

One panel for the volumetric **fog** and the **weather/particle emitters**
(rain / snow / sleet). Both can be keyframed.

**Open:** Window ▸ Atmosphere…  ·  **⌘⇧A**

## Fog volume

| Control | Description |
|---------|-------------|
| **Enabled** | Toggles the fog volume. |
| **Color** | Fog tint. |
| **Density** | 0…1. |
| **Position / Size** | The fog box centre and dimensions. |
| **Variance** | Noise variation within the volume. |
| **Quality** | Raymarch step count (8…96) — higher is smoother but slower. |
| **Add Keyframe / Clear** | Stamp / clear fog keyframes (whole-volume snapshot at the playhead). |

## Weather emitters

Add / remove emitters with the **+ / −** buttons (up to the per-scene maximum,
shown as a count). Per emitter:

| Control | Description |
|---------|-------------|
| **Enabled**, **Type** | Rain / Snow / Sleet. |
| **Color**, **Density** | — |
| **Position / Size** | Emitter box (copy / paste / zero). |
| **Particle Size**, **Lifetime**, **Growth**, **Opacity** | Particle look/lifespan. |
| **Fall Speed**, **Streak** | Motion + motion-blur streak length. |
| **Variance** | Spread/randomness. |
| **Add Keyframe / Clear** | Per-emitter keyframes. |

## Keyframes & easing

Fog and each emitter have their own Timeline lanes with per-track easing (linear or
spline tiers) — set it in the [Timeline Editor](Timeline-Editor.md).

> FX (fog, weather, lasers, sparks) render in the **Full**, **Scene**, and **FX**
> Export All passes. See [Export](Export.md).

## Persistence

Fog settings, emitters, and their keyframes are saved with the project.
