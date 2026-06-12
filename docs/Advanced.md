# Advanced — Putting It Together

The other pages are reference chapters, one feature each. This page is a **guide**:
it walks through how the pieces combine into real workflows — building layered
motion, and cutting a scene into clean compositing passes for DaVinci Resolve or an
LZX video synthesizer rig.

If a term is new, follow the link to its chapter. Here we focus on how they play
together.

---

## Part 1 — Surveying and placing the scene

Before you animate or export, you usually need to put things in **exact** places —
an object here, a light aimed there, a camera framed just so, an orbit centred on a
precise point. Three small tools turn that from eyeballing into something exact and
repeatable: the **Probe** (a movable world cursor), **Marks** (saved named
positions), and the **Copy / Paste** coordinate clipboard.

### The shared clipboard is the glue

Every panel with X/Y/Z fields has **Copy / Paste / Zero** icons backed by one
**app-wide, type-matched clipboard** (see [Copy / Paste / Zero](Coordinate-Clipboard.md)).
The key idea: the **Position** channel is shared by *every* world-space point —
object positions, the Probe, mark positions, **camera/light Targets** (an aim point
*is* a position), and even **Path Animator axis/line points**. So a single copied
coordinate can travel anywhere a position is expected. (Paste is channel-locked, so
a Position can never land in a Size or Rotation field by accident.)

### The Probe is your cursor and tape measure

Park the [Probe](Probe-Inspector.md) anywhere with its sliders (arrow keys nudge by
the last digit), then **Copy** its position and paste it where you need it — into an
object's Position, a light's Target, an orbit axis point. It works in reverse too:
**Copy** an object's position and **Paste** it into the Probe to send the Probe
exactly there.

### Marks are a reusable scaffold of named points

A [Mark](Probe-Inspector.md) is a saved, named, colour-coded world position. Drop
them at the spots that matter — a hero's first and last positions, where a light
should aim, the centre of an orbit. Then:

- **K** shows/hides all marks (they can also render into exports for dialing a take).
- **N** / **Shift+N** cycle through them and **move the Probe to each one**, so its
  coordinates are immediately ready to **Copy**.

Marks persist with the project, so the scaffold survives across sessions.

### Recipes that combine all three

- **Place an object exactly on a reference.** Cycle to a mark (**N**) → the Probe
  jumps there → **Copy** the Probe position → select the object → **Paste** into its
  Model Inspector Position. (Or copy object A's position straight onto object B.)
- **Aim a light or the camera at a point.** **Copy** an object or mark position →
  **Paste** into the light's / camera's **Target**. Re-copy and re-paste to re-aim
  after things move.
- **Lay out a motion against references.** Drop a row of same-colour marks where a
  subject should be over time, then key against them: cycle **N**, **Copy**, and
  **Paste** onto the animated object — because pasting onto an already-animated item
  **auto-stamps a keyframe** at the playhead.
- **Seed a Path Animator from known points.** Mark the two ends of an orbit axis,
  cycle to each, **Copy**, and **Paste** into the
  [Orbit](Orbit-Path-Animator.md) animator's **Capture Axis Start / End** — an exact,
  repeatable orbit centre instead of a hand-dragged Probe (this feeds Part 3).
- **Anchor a Glue unit deliberately.** Drop a mark at the intended pivot, send an
  object's origin there first, then [glue](Glue.md) with that object as the anchor so
  the unit rotates around the point you chose.

These named points and copied coordinates become the raw material for the motion in
Part 3 and the framing for the passes in Part 2.

---

## Part 2 — Thinking in layers and passes

Most of the power in ThreeDViewport comes from **separating a scene into layers you
can recombine later** in a compositor. Three features cooperate to do that:
**mattes**, **holdouts**, and **occlusion**. Get the mental model right and
[Export All Passes](Export.md) becomes obvious.

### Mattes — the silhouette of what matters

A **matte** is a black-and-white image where white = "this is my subject" and black
= "ignore." ThreeDViewport gives you mattes two ways:

- **Live, in the viewport:** the **Render Mode** toggle (**G**) cycles
  Greyscale → Color → **Black + White**. In Black + White every object renders as a
  solid **white silhouette on black** — a luma matte you can eyeball before
  committing to an export.
- **In the file, on export:** with **ProRes 4444**, *color* passes carry the matte
  in the **alpha channel** (alpha = Rec.709 luma, premultiplied — the RGB stays at
  full brightness while a ready-made key rides along), and *matte* passes carry a
  **geometry-coverage alpha** (1 = geometry, 0 = background). See
  [Export](Export.md) for the codec table.

This matters for the synth pipeline: an LZX FKG3 module can key on **luma** (the white
silhouette), so a Black + White matte pass is what it wants. Resolve, by contrast,
can blend on the **4444 alpha**. Same scene, two delivery shapes.

### Holdouts and occlusion — cutting clean holes

A matte of the whole scene isn't enough — you usually want one subject's matte with
*everything in front of it punched out*, so the layers stack correctly. That's what
**holdouts** do.

In the [Model Inspector](Model-Inspector.md), every object has **Occlude when
hidden** (holdout, default on). The rule:

- **Visible object** → drawn normally.
- **Hidden + holdout on** → not drawn, but still **occludes** — it's rendered
  depth-only *before* the visible geometry, so anything behind it is cut to
  background.

That depth-only pass is the **occlusion** mechanism. Practically: hide the object
that should "bite a hole," leave holdout on, and the subject behind it comes out
with a clean silhouette gap where the foreground object sits — no manual rotoscoping.

### Bringing it together: Export All Passes

[Export All Passes](Export.md) (**⌘⇧E**) automates exactly this layering. Tag each
object's **class** (Actor / Background / MacGuffin) in the
[Model Inspector](Model-Inspector.md), pick one codec, and it renders a whole cycle:

- **Scene** — everything, with FX.
- **Actor Solo / Matte** — just the actors (solo = lit, matte = white silhouette),
  everything else **held out** so the actor's edges stay clean.
- **Background** — set dressing only, over the real backdrop, no FX.
- **Background Matte** — white silhouette of the set dressing on black.
- **MacGuffin Solo / Matte** — your hero prop, isolated the same way.
- **FX Solo / Matte** — the effects layer on black.

Every pass starts with the same **3-2-1 countdown + white flash frame**, so the
separate `.mov` files line up frame-accurately on a Resolve timeline. The takeaway:
*classes + holdouts + matte mode* are the three dials; Export All just turns them
for you, consistently, across the whole set.

> **Recipe — a keyable actor over a CG background for the synth:**
> 1. Class the character **Actor**, the set **Background**.
> 2. Leave holdout on for both.
> 3. Export All on **ProRes 4444**.
> 4. Feed the **Actor Matte** (white silhouette) to the FKG3's key input and
>    the **Background** pass to a fill input — the foreground props that overlap the
>    actor are already punched out of the matte.

---

## Part 3 — Building motion that composes

Motion in ThreeDViewport is **layered** too. Each track contributes a piece, and
the renderer multiplies them together, so you can author one clean motion at a time
instead of hand-keying a tangled whole.

### Glue — rigid relationships and shared motion

[Glue](Glue.md) binds objects to an **envelope** (a null parent). Keyframe the
envelope and the whole unit moves as one; keyframe a member and it moves *within*
the unit. The envelope's origin sits at the **anchor** you choose, which becomes the
pivot the unit rotates around.

The important property: **a member's own animation composes on top of the
envelope's.** That's what lets you build compound motion cleanly.

### The Path Animators — generated motion without the wobble

Four generators build whole keyframe tracks so you don't hand-key arcs:

- **[Orbit](Orbit-Path-Animator.md)** — circles an object on a **planar** (constant-
  height) ring around a **world-space** Probe axis, aiming at the centre. Driven by
  **rate markers**: set a rev/s rate, drop a keyframe, and it holds that rate until
  the next marker (rate 0 stops). Great for turntables and sweeping fly-arounds.
- **[Linear](Linear-Path-Animator.md)** — a straight constant-velocity run between
  two points; shape the accel/decel with the track's easing.
- **[Curve](Curve-Path-Animator.md)** — a flat spiral arc from a start to an end
  point *around* an aim point, easing its radius in or out — for arcing reveals and
  swooping moves that also travel across the scene.
- **[Spin](Spin-Path-Animator.md)** — a constant, **wobble-free self-spin** about
  the object's own local axis, also driven by **rate markers**. It writes pure-
  rotation keyframes and forces linear easing, so the spin is dead steady (hand-keyed
  rotations drift off-axis and the spline easing overshoots — that's the wobble Spin
  avoids).

### Layering them: B orbits A *and* spins

This is the canonical compound move, and it shows all three motion features working
together:

1. **[Glue](Glue.md)** B to A with **A as the anchor**.
2. Select the **envelope** and run the **[Orbit](Orbit-Path-Animator.md)** animator
   → the unit revolves, so B circles A.
3. Select **B's lane** in the [Timeline Editor](Timeline-Editor.md) and run the
   **[Spin](Spin-Path-Animator.md)** animator → B turns on its own axis.
4. Play. The orbit lives on the envelope; the spin lives on B; the renderer
   composes them. Either can be retimed or re-eased independently.

Use the right generator for each layer: **Orbit on the parent** for the path,
**Spin on the child** for the self-rotation. (The Orbit animator writes a *world*
pose, so run it on a root/envelope — not directly on a glued child, where it would
be reinterpreted in the envelope's frame.)

### Vector Path — see the motion before you commit

Press **V** to toggle the **keyframe motion-path overlay** (the "vector path"). It
draws the path of the **currently active entity** — the camera in Camera/Director
mode, a light in Light mode, the selected object/group in Object/Model mode — as a
line through its keyframes, right in the viewport.

It's an authoring aid, not part of the render: turn it on to confirm an orbit's
radius and centering, check that a glued member's spin isn't secretly translating,
or judge spacing before exporting. It follows your selection, so flip between the
envelope and a member to compare their separate contributions.

---

## Part 4 — Reuse: exported models and looping clips

Once a sub-assembly or a piece of motion is right, you rarely want to rebuild it. Two
features turn finished work into reusable building blocks: **Export Model** bakes
geometry you can re-import anywhere, and **Repeat to Fill Timeline** loops a short
imported clip across a whole shot. Together they let you assemble big scenes from small,
polished pieces instead of authoring everything in one giant project.

### Bake a sub-assembly into a reusable model

[Glue](Glue.md) the parts of a thing — a robot, a lamp, a planet-and-rings — into one
unit, then select the envelope and **File ▸ Export Model…** to write the whole unit as a
single **.glb**, with material overrides, [Brightness](Model-Inspector.md#brightness-self-emission),
and textures **baked in**. Re-import it as one object and build larger scenes from these
sub-assemblies.

Export Model isn't envelope-only — it exports whatever is selected: a single tinted
shape, a whole multi-part model, or an envelope's subtree. So you can finish one prop in
the [Model Inspector](Model-Inspector.md) and bake it directly, no gluing required.

> **The export is baked — and the glue cannot be undone.** Glue is a
> ThreeDViewport-only relationship (which parts belong to the envelope, the anchor, each
> member's base transform). It lives **only in the `.3dvp` project file** — glTF has no
> concept of it, so **none of it is written to the `.glb`.** The exporter flattens every
> member's glued-arrangement transform into the geometry. A re-imported unit comes back as
> an ordinary multi-part model — its former members are now plain **parts**, frozen in
> their glued positions, with **no Unglue**. You can still
> [Spin](Spin-Path-Animator.md) or keyframe an individual part, but a part can no longer
> be **orbited** independently (Orbit writes a world pose that only applies to
> roots/envelopes), and you can never re-anchor it, swap a member, or re-glue it
> differently.
>
> **So always keep the source project.** The `.3dvp` you built the envelope in is the
> only thing that holds the live, editable glue. Treat the `.glb` as a one-way **delivery
> format** and archive its source project alongside it. See
> [Glue ▸ Export the glued unit as a model](Glue.md#export-the-glued-unit-as-a-model).

### Build a short, loopable clip project

The companion move to baking geometry is baking **motion** — a small, self-contained
`.3dvp` that does one thing and loops:

1. **Start small.** A few models (your exported `.glb` sub-assemblies or plain models)
   and one simple motion — a turntable, a machine cycle, a planet circling a star, a
   light pulsing.
2. **Design it to loop.** The repeat is a **hard cut** back to the import's frame zero;
   ThreeDViewport does **not** smooth the seam — that's your job. Make the last frame
   land on the first frame's pose: key a full **360°** with a [Spin](Spin-Path-Animator.md)
   or [Orbit](Orbit-Path-Animator.md) rate marker (exact by construction), or return any
   animated value to its starting number.
3. **Mind the clip's duration.** The loop length is the clip's **whole timeline
   duration** (frame zero → last frame), not just the keyframed span. Any quiet lead-in
   or lead-out you leave in the timeline repeats too — so you can build deliberate pauses
   *between* cycles by padding the ends. The first keyframe need not sit at frame zero,
   nor the last at the final frame.
4. **Optionally mark the loop window.** Set In / Out
   [timeline marks](Timeline-Editor.md#in--out-marks) on the clip so the importer can
   bring in exactly that slice.

### Import it and repeat to fill

In the host scene, **File ▸ Import Project…** brings the clip in as a
[bundle](Timeline-Editor.md#import-bundles). Right-click the bundle header ▸ **Repeat to
Fill Timeline** and it tiles forward to the end of the host timeline.

- Repeats draw **dark green and are locked** — they regenerate from the editable first
  cycle. Tweak the first cycle (drag or stamp a keyframe) and every repeat follows.
- Slide the whole loop in time by dragging the bundle's span bar; the repeats re-tile.
- **Lengthen the host timeline later and it refills by itself** — no re-import, so your
  edits to the imported group are safe. Shorten it and the extra repeats trim away.
- Each import loops on its **own** period. Bring in several short clips at different
  start times — ticking machinery, a spinning planet, a flickering sign — and repeat
  each; they cycle independently and layer into a living scene.

> **Recipe — a planet orbiting a star, forever:**
> 1. New project: a star (give it [Brightness](Model-Inspector.md#brightness-self-emission))
>    and a planet.
> 2. [Orbit](Orbit-Path-Animator.md) the planet around the star with a rate marker, and
>    set the clip's timeline duration to **exactly one revolution** so the planet returns
>    to its start pose.
> 3. Save the clip.
> 4. In the main shot, **Import Project…** → right-click the bundle ▸ **Repeat to Fill
>    Timeline**. The planet now circles for the whole shot — extend the timeline and it
>    keeps going.

---

## Part 5 — A full pass through the pipeline

Tying it all together, a typical shot:

1. **Block the scene.** Load models, then place them precisely with the
   [Probe, Marks, and Copy/Paste](Probe-Inspector.md) — drop reference marks for hero
   positions, light aims, and orbit centres. Set object **classes** (Actor /
   Background / MacGuffin) in the [Model Inspector](Model-Inspector.md), leave
   **holdout** on.
2. **Build the motion.** [Glue](Glue.md) anything that should move as a unit, then
   use the [Orbit](Orbit-Path-Animator.md) / [Linear](Linear-Path-Animator.md) /
   [Spin](Spin-Path-Animator.md) animators to generate the layers. Refine timing and
   easing in the [Timeline Editor](Timeline-Editor.md).
3. **Preview.** Toggle **V** to sanity-check each entity's path; scrub to confirm the
   layers compose as intended; flip to **Black + White** (**G**) to preview the
   mattes.
4. **Export.** [Export All Passes](Export.md) on the codec your finishing tool wants
   — 4444 for Resolve (luma-alpha color + coverage mattes), 422 for a
   plain colour-grade chain using FKG3.
5. **Composite.** Line the passes up on the white flash frame; key the matte passes,
   stack the solos over the background, add the FX layer last.

---

See also: [Probe Inspector](Probe-Inspector.md) ·
[Copy / Paste / Zero](Coordinate-Clipboard.md) · [Export](Export.md) ·
[Model Inspector](Model-Inspector.md) · [Glue](Glue.md) ·
[Import Project](Import-Project.md) ·
[Orbit](Orbit-Path-Animator.md) / [Linear](Linear-Path-Animator.md) /
[Spin](Spin-Path-Animator.md) Path Animators · [Timeline Editor](Timeline-Editor.md).
