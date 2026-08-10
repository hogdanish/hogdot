# hogdot

**A fork of the [Godot Engine](https://github.com/godotengine/godot) that renders through WebGPU on
the web.**

The WebGPU backend is **[GodotWebGPU](https://github.com/dwalter/godotwebgpu)**, by
[dwalter](https://github.com/dwalter). That project did the hard work: the driver, the SPIR-V to WGSL
pipeline, and every workaround the browser needed. hogdot carries it onto a current Godot release and
keeps it there. Authorship stays in this repository's history, and every ported commit cites the
GodotWebGPU commit it came from.

## Why it exists

hogdot has one consumer: **COMMONGROUNDS**, a multiplayer game that runs in the browser. That game
wants compute shaders and a modern graphics API, and Godot's web export ships WebGL 2. Every browser
it targets ships WebGPU today.

This is a long-term fork. Each new Godot release repeats the same rebase-forward exercise.

| | |
| --- | --- |
| Base | Godot **4.7.1-stable** |
| WebGPU source | GodotWebGPU, forked from Godot 4.6.2-stable |
| Target | **Mobile** renderer, **web** platform |
| License | MIT, the same as Godot |

## What hogdot adds on top of GodotWebGPU

**Godot 4.7 parity.** GodotWebGPU stopped at 4.6.2. hogdot moves the whole backend to 4.7.1 and makes
the release's new rendering work function on WebGPU: rectangular area lights (`AreaLight3D`) with
shadows, per-mesh light selection, the `DrawableTexture2D` and `BlitMaterial` texture-authoring API,
the rewritten clearcoat and reflection shading, and the discardable-texture rework. The 13 new
hardware-raytracing driver methods are stubbed, because no browser ships a WebGPU raytracing
extension.

**HDR display output on the web.** Godot 4.7 added HDR end to end and implemented none of it for web.
hogdot configures the WebGPU canvas for extended tone mapping, so an HDR panel gets real HDR. SDR
output is unchanged when the display or the browser cannot do it.

**Threaded web builds.** `threads=yes webgpu=yes` builds and delivers real parallelism, measured at
**2.86×** across four workers. Rendering stays on the browser main thread, because a `GPUDevice`
belongs to one JavaScript realm and no browser shares it across workers. Both a threaded and a
`nothreads` template are shipped.

**Correctness fixes.** A running review ledger tracks 49 findings against the port, from silent
under-lighting of area-lit meshes to an out-of-bounds write in the shader-stage tables. Real-game use
found three blockers beyond the reach of any engine test scene: `RDShaderFile`, `stencil_mode` materials
and direct `RenderingDevice` use were all broken, and all three are fixed. Custom `.glsl` shaders now
bake to portable SPIR-V at import, which is what makes them work in the browser.

**Less machinery.** The dead precompiled-WGSL path and two other unused mechanisms are deleted, the
two WGSL code paths are unified, and `glslang` is no longer a build dependency. Device work is pinned
to the render thread at the four sites that need it.

**A test surface.** `webgpu_tests/` holds a shader corpus that pushes engine SPIR-V through Tint, plus
gate scenes that exercise one rendering feature each in a browser and compare the result against a
native render.

## Building

```bash
# Web export templates — the reason this fork exists
scons platform=web target=template_release webgpu=yes opengl3=no threads=no num_jobs=4
scons platform=web target=template_release webgpu=yes opengl3=no threads=yes num_jobs=4

# Native editor — unchanged from mainline, and the cheap regression check
scons platform=macos target=editor
```

CAUTION: Pass `num_jobs=4` on web builds. The default job count compiles the Tint and SPIRV-Tools
sources in parallel and exhausts 24 GB of memory.

Web builds need an Emscripten toolchain. SCons gives the compiler no environment of its own, so
`ccache` and Emscripten's cache need `import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH,EM_CACHE`.

⚠ The two templates differ only by a file-name suffix: `threads=no` adds `.nothreads`. An export
preset that names the wrong zip fails at run time, not at export time.

## Limits

- **Mobile renderer only.** Forward+ features — SSAO, SSIL, SSR, volumetric fog, SDFGI, TAA, FSR2,
  subsurface scattering — are unavailable. That is Godot's own constraint on Mobile, not a WebGPU one.
- **No performance number exists.** Nothing compares hogdot against native Godot or against the
  WebGL 2 web export.
- **Chrome is the tested browser.** Safari and Firefox are largely unmeasured.

## Upstream and license

hogdot tracks [godotengine/godot](https://github.com/godotengine/godot) and is MIT-licensed, exactly
as Godot is. Read [Godot's own README](https://github.com/godotengine/godot#readme) for what the
engine is and what it does.

Bugs in this fork are the fork's own. Do not report them to the Godot project or to GodotWebGPU.
