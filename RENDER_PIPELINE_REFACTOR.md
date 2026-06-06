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

## 4. Proposed interface — granular per-pass methods (not a monolithic `render`)

**Design decision (settled):** `ScenePipeline` exposes **one encode method per pass**,
all sharing a single set of pipeline states built once in `init`. It does **not**
expose a single `render(ctx)` that owns the whole frame.

Why not the monolithic form: the code today does **not** composite into one uniform
pass. Two facts drive this:

1. **The driver — not the effect code — owns the render target and pass descriptor.**
   `Renderer.draw` (Renderer.swift:797–836) chooses between three targets per frame:
   the drawable, the feedback scene-texture, or a fog-offscreen-depth variant. The
   exporter chooses an offscreen private texture. A `ScenePipeline.render` that owned
   a `colorTarget` would have to absorb all of that target juggling.
2. **Passes split into two kinds, and that split is real:**
   - **In-encoder passes** drawn into the driver's already-open main
     `MTLRenderCommandEncoder`: background/skybox → holdout → opaque → transparent →
     particles → lasers/hits/sparks.
   - **Own-encoder post passes** that open their *own* command-buffer pass:
     `drawFogVolume(commandBuffer:)` and `applyColorGrade(commandBuffer:)`
     (plus the exporter-only `lumaAlpha` rewrite).

Granular methods keep each migration step a clean one-pass move, let the drivers keep
owning encoder/target creation, and still give the "one place per effect" payoff. A
monolithic `render` can be reconsidered at the very end if target ownership ever
simplifies — but we do not commit to it up front.

```swift
struct SceneRenderContext {
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
    var includeFX:        Bool                // fog/particles/lasers
    var suppressTransparent: Bool             // Background pass
    var isWireframe:      Bool
}

final class ScenePipeline {
    init(device: MTLDevice, library: MTLLibrary)   // builds ALL effect pipelines once

    // ── In-encoder passes: caller passes its already-open encoder ──────────────
    func encodeBackground(into encoder: MTLRenderCommandEncoder, _ ctx: SceneRenderContext)
    func encodeParticles (into encoder: MTLRenderCommandEncoder, _ ctx: SceneRenderContext)
    func encodeLasers    (into encoder: MTLRenderCommandEncoder, _ ctx: SceneRenderContext)

    // ── Own-encoder post passes: caller passes the command buffer + targets ────
    func encodeFogVolume (commandBuffer: MTLCommandBuffer, color: MTLTexture,
                          sceneDepth: MTLTexture, _ ctx: SceneRenderContext)
    func encodeColorGrade(commandBuffer: MTLCommandBuffer, color: MTLTexture,
                          _ ctx: SceneRenderContext)
}
```

(Geometry + holdout already live in the shared `SceneGeometryEncoder`; `ScenePipeline`
may *call* it but need not re-own it. The exact signatures above are illustrative —
match the existing draw-function shapes when each pass actually moves.)

Notes:
- Overlays (gizmos/widgets/HUD) and export post (countdown/luma-alpha/writer) are
  **not** in `ScenePipeline` — they stay in their drivers.
- `colorMode`/`suppressTransparent`/`includeFX` are the knobs Export All already
  toggles; centralizing them here removes the parallel logic in both files. (The
  export luma-premult-vs-coverage *alpha* choice stays in the exporter — it's a
  post-`ScenePipeline` rewrite, see §5 Phase 5.)
- `LaserHitSystem` becomes a single instance owned by the driver and passed in (the
  exporter's separate instance at VideoExporter.swift:222 goes away).

---

## 5. Migration plan (incremental, verify after each step)

Do this **one pass at a time**, keeping the app working and each diff reviewable.
Build with `./make_app.sh` after each phase, then render the same scene live and
exported and confirm they match (see §6).

**Phase 0 — Scaffold.** Create `ScenePipeline.swift`. Move the *construction* of the
shared pipeline states (the `makeRenderPipelineState` calls + descriptors for
background, skybox, fog, laserBeam, laserHit, spark, particleFX, colorGrade) out of
both drivers and into `ScenePipeline.init`, built once. `Renderer` constructs the
`ScenePipeline` and hands it to `VideoExporter` (extend the `VideoExporter` init,
currently passing only `pipelineState`/`depthStencilState`/`holdout`/`transparent`).
**No draw calls move yet** — both drivers still draw, but reference
`scenePipeline.<state>` instead of their own stored fields. *Verify: viewport + export
visually unchanged.*

**Phase 1 — Background + skybox.** Move both drivers' inline background/skybox draw
(Renderer.swift:838–874; VideoExporter.swift:~880–900) into
`scenePipeline.encodeBackground(into:_:)`. Delete the exporter's duplicate descriptors.
Safest, most self-contained.

**Phase 2 — Fog volume.** Move `drawFogVolume(commandBuffer:)` into
`encodeFogVolume(...)` (own-encoder post pass).

**Phase 3 — Weather particles.** Move `drawParticleEffects` into `encodeParticles(...)`
(`ParticleManager` already shared as state).

**Phase 4 — Lasers (beam + hit + spark).** Move the laser/hit/spark draws; collapse the
two `LaserHitSystem` instances into one passed via context (the exporter's instance at
VideoExporter.swift:222 goes away).

**Phase 5 — Color grade.** Move `applyColorGrade(commandBuffer:)` into
`encodeColorGrade(...)`. Keep the exporter's `lumaAlpha` alpha-rewrite *after*
`ScenePipeline` in the exporter — it's export-only.

**Phase 6 — Cleanup.** Delete now-dead pipeline fields from `VideoExporter`; update
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
