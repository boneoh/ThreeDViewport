# Creating & Exporting an HDR Background Scene

A how-to guide for building a scene and baking it into an environment `.hdr` you can
reuse as **lighting** and/or a **backdrop**. This is the task-oriented companion to
the [HDR & Image-Based Lighting](HDR.md) reference page.

---

## The one idea to hold onto

When you **export a scene to HDR**, the app stands at the **Probe**'s position and
photographs the whole scene in *every* direction — a full 360° × 180°
**equirectangular panorama** captured from that single point.

When you later **use** that HDR (as lighting or background), it's painted onto an
**infinitely large sphere** around the scene. That means:

- **All depth/parallax is gone.** Everything in the panorama reads as if it's
  infinitely far away. A near object and a far object both become "the surroundings."
- **What matters is the *angle* each thing takes up** from the probe, not its real
  size or distance — only the *ratio* of size to distance.

So building a good HDR background is really about arranging geometry at the right
**angular sizes** as seen from the probe.

---

## Step by step

1. **Start a clean scene.** Load or build the geometry you want *around* you — sky
   dome, distant hills, walls, a floor, set dressing. Hide anything you don't want
   captured (hidden objects are skipped; the probe gizmo is never captured).
2. **Place the Probe where your future camera/action will be.** Open
   [Probe Inspector](Probe-Inspector.md), and position the probe at the spot your
   real scene will be built around — usually the origin `(0, 0, 0)`. The bake is shot
   from here, so this becomes the "center of the world" for the panorama.
3. **Light it.** The bake captures the **lit** scene (your [lights](Lights-and-Background.md)
   + IBL), as raw linear brightness. If you want the HDR to also *light* a future
   scene, make sure there's a bright sky / large bright area — that brightness becomes
   the image-based light later.
4. **Decide on the backdrop.** **File ▸ Export Scene to HDR File…** offers
   *Include current environment background* — on = your current sky/gradient is baked
   in behind the geometry; off = geometry/lights over black.
5. **Pick resolution** (see below) and **Save**. The file lands in your HDRs folder
   with an auto-incrementing name.
6. **Reuse it.** **File ▸ Open Lighting HDR…** to light with it, and/or
   **File ▸ Open Background HDR…** to show it as the backdrop. See [HDR](HDR.md).

---

## Sizing & distance — the part that's easy to get wrong

Because the panorama is shot from the probe, an object's **apparent size** in the
final HDR is its **angular size**: roughly `width ÷ distance` (in radians; multiply by
57° for degrees). Practical consequences:

- **Keep the backdrop large and far from the probe.** Distant, big geometry reads as
  believable surroundings. A handy rule of thumb: to make something span about **30°**
  of the panorama, its width should be **≈ half its distance** from the probe
  (`width ≈ 0.5 × distance`). Want it smaller/farther-feeling? Increase the distance.
- **Don't crowd the probe.** Anything within a few units looms huge and wraps around —
  it stops looking like "background" and starts looking like a wall in your face. The
  near clip is tiny (1 cm), so close objects *will* be captured, just distorted.
- **Scale is relative — only the ratio matters.** A 100-unit dome at 50 units away
  looks identical to a 10-unit dome at 5 units away. Build at whatever scale is
  comfortable and control the *look* with the size-to-distance ratio.
- **Keep the important stuff near the horizon.** Equirectangular projection stretches
  the **poles** (straight up / straight down) badly, while the **equator** (horizon
  band) is faithful. Put your hero scenery within roughly **±45° of the horizon**; use
  the zenith for sky and the nadir for ground, where stretching is least noticeable.
- **A floor:** a large flat plane *below* the probe fills the lower hemisphere as
  ground. A large dome/sphere around everything fills the sky.
- **Surround, don't leave gaps.** The bake captures all directions — any direction
  with nothing in it (and background off) becomes black in the HDR. Decide whether
  that's intended (e.g., a black void) or fill it.

---

## Resolution: how much detail to keep

The export is a 2:1 equirect at one of two sizes. Detail is set by pixels-per-degree
along the equator:

| Resolution | Equator px | ≈ px / degree | Good for |
|------------|-----------|---------------|----------|
| **2K** (2048 × 1024) | 2048 | ~5.7 | soft skies, simple backdrops, lighting-only use |
| **4K** (4096 × 2048) | 4096 | ~11.4 | crisp distant detail, recognisable structures |

If the backdrop has fine or near-ish detail, choose **4K**. For a pure lighting
environment (blurry by nature), **2K** is plenty and lighter.

---

## What is — and isn't — captured

| Captured | Not captured |
|----------|--------------|
| Visible geometry, lit by your lights + IBL | **Fog** and **weather particles** (smoke/rain/etc.) |
| The environment backdrop (if *Include…* is on) | **Lasers** and spark effects |
| Raw linear brightness (HDR range preserved) | The **Color Grade** (exposure/contrast/etc.) — *not* applied |

Two things follow from the right column:

- **Set real brightness with lights / materials / IBL, not the Color Grade panel.**
  The bake is raw radiance, so grading is ignored — a scene that only looks bright
  because of a Color Grade boost will bake dark.
- **Bake clean, add atmosphere later.** Build the HDR from solid geometry + lighting;
  add fog, weather, and lasers in the *real* scene that uses the HDR, not in the bake.

---

## Quick recipe: a simple sky + ground backdrop

1. Probe at origin.
2. A large **ground plane** a few units below the probe (fills the lower hemisphere).
3. A large **dome or sphere** enclosing everything (the sky); give it an emissive or
   bright material if you want it to light future scenes.
4. A few **distant** large shapes near the horizon as landmarks (remember
   `width ≈ 0.5 × distance` for ~30° wide).
5. Light the scene; turn **Include current environment background** on if you also
   want your gradient/sky color baked in.
6. Export at **4K** if there's recognisable detail, **2K** if it's a soft lighting env.
7. Load it back via **Open Lighting HDR…** / **Open Background HDR…** and check it from
   the scene camera; re-bake if the scale/horizon needs adjusting.

---

See also: [HDR & Image-Based Lighting](HDR.md) · [Probe Inspector](Probe-Inspector.md) ·
[Lights & Background](Lights-and-Background.md) · [Settings](Settings.md).
