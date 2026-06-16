# Limits & Clamps

Every user-facing limit in the app is defined in one place —
`Sources/ThreeDViewport/Scene/SceneLimits.swift`. Change a value there and it takes
effect everywhere it's used. This doc explains what each limit is and how you know
when you hit one.

## Two kinds of limit

**World-space movement clamps** apply when you move something in the viewport with
the keys, mouse drag, or scroll wheel. There's no slider to show you the edge, so
hitting one is **not silent**: it plays a beep (throttled, so holding a key against a
limit doesn't machine-gun) and writes a `[LIMIT] …` line to the log when diagnostic
logging is on (see below).

**Inspector slider ranges** are the min…max each panel slider allows. These stop
visibly at the slider handle, so they don't beep.

## World-space movement clamps

| Limit | Value | Applies to | Beeps + logs as |
|---|---|---|---|
| Position bound | **±100** per axis | object / model / light / probe moved by keys, drag, scroll | "Object/Model/Light/Probe position" |
| Depth-dolly near limit | **0.5** | closest a `+` / scroll depth move pulls an entity toward the eye | "Depth dolly (near limit)" |
| Depth-dolly world bound | **±100** along the ray | a `+` / scroll depth move that would leave the ±100 box | "Depth dolly (world bound)" |
| Lens FOV (zoom) | **10° – 90°** | `+` / `−` in Camera mode; `⌘+` / `⌘−` for the Director | "Lens FOV" / "Director FOV" |

The position bound is the same number the position **sliders** enforce, so the
viewport and the inspectors agree.

**Clamped silently (no beep yet):** the **camera target** hitting ±100 while panning,
and the **camera/Director orbit distance** (0.05–5000) — the latter is visible as the
zoom simply stopping. The camera-target clamp lives in a `didSet` that also runs during
playback, so beeping there would fire on every keyframe; wiring a playback-safe report
for camera pan is a possible follow-up.

## Inspector slider ranges

All defined in `SceneLimits.swift`. Current values:

- **Transform:** Position ±100, Rotation ±180°, Scale 0.01–10
- **Camera:** Focal length 12–140 mm, POV distance 0.05–5, azimuth ±180°, elevation ±90°
- **Lights:** Intensity 0–10, Range 0–50, cone 0–90°, beam thickness 1–30, IBL 0–2, HDRI backdrop intensity 0–4 / horizon −1…1
- **Atmosphere:** density 0–1, variance 0–1, fog quality 8–96, fog size 0.5–40; emitter size 0.005–0.5, lifetime 0.5–12, growth 0–12, opacity 0.02–1, fall speed 0–20, streak 1–16
- **Material overrides:** Metallic / Roughness / Opacity / Brightness 0–1
- **Feedback:** Decay 0–1, Interval / Length 1–60 frames
- **Color Grade:** Exposure 0.1–4, Brightness −1…1, Contrast 0–3, Gamma 0.2–3
- **Settings:** movement sensitivity 0.1–10×

## Diagnostic logging

The `[LIMIT]` lines (and other diagnostics) print only when logging is on. Toggle it
in **Settings ▸ Diagnostics ▸ Enable diagnostic logging** — it persists and takes
effect immediately, no relaunch. The same toggle also enables per-frame performance
logging. Launching with `--perf-log` forces logging on regardless of the setting.

Logging is gated by `AppLog` (a fast static flag) and clamp reporting by
`LimitReporter` (beep + `AppLog`), both in `Sources/ThreeDViewport/App/`.
