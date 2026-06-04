# Copy / Paste / Zero (Coordinate Clipboard)

Most panels with X/Y/Z fields show three small icons in the section header:

| Icon | Action |
|------|--------|
| 📄 **Copy** | Copies the section's current X/Y/Z values to a shared, app-wide clipboard. Always available (light blue). |
| 📋 **Paste** | Writes a previously copied value into this section. Light blue when a *matching* value has been copied; greyed out otherwise. |
| **Z** **Zero** | Sets the section's values to zero (or identity, for rotation). Shown where zeroing makes sense. |

The clipboard is **session-only** (it isn't saved with the project) and is **shared
across every panel**, so you can copy in one window and paste in another.

## Typed channels — paste is always type-matched

The clipboard keeps three separate slots so a paste can never land in the wrong kind
of field:

| Channel | Fields that use it |
|---------|--------------------|
| **Position** | Any **Position** field — **and Target/aim points** (a camera or light *Target* is itself a world position), plus Probe position, mark positions, and Path Animator axis/line points. |
| **Size** | Fog volume / weather emitter **Size**. |
| **Rotation** | Object **Rotation** (Euler degrees). |

Because Target shares the **Position** channel, you can copy a *position* and paste
it into a *Target* (and vice-versa). You **cannot** paste a Position into a Size or
Rotation field — those are different channels, which prevents, say, dropping a scale
into a translation by accident.

## Auto-stamp on animated tracks

If you Paste or Zero a Position/Rotation on something that **already has keyframes**,
the app stamps a keyframe at the current playhead so the change lands on the
timeline instead of being silently overwritten on the next frame. On un-animated
items it just sets the value.

## Examples

**Line two objects up on an axis**
Select object A → Model Inspector → **Copy** its Position. Select object B →
**Paste**. B now sits exactly where A is; tweak one axis to offset it.

**Aim a light (or the camera) at an object**
Select the object → **Copy** its Position. Open Lights & Background (or the Camera
panel) → in the light's/camera's **Target** section, **Paste**. The light/camera now
points right at the object's location. (Re-copy and re-paste after moving the object
to re-aim.)

**Send the Probe to an object, then mark it**
Copy an object's Position → open the Probe Inspector → **Paste** into the Probe
Position → **Mark Position**. You've dropped a named reference exactly on the object.
The reverse works too: cycle to a mark (**N**) to move the Probe there, then **Copy**
the Probe position and paste it wherever you need it.

**Feed a Path Animator from a known point**
Copy a Probe/mark/object position, then **Paste** it into a
[Rotation](Rotation-Path-Animator.md) axis point or a
[Linear](Linear-Path-Animator.md) line point instead of re-positioning the Probe.

**Match a camera target to a light target**
Copy a light's Target → Paste into the Camera panel's Target so both aim at the same
spot.

**Reset to origin**
Use **Z** to snap a Position or Target back to `(0, 0, 0)`, or a Rotation back to
identity — handy for re-centering after experimenting.

## Where you'll find the buttons

[Probe Inspector](Probe-Inspector.md) · [Camera Panel](Camera-Panel.md) ·
[Model Inspector](Model-Inspector.md) · [Lights & Background](Lights-and-Background.md) ·
[Atmosphere](Atmosphere.md) · [Rotation](Rotation-Path-Animator.md) /
[Linear](Linear-Path-Animator.md) Path Animator.
