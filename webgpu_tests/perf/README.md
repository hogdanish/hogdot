# hogdot perf bed

CommonGrounds-shaped rendering benchmarks for the WebGPU backend, runnable against any web
template (hogdot, GodotWebGPU 4.6.2, stock Godot) from one exported project.

```
project/            Godot project. Scenes are built in GDScript (no imported assets), picked by
                    ?scene=<key>; every scene extends bench_scene.gd and prints [CGBENCH] lines.
head_include.js     Page-side instruments injected into html/head_include by export.sh:
                    rAF busy time, long tasks, WebGPU API call census, writeBuffer byte census.
export.sh           Export the bed with a given editor + template into exports/<label>.
bench.mjs           Playwright runner: serves an export, drives Chrome, records JSON per run,
                    prints a Markdown comparison. --throttle N, --profile, --runs N, --fresh.
results/<tag>/      One JSON per (label, scene) plus SUMMARY.md and .cpuprofile files.
HANDOFF.md          What CommonGrounds needs to know from the measurements.
```

## Scenes

| key | what it emulates | ramp |
| --- | --- | --- |
| `world` | the whole CommonGrounds frame: sky+glow+fog+AgX, sun shadows, props, puppets in 600² SubViewports, soft particles + omni bursts, water (depth+screen texture), HUD | params `chars vp particles props hud water` |
| `sprites3d` | puppet SubViewports shown as two billboard Sprite3Ds | chars 0/27/81/162 |
| `particles` | GPUParticles3D bursts with proximity fade | emitters 8/32/96 |
| `draws` | per-draw cost, unique materials, rotating | n 128/512/2048/4096 |
| `ui` | CanvasLayer HUD widgets with changing labels | widgets 64/256/1024 |
| `postfx` | environment stack cost over fixed geometry | bare → sky → +glow → +fog → scale 1.0 |
| `shadows` | shadow-casting omni lights over 300 props | omni 0/2/4/8 |
| `spawn` | hitches: new material/shader variants introduced mid-run | base → materials → particles → shaders → puppets |

Common query params: `frames` (measured frames per phase, default 240), `warm` (discarded
frames per phase, 40), `scale` (3D scaling), `hold` (stay on screen after the report).

## Metrics per phase line

- `fps`, `frame_p50/p95/p99/max` — `_process` delta (rAF-to-rAF on web; clamped by vsync).
- `busy_p50/p95/max` — time inside the rAF callback: the real CPU cost of a frame. Web only.
- `warm_max_ms` — longest frame during the phase's warm-up (where first-use compiles land).
- `hitch50` — measured frames over 50 ms. `longtasks`/`longtask_ms` — browser long tasks.
- `api_*` — WebGPU calls per frame (`wb` writeBuffer, `wb_kb`, `submit`, `rp` render passes,
  `draw`, `setbg`, `setpipe`, `setvb`, `setib`, `dispatch`, …), any build.
- `drv_*` — hogdot driver ring (`__cgPerf`): `drv_cpu_p50`, `drv_draws`, `drv_setbg`, `drv_rp`,
  `drv_submit_p50/p95`, `drv_fence_neg`, `drv_pipes`. `na` on builds without the channel.
- `compiles`/`compile_ms` — driver pipeline/module creation records inside the phase (hogdot).
- `eng_draws/objects/prims`, `vram_mb` — Godot's own monitors.

`na` means not measured, never zero.

## Typical session

```bash
# 1. templates + editor from the same commit (see the build-export skill), then:
webgpu_tests/perf/export.sh --template bin/godot.web.template_release.wasm32.nothreads.zip \
    --out webgpu_tests/perf/exports/hogdot-main
# 2. run
node webgpu_tests/perf/bench.mjs --export main=webgpu_tests/perf/exports/hogdot-main \
    --scenes world,sprites3d,draws --tag main-$(date +%m%d)
# compare builds, emulate a slower CPU, profile
node webgpu_tests/perf/bench.mjs --export a=exports/before --export b=exports/after --throttle 4
node webgpu_tests/perf/bench.mjs --export main=exports/hogdot-main --scenes world --profile
```

Playwright comes from `webgpu_tests/scene_smoketest/node_modules`. The runner uses installed
Google Chrome (`channel: 'chrome'`) with a visible window; keep it visible — Chrome stops
`requestAnimationFrame` in hidden tabs and pauses occluded windows, and the scene marks such a
phase `stale`.

Native check of the scripts: `bin/godot.macos.editor.arm64 --path webgpu_tests/perf/project -- --scene=world --warm=5 --frames=20`.
