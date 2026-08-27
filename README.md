# hogdot

<p align="center">
  <a href="https://godotengine.org">
    <img src="misc/logo/hogdot_logo_outlined.svg" width="400" alt="Hogdot Engine logo">
  </a>
</p>

A custom fork of [Godot 4.7.2](https://github.com/godotengine/godot) developed for my game, [COMMONGROUNDS](https://hogdani.sh)

The WebGPU work was directly borrowed from **[GodotWebGPU](https://github.com/dwalter/godotwebgpu)** by [dwalter](https://github.com/dwalter). This fork ports over his work to Godot 4.7.2 and adds a few additional features, fixes, and improvements on top of it.

## What this adds on top of GodotWebGPU

**Godot 4.7 parity**: This fork brings [dwalter](https://github.com/dwalter)'s WebGPU support to Godot 4.7.2 with full compatibility with new features, such as rectangular area lights (`AreaLight3D`), stencil outlines, per-mesh light selection, `DrawableTexture2D` and `BlitMaterial` texture-authoring API, rewritten clearcoat and reflection shading, the discardable-texture rework, and other 4.7.x specific additions.

**HDR display output on the web**: Godot 4.7 added HDR for all platforms except the browser. This fork enables extended tone mapping on the WebGPU canvas so an HDR panel gets actual HDR (... in theory. HDR is really complicated)

**Threaded web builds**: `threads=yes webgpu=yes` builds and gives around ~2.86x better performance. Rendering stays on the browser main thread since rendering is locked to a single JS thread. Both threaded & a `nothreads` template are shipped, neither are tested in production though.

**Misc. fixes and improvements**: Fixed many miscellaneous issues from the original fork, such as `RDShaderFile`, `stencil_mode` materials and direct `RenderingDevice` use being broken, as well as [this user shader slot issue](https://github.com/dwalter/godotwebgpu/issues/1) from the [GodotWebGPU](https://github.com/dwalter/godotwebgpu) repo. Custom `.glsl` shaders (in my game, used for stencil outlines) now properly bake to portable SPIR-V at import and work in the browser now. A few other minor optimization fixes were tacked on to [dwalter's excellent work](https://github.com/dwalter/godotwebgpu).

## Building

```bash
# Threads disabled
scons platform=web target=template_release webgpu=yes opengl3=no threads=no

# Threads enabled
scons platform=web target=template_release webgpu=yes opengl3=no threads=yes
```

## Limitations

- **Mobile renderer only**: Forward+ features such as SSAO, SSIL, SSR, volumetric fog, SDFGI, TAA, FSR2, etc. are unavailable.
- **Chrome is the only tested browser:** Safari and Firefox are confirmed working but have not been thoroughly tested. Chrome provides best results.
- **Not battle tested**: This hasn't been tested in production and is subject to change as I develop my game. Use at your own risk.

## CI and releases

This fork exists to ship one thing: WebGPU web export templates (plus the Linux editor that bakes
their shaders) to [COMMONGROUNDS](https://hogdani.sh). CI is deliberately trimmed to match and
**diverges from upstream Godot's by design**: pushes run static checks, the web template matrix
(the two `webgpu=yes` wasm32 builds plus one vanilla wasm32 canary), and a single linuxbsd editor
build. The android/ios/macos/windows workflows are still in-tree but are not called — those
platforms ship on official Godot, not this fork.

Engine artifacts are published by the `cg_release.yml` workflow: pushing a `cg-v*` tag builds the
linuxbsd editor (with `tint_convert_cli`) and all four production web templates from that one
commit and attaches them, with sha256 digests, to a GitHub Release.

## Upstream and license

hogdot tracks [godotengine/godot](https://github.com/godotengine/godot) and is MIT-licensed, exactly
as Godot is. See [Godot's own README](https://github.com/godotengine/godot#readme) and [LICENSE](https://github.com/godotengine/godot/blob/master/LICENSE).

Special thanks to [dwalter](https://github.com/dwalter) who, again, did 99% of the hard work here.

**Bugs in this fork are the fork's own. Do not report them to the Godot project or to GodotWebGPU.**
