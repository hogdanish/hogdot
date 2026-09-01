# hogdot → CommonGrounds performance handoff

Ledger for agents working in the `commongrounds` repo. Written 2026-09-01 during the browser
rendering performance session; every number here was measured with `webgpu_tests/perf` on an M5
MacBook Pro in Google Chrome unless a row says otherwise. Read `webgpu_tests/perf/README.md` for
how to reproduce a figure.

## What changed in the engine (and what it means for the game)

| Change | Effect on a CommonGrounds frame | What the game should do |
| --- | --- | --- |
| Range-accurate flush of dynamic persistent buffers (`RD::buffer_flush(rid, offset, size)`) | Every canvas render (each SubViewport, the HUD) and each 3D instance-list upload used to push its whole ~2 MB buffer through `queue.writeBuffer`; 40 puppet viewports were ~150 MB/frame and half the CPU time of a frame. Now only the bytes actually written move. | Nothing. Automatic. If you call `RenderingDevice.buffer_flush` yourself, pass the written size. |
| Per-render-pass encoder split is off by default (`rendering/rendering_device/webgpu_encoder_isolation`) | One `queue.submit` per frame instead of one per render pass (65/frame on the 40-puppet bed, ~250/frame at 81 characters). | Nothing. If a frame ever renders black after a WebGPU validation error, set the project setting to `true` (or append `?webgpu_encoder_isolation` to the URL) to get the old damage-control behavior back, and report the validation error. |
| Redundant `setBindGroup` for material sets with dynamic offsets skipped | Consecutive draws sharing a material no longer rebind it. | Nothing. Sorting by material still helps (it always did). |
| Buffers carry labels (`buf <size> B usage=… dyn`) | `webgpu_tests/perf/head_include.js`'s writeBuffer census can attribute bytes per buffer kind. | Copy the head include into the game's shell if you want the same census in `/bench`. |

## How to measure the game the same way

- The page-side instrument is `webgpu_tests/perf/head_include.js`. It wraps
  `requestAnimationFrame` (busy time per frame = the CPU cost, not clamped by vsync) and the
  browser's `GPU*` prototypes (API calls and writeBuffer bytes per frame). It works on any
  template, hogdot or not. Inject it through the export preset's `html/head_include` (see
  `export.sh` for the one-liner conversion) and read `window.__bench.rafTail(n)` /
  `window.__bench.apiTail(n)` / `window.__bench.byLabelTop(n)`.
- `window.__cgPerf` (driver ring) is unchanged; `submit_ms` will now be one submit per frame.
- Judge CPU cost by rAF busy time, never by fps: at 120 Hz the display hides everything under
  8.3 ms, and at 60 Hz everything under 16.7 ms.
- Emulate a slower machine with Chrome DevTools CPU throttling (the runner's `--throttle 4`).
  The fork is CPU-bound in the browser on this hardware; a 4× slower CPU is the median laptop.

## Where the remaining cost is (after this session's fixes)

_To be filled from the post-optimization runs._

## Game-side recommendations (measured, not guessed)

_To be filled: SubViewport puppets, HUD churn, particles, hint_depth_texture._
