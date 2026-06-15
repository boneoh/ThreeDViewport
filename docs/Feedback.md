# Feedback (Delay-Line)

A video feedback / trail effect: each frame is blended with a delayed buffer of
earlier frames, producing echoes and trails. Runs in the viewport and export.

**Open:** Window ▸ Feedback…  ·  **⌘F**

## Controls

| Control | Description |
|---------|-------------|
| **Enabled** | Turns the delay-line on/off. |
| **Length** | Number of delayed frames held in the buffer. |
| **Decay** | How quickly the echoes fade. |
| **Interval** | Spacing between sampled delay frames. |
| **Blend mode** | How the delayed buffer composites over the current frame. |
| **Swap layers** | Reverses the composite order (delayed over current vs current over delayed). |
| **Clear** | Flushes the buffer (also auto-clears on loop wrap and when you scrub while paused). |

The panel shows a **priming / active** status while the buffer fills.

## Notes

- Feedback forces single-slot (non-pipelined) export, so 4444/422 exports run a bit
  slower with it enabled.
- The buffer is reset on each loop revolution so trails restart cleanly.
- **Feedback-off backdrop + a feedback-on transparent object in front:** per-object
  feedback is toggled in the **Effects** window (Window ▸ Effects). If an **opaque** object
  has feedback **off** (a stable, non-trailing backdrop) and a **transparent** object in
  front of it has feedback **on**, the transparent object composites over the sky / its
  own trail — *not* over the backdrop. It renders in front correctly, but its **trail
  can read as "behind"** the backdrop. (Putting the backdrop in the feedback lane fixes
  the layering, but then it trails too.)

## Persistence

All feedback settings are saved with the project (the buffer itself is transient).
