# hogdot

A fork of [Godot 4.7.2](https://github.com/godotengine/godot) that renders through WebGPU on the web for [COMMONGROUNDS](https://hogdani.sh) (my game)

The WebGPU backend was borrowed directly from **[GodotWebGPU](https://github.com/dwalter/godotwebgpu)** by [dwalter](https://github.com/dwalter) who did all the hard work. This fork ports over his work to Godot 4.7.2 and adds a few additional features, fixes, and improvements on top of it.

## What this adds on top of GodotWebGPU

**Godot 4.7 parity**: GodotWebGPU is for 4.6.2, this fork brings it to 4.7.2 with full compatibility with new features, such as rectangular area lights (`AreaLight3D`) w/ shadows, per-mesh light selection, `DrawableTexture2D` and `BlitMaterial` texture-authoring API, rewritten clearcoat and reflection shading, the discardable-texture rework, etc.

**HDR display output on the web**: Godot 4.7 added HDR for all platforms except the browser. This fork enables extended tone mapping on the WebGPU canvas so an HDR panel gets actual HDR... in theory. HDR is really complicated

**Threaded web builds**: `threads=yes webgpu=yes` builds and measures around ~2.86x. Rendering stays on the browser main thread since a `GPUDevice` belongs to one JavaScript thread. Both threaded & a `nothreads` template are shipped, still not tested in production though.

**Misc. fixes and improvements**: Fixed many miscellaneous issues, such as `RDShaderFile`, `stencil_mode` materials and direct `RenderingDevice` use being broken, as well as [this user shader slot issue](https://github.com/dwalter/godotwebgpu/issues/1) from the [GodotWebGPU](https://github.com/dwalter/godotwebgpu) repo. Custom `.glsl` shaders (in my game, used for stencil outlines) now properly bake to portable SPIR-V at import and work in the browser now. A few other minor optimization fixes were tacked on to [dwalter's excellent work](https://github.com/dwalter/godotwebgpu).

## Building

```bash
# Web export templates
scons platform=web target=template_release webgpu=yes opengl3=no threads=no num_jobs=4
scons platform=web target=template_release webgpu=yes opengl3=no threads=yes num_jobs=4
```

Word to the wise: Pass `num_jobs=4` on web builds if you don't have a ton of memory because the default job count compiles the Tint and SPIRV-Tools sources in parallel and quickly exhausts 24 GB of memory on my machine.

## Limits

- **Mobile renderer only.** Forward+ features — SSAO, SSIL, SSR, volumetric fog, SDFGI, TAA, FSR2,
  subsurface scattering — are unavailable. That is Godot's own constraint on Mobile, not a WebGPU one.
- **No performance number exists.** Nothing compares hogdot against native Godot or against the
  WebGL 2 web export.
- **Chrome is the only tested browser.** Safari and Firefox are largely unmeasured.
- **No testing in production has been done.** My game isn't live yet, so this fork has not been tested in production. It is a work in progress.

## Upstream and license

hogdot tracks [godotengine/godot](https://github.com/godotengine/godot) and is MIT-licensed, exactly
as Godot is. Read [Godot's own README](https://github.com/godotengine/godot#readme) for what the
engine is and what it does.

Special thanks to [dwalter](https://github.com/dwalter) who, again, did 99% of the hard work here.

Bugs in this fork are the fork's own. Do not report them to the Godot project or to GodotWebGPU.
