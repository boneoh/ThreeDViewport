# HDR & Image-Based Lighting

ThreeDViewport lights scenes with **image-based lighting (IBL)**: an equirectangular
Radiance **`.hdr`** image wraps the scene like a sphere and acts as a soft,
omnidirectional light source — and, optionally, as the visible backdrop. This page
covers the three pieces that work together: the **IBL intensity** control, the
**environment HDR files** (lighting vs background), and **baking a new `.hdr`** from
your scene.

---

## IBL intensity

In [Lights & Background](Lights-and-Background.md) (**⌘L**), the **IBL** slider sets
how strongly the environment HDR lights the scene.

| | |
|--|--|
| **Range** | 0.00 – 2.00 (default **1.00**) |
| **0** | environment contributes no light — the scene is lit only by the scene lights you add |
| **1** | the HDR's natural exposure |
| **>1** | brighter, punchier ambient/reflected light |

This is **live** — drag it and the viewport updates immediately. It scales only the
*lighting* contribution; it does **not** change how bright the HDR looks as a
**backdrop** (that's the Background **Intensity**, below). IBL intensity is saved
with the project.

> Reflective (metallic / low-roughness) materials show IBL most strongly, since they
> mirror the environment. See [Model Inspector](Model-Inspector.md) for the
> metallic/roughness controls.

---

## Environment HDR files

Two HDRs can be loaded independently, so you can **light** with one image and
**show** another behind the models. Both are loaded from the **File** menu and both
are Radiance `.hdr` (equirectangular) images.

| File menu item | Role |
|----------------|------|
| **Open Lighting HDR…** | The HDR that drives **IBL** (the light on your models). Also the default backdrop source for the Environment background mode. |
| **Open Background HDR…** | A separate image used **only as the backdrop**. Opening one switches the Background mode to **Environment** so you see it right away. |

**How they interact**

- The **Background ▸ Environment** mode shows the **background HDR** if one is set;
  otherwise it mirrors the **lighting HDR**. So you can light the scene with a studio
  HDR while showing a sky, or use one image for both.
- The Environment background has its own **Intensity** (backdrop brightness) and
  **Horizon** (shifts the horizon line up/down) — these are independent of the **IBL
  intensity** that lights the geometry.

**Loading & hot-reload**

- Pickers open in your **HDRs folder** (set in [Settings](Settings.md); default
  `~/Documents/ThreeDViewport/HDRs`).
- **Open Lighting HDR…** recomputes the IBL on the spot — the new lighting takes
  effect immediately.
- Both HDR **paths are saved with the project**; if a file is missing on reopen, the
  app falls back to the bundled default rather than failing.

> The **default** lighting HDR (the Settings folder path used when no project HDR is
> set) is read **once at launch**, because the IBL is precomputed on startup.
> Changing that default in Settings applies on the **next launch** — but loading an
> HDR through **Open Lighting HDR…** is immediate. (See [Settings](Settings.md).)

---

## Export Scene to HDR File — bake your own

**File ▸ Export Scene to HDR File…** renders the current scene into a brand-new
equirectangular `.hdr`, captured from the [Probe](Probe-Inspector.md)'s position. Use
it to turn a scene you've built (geometry, lights, a sky) into a reusable
lighting/background environment — then load it back via Open Lighting/Background HDR.

> For a full walkthrough — including how to size and place objects so they read well
> as a backdrop — see **[Creating & Exporting an HDR Background Scene](Creating-HDR-Backgrounds.md)**.

**Workflow**

1. Position the [Probe](Probe-Inspector.md) where you want the capture origin — the
   bake looks out in all directions from this point.
2. Hide anything you don't want captured (the probe gizmo itself is never baked).
3. **File ▸ Export Scene to HDR File…** opens a save panel with options:

   | Option | Choices |
   |--------|---------|
   | **Resolution** | **2048 × 1024 (2K)** or **4096 × 2048 (4K)** |
   | **Include current environment background** | On = bake the visible backdrop into the image; Off = geometry/lights over black |

4. The default name comes from the project with an auto-incrementing `.NN` suffix,
   and it saves into your **HDRs folder** by default. Click **Save**.

The result is a standard equirectangular `.hdr` you can immediately reuse as a
Lighting or Background HDR here, or in another tool.

---

## Persistence

IBL intensity, both HDR paths, and the background mode / intensity / horizon are all
saved with the project. Missing HDR files fall back to the bundled default on load.

See also: [Creating & Exporting an HDR Background Scene](Creating-HDR-Backgrounds.md) ·
[Lights & Background](Lights-and-Background.md) · [Probe Inspector](Probe-Inspector.md) ·
[Settings](Settings.md) · [Advanced guide](Advanced.md).
