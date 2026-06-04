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
- **Background** — set dressing only, no FX, no Actor, no MacGuffin.
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

Three generators build whole keyframe tracks so you don't hand-key arcs:

- **[Orbit](Orbit-Path-Animator.md)** — moves an object along a helix / arc /
  corkscrew around a **world-space** Probe axis, aiming as it goes. Great for
  circling, rising spirals, sweeping camera moves.
- **[Linear](Linear-Path-Animator.md)** — a straight constant-velocity run between
  two points; shape the accel/decel with the track's easing.
- **[Spin](Spin-Path-Animator.md)** — a constant, **wobble-free self-spin** about
  the object's own local axis. It writes pure-rotation keyframes and forces linear
  easing, so the spin is dead steady (hand-keyed rotations drift off-axis and the
  spline easing overshoots — that's the wobble Spin avoids).

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

## Part 4 — A full pass through the pipeline

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
[Orbit](Orbit-Path-Animator.md) / [Linear](Linear-Path-Animator.md) /
[Spin](Spin-Path-Animator.md) Path Animators · [Timeline Editor](Timeline-Editor.md).
