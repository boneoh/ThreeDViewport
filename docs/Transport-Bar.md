# Transport Bar

The playback strip docked along the bottom of the main window. Always visible.

## Controls

| Control | Action |
|---------|--------|
| **⏹ Stop** | Stop and return the playhead to 0. |
| **▶ / ⏸ Play / Pause** | Toggle playback (also **P** in the viewport). |
| **Loop** | Toggle loop playback (also View ▸ Loop Playback). On loop wrap the feedback buffer clears. |
| **Playhead / time** | Shows the current time; the scrubber follows playback (throttled for UI smoothness). |
| **Duration** | Click to set the timeline duration. If keyframes exist you're prompted whether to **rescale** them to fit the new length. |
| **Add Keyframe** | Stamps a keyframe for the current mode/selection at the playhead (same as **I**). |
| **Export** | Opens the export flow. See [Export](Export.md). |

Transport buttons are disabled while an export is running.

## Playback timing

Playback advances by real wall-clock time, decoupled from the draw rate, so it
runs at 1× regardless of display refresh. Pausing freezes the playhead; nothing in
the scene animates while paused.

## Related

- The full keyframe view is the [Timeline Editor](Timeline-Editor.md) (**⌘J**).
- Playhead navigation keys (**Home/End**, **Tab/Shift+Tab**, **F/B**) are in the
  [keyboard reference](../KEYBOARD_REFERENCE.md).
