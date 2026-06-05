# Render Pipeline Refactor — Planning Doc

Status: **proposed / not started.** This is a design + migration plan to do *before*
adding or modifying visual effects. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
current component overview.

---

## 1. Why

The app has two ~1,800-line rendering drivers — `Renderer.swift` (viewport) and
`Export/VideoExporter.swift` (export). They share the mesh draw (`SceneGeometryEncoder`)
and the `.metal` shader functions, **but each independently builds the effect
pipeline states and re-implements the per-frame compositing order.** The code says
so directly: *"mirrors Renderer's X pipeline,"* *"shared from the Renderer so export
matches."*

**Consequence:** adding one effect today means writing the shader once but wiring the
pipeline + inserting it into the draw order + setting its blend/depth state **twice**,
and keeping the two in lockstep. The failure mode is silent — preview looks right,
export quietly doesn't match. Every new effect multiplies this tax.

**Goal:** one shared scene-compositing engine, called by two thin drivers, so a new
effect is added **once** and both paths get it identically.

**Non-goal:** merging `Renderer` and `VideoExporter` into a single class. Their
lifecycles differ enough (drawable+vsync+overlays vs offscreen+readback+writer) that
one class would be a branch-heavy god-object. Keep two drivers; share the core.

---

## 2. Current state — what's shared vs duplicated

**Already shared (the pattern to extend):**
- `SceneGeometryEncoder` — the PBR mesh draw, one source of truth.
- `holdoutPipelineState`, `ibl` (`IBL`), `backgroundEquirect` — built by `Renderer`,
  handed to `VideoExporter`.
- The `.metal` library functions (both load the same shaders).

**Duplicated today (everything between geometry and pixels):**
- Pipeline-state construction, built independently in *both* files with near-identical
  descriptors: **background gradient, skybox, fog volume, laser beam, laser hit,
  color grade.**
- A second `LaserHitSystem` instance inside `VideoExporter`.
- The **per-frame compositing order**, re-implemented in each driver:
  `background → holdout → opaque → transparent → fog → particles → lasers → color grade`
  (`→ feedback` on the viewport / pipelined offscreen on export).

**Legitimately driver-specific (must stay split):**

| Viewport-only (`Renderer`) | Export-only (`VideoExporter`) |
|----------------------------|-------------------------------|
| MTKView drawable + present, vsync, ~50fps cap | Offscreen private texture → `getBytes` → `CVPixelBuffer` → `AVAssetWriter` |
| Live-lights decouple, wall-clock tick | Deterministic per-frame clock |
| Gizmos, scene widgets, `V` motion-path overlay, probe gizmo, HUD | 3-2-1 countdown + flash frame |
| Hit-testing context | Luma-alpha / coverage-alpha rewrite + premult tagging (`lumaAlphaPipelineState`) |
| | Codec/format handling; `suppressTransparent`; `includeLaserFX`; pass-driven visibility |

This table is the seam: everything on the left/right stays in its driver; everything
*not* in this table (the effect stack) moves into the shared engine.

---

## 3. Target architecture

```
                 ┌─────────────────────────────┐
   Renderer ───► │                             │ ◄─── VideoExporter
 (viewport driver)│        ScenePipeline        │   (export driver)
                 │  (shared compositing core)  │
                 └─────────────────────────────┘
```

- **`ScenePipeline` (new, shared)** — owns *all* effect pipeline states and the
  canonical pass order. Renders a scene + effects into a caller-provided color
  attachment. A new effect is added here, once.
- **`Renderer` (viewport driver)** — owns MTKView/drawable, fps, live lights;
  calls `ScenePipeline` to fill the drawable, then draws viewport-only overlays
  (gizmos, widgets, HUD) on top.
- **`VideoExporter` (export driver)** — owns the offscreen target, writer,
  deterministic clock, countdown; calls the **same** `ScenePipeline`, then applies
  export-only post (luma-alpha, codec).

This is the existing `SceneGeometryEncoder` pattern lifted from "just geometry" to
"the whole effect stack."

---

## 4. Proposed interface (sketch — illustrative, not final)

A render context carries everything a pass needs; flags express the driver/pass
differences that are currently scattered as duplicated `if`s.

```swift
struct SceneRenderContext {
    // Targets
    var colorTarget:      MTLTexture          // where the composite lands
    var depthTarget:      MTLTexture
    let commandBuffer:    MTLCommandBuffer

    // Camera / timing
    var viewProjection:   matrix_float4x4
    var eyePosition:      SIMD3<Float>
    var time:             Double              // deterministic on export, wall-clock live

    // Scene + effect state (references to the existing managers/settings)
    var objects:          [SceneObject]
    var groupTransforms:  [Int: matrix_float4x4]
    var lights:           LightUniforms
    var ibl:              IBL?
    var background:       BackgroundConfig
    var backgroundEquirect: MTLTexture?
    var fog:              FogSettings?
    var particles:        ParticleManager?
    var lasers:           LaserHitSystem?     // single instance, passed in
    var colorGrade:       ColorGradeSettings?

    // Mode / pass flags (replace today's duplicated branches)
    var colorMode:        RenderColorMode     // color / greyscale / B+W matte
    var alphaMode:        AlphaMode           // none / lumaPremult / coverage  (export)
    var includeFX:        Bool                // fog/particles/lasers
    var suppressTransparent: Bool             // Background pass
    var isWireframe:      Bool
}

final class ScenePipeline {
    init(device: MTLDevice, library: MTLLibrary)   // builds ALL effect pipelines once

    /// Encodes the full ordered pass set into ctx.colorTarget. The ONLY place the
    /// pass order and per-effect blend/depth state live.
    func render(_ ctx: SceneRenderContext)
}
```

Notes:
- Overlays (gizmos/widgets/HUD) and export post (countdown/luma-alpha/writer) are
  **not** in `ScenePipeline` — they stay in their drivers.
- `alphaMode`/`colorMode`/`suppress*`/`includeFX` are the knobs Export All already
  toggles; centralizing them here removes the parallel logic in both files.
- `LaserHitSystem` becomes a single instance owned by the driver and passed in (the
  exporter's separate instance goes away).

---

## 5. Migration plan (incremental, verify after each step)

Do this **one pass at a time**, keeping the app working and each diff reviewable.
After every step, render the same scene live and exported and confirm they match.

1. **Scaffold** `ScenePipeline` that does nothing but call the existing
   `SceneGeometryEncoder` (geometry + holdout). Route `Renderer`'s geometry pass
   through it. Verify viewport unchanged. Then route `VideoExporter` through it too.
2. **Background + skybox** — move both pipelines + the draw into `ScenePipeline`;
   delete the duplicated descriptors from `VideoExporter`.
3. **Fog volume** — same.
4. **Weather particles** — same (`ParticleManager` already shared as state).
5. **Lasers** (beam + hit) — collapse the two `LaserHitSystem` instances into one
   passed via context.
6. **Color grade** — move the post pass; keep export's luma-alpha rewrite *after*
   `ScenePipeline` in the exporter (it's export-only).
7. **Cleanup** — delete now-dead pipeline fields from `VideoExporter`; update
   `ARCHITECTURE.md` (§ Renderer and § Export Pipeline) to describe the shared core.

Order rationale: start with the safest, most self-contained passes (background) and
end with the most entangled (lasers, color grade), so risk rises only as confidence does.

---

## 6. Verification strategy

- **Golden-frame compare:** pick 2–3 scenes exercising each effect (fog, weather,
  lasers, feedback, matte mode, 4444 alpha). After each migration step, export a few
  frames and eyeball against a screen grab of the live viewport at the same time/camera.
- **Per-pass toggle:** verify each effect still responds to its enable flag in both
  paths after it moves.
- **Export All:** run a full cycle (Scene / Solo / Matte / Background / Background
  Matte / FX) and confirm alpha (luma-premult vs coverage) and black-bg passes are
  unchanged.
- The split is correct when **nothing in the export output changes** across the whole
  migration — the refactor is behavior-preserving by construction.

---

## 7. Definition of done

Adding a new effect afterward is: **write the shader, add its pipeline + draw step to
`ScenePipeline` once, expose its enable flag.** Both viewport and export pick it up
with no second wiring and no preview/export drift.

## 8. Risks & mitigations

- **Large surface area (two 1,800-line files).** → Incremental, one pass per step,
  verified each time; never a single big-bang diff.
- **Subtle blend/depth-state drift during the move.** → Move descriptors verbatim;
  diff old vs new descriptor fields before deleting the duplicate.
- **Hidden coupling (e.g. feedback's offscreen pipelining on export).** → Keep
  feedback compositing in the drivers initially; `ScenePipeline` renders the scene
  into a target, and *who owns that target* (drawable vs offscreen vs feedback slot)
  stays a driver decision.
- **Timing differences.** → `time` is passed in via context; `ScenePipeline` never
  reads a clock itself, so deterministic-export vs wall-clock-live is a driver concern.

## 9. When

Highest leverage **before** the next batch of effects (smoke variants, new feedback,
etc.) — every effect added before the refactor is one more thing to migrate; every
effect added after is free on both paths. Best done as its own session with explicit
before/after verification, not bolted onto a feature change.
