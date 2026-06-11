# Known Limitations

A single place to track the app's current rough edges, intentional design choices,
and not-yet-built features. Each entry is tagged:

- **[by design]** — intentional; behaves this way on purpose.
- **[gap]** — a rough edge worth fixing eventually.
- **[not built]** — planned or absent.
- **[WAI]** — working as intended, but surprising enough to call out.

Where a workaround exists it's noted in *italics*.

---

## Import Project

See [Import Project](docs/Import-Project.md).

- **Camera + globals aren't imported** — camera + camera moves, color grade,
  background/HDRI, and feedback are skipped; the host scene keeps its own. (Fog and
  particles **are** imported, opt-in — fog only when the host has none.) **[by design]**
- **Imported spin/orbit import as baked keyframes** (the live rate markers aren't), so
  they stop at the source's duration. Recover the editable, host-length rate via the
  bundle header's **Extend Spin/Orbit to End** (re-reads the source file). **[by design]**
- **A referenced model file missing on disk blocks the import** — rather than mis-map
  the (positional) per-object restore, the import is refused with a message naming the
  missing file. Restore the file or fix its path. **[by design]** *(was a silent
  mis-map bug; fixed.)*
- **Old project files saved before the per-instance `modelPaths` fix** import only
  partially. **[gap, legacy]**

## Looping — Repeat to Fill Timeline

See [Timeline Editor ▸ Import bundles](docs/Timeline-Editor.md#import-bundles).

- **No "stop after N repeats"** — fill-to-end is the only mode. **[not built,
  deferred]** (wanted eventually for machinery that stops).
- **No seam smoothing** — each repeat is a hard cut back to the import's frame zero;
  you author the source so its last frame returns to its first. **[by design]**

## Glue & Export Model

See [Glue](docs/Glue.md).

- **Lights and effects can't be glued** — models only. **[gap / not built]**
- **Nested envelopes** (gluing a unit into a larger unit) work in the transform system
  but aren't exposed in the Glue dialog. **[not built]**
- **Export Model is baked** — a re-imported glued unit comes back as a flat multi-part
  model with **no joint hierarchy**; its parts can be spun and keyframed but **not
  orbited independently**. *Workaround: keep the original project with the live
  envelope for full per-member freedom.* **[by design — Forward Kinematics will
  address this]**

## Path Animators

See [Orbit](docs/Orbit-Path-Animator.md) · [Spin](docs/Spin-Path-Animator.md) ·
[Curve](docs/Curve-Path-Animator.md) · [Linear](docs/Linear-Path-Animator.md).

- **Curve and Linear write a *world* pose** — intended for root objects (cameras,
  lights, ungrouped models), not glued children. **[by design]**
- **Orbit / Spin / Curve replace the track from the first marker onward** and force
  linear easing for exact constant speed. Hand-keyed frames before the first marker are
  left alone. **[by design]**

## Duplicate model instances (same model loaded more than once)

See [Model loaded multiple times](docs/Model-Inspector.md).

- Object-level spin/orbit schedules and the camera-follow target now resolve the
  **correct** duplicate via occurrence/display-name identity (persisted across reload).
  The only remaining name-by-first ambiguity is the **cross-instance clipboard**, which
  isn't built yet (its design already uses occurrence identity). **[mostly fixed]**

## Rendering & Export

See [Export](docs/Export.md) · [Feedback](docs/Feedback.md).

- **Feedback forces single-slot (non-pipelined) export** — 4444/422 exports run a bit
  slower with feedback enabled. **[by design, performance]**
- **HDR reflections still appear over a solid background** — the reflection isn't
  masked out when the background is a solid color. *Workaround: set IBL intensity to
  0.* **[WAI]**

## Inspector / UI

See [Model Inspector](docs/Model-Inspector.md).

- **Euler X rotation is limited to ±90°** near the poles (gimbal lock); Y and Z cover
  the full ±180° cleanly. **[by design, math]**

## Not built yet (planned)

- **Forward Kinematics** — walk/wave Animation-Path preset helpers, and a
  hierarchy-preserving Glue export so complex rigs stay articulated. **[not built]**
- **Cross-instance copy/paste** — mirroring the coordinate/keyframe clipboard through
  the system pasteboard so two app instances can share copies. **[not built, queued]**
