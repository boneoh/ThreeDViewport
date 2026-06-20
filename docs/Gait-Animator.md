# Gait Path Animator

Walks (or runs, hops, or swims) an articulated **model** along a path through your
position marks: the whole model follows a smooth route at a set speed, turning to face
the direction of travel, while its **legs and arms cycle in step** — and, with foot
lock on, its planted feet stay glued to the ground as the body rolls over them.

It's forward kinematics baked to keyframes: nothing is solved at playback time. The
generated keyframes are ordinary tracks you can trim, retime, and ease like any other.

**Open:** Window ▸ Path Animator ▸ Gait…

## Requirements

- The target must be a **multi-part model (a group)** — it owns the root path plus the
  limb parts. Single-mesh objects can't walk.
- Limbs are matched to parts by **canonical joint name** (`hips`, `upper_leg_L/R`,
  `knee_L/R`, `upper_arm_L/R`, `elbow_L/R`, `neck`, …). Models built by
  `generate_character.py` already use these names; any rig that follows the same
  convention works. Missing joints are reported and simply skipped.
- The rig hierarchy must be preserved (it is, on import) so a rotation on `upper_leg_L`
  swings the whole leg. Foot lock additionally needs `upper_leg_L/R`, `knee_L`, and
  `foot_L`/`ankle_L`; without them the legs fall back to open-loop swinging.

## Workflow

1. **Drop position marks** along the route (`N` / Add Position Mark), one per waypoint.
2. **Open the panel** and pick the **model** to walk in *Model & Gait*.
3. **Choose the gait** — Walk / Run / Hop / Swim.
4. **Build the path** in *Path Marks*: add the marks you want and **put them in the
   order to be walked** (see below).
5. **Set Speed**, leave **Auto stride** on (or set Stride manually).
6. **Position the playhead** where the walk should begin — the *Start at playhead*
   readout shows the start time as `MM:SS:FF`; the walk always begins there.
7. **Create Keyframes** — bakes the root path and the limb cycle into the tracks.

## Path Marks — choosing and ordering

The path is the **ordered list** in *Path Marks*, not the marks' scene order:

- **Add ▾** includes a mark that isn't in the path yet (appended to the end).
- **↑ / ↓** reorder a mark in the walk sequence; **✕** removes it from the path.
- **All** adds every mark (scene order); **None** clears the path.
- The numbered list *is* the route: `1 → 2 → 3 …`. The model walks the marks in that
  order, so the same marks can describe different routes.

You need at least two marks in the path. The model follows a smooth **Catmull-Rom**
curve through them at constant speed, yawing so its front (+Z) faces the direction of
travel.

## Gaits

| Gait | Legs | Character |
|------|------|-----------|
| **Walk** | alternating | gentle swing, slight knee flex, light arm/forearm counter-swing, small bob |
| **Run** | alternating, brief airborne phase | bigger swing + knee flex, raised forearms, stronger bob |
| **Hop** | together | both legs crouch and spring together, arms pump, one airborne arch per cycle |
| **Swim** | flutter | body goes **prone** head-first, fast flutter legs, big alternating arm strokes, head tilts up |

Every gait **eases in from standing** at the first mark and **settles to standing** at
the last (over ~1 s at each end, capped to half a short path), so it starts and ends
clean instead of snapping into mid-stride. Swim additionally stands up, dives to prone,
swims, and stands again. On curves the body **banks into the turn** (scaled by speed and
how sharply the path bends; swim excepted).

## Parameters

- **Speed** (units/sec) — how fast the model travels the path.
- **Auto stride** (on by default) — derives the stride that **minimises foot-slip**
  from the model's own legs (`stride ≈ 4 · leg-length · sin(hip-swing)`). With it on,
  changing Speed changes the **cadence** (steps per second) at a constant step length —
  the natural way to go faster. Turn it off to set **Stride** (distance per full cycle)
  by hand.
- **Start at playhead** — the walk always begins at the current playhead position; the
  readout shows that time as `MM:SS:FF` (matching the viewport playhead).
- **Tuning** — per-channel multipliers (Swing / Knee / Arm / Bob), `1.0` = the gait's
  default amplitude, to dial the motion up or down.
- **Plant feet on marks** — drops the model so its **feet** meet the marks (instead of
  its hips/origin).
- **Foot lock (IK)** (on by default) — solves each leg so the **planted foot stays
  fixed on the ground** through its stance while the body passes over it (no skating);
  the swing foot arcs forward to the next step. Turn it off to compare against the
  plain open-loop leg swing. (Foot lock implies feet-on-ground so the targets are
  reachable.)

## Notes

- **Create Keyframes** clears this model's existing keyframes from the walk's start
  onward (root group track + every part) before baking, so a previous, longer walk
  leaves no tail.
- Arms, body bob, and turning lean stay procedural even with foot lock on; only the
  legs are IK-solved.
- The path-marks selection is **per session** (it isn't saved in the project); the
  panel restores your order when reopened and picks up newly-added marks.
- The bake is plain keyframes — shape acceleration with the track's
  [easing](Timeline-Editor.md), loop or retime it, or layer
  [Spin](Spin-Path-Animator.md) on top.

See also: [Linear](Linear-Path-Animator.md) · [Curve](Curve-Path-Animator.md) ·
[Orbit](Orbit-Path-Animator.md) · [Spin](Spin-Path-Animator.md) Path Animators ·
[Probe Inspector](Probe-Inspector.md).
